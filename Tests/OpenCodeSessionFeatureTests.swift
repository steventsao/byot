import Foundation
import Testing
@testable import byot

@Suite("Session feature contracts")
struct OpenCodeSessionFeatureTests {
    @Test("V1 lifecycle and recovery use scoped routes and exact bodies")
    func v1Requests() async throws {
        let transport = SessionFeatureTransport(v2: false)
        let service = featureService(transport: transport, v2: false)
        _ = try await service.details("ses_one", directory: "/project", workspace: "wrk_one")
        _ = try await service.rename("ses_one", directory: "/project", workspace: "wrk_one", title: " Updated ")
        _ = try await service.children("ses_one", directory: "/project", workspace: "wrk_one")
        _ = try await service.todos("ses_one", directory: "/project", workspace: "wrk_one")
        try await service.stage("ses_one", directory: "/project", workspace: "wrk_one", messageID: "msg_two")
        try await service.clear("ses_one", directory: "/project", workspace: "wrk_one")
        try await service.compact("ses_one", directory: "/project", workspace: "wrk_one", model: Self.model)
        _ = try await service.fork("ses_one", directory: "/project", workspace: "wrk_one", beforeMessageID: "msg_two")
        try await service.delete("ses_one", directory: "/project", workspace: "wrk_one")
        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["GET", "PATCH", "GET", "GET", "POST", "POST", "POST", "POST", "DELETE"])
        #expect(requests.allSatisfy { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "workspace", value: "wrk_one")) == true })
        #expect(try body(requests[1]) == ["title": .string("Updated")])
        #expect(try body(requests[4]) == ["messageID": .string("msg_two")])
        #expect(try body(requests[6]) == ["providerID": .string("provider"), "modelID": .string("model")])
        #expect(try body(requests[7]) == ["messageID": .string("msg_two")])
    }

    @Test("V2 lifecycle, reversible conversation undo, compact, and fork match beta schema")
    func v2Requests() async throws {
        let transport = SessionFeatureTransport(v2: true)
        let service = featureService(transport: transport, v2: true)
        _ = try await service.rename("ses_one", directory: "/project", workspace: "wrk_one", title: "New name")
        _ = try await service.children("ses_one", directory: "/project", workspace: "wrk_one")
        try await service.stage("ses_one", directory: "/project", workspace: "wrk_one", messageID: "msg_two")
        try await service.clear("ses_one", directory: "/project", workspace: "wrk_one")
        try await service.compact("ses_one", directory: "/project", workspace: "wrk_one", model: nil)
        _ = try await service.fork("ses_one", directory: "/project", workspace: "wrk_one", beforeMessageID: "msg_two")
        _ = try await service.fork("ses_one", directory: "/project", workspace: "wrk_one", beforeMessageID: nil)
        try await service.delete("ses_one", directory: "/project", workspace: "wrk_one")
        let requests = await transport.requests
        let paths = requests.map { $0.url!.path }
        #expect(paths.prefix(3) == ["/api/session/ses_one/rename", "/api/session/ses_one", "/api/session"])
        #expect(paths.contains("/api/session/ses_one/inbox/pending"))
        let stage = try #require(requests.first { $0.url!.path.hasSuffix("/revert/stage") })
        #expect(try body(stage) == ["messageID": .string("msg_two"), "files": .bool(false)])
        let compact = try #require(requests.first { $0.url!.path.hasSuffix("/compact") })
        #expect(try body(compact).isEmpty)
        let forks = requests.filter { $0.url!.path.hasSuffix("/fork") }
        #expect(try body(forks[0]) == ["boundary": .object(["type": .string("before"), "messageID": .string("msg_two")])])
        #expect(try body(forks[1]) == ["boundary": .object(["type": .string("through")])])
        #expect(requests.filter { $0.url!.path != "/api/session" }.allSatisfy { $0.url!.query == nil })
    }

    @Test("V2 fork lineage stays distinct from the parent used to filter subagent sessions")
    func forkSourceRemainsRoot() throws {
        let value: [String: OpenCodeJSONValue] = [
            "id": .string("ses_fork"),
            "fork": .object(["sessionID": .string("ses_source"), "boundary": .object(["type": .string("through"), "messageID": .string("msg_last")])]),
            "location": .object(["directory": .string("/project")])
        ]
        let session = try #require(OpenCodeV2Normalization.session(value))
        #expect(session.parentID == nil)
        #expect(session.forkSourceID == "ses_source")
        var childValue = value
        childValue["parentID"] = .string("ses_agent_parent")
        let child = try #require(OpenCodeV2Normalization.session(childValue))
        #expect(child.parentID == "ses_agent_parent")
        #expect(child.forkSourceID == "ses_source")
    }

    @Test("Unsupported v2 features and task snapshots never probe guessed endpoints")
    func unsupportedDoesNotSend() async throws {
        let transport = SessionFeatureTransport(v2: true)
        let service = featureService(transport: transport, v2: true, supported: false)
        #expect(!service.support.undo && !service.support.children && !service.support.fork)
        #expect(try await service.todos("ses_one", directory: "/project", workspace: nil) == nil)
        await #expect(throws: OpenCodeSessionFeatureError.self) { try await service.stage("ses_one", directory: "/project", workspace: nil, messageID: "msg_two") }
        await #expect(throws: OpenCodeSessionFeatureError.self) { try await service.fork("ses_one", directory: "/project", workspace: nil, beforeMessageID: nil) }
        #expect(await transport.requests.isEmpty)
    }

    @Test("Failed authoritative queue cancellation prevents undo mutation")
    func inboxFailureStopsUndo() async throws {
        let transport = SessionFeatureTransport(v2: true, failCancellation: true)
        let service = featureService(transport: transport, v2: true)
        await #expect(throws: (any Error).self) { try await service.stage("ses_one", directory: "/project", workspace: nil, messageID: "msg_two") }
        #expect(await transport.requests.allSatisfy { !$0.url!.path.hasSuffix("/revert/stage") })
    }

    @Test("Task events replace the ordered snapshot and a stale fetch cannot overwrite them")
    @MainActor
    func todosReconcile() async throws {
        let service = FeatureStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        #expect(store.todoProgress.items == [Self.pending])
        await service.setTodoDelay(true)
        let refresh = Task { await store.refreshSessionFeatures() }
        try await Task.sleep(for: .milliseconds(10))
        store.handle(Self.todoEvent([Self.completed]))
        await refresh.value
        #expect(store.todoProgress.items == [Self.completed])
        store.handle(Self.todoEvent([], sessionID: "other"))
        #expect(store.todoProgress.items == [Self.completed])
        await service.setTodoDelay(false)
        await service.setTodos([])
        store.handle(OpenCodeEvent(id: "connected", type: "server.connected", properties: [:]))
        for _ in 0..<100 where store.todoProgress.items != [] { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.todoProgress.items == [])
    }

    @Test("Undo restores the original prompt, hides reverted history, and pauses queued prompts through idle reconciliation")
    @MainActor
    func undoQueueSafety() async throws {
        let service = FeatureStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        store.handle(OpenCodeEvent(id: "busy", type: "session.status", properties: ["sessionID": .string("ses_one"), "status": .object(["type": .string("busy")])]))
        #expect(store.send("Follow-up against old history"))
        await store.stopTurn()
        #expect(store.queuedPrompts.count == 1)
        await service.omitRevertedSnapshots()
        await store.performSessionAction(.undo)
        await store.refresh()
        #expect(store.restoredPrompt?.message.id == "msg_two")
        #expect(store.messages.map(\.id) == ["msg_one", "msg_answer"])
        #expect(store.queuedPrompts.count == 1)
        #expect(!store.willQueueNextPrompt)
        #expect(await service.sentCount == 0)
        #expect(store.canRetryFirstQueuedPrompt)
        await store.performSessionAction(.undo)
        #expect(store.messages.isEmpty)
        await store.performSessionAction(.redo)
        #expect(store.revertMessageID == "msg_two")
        await store.performSessionAction(.redo)
        #expect(store.revertMessageID == nil)
        #expect(store.messages.count == 3)
        #expect(store.restoredPrompt?.message.parts.isEmpty == true)
        #expect(await service.sentCount == 0)
    }

    @Test("A refresh during stage preserves redo boundaries after the server omits undone messages")
    @MainActor
    func refreshDuringUndoKeepsRecoveryHistory() async throws {
        let service = FeatureStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        await service.omitRevertedSnapshots()
        await service.setStagePaused(true)
        let undo = Task { await store.performSessionAction(.undo) }
        for _ in 0..<100 {
            if await service.stageStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.stageStarted)
        // Details still report no revert while its stage request is pending.
        // Publishing this snapshot must not erase the saved user boundaries.
        await store.refresh()
        await service.resumeStage()
        await undo.value
        await service.setStagePaused(false)
        await store.performSessionAction(.undo)
        #expect(store.revertMessageID == "msg_one")
        await store.performSessionAction(.redo)
        #expect(store.revertMessageID == "msg_two")
        #expect(store.messages.map(\.id) == ["msg_one", "msg_answer"])
    }

    @Test("An edited undo prompt commits v2 history before dispatch and leaves old queued work paused")
    @MainActor
    func revisedPromptCommitsBeforeDispatch() async throws {
        let service = FeatureStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        store.handle(OpenCodeEvent(id: "busy", type: "session.status", properties: ["sessionID": .string("ses_one"), "status": .object(["type": .string("busy")])]))
        #expect(store.send("Old queued prompt"))
        await store.stopTurn()
        await store.performSessionAction(.undo)
        #expect(store.send("Revised direction"))
        for _ in 0..<100 where await service.sentCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await service.committed)
        #expect(await service.sentTexts == ["Revised direction"])
        #expect(store.queuedPrompts.map(\.text) == ["Old queued prompt"])
    }

    @Test("Running sessions disable recovery; rename and fork keep the correct session scope")
    @MainActor
    func lifecycleState() async throws {
        let service = FeatureStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        #expect(await store.renameSession("Renamed"))
        #expect(store.session.title == "Renamed")
        await store.loadRelatedSessions()
        #expect(store.childSessions.first?.parentID == "ses_one")
        await store.performSessionAction(.fork, messageID: "msg_two")
        #expect(store.forkedSession?.id == "ses_child")
        #expect(await service.lastForkMessage == "msg_two")
        store.handle(OpenCodeEvent(id: "busy", type: "session.status", properties: ["sessionID": .string("ses_one"), "status": .object(["type": .string("busy")])]))
        #expect(store.actionUnavailableReason(.undo) != nil)
        #expect(!(await store.deleteSession()))
        await store.stopTurn()
        #expect(await store.deleteSession())
        #expect(store.didDeleteSession && !store.canSubmitPrompt)
    }

    private static let model = OpenCodeModelOption(providerID: "provider", providerName: "Provider", modelID: "model", modelName: "Model", status: nil)
    fileprivate static let pending = OpenCodeTodo(content: "Check implementation", status: "in_progress", priority: "high")
    fileprivate static let completed = OpenCodeTodo(content: "Check implementation", status: "completed", priority: "high")
    private func body(_ request: URLRequest) throws -> [String: OpenCodeJSONValue] {
        try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: #require(request.httpBody))
    }
    @MainActor private func makeStore(_ service: FeatureStoreService) -> OpenCodeSessionStore {
        OpenCodeSessionStore(service: service, serverID: UUID(), session: featureSession(), directory: "/project", defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }
    private static func todoEvent(_ todos: [OpenCodeTodo], sessionID: String = "ses_one") -> OpenCodeEvent {
        let value = try! JSONDecoder().decode(OpenCodeJSONValue.self, from: JSONEncoder().encode(todos))
        return OpenCodeEvent(id: UUID().uuidString, type: "todo.updated", properties: ["sessionID": .string(sessionID), "todos": value])
    }
}

private func featureService(transport: SessionFeatureTransport, v2: Bool, supported: Bool = true) -> OpenCodeSessionFeatureService {
    let routes = ["/api/session", "/api/session/{sessionID}", "/api/session/{sessionID}/rename", "/api/session/{sessionID}/fork", "/api/session/{sessionID}/compact", "/api/session/{sessionID}/revert/stage", "/api/session/{sessionID}/revert/clear", "/api/session/{sessionID}/revert/commit", "/api/session/{sessionID}/inbox", "/api/session/{sessionID}/inbox/{inboxID}"]
    let operations: OpenCodeJSONValue = .object(["get": .object([:]), "post": .object([:]), "delete": .object([:])])
    let schema: OpenCodeJSONValue = .object(["paths": .object(supported ? Dictionary(uniqueKeysWithValues: routes.map { ($0, operations) }) : [:])])
    return OpenCodeSessionFeatureService(context: OpenCodeFeatureContext(serverProtocol: v2 ? .v2 : .v1, schema: schema, transport: transport, profile: OpenCodeServerProfile(name: "Test", baseURL: "https://test.example", directory: "/project")))
}

private actor SessionFeatureTransport: OpenCodeHTTPTransport {
    let v2: Bool
    let failCancellation: Bool
    var requests: [URLRequest] = []
    init(v2: Bool, failCancellation: Bool = false) { self.v2 = v2; self.failCancellation = failCancellation }
    nonisolated func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        var components = URLComponents(string: "https://features.test/" + path.joined(separator: "/"))!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method; request.httpBody = body
        return request
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url!.path
        var result: OpenCodeJSONValue = try JSONDecoder().decode(OpenCodeJSONValue.self, from: JSONEncoder().encode(featureSession()))
        if v2 { result = .object(["data": result]) }
        if path.hasSuffix("/todo") || path.hasSuffix("/children") { result = .array([]) }
        if path.hasSuffix("/summarize") { result = .bool(true) }
        if path == "/api/session" { result = .object(["data": .array([]), "cursor": .object([:])]) }
        if path.hasSuffix("/inbox") { result = .object(["data": .array([.object(["type": .string("user"), "id": .string("pending")])])]) }
        if failCancellation && path.hasSuffix("/inbox/pending") { throw OpenCodeSessionFeatureError(message: "Cancellation failed") }
        let status = v2 && (request.httpMethod == "DELETE" || path.hasSuffix("/rename") || path.hasSuffix("/clear")) ? 204 : 200
        return (status == 204 ? Data() : try JSONEncoder().encode(result), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
    nonisolated func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> { AsyncThrowingStream { _ in } }
}

private func featureSession(id: String = "ses_one", parentID: String? = nil, title: String = "Session") -> OpenCodeSession {
    OpenCodeSession(id: id, slug: id, projectID: "project", workspaceID: nil, directory: "/project", parentID: parentID, summary: nil, title: title, agent: nil, version: "1", time: OpenCodeSessionTime(created: 1, updated: 2, compacting: nil, archived: nil))
}

private actor FeatureStoreService: OpenCodeSessionServicing, OpenCodeSessionFeatureServicing {
    var currentSession = featureSession()
    var revert: String?
    var todoValues = [OpenCodeSessionFeatureTests.pending]
    var todoDelay = false
    var sentCount = 0
    var sentTexts: [String] = []
    var lastForkMessage: String?
    var omitRevertedMessages = false
    var committed = false
    var stagePaused = false
    var stageStarted = false
    var stageContinuation: CheckedContinuation<Void, Never>?
    func setStagePaused(_ value: Bool) { stagePaused = value }
    func resumeStage() { stageContinuation?.resume(); stageContinuation = nil }
    func omitRevertedSnapshots() { omitRevertedMessages = true }
    func setTodoDelay(_ value: Bool) { todoDelay = value }
    func setTodos(_ value: [OpenCodeTodo]) { todoValues = value }
    func sessionFeatureSupport() async throws -> OpenCodeSessionFeatureSupport { OpenCodeSessionFeatureSupport(details: true, rename: true, delete: true, children: true, todoSnapshot: true, undo: true, redo: true, compact: true, fork: true) }
    func sessionDetails(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSessionDetails { OpenCodeSessionDetails(session: currentSession, revertMessageID: revert) }
    func renameSession(sessionID: String, directory: String, workspace: String?, title: String) async throws -> OpenCodeSessionDetails { currentSession = featureSession(title: title); return OpenCodeSessionDetails(session: currentSession, revertMessageID: revert) }
    func deleteSession(sessionID: String, directory: String, workspace: String?) async throws {}
    func childSessions(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeSession] { [featureSession(id: "ses_child", parentID: sessionID)] }
    func sessionTodos(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeTodo]? { let snapshot = todoValues; if todoDelay { try await Task.sleep(for: .milliseconds(75)) }; return snapshot }
    func stageSessionRevert(sessionID: String, directory: String, workspace: String?, messageID: String) async throws {
        stageStarted = true
        if stagePaused { await withCheckedContinuation { stageContinuation = $0 } }
        revert = messageID
    }
    func clearSessionRevert(sessionID: String, directory: String, workspace: String?) async throws { revert = nil }
    func commitSessionRevert(sessionID: String, directory: String, workspace: String?) async throws -> Bool { revert = nil; committed = true; return true }
    func compactSession(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?) async throws {}
    func forkSession(sessionID: String, directory: String, workspace: String?, beforeMessageID: String?) async throws -> OpenCodeSession { lastForkMessage = beforeMessageID; return featureSession(id: "ses_child", parentID: sessionID) }
    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] { [] }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] {
        let all = try JSONDecoder().decode([OpenCodeMessageEnvelope].self, from: Data(#"[{"info":{"id":"msg_one","sessionID":"ses_one","role":"user","time":{"created":1}},"parts":[{"id":"part_one","sessionID":"ses_one","messageID":"msg_one","type":"text","text":"First"}]},{"info":{"id":"msg_answer","sessionID":"ses_one","role":"assistant","time":{"created":2}},"parts":[{"id":"part_answer","sessionID":"ses_one","messageID":"msg_answer","type":"text","text":"Answer"}]},{"info":{"id":"msg_two","sessionID":"ses_one","role":"user","time":{"created":3}},"parts":[{"id":"part_two","sessionID":"ses_one","messageID":"msg_two","type":"text","text":"Second"}]}]"#.utf8))
        if omitRevertedMessages, let revert, let index = all.firstIndex(where: { $0.id == revert }) { return Array(all.prefix(index)) }
        return all
    }
    func sendMessage(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String, attachments: [OpenCodePromptAttachment], promptID: UUID) async throws { sentCount += 1; sentTexts.append(text) }
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool { true }
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff] { [] }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] { [:] }
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest] { [] }
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest] { [] }
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] { [] }
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] { [] }
    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?, reply: OpenCodePermissionReply) async throws {}
    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws {}
    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?) async throws {}
    nonisolated func events(directory: String, workspace: String?) -> AsyncThrowingStream<OpenCodeEvent, Error> { AsyncThrowingStream { _ in } }
}
