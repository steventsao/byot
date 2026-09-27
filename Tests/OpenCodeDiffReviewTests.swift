import Foundation
import Testing
@testable import byot

@Suite("Unified diff parsing")
struct OpenCodeUnifiedDiffTests {
    @Test("git patches number both sides, keep hunk sections and report the new-file path")
    func gitPatch() {
        let diff = OpenCodeUnifiedDiff.parse("""
            diff --git a/src/app.ts b/src/app.ts
            index 94954ab..363f0a5 100644
            --- a/src/app.ts
            +++ b/src/app.ts
            @@ -3,4 +3,5 @@ export function main() {
             const a = 1
            -const b = 2
            +const b = 3
            +const c = 4

             return a
            @@ -40 +41 @@
            -old
            +new
            """)
        #expect(diff.path == "src/app.ts")
        #expect(diff.status == nil)
        #expect(diff.hunks.count == 2)
        #expect(diff.hunks[0].section == "export function main() {")
        #expect(diff.additions == 3)
        #expect(diff.deletions == 2)
        let lines = diff.hunks[0].lines
        #expect(lines.map(\.kind) == [.context, .deletion, .addition, .addition, .context, .context])
        #expect(lines[1].oldNumber == 4 && lines[1].newNumber == nil)
        #expect(lines[3].newNumber == 5 && lines[3].oldNumber == nil)
        // A blank context line whose leading space was stripped still advances both sides.
        #expect(lines[4].text.isEmpty && lines[4].oldNumber == 5 && lines[4].newNumber == 6)
        #expect(lines[5].oldNumber == 6 && lines[5].newNumber == 7)
        #expect(diff.hunks[1].oldCount == 1 && diff.hunks[1].lines.map(\.oldNumber) == [40, nil])
        #expect(diff.maximumLineNumber == 42)
    }

    @Test("jsdiff snapshot patches, added and deleted files, missing newlines and CRLF")
    func snapshotAndStatusHeaders() {
        let snapshot = OpenCodeUnifiedDiff.parse(
            "Index: notes.txt\r\n===================================================================\r\n--- notes.txt\t\r\n+++ notes.txt\t\r\n@@ -1,1 +1,1 @@\r\n-hello\r\n\\ No newline at end of file\r\n+hello\r\n")
        #expect(snapshot.path == "notes.txt")
        #expect(snapshot.hunks.first?.lines.first?.missingNewline == true)
        #expect(snapshot.hunks.first?.lines.last?.missingNewline == false)
        #expect(snapshot.hunks.first?.lines.last?.text == "hello")

        let added = OpenCodeUnifiedDiff.parse("--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+new file\n")
        #expect(added.status == .added)
        #expect(added.path == "new.txt")
        #expect(added.hunks.first?.lines.first?.newNumber == 1)

        let deleted = OpenCodeUnifiedDiff.parse("diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\n")
        #expect(deleted.status == .deleted)
        #expect(deleted.path == "gone.txt")

        let binary = OpenCodeUnifiedDiff.parse("diff --git a/logo.png b/logo.png\nBinary files a/logo.png and b/logo.png differ\n")
        #expect(binary.isBinary)
        #expect(binary.hunks.isEmpty)
    }

    @Test("Long unchanged runs collapse around changes and expand by stable id")
    func collapsing() throws {
        let context = (1...20).map { " line \($0)" }
        let patch = "@@ -1,21 +1,21 @@\n" + (context + ["-old", "+new"]).joined(separator: "\n") + "\n"
        let diff = OpenCodeUnifiedDiff.parse(patch)
        let rows = OpenCodeDiffRow.rows(for: diff, expandedGaps: [])
        // Leading context keeps only the three lines nearest the change.
        guard case .gap(let gapID, let hidden) = rows[1] else { Issue.record("Expected a gap row"); return }
        #expect(hidden == 17)
        #expect(rows.count == 1 + 1 + 3 + 2)
        let expanded = OpenCodeDiffRow.rows(for: diff, expandedGaps: [gapID])
        #expect(expanded.count == 1 + 20 + 2)
        #expect(Set(expanded.map(\.id)).count == expanded.count)

        let short = OpenCodeUnifiedDiff.parse("@@ -1,5 +1,5 @@\n a\n b\n-c\n+C\n d\n e\n")
        #expect(!OpenCodeDiffRow.rows(for: short, expandedGaps: []).contains { if case .gap = $0 { true } else { false } })

        let middle = OpenCodeUnifiedDiff.parse("@@ -1,12 +1,12 @@\n-a\n+A\n" + (1...10).map { " \($0)" }.joined(separator: "\n") + "\n-z\n+Z\n")
        let middleRows = OpenCodeDiffRow.rows(for: middle, expandedGaps: [])
        #expect(middleRows.contains(.gap(id: "h0-gap2", hiddenLines: 4)))
    }

    @Test("Display text expands tabs, bounds huge lines and measures wide characters")
    func displayText() {
        #expect(OpenCodeDiffRow.displayText("\tlet") == "    let")
        let huge = String(repeating: "x", count: OpenCodeDiffRow.maximumDisplayedCharacters + 50)
        #expect(OpenCodeDiffRow.displayText(huge).count == OpenCodeDiffRow.maximumDisplayedCharacters + 1)
        #expect(OpenCodeDiffRow.displayColumns("ab你好") == 6)
    }

    @Test("Files normalize paths, statuses and counts from every server shape")
    func normalization() {
        let files = OpenCodeDiffFile.normalized([
            OpenCodeDiff(file: "/repo/app/src/a.swift", patch: "@@ -1 +1 @@\n-a\n+b\n", additions: 0, deletions: 0, status: nil),
            OpenCodeDiff(file: nil, patch: "--- /dev/null\n+++ b/docs/new.md\n@@ -0,0 +1 @@\n+hi\n", additions: 1, deletions: 0, status: nil),
            OpenCodeDiff(file: "src/a.swift", patch: nil, additions: 9, deletions: 9, status: "modified"),
            OpenCodeDiff(file: "gone.txt", patch: nil, additions: 0, deletions: 3, status: "deleted"),
        ], directory: "/repo/app/")
        #expect(files.map(\.path) == ["src/a.swift", "docs/new.md", "gone.txt"])
        #expect(files[0].additions == 1 && files[0].deletions == 1)
        #expect(files[0].name == "a.swift" && files[0].folder == "src")
        #expect(files[1].status == .added && files[1].folder == "docs")
        #expect(files[2].status == .deleted && files[2].folder == nil)
        #expect(files[2].accessibilitySummary == "gone.txt, Deleted, 0 additions, 3 deletions")
    }

    @Test("Assistant replies decode the prompt they answer")
    func parentID() throws {
        let json = #"{"id":"msg_b","sessionID":"ses","role":"assistant","parentID":"msg_a","time":{"created":1}}"#
        let info = try JSONDecoder().decode(OpenCodeMessageInfo.self, from: Data(json.utf8))
        #expect(info.parentID == "msg_a")
    }
}

@Suite("Diff review service")
struct OpenCodeDiffReviewServiceTests {
    private let profile = OpenCodeServerProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000079")!, name: "Review",
        baseURL: "https://review.example.test/opencode")
    private let patch = "--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,3 @@\n hello\n+there\n world\n"

    @Test("v1 reviews a turn by prompt id and the working copy through /vcs")
    func v1Routes() async throws {
        let transport = DiffTestTransport(profile: profile) { request in
            switch request.url!.path {
            case "/opencode/vcs": .json(["branch": "feature", "default_branch": "main"])
            default: .json([["file": "a.txt", "patch": patch, "additions": 1, "deletions": 0, "status": "modified"]])
            }
        }
        let service = makeService(transport, protocol: .v1)
        let availability = try await service.availability()
        #expect(availability == .init(turn: true, uncommitted: true, branch: .init(current: "feature", defaultBranch: "main")))
        let turn = try await service.diffs(.turn, messageID: "msg_user")
        #expect(turn.first?.patch == patch)
        _ = try await service.diffs(.uncommitted, messageID: nil)
        _ = try await service.diffs(.branch, messageID: nil)
        let requests = transport.requests
        #expect(requests.map { $0.url!.path } == ["/opencode/vcs", "/opencode/session/ses_review/diff", "/opencode/vcs/diff", "/opencode/vcs/diff"])
        #expect(query(requests[1], "messageID") == "msg_user")
        #expect(query(requests[2], "mode") == "git")
        #expect(query(requests[3], "mode") == "branch")
        for request in requests {
            #expect(query(request, "directory") == "/repo/app")
            #expect(query(request, "workspace") == "wrk_review")
        }
        await #expect(throws: OpenCodeDiffReviewError.missingTurn) { try await service.diffs(.turn, messageID: nil) }
    }

    @Test("v1 servers without /vcs keep turn review and hide working-copy review")
    func v1WithoutVcs() async throws {
        let html = DiffTestTransport(profile: profile) { _ in .init(data: Data("<!doctype html>".utf8), mime: "text/html") }
        #expect(try await makeService(html, protocol: .v1).availability() == .init(turn: true, uncommitted: false, branch: nil))
        let missing = DiffTestTransport(profile: profile) { _ in .init(data: Data(), mime: "application/json", status: 404) }
        #expect(try await makeService(missing, protocol: .v1).availability().uncommitted == false)
        // Live 1.18.21 outside a repository: {"branch":null,"default_branch":null}.
        let nonGit = DiffTestTransport(profile: profile) { _ in .json(["branch": NSNull(), "default_branch": NSNull()]) }
        #expect(try await makeService(nonGit, protocol: .v1).availability() == .init(turn: true, uncommitted: false, branch: .init(current: nil, defaultBranch: nil)))
    }

    @Test("A detached HEAD keeps working-copy review but offers no branch comparison")
    func v1DetachedHead() async throws {
        let detached = DiffTestTransport(profile: profile) { _ in .json(["default_branch": "main"]) }
        let availability = try await makeService(detached, protocol: .v1).availability()
        #expect(availability.uncommitted)
        #expect(availability.branch?.comparesWithDefault == false)
    }

    @Test("An unreachable server is a retryable failure, not a missing feature")
    func unreachable() async {
        let service = OpenCodeDiffReviewService(sessionID: "ses_review", directory: "/repo/app", workspace: nil) {
            throw OpenCodeConnectionError.httpStatus(502, nil)
        }
        await #expect(throws: OpenCodeConnectionError.self) { try await service.availability() }
    }

    @Test("v2 reviews the working copy through the pinned beta schema and checks location")
    func v2Routes() async throws {
        let transport = DiffTestTransport(profile: profile) { request in
            if request.url!.path.hasSuffix("/api/vcs") {
                return envelope(["branch": ["current": "main", "default": "main"]])
            }
            return envelope([["file": "a.txt", "patch": patch, "additions": 1, "deletions": 0, "status": "modified"]])
        }
        let service = makeService(transport, protocol: .v2, schema: try schema())
        let availability = try await service.availability()
        #expect(availability.turn == false)
        #expect(availability.uncommitted)
        #expect(availability.branch?.comparesWithDefault == false)
        let diffs = try await service.diffs(.uncommitted, messageID: nil)
        #expect(diffs.map(\.file) == ["a.txt"])
        _ = try await service.diffs(.branch, messageID: nil)
        let requests = transport.requests
        #expect(requests.map { $0.url!.path } == ["/opencode/api/vcs", "/opencode/api/vcs/diff", "/opencode/api/vcs/diff"])
        #expect(query(requests[1], "mode") == "working")
        #expect(query(requests[2], "mode") == "branch")
        #expect(query(requests[1], "location[directory]") == "/repo/app")
        #expect(query(requests[1], "location[workspace]") == "wrk_review")
        await #expect(throws: OpenCodeDiffReviewError.unsupported(.turn)) { try await service.diffs(.turn, messageID: "msg") }
        #expect(transport.requests.count == 3)
    }

    @Test("v2 rejects another project's diff and never guesses missing routes")
    func v2Guards() async throws {
        let wrong = DiffTestTransport(profile: profile) { _ in
            .json(["location": ["directory": "/elsewhere", "project": ["id": "pro"]], "data": []])
        }
        await #expect(throws: OpenCodeDiffReviewError.wrongLocation) {
            try await makeService(wrong, protocol: .v2, schema: try schema()).diffs(.uncommitted, messageID: nil)
        }
        let bare = DiffTestTransport(profile: profile) { _ in .json([]) }
        let service = makeService(bare, protocol: .v2, schema: .object(["paths": .object([:])]))
        let availability = try await service.availability()
        #expect(!availability.turn && !availability.uncommitted && availability.unavailableReason != nil)
        await #expect(throws: OpenCodeDiffReviewError.unsupported(.uncommitted)) { try await service.diffs(.uncommitted, messageID: nil) }
        #expect(bare.requests.isEmpty)
    }

    private func makeService(_ transport: DiffTestTransport, protocol value: OpenCodeServerProtocol,
                             schema: OpenCodeJSONValue? = nil) -> OpenCodeDiffReviewService {
        let context = OpenCodeFeatureContext(serverProtocol: value, schema: schema, transport: transport, profile: profile)
        return OpenCodeDiffReviewService(sessionID: "ses_review", directory: "/repo/app", workspace: "wrk_review") { context }
    }

    private func envelope(_ data: Any) -> DiffTestTransport.Response {
        .json(["location": ["directory": "/repo/app", "workspaceID": "wrk_review", "project": ["id": "pro"]], "data": data])
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func schema() throws -> OpenCodeJSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/opencode2-beta-19242-openapi.json")
        return try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(contentsOf: url))
    }
}

@MainActor
@Suite("Diff review store")
struct OpenCodeDiffReviewStoreTests {
    private let diff = OpenCodeDiff(file: "a.txt", patch: "@@ -1 +1 @@\n-a\n+b\n", additions: 1, deletions: 1, status: "modified")

    @Test("Opening prefers the latest turn and offers only negotiated sources")
    func openLatestTurn() async {
        let service = FakeDiffService(availability: .init(turn: true, uncommitted: true, branch: .init(current: "main", defaultBranch: "main")),
                                      diffs: [.turn: [diff]])
        let store = OpenCodeDiffReviewStore(service: service, directory: "/repo")
        await store.open(OpenCodeDiffReviewRequest(), latestTurnMessageID: "msg_latest", sessionDiffs: [])
        #expect(store.sources == [.turn, .uncommitted])
        #expect(store.source == .turn)
        #expect(store.phase == .loaded)
        #expect(store.files.map(\.path) == ["a.txt"])
        #expect(!store.isPinnedTurn)
        #expect(await service.calls == ["turn:msg_latest"])

        await store.select(.uncommitted)
        #expect(store.source == .uncommitted)
        #expect(store.files.isEmpty && store.phase == .loaded)
        #expect(await service.calls.last == "uncommitted:-")
    }

    @Test("A transcript patch row pins its own turn; branch appears off the default branch")
    func pinnedTurn() async {
        let service = FakeDiffService(availability: .init(turn: true, uncommitted: true, branch: .init(current: "feature", defaultBranch: "main")))
        let store = OpenCodeDiffReviewStore(service: service, directory: "/repo")
        await store.open(OpenCodeDiffReviewRequest(messageID: "msg_old", files: ["a.txt"]), latestTurnMessageID: "msg_latest", sessionDiffs: [])
        #expect(store.sources == [.turn, .uncommitted, .branch])
        #expect(store.isPinnedTurn)
        #expect(await service.calls == ["turn:msg_old"])
    }

    @Test("Without a prompt or server support the reviewer explains why")
    func unavailable() async {
        let noTurn = OpenCodeDiffReviewStore(service: FakeDiffService(availability: .init(turn: true)), directory: "/repo")
        await noTurn.open(OpenCodeDiffReviewRequest(), latestTurnMessageID: nil, sessionDiffs: [])
        #expect(noTurn.phase == .unavailable(OpenCodeDiffReviewError.missingTurn.localizedDescription))
        let none = OpenCodeDiffReviewStore(service: FakeDiffService(availability: .none), directory: "/repo")
        await none.open(OpenCodeDiffReviewRequest(), latestTurnMessageID: "msg", sessionDiffs: [])
        #expect(none.phase == .unavailable(OpenCodeDiffAvailability.none.unavailableReason!))
        #expect(none.sources.isEmpty)
    }

    @Test("Legacy session diffs stay live, and failures keep the refreshed list")
    func sessionDiffsAndFailures() async {
        let service = FakeDiffService(availability: .init(turn: true), failing: [.turn])
        let store = OpenCodeDiffReviewStore(service: service, directory: "/repo")
        await store.open(OpenCodeDiffReviewRequest(), latestTurnMessageID: "msg", sessionDiffs: [diff])
        #expect(store.sources == [.turn, .session])
        if case .failed = store.phase {} else { Issue.record("A failed turn load must surface its error") }
        await store.select(.session)
        #expect(store.files.map(\.path) == ["a.txt"])
        store.updateSessionDiffs([])
        #expect(store.files.isEmpty)
        // The selected source stays in the picker until the reviewer leaves it.
        #expect(store.sources == [.turn, .session])
        await store.select(.turn)
        store.updateSessionDiffs([])
        #expect(store.sources == [.turn])
    }

    @Test("A failed negotiation shows a retry that negotiates again")
    func retryNegotiation() async {
        let service = FakeDiffService(availability: .init(turn: true), diffs: [.turn: [diff]], availabilityFailures: 1)
        let store = OpenCodeDiffReviewStore(service: service, directory: "/repo")
        await store.open(OpenCodeDiffReviewRequest(), latestTurnMessageID: "msg", sessionDiffs: [])
        if case .failed = store.phase {} else { Issue.record("An unreachable server must offer a retry") }
        #expect(store.source == nil)
        await store.refresh()
        #expect(store.source == .turn)
        #expect(store.files.map(\.path) == ["a.txt"])
    }

    @Test("Refreshing the latest turn follows a newer prompt; a pinned turn stays put")
    func refreshFollowsLatestTurn() async {
        let service = FakeDiffService(availability: .init(turn: true), diffs: [.turn: [diff]])
        let latest = OpenCodeDiffReviewStore(service: service, directory: "/repo")
        await latest.open(OpenCodeDiffReviewRequest(), latestTurnMessageID: nil, sessionDiffs: [])
        if case .unavailable = latest.phase {} else { Issue.record("No prompt yet means nothing to review") }
        await latest.refresh(latestTurnMessageID: "msg_new")
        #expect(latest.source == .turn)
        #expect(latest.turnMessageID == "msg_new")

        let pinned = OpenCodeDiffReviewStore(service: service, directory: "/repo")
        await pinned.open(OpenCodeDiffReviewRequest(messageID: "msg_old"), latestTurnMessageID: "msg_mid", sessionDiffs: [])
        await pinned.refresh(latestTurnMessageID: "msg_new")
        #expect(pinned.turnMessageID == "msg_old")
        #expect(await service.calls == ["turn:msg_new", "turn:msg_old", "turn:msg_old"])
    }

    @Test("A slow earlier source cannot replace the newer selection")
    func staleResponses() async throws {
        let service = FakeDiffService(availability: .init(turn: true, uncommitted: true),
                                      diffs: [.uncommitted: [diff]], delayed: [.turn])
        let store = OpenCodeDiffReviewStore(service: service, directory: "/repo")
        let opening = Task { await store.open(OpenCodeDiffReviewRequest(), latestTurnMessageID: "msg", sessionDiffs: []) }
        while await service.calls.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        await store.select(.uncommitted)
        await opening.value
        #expect(store.source == .uncommitted)
        #expect(store.files.map(\.path) == ["a.txt"])
    }
}

private actor FakeDiffService: OpenCodeDiffReviewServicing {
    let availabilityValue: OpenCodeDiffAvailability
    let responses: [OpenCodeDiffSource: [OpenCodeDiff]]
    let failing: Set<OpenCodeDiffSource>
    let delayed: Set<OpenCodeDiffSource>
    private(set) var calls: [String] = []

    init(availability: OpenCodeDiffAvailability, diffs: [OpenCodeDiffSource: [OpenCodeDiff]] = [:],
         failing: Set<OpenCodeDiffSource> = [], delayed: Set<OpenCodeDiffSource> = [], availabilityFailures: Int = 0) {
        availabilityValue = availability
        self.availabilityFailures = availabilityFailures
        responses = diffs
        self.failing = failing
        self.delayed = delayed
    }

    private var availabilityFailures: Int

    func availability() async throws -> OpenCodeDiffAvailability {
        guard availabilityFailures == 0 else {
            availabilityFailures -= 1
            throw OpenCodeConnectionError.httpStatus(502, "offline")
        }
        return availabilityValue
    }

    func diffs(_ source: OpenCodeDiffSource, messageID: String?) async throws -> [OpenCodeDiff] {
        calls.append("\(source.rawValue):\(messageID ?? "-")")
        if delayed.contains(source) { try await Task.sleep(for: .milliseconds(150)) }
        if failing.contains(source) { throw OpenCodeConnectionError.httpStatus(500, "boom") }
        return responses[source] ?? []
    }
}

private final class DiffTestTransport: OpenCodeHTTPTransport, @unchecked Sendable {
    struct Response {
        let data: Data
        let mime: String
        var status = 200
        static func json(_ value: Any) -> Self {
            .init(data: try! JSONSerialization.data(withJSONObject: value), mime: "application/json")
        }
    }

    let base: OpenCodeTransport
    let respond: @Sendable (URLRequest) -> Response
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }

    init(profile: OpenCodeServerProfile, respond: @escaping @Sendable (URLRequest) -> Response) {
        base = .init(profile: profile, password: "test", session: .shared)
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

    func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> { .init { $0.finish() } }
}
