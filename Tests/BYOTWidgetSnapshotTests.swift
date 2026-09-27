import Foundation
import Testing
@testable import byot

@MainActor
struct BYOTWidgetSnapshotTests {
    @Test("Widget rows keep running and attention sessions and drop idle ones")
    func serverRows() {
        let profile = OpenCodeServerProfile(name: "Studio", baseURL: "https://studio.invalid")
        let server = BYOTWidgetSync.server(
            profile: profile,
            sessions: [session("busy"), session("retry"), session("waiting"), session("failed"), session("idle"),
                       session("recovered")],
            statuses: ["busy": .busy, "retry": .retry(attempt: 1, message: "", next: 0), "waiting": .busy,
                       "failed": .idle, "idle": .idle, "recovered": .busy],
            pendingSessionIDs: ["waiting"],
            failures: ["failed": "Model retired", "recovered": "Old failure"],
            at: Date(timeIntervalSince1970: 50))
        let states = Dictionary(uniqueKeysWithValues: server.sessions.map { ($0.sessionID, $0.state) })
        #expect(states == ["busy": .running, "retry": .retrying, "waiting": .needsResponse, "failed": .failed,
                           "recovered": .running])
        #expect(server.refreshedAt == Date(timeIntervalSince1970: 50))
        let row = server.sessions.first { $0.sessionID == "busy" }
        #expect(row?.projectName == "repo")
        #expect(row?.updatedAt == Date(timeIntervalSince1970: 2))
    }

    @Test("Sessions sort by urgency and counts separate attention from activity")
    func orderingAndCounts() {
        var snapshot = BYOTWidgetSnapshot()
        let first = UUID()
        let second = UUID()
        snapshot.replace(BYOTWidgetServer(serverID: first, name: "B", refreshedAt: Date(timeIntervalSince1970: 100), sessions: [
            row("run-old", server: first, state: .running, updated: 1),
            row("run-new", server: first, state: .running, updated: 5),
            row("failed", server: first, state: .failed, updated: 2),
        ]))
        snapshot.replace(BYOTWidgetServer(serverID: second, name: "A", refreshedAt: Date(timeIntervalSince1970: 40), sessions: [
            row("waiting", server: second, state: .needsResponse, updated: 0),
            row("retry", server: second, state: .retrying, updated: 3),
        ]))
        #expect(snapshot.sessions.map(\.sessionID) == ["waiting", "failed", "retry", "run-new", "run-old"])
        #expect(snapshot.attentionCount == 2)
        #expect(snapshot.activeCount == 4)
        #expect(snapshot.servers.map(\.name) == ["A", "B"])
        #expect(snapshot.refreshedAt == Date(timeIntervalSince1970: 40))
        #expect(snapshot.primaryLink == snapshot.sessions[0].link)
        #expect(!snapshot.isStale(at: Date(timeIntervalSince1970: 40 + BYOTWidgetSnapshot.freshness)))
        #expect(snapshot.isStale(at: Date(timeIntervalSince1970: 41 + BYOTWidgetSnapshot.freshness)))
        snapshot.removeServer(second)
        #expect(snapshot.attentionCount == 1)
        #expect(BYOTWidgetSnapshot().primaryLink == BYOTWidgetLink.app)
    }

    @Test("A server keeps at most the most urgent sessions")
    func sessionLimit() {
        var snapshot = BYOTWidgetSnapshot()
        let server = UUID()
        let rows = (0..<20).map { row("r\($0)", server: server, state: .running, updated: Double($0)) }
            + [row("waiting", server: server, state: .needsResponse, updated: 0)]
        snapshot.replace(BYOTWidgetServer(serverID: server, name: "S", refreshedAt: .now, sessions: rows))
        #expect(snapshot.sessions.count == BYOTWidgetSnapshot.sessionLimit)
        #expect(snapshot.sessions.first?.sessionID == "waiting")
    }

    @Test("A server byot has moved away from drops out instead of keeping the widget out of date")
    func abandonedServer() {
        var snapshot = BYOTWidgetSnapshot()
        let old = UUID()
        let recent = UUID()
        let current = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        snapshot.replace(BYOTWidgetServer(serverID: old, name: "Old", refreshedAt: start,
                                          sessions: [row("stuck", server: old, state: .running, updated: 1)]))
        snapshot.replace(BYOTWidgetServer(serverID: recent, name: "Recent", refreshedAt: start + 20 * 60,
                                          sessions: [row("recent", server: recent, state: .running, updated: 2)]))
        let now = start + BYOTWidgetSnapshot.freshness + 60
        snapshot.replace(BYOTWidgetServer(serverID: current, name: "Current", refreshedAt: now,
                                          sessions: [row("live", server: current, state: .running, updated: 3)]))
        #expect(snapshot.servers.map(\.name) == ["Current", "Recent"])
        #expect(!snapshot.isStale(at: now))
        #expect(snapshot.activeCount == 2)
    }

    @Test("A live conversation updates only its own row")
    func upsert() {
        var snapshot = BYOTWidgetSnapshot()
        let server = UUID()
        let refreshed = Date(timeIntervalSince1970: 10)
        snapshot.replace(BYOTWidgetServer(serverID: server, name: "Old", refreshedAt: refreshed,
                                          sessions: [row("other", server: server, state: .running, updated: 1)]))
        snapshot.upsert(row("live", server: server, state: .needsResponse, updated: 2), serverID: server,
                        sessionID: "live", serverName: "Renamed", at: .now)
        #expect(Set(snapshot.sessions.map(\.sessionID)) == ["other", "live"])
        #expect(snapshot.servers.first?.name == "Renamed")
        #expect(snapshot.refreshedAt == refreshed)
        snapshot.upsert(nil, serverID: server, sessionID: "live", serverName: "Renamed", at: .now)
        #expect(snapshot.sessions.map(\.sessionID) == ["other"])
        // Clearing a row for a server the widget has never seen adds nothing.
        snapshot.upsert(nil, serverID: UUID(), sessionID: "x", serverName: "New", at: .now)
        #expect(snapshot.servers.count == 1)
    }

    @Test("The snapshot round-trips through the shared suite and reloads are coalesced")
    func syncPersistsAndCoalesces() async throws {
        let suite = "widget-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BYOTWidgetSnapshotStore(defaults: defaults)
        let counter = ReloadCounter()
        let sync = BYOTWidgetSync(store: store, reloadDelay: .milliseconds(20)) { counter.count += 1 }
        let server = UUID()
        let refreshed = BYOTWidgetServer(serverID: server, name: "S", refreshedAt: Date(timeIntervalSince1970: 5),
                                         sessions: [row("a", server: server, state: .running, updated: 1)])
        sync.publish(refreshed)
        sync.update(row("b", server: server, state: .needsResponse, updated: 2), serverID: server, sessionID: "b",
                    serverName: "S")
        sync.publish(BYOTWidgetSync.server(profile: OpenCodeServerProfile(id: server, name: "S", baseURL: "https://s.invalid"),
                                           sessions: [], statuses: [:], pendingSessionIDs: [], failures: [:],
                                           at: Date(timeIntervalSince1970: 6)))
        for _ in 0..<100 where counter.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(counter.count == 1)
        #expect(store.load() == sync.current)
        #expect(store.load().servers.first?.sessions.isEmpty == true)
        // Publishing the same state again writes nothing and reloads nothing.
        sync.publish(sync.current.servers[0])
        try await Task.sleep(for: .milliseconds(60))
        #expect(counter.count == 1)
        sync.removeServer(server)
        #expect(store.load().isEmpty)
    }

    @Test("Automated launches never write widget state")
    func disabledSync() async throws {
        let suite = "widget-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BYOTWidgetSnapshotStore(defaults: defaults)
        let sync = BYOTWidgetSync(store: store, isEnabled: false, reloadDelay: .zero) { Issue.record("Unexpected reload") }
        sync.publish(BYOTWidgetServer(serverID: UUID(), name: "S", refreshedAt: .now, sessions: []))
        try await Task.sleep(for: .milliseconds(20))
        #expect(store.load().isEmpty)
        #expect(defaults.data(forKey: BYOTWidgetSnapshotStore.key) == nil)
    }

    @Test("The session list asks for waiting requests only where sessions are running")
    func browserPendingRequests() async {
        let service = PendingBrowserService()
        let store = OpenCodeSessionBrowserStore(service: service)
        let quiet = OpenCodeProject(id: "/quiet", worktree: "/quiet", vcs: nil, name: nil,
                                    time: OpenCodeProjectTime(created: 1, updated: 2), sandboxes: [])
        let busy = OpenCodeProject(id: "/busy", worktree: "/busy", vcs: nil, name: nil,
                                   time: OpenCodeProjectTime(created: 1, updated: 2), sandboxes: [])
        await store.load(projects: [quiet, busy])
        #expect(await service.pendingQueries == [["/busy/running", "/busy/waiting"]])
        #expect(store.pendingSessionIDs == ["/busy/waiting"])
        #expect(store.groups.first { $0.id == "/quiet" }?.pendingSessionIDs.isEmpty == true)
    }

    @Test("A legacy server reports waiting sessions from its permission and question lists")
    func clientPendingRequests() async throws {
        let transport = PendingTransport()
        let client = OpenCodeClient(profile: OpenCodeServerProfile(name: "Fixture", baseURL: "https://fixture.invalid"),
                                    transport: transport, serverProtocol: .v1)
        #expect(try await client.pendingResponseSessionIDs(directory: "/repo", activeSessionIDs: []).isEmpty)
        #expect(await transport.paths.isEmpty)
        let waiting = try await client.pendingResponseSessionIDs(directory: "/repo",
                                                                 activeSessionIDs: ["approve", "answer", "running"])
        #expect(waiting == ["approve", "answer"])
        #expect(Set(await transport.paths) == ["/permission", "/question"])
    }

    @Test("A legacy server without a question route still reports waiting permissions")
    func clientPendingWithoutQuestions() async throws {
        let transport = PendingTransport(hasQuestions: false)
        let client = OpenCodeClient(profile: OpenCodeServerProfile(name: "Fixture", baseURL: "https://fixture.invalid"),
                                    transport: transport, serverProtocol: .v1)
        let waiting = try await client.pendingResponseSessionIDs(directory: "/repo",
                                                                 activeSessionIDs: ["approve", "answer"])
        #expect(waiting == ["approve"])
    }

    @Test("OpenCode 2 checks each running session's permissions and questions")
    func clientPendingV2() async throws {
        let transport = PendingTransport()
        let client = OpenCodeClient(profile: OpenCodeServerProfile(name: "Fixture", baseURL: "https://fixture.invalid"),
                                    transport: transport, serverProtocol: .v2)
        let waiting = try await client.pendingResponseSessionIDs(
            directory: "/repo", activeSessionIDs: ["approve", "answer", "running", "broken"])
        #expect(waiting == ["approve", "answer"])
        let paths = Set(await transport.paths)
        #expect(paths.isSuperset(of: ["/api/session/approve/permission", "/api/session/answer/question",
                                      "/api/session/running/permission", "/api/session/broken/question"]))
        #expect(!paths.contains("/permission") && !paths.contains("/question"))
    }

    @Test("Widget links round-trip and open only well-formed session routes")
    func links() throws {
        let server = UUID()
        let link = BYOTWidgetLink(serverID: server, sessionID: "ses_1", directory: "/Users/me/my repo", workspace: "wrk")
        #expect(BYOTWidgetLink(url: link.url) == link)
        let destination = try #require(BYOTPushDestination(widgetURL: link.url))
        #expect(destination.origin == .widget)
        #expect(destination.route == BYOTPushRoute(serverID: server, sessionID: "ses_1", directory: "/Users/me/my repo",
                                                    workspace: "wrk"))
        #expect(BYOTPushDestination(widgetURL: BYOTWidgetLink.app) == nil)
        #expect(BYOTPushDestination(widgetURL: URL(string: "https://byot.app/session")!) == nil)
        let unsafe = BYOTWidgetLink(serverID: server, sessionID: "../x", directory: "/r", workspace: nil)
        #expect(BYOTPushDestination(widgetURL: unsafe.url) == nil)
        let noWorkspace = BYOTWidgetLink(serverID: server, sessionID: "s", directory: "/r", workspace: nil)
        #expect(BYOTWidgetLink(url: noWorkspace.url)?.workspace == nil)
    }

    @Test("Widget copy stays short and collapses whitespace")
    func trimmedText() {
        #expect("  Fix\n the   login ".trimmedWidgetText == "Fix the login")
        #expect(" \n ".trimmedWidgetText == nil)
        #expect(String(repeating: "a", count: 80).trimmedWidgetText?.count == 60)
    }

    private func session(_ id: String) -> OpenCodeSession {
        OpenCodeSession(id: id, slug: id, projectID: "/repo", workspaceID: nil, directory: "/work/repo", parentID: nil,
                        summary: nil, title: id, agent: nil, version: "1.18.29",
                        time: OpenCodeSessionTime(created: 1, updated: 2_000, compacting: nil, archived: nil))
    }

    private func row(_ id: String, server: UUID, state: BYOTWidgetSessionState, updated: Double) -> BYOTWidgetSession {
        BYOTWidgetSession(serverID: server, serverName: "S", sessionID: id, title: id, projectName: "repo",
                          directory: "/repo", workspace: nil, state: state,
                          updatedAt: Date(timeIntervalSince1970: updated))
    }
}

@MainActor
private final class ReloadCounter {
    var count = 0
}

private actor PendingBrowserService: OpenCodeSessionBrowsing {
    private(set) var pendingQueries: [[String]] = []

    func listSessions(directory: String) async throws -> [OpenCodeSession] {
        ["running", "waiting", "idle"].map { suffix in
            OpenCodeSession(id: "\(directory)/\(suffix)", slug: suffix, projectID: directory, workspaceID: nil,
                            directory: directory, parentID: nil, summary: nil, title: suffix, agent: nil,
                            version: "1.18.29", time: OpenCodeSessionTime(created: 1, updated: 2, compacting: nil, archived: nil))
        }
    }

    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] {
        directory == "/busy" ? ["/busy/running": .busy, "/busy/waiting": .busy] : [:]
    }

    func pendingResponseSessionIDs(directory: String, activeSessionIDs: [String]) async throws -> Set<String> {
        pendingQueries.append(activeSessionIDs.sorted())
        return ["\(directory)/waiting"]
    }
}

private actor PendingTransport: OpenCodeHTTPTransport {
    private(set) var paths: [String] = []
    private let hasQuestions: Bool

    init(hasQuestions: Bool = true) { self.hasQuestions = hasQuestions }

    nonisolated func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        URLRequest(url: URL(string: "https://fixture.invalid/" + path.joined(separator: "/"))!)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url!.path
        paths.append(path)
        let status = switch path {
        case "/question" where !hasQuestions, "/api/session/broken/permission", "/api/session/broken/question": 500
        default: 200
        }
        let body: String = switch path {
        case "/openapi.json":
            #"{"paths":{"/api/session/{sessionID}/prompt":{"post":{"requestBody":{"content":{"application/json":"#
                + #"{"schema":{"properties":{"text":{}}}}}}}}}}"#
        case "/api/session/approve/permission":
            #"{"data":[{"id":"per_1","sessionID":"approve","action":"bash","resources":["npm test"]}]}"#
        case "/api/session/answer/question": #"{"data":[{"id":"que_1","sessionID":"answer","questions":[]}]}"#
        case _ where path.hasPrefix("/api/"): #"{"data":[]}"#
        case "/permission":
            #"[{"id":"per_1","sessionID":"approve","permission":"bash","patterns":["npm test"],"metadata":{},"always":[]},"#
                + #"{"id":"per_2","sessionID":"elsewhere","permission":"edit","patterns":[],"metadata":{},"always":[]}]"#
        case "/question": #"[{"id":"que_1","sessionID":"answer","questions":[]}]"#
        default: "[]"
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                                 headerFields: ["Content-Type": "application/json"])!)
    }

    nonisolated func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
