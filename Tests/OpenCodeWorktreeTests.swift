import Foundation
import Testing
@testable import byot

@Suite("Worktree models")
struct OpenCodeWorktreeModelTests {
    @Test("Create answers decode with name and branch; listed folders fall back to their name")
    func decoding() throws {
        let created = try JSONDecoder().decode(OpenCodeWorktree.self, from: Data("""
            {"name":"my-feature","branch":"opencode/my-feature","directory":"/data/worktree/p1/my-feature"}
            """.utf8))
        #expect(created == OpenCodeWorktree(directory: "/data/worktree/p1/my-feature", name: "my-feature",
                                            branch: "opencode/my-feature"))
        let detached = try JSONDecoder().decode(OpenCodeWorktree.self, from: Data(#"{"name":" ","directory":"/w/calm-river/"}"#.utf8))
        #expect(detached.name == "calm-river" && detached.branch == nil)
        #expect(OpenCodeWorktree(directory: "/w/misty-island").name == "misty-island")
        #expect(OpenCodeWorktree.key("/w/misty-island//") == "/w/misty-island")
        #expect(OpenCodeWorktree.key("/") == "/")
    }

    @Test("Names are slugged like the server, so the sheet can name the branch it creates")
    func naming() {
        #expect(OpenCodeWorktreeNaming.slug("  My Feature!  ") == "my-feature")
        #expect(OpenCodeWorktreeNaming.slug("--Fix #42: Crash--") == "fix-42-crash")
        #expect(OpenCodeWorktreeNaming.slug("café au lait") == "caf-au-lait")
        #expect(OpenCodeWorktreeNaming.slug("!!!").isEmpty)
        #expect(OpenCodeWorktreeNaming.branch(for: "Login Flow") == "opencode/login-flow")
        #expect(OpenCodeWorktreeNaming.branch(for: "   ") == nil)
        #expect(OpenCodeWorktreeNaming.branch(for: "***") == nil)
    }

    @Test("Global events unwrap their payload; sync records without an ID or properties still decode")
    func globalEvents() throws {
        func decode(_ json: String) throws -> OpenCodeEvent {
            try JSONDecoder().decode(OpenCodeEvent.self, from: Data(json.utf8))
        }
        let connected = try decode(#"{"payload":{"id":"evt_1","type":"server.connected","properties":{}}}"#)
        #expect(connected.type == "server.connected" && connected.location == nil)
        #expect(OpenCodeWorktreeEvent(connected) == .connected)

        let ready = try decode("""
            {"directory":"/w/my-feature","project":"p1","payload":{"type":"worktree.ready",
             "properties":{"name":"my-feature","branch":"opencode/my-feature"},"id":"evt_2"}}
            """)
        #expect(ready.id == "evt_2" && ready.location?.directory == "/w/my-feature")
        #expect(ready.properties["branch"]?.stringValue == "opencode/my-feature")
        #expect(OpenCodeWorktreeEvent(ready) == .ready(directory: "/w/my-feature"))

        let failed = try decode(#"{"directory":"/w/x/","payload":{"type":"worktree.failed","properties":{"message":"fatal: bad ref"}}}"#)
        #expect(OpenCodeWorktreeEvent(failed) == .failed(directory: "/w/x", message: "fatal: bad ref"))
        let silent = try decode(#"{"directory":"/w/x","payload":{"type":"worktree.failed","properties":{}}}"#)
        #expect(OpenCodeWorktreeEvent(silent) == .failed(directory: "/w/x", message: "OpenCode couldn’t check out the worktree."))

        let sync = try decode(#"{"directory":"/w/x","project":"p1","payload":{"type":"sync","syncEvent":{"id":"evt_3","seq":0}}}"#)
        #expect(sync.id.isEmpty && sync.type == "sync" && sync.properties.isEmpty)
        #expect(OpenCodeWorktreeEvent(sync) == nil)
        let global = try decode(#"{"directory":"global","payload":{"type":"worktree.ready","properties":{"name":"x"}}}"#)
        #expect(global.location == nil)
        #expect(OpenCodeWorktreeEvent(global) == nil, "A readiness report must name its worktree")

        // Instance and v2 events decode as before.
        let instance = try decode(#"{"id":"evt_4","type":"session.idle","properties":{"sessionID":"ses_1"}}"#)
        #expect(instance.sessionID == "ses_1" && instance.location == nil && !instance.isV2)
    }

    @Test("Confirmations say what a reset or delete discards")
    func copy() {
        let worktree = OpenCodeWorktree(directory: "/w/login", branch: "opencode/login")
        let dirty = OpenCodeWorktreeSummary(branch: "opencode/login", defaultBranch: "main", changes: 3, sessions: 2)
        #expect(OpenCodeWorktreeCopy.resetMessage(worktree, summary: dirty)
            == "Resets opencode/login to match main. Commits on it and 3 uncommitted changes will be discarded. Its sessions are kept.")
        #expect(OpenCodeWorktreeCopy.resetMessage(OpenCodeWorktree(directory: "/w/x"), summary: nil)
            == "Resets the worktree to match the default branch. Commits on it and any uncommitted changes will be discarded. Its sessions are kept.")
        #expect(OpenCodeWorktreeCopy.removalMessage(worktree, summary: dirty)
            == "Deletes the worktree’s folder on the server and its branch, opencode/login. 3 uncommitted changes will be lost. Its 2 sessions will no longer be listed.")
        let clean = OpenCodeWorktreeSummary(branch: nil, changes: 0, sessions: 1)
        #expect(OpenCodeWorktreeCopy.removalMessage(OpenCodeWorktree(directory: "/w/x"), summary: clean)
            == "Deletes the worktree’s folder on the server and its branch. Its session will no longer be listed.")
        #expect(OpenCodeWorktreeCopy.changes(0) == "No uncommitted changes")
        #expect(OpenCodeWorktreeCopy.changes(1) == "1 uncommitted change")
        #expect(OpenCodeWorktreeCopy.sessions(0) == "No sessions")
        #expect(OpenCodeWorktreeCopy.sessions(1) == "1 session")
        #expect(OpenCodeWorktreeCopy.sessions(4) == "4 sessions")
    }
}

@Suite("Worktree service")
struct OpenCodeWorktreeServiceTests {
    private let profile = OpenCodeServerProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000088")!, name: "Worktrees",
        baseURL: "https://wt.example.test/opencode")

    @Test("v1 lists, creates, removes and resets through the project's experimental routes")
    func v1Routes() async throws {
        let transport = WorktreeTestTransport(profile: profile) { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/opencode/experimental/worktree"):
                .raw(#"["/w/p1/login","/w/p1/misty-island","/w/p1/login/"]"#)
            case ("POST", "/opencode/experimental/worktree"):
                .raw(#"{"name":"login-flow","branch":"opencode/login-flow","directory":"/w/p1/login-flow"}"#)
            case ("DELETE", "/opencode/experimental/worktree"), ("POST", "/opencode/experimental/worktree/reset"): .raw("true")
            default: .init(data: Data(), mime: "application/json", status: 404)
            }
        }
        let service = makeService(transport, protocol: .v1)
        #expect(await service.isAvailable())
        #expect(try await service.list() == [OpenCodeWorktree(directory: "/w/p1/login"),
                                             OpenCodeWorktree(directory: "/w/p1/misty-island")])
        #expect(try await service.create(name: " Login Flow ") == OpenCodeWorktree(
            directory: "/w/p1/login-flow", name: "login-flow", branch: "opencode/login-flow"))
        _ = try await service.create(name: "  ")
        try await service.remove("/w/p1/login")
        try await service.reset("/w/p1/misty-island")

        let requests = transport.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "GET /opencode/experimental/worktree", "GET /opencode/experimental/worktree",
            "POST /opencode/experimental/worktree", "POST /opencode/experimental/worktree",
            "DELETE /opencode/experimental/worktree", "POST /opencode/experimental/worktree/reset",
        ])
        for request in requests {
            #expect(query(request, "directory") == "/repo")
        }
        #expect(try body(requests[2]) == ["name": .string("Login Flow")])
        #expect(try body(requests[3]).isEmpty, "An empty name lets the server pick one")
        #expect(try body(requests[4]) == ["directory": .string("/w/p1/login")])
        #expect(try body(requests[5]) == ["directory": .string("/w/p1/misty-island")])
    }

    @Test("Older servers without the routes read as unsupported; the server's own errors are kept")
    func failures() async throws {
        let html = WorktreeTestTransport(profile: profile) { _ in .init(data: Data("<!doctype html>".utf8), mime: "text/html") }
        await #expect(throws: OpenCodeWorktreeError.unsupported) { try await makeService(html, protocol: .v1).list() }
        #expect(await makeService(html, protocol: .v1).isAvailable() == false)
        let missing = WorktreeTestTransport(profile: profile) { _ in .init(data: Data(), mime: "application/json", status: 404) }
        await #expect(throws: OpenCodeWorktreeError.unsupported) { try await makeService(missing, protocol: .v1).list() }

        let notGit = WorktreeTestTransport(profile: profile) { _ in
            .init(data: Data(#"{"name":"WorktreeNotGitError","data":{"message":"Worktrees are only supported for git projects"}}"#.utf8),
                  mime: "application/json", status: 400)
        }
        await #expect(throws: OpenCodeWorktreeError.server("Worktrees are only supported for git projects")) {
            try await makeService(notGit, protocol: .v1).create(name: nil)
        }
        let broken = WorktreeTestTransport(profile: profile) { _ in .init(data: Data(), mime: "application/json", status: 500) }
        await #expect(throws: OpenCodeConnectionError.self) { try await makeService(broken, protocol: .v1).remove("/w/x") }

        let unreachable = OpenCodeWorktreeService(directory: "/repo") { throw OpenCodeConnectionError.httpStatus(502, nil) }
        await #expect(throws: OpenCodeConnectionError.self) { try await unreachable.list() }
        #expect(await unreachable.isAvailable() == false)
    }

    @Test("v2 uses the routes only when its schema publishes every one of them")
    func v2Gating() async throws {
        let transport = WorktreeTestTransport(profile: profile) { request in
            request.url!.path.hasSuffix("/reset") ? .raw("true") : .raw(#"["/w/p1/a"]"#)
        }
        let beta = makeService(transport, protocol: .v2, schema: schema([
            "/experimental/worktree": ["get", "post"],
        ]))
        await #expect(throws: OpenCodeWorktreeError.unsupported) { try await beta.list() }
        await #expect(throws: OpenCodeWorktreeError.unsupported) { try await beta.reset("/w/p1/a") }
        #expect(transport.requests.isEmpty, "Routes a v2 schema omits are never guessed")

        let full = makeService(transport, protocol: .v2, schema: schema([
            "/experimental/worktree": ["get", "post", "delete"],
            "/experimental/worktree/reset": ["post"],
        ]))
        #expect(try await full.list().map(\.name) == ["a"])
        try await full.reset("/w/p1/a")
        #expect(transport.requests.map(\.url!.path) == ["/opencode/experimental/worktree", "/opencode/experimental/worktree/reset"])
        #expect(query(transport.requests[0], "directory") == "/repo")
    }

    @Test("Readiness comes from the global stream, and only where the server has one")
    func events() async throws {
        let stream: [OpenCodeEvent] = [
            OpenCodeEvent(id: "1", type: "server.connected", properties: [:]),
            OpenCodeEvent(id: "2", type: "session.idle", properties: [:], location: .init(directory: "/repo")),
            OpenCodeEvent(id: "3", type: "worktree.ready", properties: [:], location: .init(directory: "/w/a")),
            OpenCodeEvent(id: "4", type: "worktree.failed", properties: ["message": .string("boom")], location: .init(directory: "/w/b")),
        ]
        let transport = WorktreeTestTransport(profile: profile, events: stream) { _ in .raw("[]") }
        var received: [OpenCodeWorktreeEvent] = []
        for try await event in makeService(transport, protocol: .v1).events() { received.append(event) }
        #expect(received == [.connected, .ready(directory: "/w/a"), .failed(directory: "/w/b", message: "boom")])
        #expect(transport.eventPaths == [["global", "event"]])

        let v2 = WorktreeTestTransport(profile: profile, events: stream) { _ in .raw("[]") }
        var none: [OpenCodeWorktreeEvent] = []
        for try await event in makeService(v2, protocol: .v2, schema: schema([:])).events() { none.append(event) }
        #expect(none.isEmpty && v2.eventPaths.isEmpty)
    }

    @Test("A summary reads the worktree's branch and changes and counts its root sessions")
    func summary() async throws {
        let transport = WorktreeTestTransport(profile: profile) { request in
            switch request.url!.path {
            case "/opencode/vcs": .raw(#"{"branch":"opencode/a","default_branch":"main"}"#)
            case "/opencode/vcs/status":
                .raw(#"[{"file":"a.swift","additions":1,"deletions":0,"status":"modified"},{"file":"b.swift","additions":0,"deletions":2,"status":"deleted"}]"#)
            default: .init(data: Data(), mime: "application/json", status: 404)
            }
        }
        let context = OpenCodeFeatureContext(serverProtocol: .v1, schema: nil, transport: transport, profile: profile)
        let service = OpenCodeWorktreeService(directory: "/repo", context: { context }, listSessions: { directory in
            [session("a", directory: directory), session("child", directory: directory, parent: "a"),
             session("old", directory: directory, archived: 5)]
        })
        #expect(await service.summary(of: "/w/a") == OpenCodeWorktreeSummary(
            branch: "opencode/a", defaultBranch: "main", changes: 2, sessions: 1))
        for request in transport.requests { #expect(query(request, "directory") == "/w/a") }

        let failing = OpenCodeWorktreeService(directory: "/repo", context: { throw URLError(.notConnectedToInternet) },
                                              listSessions: { _ in throw URLError(.notConnectedToInternet) })
        #expect(await failing.summary(of: "/w/a") == OpenCodeWorktreeSummary())
    }

    private func makeService(_ transport: WorktreeTestTransport, protocol serverProtocol: OpenCodeServerProtocol,
                             schema: OpenCodeJSONValue? = nil) -> OpenCodeWorktreeService {
        let context = OpenCodeFeatureContext(serverProtocol: serverProtocol, schema: schema, transport: transport, profile: profile)
        return OpenCodeWorktreeService(directory: "/repo") { context }
    }

    private func schema(_ paths: [String: [String]]) -> OpenCodeJSONValue {
        .object(["paths": .object(paths.mapValues { methods in
            .object(Dictionary(uniqueKeysWithValues: methods.map { ($0, OpenCodeJSONValue.object([:])) }))
        })])
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func body(_ request: URLRequest) throws -> [String: OpenCodeJSONValue] {
        try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: try #require(request.httpBody))
    }
}

@MainActor
@Suite("Worktree store")
struct OpenCodeWorktreeStoreTests {
    @Test("Loading lists worktrees with their summaries; a server without routes reads as unsupported")
    func load() async {
        let service = FakeWorktreeService()
        service.listed = [OpenCodeWorktree(directory: "/w/a"), OpenCodeWorktree(directory: "/w/b")]
        let store = OpenCodeWorktreeStore(service: service)
        #expect(store.availability == .unknown)
        await store.load()
        #expect(store.availability == .available && store.hasLoaded)
        #expect(store.worktrees.map(\.name) == ["a", "b"])
        #expect(store.summaries["/w/a"] == OpenCodeWorktreeSummary(branch: "opencode/a", changes: 0, sessions: 1))
        #expect(store.branch(of: store.worktrees[1]) == "opencode/b")

        service.listError = OpenCodeWorktreeError.unsupported
        let unsupported = OpenCodeWorktreeStore(service: service)
        await unsupported.load()
        #expect(unsupported.availability == .unsupported && unsupported.worktrees.isEmpty)

        store.use(nil)
        #expect(store.availability == .unsupported && store.worktrees.isEmpty && store.summaries.isEmpty)
    }

    @Test("A failed refresh keeps the list; a failed first load says so")
    func refreshFailure() async {
        let service = FakeWorktreeService()
        service.listed = [OpenCodeWorktree(directory: "/w/a")]
        let store = OpenCodeWorktreeStore(service: service)
        await store.load()
        service.listError = OpenCodeConnectionError.httpStatus(502, nil)
        await store.load()
        #expect(store.worktrees.map(\.name) == ["a"])
        #expect(store.refreshError != nil && store.loadError == nil)

        let fresh = OpenCodeWorktreeStore(service: service)
        await fresh.load()
        #expect(fresh.loadError != nil && fresh.availability == .unknown)
    }

    @Test("Create waits for the server's readiness report, even one sent before the request returns")
    func createWaitsForReady() async {
        let service = FakeWorktreeService()
        service.readiness = .ready
        let store = OpenCodeWorktreeStore(service: service, readinessTimeout: .seconds(5))
        let worktree = await store.create(name: "Login Flow")
        #expect(worktree == OpenCodeWorktree(directory: "/w/login-flow", name: "login-flow", branch: "opencode/login-flow"))
        #expect(service.createdNames == ["Login Flow"])
        #expect(store.worktrees == [worktree])
        #expect(store.creation == nil && store.actionError == nil)
        #expect(store.summaries["/w/login-flow"]?.sessions == 1)

        // The list only has folders; the name and branch the create answered with stay.
        service.listed = [OpenCodeWorktree(directory: "/w/login-flow")]
        service.summaryBranch = .some(nil)
        await store.load()
        #expect(store.worktrees.first?.branch == "opencode/login-flow")
        #expect(store.branch(of: store.worktrees[0]) == "opencode/login-flow")
    }

    @Test("A worktree that fails to check out is reported and not used")
    func createFailure() async {
        let service = FakeWorktreeService()
        service.readiness = .failed("fatal: invalid reference")
        let store = OpenCodeWorktreeStore(service: service, readinessTimeout: .seconds(5))
        #expect(await store.create(name: nil) == nil)
        #expect(store.actionError?.contains("fatal: invalid reference") == true)
        #expect(store.worktrees.map(\.name) == ["new"], "It exists, so it stays listed for deletion")

        service.createError = OpenCodeWorktreeError.server("Worktrees are only supported for git projects")
        #expect(await store.create(name: nil) == nil)
        #expect(store.actionError == "Couldn’t create the worktree: Worktrees are only supported for git projects")
        #expect(store.creation == nil)
    }

    @Test("Without a readiness report the worktree is still used, after the timeout or at once")
    func createUnobserved() async {
        let silent = FakeWorktreeService()
        silent.readiness = .silent
        let store = OpenCodeWorktreeStore(service: silent, connectTimeout: .milliseconds(50),
                                          readinessTimeout: .milliseconds(150))
        let started = ContinuousClock.now
        #expect(await store.create(name: nil) != nil)
        #expect(ContinuousClock.now - started >= .milliseconds(150))

        let noStream = FakeWorktreeService()
        noStream.readiness = .noStream
        let quick = OpenCodeWorktreeStore(service: noStream, readinessTimeout: .seconds(30))
        let begun = ContinuousClock.now
        #expect(await quick.create(name: nil) != nil)
        #expect(ContinuousClock.now - begun < .seconds(5))
    }

    @Test("Delete and reset report progress, update the list and keep failures visible")
    func removeAndReset() async {
        let service = FakeWorktreeService()
        service.listed = [OpenCodeWorktree(directory: "/w/a"), OpenCodeWorktree(directory: "/w/b")]
        let store = OpenCodeWorktreeStore(service: service)
        await store.load()
        let a = store.worktrees[0]
        #expect(await store.remove(a))
        #expect(store.worktrees.map(\.name) == ["b"] && store.summaries["/w/a"] == nil)
        #expect(service.removed == ["/w/a"])

        let b = store.worktrees[0]
        service.summaryChanges = 0
        #expect(await store.reset(b))
        #expect(service.reset == ["/w/b"])
        #expect(store.operations.isEmpty)

        service.removeError = OpenCodeWorktreeError.server("fatal: worktree is locked")
        #expect(await store.remove(b) == false)
        #expect(store.worktrees.map(\.name) == ["b"])
        #expect(store.actionError == "Couldn’t delete “b”: fatal: worktree is locked")

        let session = await store.createSession(in: b)
        #expect(session?.directory == "/w/b" && store.actionError == nil)
    }
}

@MainActor
@Suite("Worktree sessions in the browser")
struct OpenCodeWorktreeBrowserTests {
    @Test("Sessions in a project's worktrees are listed with the project; a failing worktree keeps its sessions")
    func sandboxes() async {
        let service = SandboxBrowserService()
        await service.set(["/repo": [session("main", directory: "/repo")],
                           "/w/a": [session("in-a", directory: "/w/a")],
                           "/w/b": [session("in-b", directory: "/w/b"), session("child", directory: "/w/b", parent: "in-b")]])
        let project = OpenCodeProject(id: "p1", worktree: "/repo", vcs: "git", name: nil,
                                      time: OpenCodeProjectTime(created: 1, updated: 2), sandboxes: ["/w/a", "/w/b", "/repo"])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project])
        #expect(Set(store.sessions.map(\.id)) == ["main", "in-a", "in-b"])
        #expect(store.statuses["in-a"] == .busy)
        #expect(store.groups[0].error == nil)
        #expect(Set(await service.listed) == ["/repo", "/w/a", "/w/b"], "The project's own directory is listed once")

        await service.fail("/w/a")
        await store.load(projects: [project])
        #expect(Set(store.sessions.map(\.id)) == ["main", "in-a", "in-b"])
        #expect(store.groups[0].error == nil)
    }
}

// MARK: - Fakes

private func session(_ id: String, directory: String, parent: String? = nil, archived: Double? = nil) -> OpenCodeSession {
    OpenCodeSession(id: id, slug: id, projectID: "p1", workspaceID: nil, directory: directory, parentID: parent,
                    summary: nil, title: id, agent: nil, version: "1.18.21",
                    time: OpenCodeSessionTime(created: 1, updated: 2, compacting: nil, archived: archived))
}

private final class FakeWorktreeService: OpenCodeWorktreeServicing, @unchecked Sendable {
    enum Readiness { case ready, failed(String), silent, noStream }

    private let lock = NSLock()
    private var state = State()
    private struct State {
        var listed: [OpenCodeWorktree] = []
        var listError: (any Error)?
        var createError: (any Error)?
        var removeError: (any Error)?
        var readiness = Readiness.ready
        var summaryBranch: String?? = .none
        var summaryChanges = 0
        var createdNames: [String?] = []
        var removed: [String] = []
        var reset: [String] = []
        var continuation: AsyncThrowingStream<OpenCodeWorktreeEvent, Error>.Continuation?
    }

    private func with<T>(_ body: (inout State) -> T) -> T { lock.withLock { body(&state) } }

    var listed: [OpenCodeWorktree] { get { with { $0.listed } } set { with { $0.listed = newValue } } }
    var listError: (any Error)? { get { with { $0.listError } } set { with { $0.listError = newValue } } }
    var createError: (any Error)? { get { with { $0.createError } } set { with { $0.createError = newValue } } }
    var removeError: (any Error)? { get { with { $0.removeError } } set { with { $0.removeError = newValue } } }
    var readiness: Readiness { get { with { $0.readiness } } set { with { $0.readiness = newValue } } }
    /// `.none` answers `opencode/<name>`; `.some(nil)` answers no branch.
    var summaryBranch: String?? { get { with { $0.summaryBranch } } set { with { $0.summaryBranch = newValue } } }
    var summaryChanges: Int { get { with { $0.summaryChanges } } set { with { $0.summaryChanges = newValue } } }
    var createdNames: [String?] { with { $0.createdNames } }
    var removed: [String] { with { $0.removed } }
    var reset: [String] { with { $0.reset } }

    func list() async throws -> [OpenCodeWorktree] {
        if let error = listError { throw error }
        return listed
    }

    func create(name: String?) async throws -> OpenCodeWorktree {
        if let error = createError { throw error }
        with { $0.createdNames.append(name) }
        let slug = name.map(OpenCodeWorktreeNaming.slug) ?? ""
        let worktree = OpenCodeWorktree(directory: "/w/\(slug.isEmpty ? "new" : slug)",
                                        name: slug.isEmpty ? "new" : slug, branch: slug.isEmpty ? nil : "opencode/\(slug)")
        // The server boots the worktree in the background, so its report can beat the response.
        let (readiness, continuation) = with { ($0.readiness, $0.continuation) }
        switch readiness {
        case .ready: continuation?.yield(.ready(directory: worktree.directory))
        case .failed(let message): continuation?.yield(.failed(directory: worktree.directory, message: message))
        case .silent, .noStream: break
        }
        try await Task.sleep(for: .milliseconds(20))
        return worktree
    }

    func remove(_ directory: String) async throws {
        if let error = removeError { throw error }
        with { $0.removed.append(directory) }
    }

    func reset(_ directory: String) async throws {
        with { $0.reset.append(directory) }
    }

    func events() -> AsyncThrowingStream<OpenCodeWorktreeEvent, Error> {
        AsyncThrowingStream { continuation in
            if case .noStream = readiness {
                continuation.finish()
                return
            }
            with { $0.continuation = continuation }
            continuation.yield(.connected)
        }
    }

    func summary(of directory: String) async -> OpenCodeWorktreeSummary {
        let name = OpenCodeWorktree.name(of: directory)
        let branch = summaryBranch ?? "opencode/\(name)"
        return OpenCodeWorktreeSummary(branch: branch, changes: summaryChanges, sessions: 1)
    }

    func createSession(in directory: String) async throws -> OpenCodeSession {
        session("ses-\(OpenCodeWorktree.name(of: directory))", directory: directory)
    }
}

private actor SandboxBrowserService: OpenCodeSessionBrowsing {
    private var sessions: [String: [OpenCodeSession]] = [:]
    private var failing: Set<String> = []
    private(set) var listed: [String] = []

    func set(_ value: [String: [OpenCodeSession]]) { sessions = value }
    func fail(_ directory: String) { failing.insert(directory) }

    func listSessions(directory: String) async throws -> [OpenCodeSession] {
        listed.append(directory)
        if failing.contains(directory) { throw OpenCodeConnectionError.httpStatus(500, nil) }
        return sessions[directory] ?? []
    }

    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] {
        directory == "/w/a" ? ["in-a": .busy] : [:]
    }
}

private final class WorktreeTestTransport: OpenCodeHTTPTransport, @unchecked Sendable {
    struct Response {
        let data: Data
        let mime: String
        var status = 200
        static func raw(_ json: String) -> Self { .init(data: Data(json.utf8), mime: "application/json") }
    }

    let base: OpenCodeTransport
    let respond: @Sendable (URLRequest) -> Response
    let streamed: [OpenCodeEvent]
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var subscribed: [[String]] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    var eventPaths: [[String]] { lock.withLock { subscribed } }

    init(profile: OpenCodeServerProfile, events: [OpenCodeEvent] = [],
         respond: @escaping @Sendable (URLRequest) -> Response) {
        base = .init(profile: profile, password: "test", session: .shared)
        streamed = events
        self.respond = respond
    }

    func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        try base.makeRequest(path: path, query: query, method: method, body: body)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(request) }
        let response = respond(request)
        return (response.data, HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil,
                                               headerFields: ["Content-Type": response.mime])!)
    }

    func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        lock.withLock { subscribed.append(path) }
        let events = streamed
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}
