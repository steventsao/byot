import Foundation
import Testing
@testable import byot

@Suite("Subagent navigation")
struct OpenCodeSubagentTests {
    @Test("A v1 task call names its child session, agent, answer, and run time")
    func v1TaskPart() throws {
        let part = try taskPart(status: "completed", metadata: ["sessionId": .string("ses_child"), "parentSessionId": .string("ses_parent")],
                                output: "<task id=\"ses_child\" state=\"completed\">\n<task_result>\nFound **3** callers.\n</task_result>\n</task>",
                                start: 1_000, end: 65_000)
        let task = try #require(OpenCodeSubagentTask(part: part))
        #expect(task.sessionID == "ses_child")
        #expect(task.description == "Find callers")
        #expect(task.agent == "explore")
        #expect(task.result == "Found **3** callers.")
        #expect(task.duration == 64)
        #expect(!task.isBackground)
        #expect(task.expectedChildTitle == "Find callers (@explore subagent)")
    }

    @Test("Without metadata the child ID comes from the result wrapper, current or earlier")
    func sessionIDFromOutput() {
        #expect(OpenCodeSubagentTask.childSessionID(metadata: nil, output: "<task id=\"ses_new\" state=\"running\">\n</task>") == "ses_new")
        #expect(OpenCodeSubagentTask.childSessionID(metadata: nil, output: "task_id: ses_old (for resuming to continue this task if needed)\n\n<task_result>\nDone\n</task_result>") == "ses_old")
        #expect(OpenCodeSubagentTask.childSessionID(metadata: ["sessionID": .string("ses_v2")], output: nil) == "ses_v2")
        #expect(OpenCodeSubagentTask.childSessionID(metadata: nil, output: "No session here") == nil)
        #expect(OpenCodeSubagentTask.resultText("task_id: ses_old\n\nPlain answer") == "Plain answer")
        #expect(OpenCodeSubagentTask.resultText("<task_error>\nboom\n</task_error>") == "boom")
    }

    @Test("Other tools are not task cards, and a running task has no result yet")
    func nonTaskParts() throws {
        let bash = try taskPart(status: "running", metadata: [:], output: nil, tool: "bash")
        #expect(OpenCodeSubagentTask(part: bash) == nil)
        let running = try #require(OpenCodeSubagentTask(part: try taskPart(status: "running", metadata: ["sessionId": .string("ses_child")], output: nil)))
        #expect(running.result == nil && running.duration == nil)
    }

    @Test("Tool metadata keeps only the subagent fields and never drops a part")
    func metadataRetention() throws {
        let edit: OpenCodeJSONValue = .object([
            "id": .string("prt_edit"), "sessionID": .string("ses_parent"), "messageID": .string("msg_a"), "type": .string("tool"),
            "tool": .string("edit"), "state": .object(["status": .string("completed"), "input": .object([:]),
                "metadata": .object(["filediff": .object(["before": .string("old file"), "after": .string("new file")])]),
                "time": .object(["start": .number(1)])])])
        let editPart = try JSONDecoder().decode(OpenCodePart.self, from: JSONEncoder().encode(edit))
        #expect(editPart.state?.metadata == nil)
        let odd: OpenCodeJSONValue = .object([
            "id": .string("prt_odd"), "sessionID": .string("ses_parent"), "messageID": .string("msg_a"), "type": .string("tool"),
            "tool": .string("task"), "state": .object(["status": .string("running"), "metadata": .string("unexpected"),
                "output": .string("<task id=\"ses_out\" state=\"running\">")])])
        let oddPart = try JSONDecoder().decode(OpenCodePart.self, from: JSONEncoder().encode(odd))
        #expect(OpenCodeSubagentTask(part: oddPart)?.sessionID == "ses_out")
        let task = try taskPart(status: "running", metadata: ["sessionId": .string("ses_child"), "parentSessionId": .string("ses_parent"),
                                                              "model": .object(["modelID": .string("m")]), "background": .bool(true)], output: nil)
        #expect(task.state?.metadata == ["sessionId": .string("ses_child"), "background": .bool(true)])
    }

    @Test("A card links only to a session the screen can open")
    @MainActor
    func linkGating() throws {
        let task = try #require(OpenCodeSubagentTask(part: try taskPart(status: "running", metadata: ["sessionId": .string("ses_child")], output: nil)))
        let child = session("ses_child", parent: "ses_parent")
        let unlisted = OpenCodeSubagentLinks(activity: [:], children: [], openingSessionID: nil, canOpenUnlisted: false) { _ in }
        #expect(unlisted.sessionID(for: task) == "ses_child" && !unlisted.canOpen("ses_child"))
        let listed = OpenCodeSubagentLinks(activity: [:], children: [child], openingSessionID: nil, canOpenUnlisted: false) { _ in }
        #expect(listed.canOpen("ses_child"))
        #expect(OpenCodeSubagentLinks(activity: [:], children: [], openingSessionID: nil, canOpenUnlisted: true) { _ in }.canOpen("ses_child"))
        let waiting = OpenCodeSubagentActivity(status: .busy, pendingRequestIDs: ["per_1"])
        #expect(OpenCodeSubagentCardPresentation(task: task, activity: waiting, isLinked: true).detail == "Open to answer")
        #expect(OpenCodeSubagentCardPresentation(task: task, activity: waiting, isLinked: false).detail == nil)
    }

    @Test("V2 projects a tool's structured record as its metadata")
    func v2StructuredMetadata() throws {
        let state = try #require(OpenCodeV2Normalization.toolState(
            ["status": .string("running"), "input": .object(["description": .string("Scan")]),
             "structured": .object(["sessionId": .string("ses_v2child"), "background": .bool(true)]), "content": .array([])],
            time: ["created": .number(1_000)]))
        #expect(state.metadata?["sessionId"] == .string("ses_v2child"))
        var reducer = OpenCodeTranscriptReducer()
        reducer.replace(with: [OpenCodeMessageEnvelope(
            info: try decode(#"{"id":"msg_a","sessionID":"ses_parent","role":"assistant","time":{"created":1}}"#), parts: [])])
        let called = OpenCodeEvent(id: "e1", type: "session.next.tool.called", properties: [
            "sessionID": .string("ses_parent"), "assistantMessageID": .string("msg_a"), "messageID": .string("msg_a"),
            "callID": .string("call_task"), "tool": .string("task"),
            "input": .object(["description": .string("Scan"), "subagent_type": .string("general")])], isV2: true)
        let progress = OpenCodeEvent(id: "e2", type: "session.next.tool.progress", properties: [
            "sessionID": .string("ses_parent"), "assistantMessageID": .string("msg_a"), "messageID": .string("msg_a"),
            "callID": .string("call_task"), "structured": .object(["sessionId": .string("ses_v2child")]),
            "content": .array([])], isV2: true)
        _ = reducer.applyV2(called)
        _ = reducer.applyV2(progress)
        let part = try #require(reducer.messages.first?.parts.first)
        #expect(OpenCodeSubagentTask(part: part)?.sessionID == "ses_v2child")
    }

    @Test("Subagent titles split into the task and a readable agent name")
    func titles() {
        #expect(OpenCodeSubagentTitle.parse("Find callers (@explore subagent)") == ("Find callers", "explore"))
        #expect(OpenCodeSubagentTitle.parse("Plain title") == ("Plain title", nil))
        #expect(OpenCodeSubagentTitle.parse("Odd (@ subagent)").agent == nil)
        #expect(OpenCodeSubagentTitle.agentLabel("code-reviewer") == "Code Reviewer")
        #expect(OpenCodeSubagentTitle.agentLabel(nil) == "Subagent")
        let child = session("ses_c", parent: "ses_p", title: "Find callers (@explore subagent)")
        #expect(OpenCodeSubagentTitle.displayTitle(of: child) == "Find callers")
        #expect(OpenCodeSubagentTitle.agent(of: child) == "explore")
        // A root session keeps its whole title, even one shaped like a subagent's.
        #expect(OpenCodeSubagentTitle.displayTitle(of: session("ses_r", parent: nil, title: "A (@b subagent)")) == "A (@b subagent)")
    }

    @Test("Siblings step in creation order without wrapping, and only a subagent has a family")
    func family() throws {
        let first = session("ses_1", parent: "ses_p", created: 10)
        let second = session("ses_2", parent: "ses_p", created: 20)
        let third = session("ses_3", parent: "ses_p", created: 30)
        let stranger = session("ses_x", parent: "ses_other", created: 15)
        let archived = session("ses_old", parent: "ses_p", created: 5, archived: 6)
        let parent = session("ses_p", parent: nil, title: "Main")
        // The current session counts even when the listing predates it.
        let middle = try #require(OpenCodeSubagentFamily(session: second, parent: parent, siblings: [third, first, stranger, archived]))
        #expect(middle.siblings.map(\.id) == ["ses_1", "ses_2", "ses_3"])
        #expect(middle.position == 2 && middle.count == 3)
        #expect(middle.previous?.id == "ses_1" && middle.next?.id == "ses_3")
        #expect(middle.parentTitle == "Main")
        let last = try #require(OpenCodeSubagentFamily(session: third, parent: nil, siblings: [first, second, third]))
        #expect(last.next == nil && last.previous?.id == "ses_2" && last.parentTitle == nil)
        #expect(OpenCodeSubagentFamily(session: parent, parent: nil, siblings: []) == nil)
    }

    @Test("The tracker follows only known children: status, tool calls, and waiting requests")
    func tracker() {
        var tracker = OpenCodeSubagentTracker()
        var changed = false
        changed = tracker.track(["ses_child"])
        #expect(changed)
        changed = tracker.track(["ses_child"])
        #expect(!changed)
        changed = tracker.apply(statusEvent("ses_other", "busy"))
        #expect(!changed)
        changed = tracker.apply(statusEvent("ses_child", "busy"))
        #expect(changed)
        #expect(tracker.activity["ses_child"]?.status == .busy)
        let readPart: OpenCodeJSONValue = .object([
            "id": .string("prt_read"), "sessionID": .string("ses_child"), "messageID": .string("msg_c"), "type": .string("tool"),
            "tool": .string("read"), "state": .object(["status": .string("running"),
                "input": .object(["filePath": .string("Sources/App.swift")]), "time": .object(["start": .number(1)])])])
        changed = tracker.apply(OpenCodeEvent(id: "p1", type: "message.part.updated", properties: ["sessionID": .string("ses_child"), "part": readPart]))
        #expect(changed)
        // Older servers name the session only inside the part.
        changed = tracker.apply(OpenCodeEvent(id: "p2", type: "message.part.updated", properties: ["part": readPart]))
        #expect(!changed)
        #expect(tracker.activity["ses_child"]?.toolCount == 1)
        #expect(tracker.activity["ses_child"]?.latestTool == "Read file · Sources/App.swift")
        changed = tracker.apply(OpenCodeEvent(id: "q1", type: "permission.asked", properties: ["id": .string("per_1"), "sessionID": .string("ses_child")]))
        #expect(changed)
        #expect(tracker.activity["ses_child"]?.needsResponse == true)
        changed = tracker.apply(OpenCodeEvent(id: "q2", type: "permission.replied", properties: ["requestID": .string("per_1"), "sessionID": .string("ses_child")]))
        #expect(changed)
        #expect(tracker.activity["ses_child"]?.needsResponse == false)
        tracker.applyPendingRequests([("ses_child", "que_1"), ("ses_other", "que_2")])
        #expect(tracker.activity["ses_child"]?.pendingRequestIDs == ["que_1"])
        #expect(tracker.activity["ses_other"] == nil)
        // v2 requests are known only from events, so a legacy snapshot (empty
        // on a v2 server) leaves them waiting until they are answered.
        changed = tracker.apply(OpenCodeEvent(id: "q3", type: "permission.v2.asked", properties: ["id": .string("per_v2"), "sessionID": .string("ses_child")], isV2: true))
        #expect(changed)
        tracker.applyPendingRequests([])
        #expect(tracker.activity["ses_child"]?.needsResponse == true)
        changed = tracker.apply(OpenCodeEvent(id: "q4", type: "permission.v2.replied", properties: ["requestID": .string("per_v2"), "sessionID": .string("ses_child")], isV2: true))
        #expect(changed)
        #expect(tracker.activity["ses_child"]?.needsResponse == false)
        tracker.applyStatuses([:])
        #expect(tracker.activity["ses_child"]?.status == .idle)
        changed = tracker.apply(OpenCodeEvent(id: "v2", type: "session.next.step.started", properties: ["sessionID": .string("ses_child")], isV2: true))
        #expect(changed)
        #expect(tracker.activity["ses_child"]?.status == .busy)
        changed = tracker.apply(OpenCodeEvent(id: "i", type: "session.idle", properties: ["sessionID": .string("ses_child")]))
        #expect(changed)
        changed = tracker.apply(OpenCodeEvent(id: "i2", type: "session.idle", properties: ["sessionID": .string("ses_child")]))
        #expect(!changed)
    }

    @Test("Task cards read the child's live state and the finished run's size")
    func cardPresentation() throws {
        let running = try #require(OpenCodeSubagentTask(part: try taskPart(status: "running", metadata: ["sessionId": .string("ses_child")], output: nil)))
        var activity = OpenCodeSubagentActivity(status: .busy, toolCallIDs: ["a", "b"], latestTool: "Search files · TODO")
        var card = OpenCodeSubagentCardPresentation(task: running, activity: activity, isLinked: true)
        #expect(card.phase == .running && card.detail == "Search files · TODO" && card.statusLabel == "Running")
        #expect(card.accessibilityLabel == "Explore subagent, Find callers, Running, Search files · TODO")
        activity.pendingRequestIDs = ["per_1"]
        card = OpenCodeSubagentCardPresentation(task: running, activity: activity, isLinked: true)
        #expect(card.phase == .needsResponse && card.statusLabel == "Needs your response")
        activity.pendingRequestIDs = []
        activity.status = .retry(attempt: 2, message: "Rate limited", next: 0)
        card = OpenCodeSubagentCardPresentation(task: running, activity: activity, isLinked: true)
        #expect(card.phase == .retrying && card.detail == "Attempt 2 · Rate limited")

        let done = try #require(OpenCodeSubagentTask(part: try taskPart(status: "completed", metadata: ["sessionId": .string("ses_child")],
                                                                        output: "<task_result>ok</task_result>", start: 1_000, end: 65_400)))
        activity.status = .idle
        card = OpenCodeSubagentCardPresentation(task: done, activity: activity, isLinked: true)
        #expect(card.phase == .completed && card.detail == "2 tool calls · 1m 4s")
        card = OpenCodeSubagentCardPresentation(task: done, activity: nil, isLinked: false)
        #expect(card.detail == "1m 4s" && !card.isLinked)

        let failed = try #require(OpenCodeSubagentTask(part: try taskPart(status: "error", metadata: [:], output: nil, error: "Task cancelled")))
        #expect(OpenCodeSubagentCardPresentation(task: failed, activity: nil, isLinked: false).phase == .failed)
        #expect(failed.error == "Task cancelled")
        let pending = try #require(OpenCodeSubagentTask(part: try taskPart(status: "pending", metadata: [:], output: nil)))
        #expect(OpenCodeSubagentCardPresentation(task: pending, activity: nil, isLinked: false).phase == .starting)
    }

    @Test("A background task runs until its child reports idle")
    func backgroundTask() throws {
        let task = try #require(OpenCodeSubagentTask(part: try taskPart(
            status: "completed", metadata: ["sessionId": .string("ses_bg"), "background": .bool(true)],
            output: "<task id=\"ses_bg\" state=\"running\">\n<task_result>\nThe task is working in the background.\n</task_result>\n</task>")))
        #expect(task.isBackground)
        #expect(OpenCodeSubagentCardPresentation(task: task, activity: nil, isLinked: true).phase == .background)
        let busy = OpenCodeSubagentCardPresentation(task: task, activity: OpenCodeSubagentActivity(status: .busy), isLinked: true)
        #expect(busy.phase == .running && busy.agentLabel == "Explore · Background")
        #expect(OpenCodeSubagentCardPresentation(task: task, activity: OpenCodeSubagentActivity(status: .idle), isLinked: true).phase == .completed)
        #expect(OpenCodeSubagentCardPresentation.durationText(3_725) == "1h 2m")
        #expect(OpenCodeSubagentCardPresentation.durationText(9.4) == "9s")
    }

    @Test("A parent follows its subagents from the transcript, the server, and live events")
    @MainActor
    func parentStore() async throws {
        let service = SubagentStoreService(statuses: ["ses_child": .busy])
        let store = OpenCodeSessionStore(service: service, serverID: UUID(), session: session("ses_parent", parent: nil, title: "Main"),
                                         directory: "/project", defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await store.start()
        defer { store.stop() }
        // The transcript's task call and the children listing both name the child.
        #expect(store.childSessions.map(\.id) == ["ses_child", "ses_sibling"])
        #expect(store.subagents.activity["ses_child"]?.status == .busy)
        #expect(store.subagents.activity["ses_sibling"]?.status == .idle)
        let revision = store.transcriptRevision
        store.handle(OpenCodeEvent(id: "s", type: "session.status", properties: [
            "sessionID": .string("ses_child"), "status": .object(["type": .string("idle")])]))
        #expect(store.subagents.activity["ses_child"]?.status == .idle)
        #expect(store.status == .idle && store.transcriptRevision == revision)
        let created = session("ses_new", parent: "ses_parent", created: 50, title: "Audit (@general subagent)")
        store.handle(OpenCodeEvent(id: "c", type: "session.created", properties: [
            "sessionID": .string("ses_new"), "info": try json(created)]))
        #expect(store.childSessions.last?.id == "ses_new")
        #expect(store.subagents.isTracking("ses_new"))
        store.handle(OpenCodeEvent(id: "d", type: "session.deleted", properties: [
            "sessionID": .string("ses_new"), "info": try json(created)]))
        #expect(!store.childSessions.contains { $0.id == "ses_new" })
        // Known children open without a request; others are fetched.
        #expect(await store.relatedSession("ses_child")?.id == "ses_child")
        #expect(await service.detailRequests.isEmpty)
        #expect(await store.relatedSession("ses_elsewhere")?.id == "ses_elsewhere")
        #expect(await service.detailRequests == ["ses_elsewhere"])
        #expect(store.subagentFamily == nil)
    }

    @Test("A subagent loads its parent and siblings and keeps them current")
    @MainActor
    func childStore() async throws {
        let service = SubagentStoreService(statuses: [:])
        let store = OpenCodeSessionStore(service: service, serverID: UUID(),
                                         session: session("ses_child", parent: "ses_parent", created: 10, title: "Find callers (@explore subagent)"),
                                         directory: "/project", defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await store.start()
        defer { store.stop() }
        let family = try #require(store.subagentFamily)
        #expect(family.parentTitle == "Main")
        #expect(family.position == 1 && family.count == 2)
        #expect(family.next?.id == "ses_sibling" && family.previous == nil)
        let renamed = session("ses_parent", parent: nil, title: "Renamed main")
        store.handle(OpenCodeEvent(id: "u", type: "session.updated", properties: ["sessionID": .string("ses_parent"), "info": try json(renamed)]))
        #expect(store.subagentFamily?.parentTitle == "Renamed main")
        let late = session("ses_late", parent: "ses_parent", created: 30)
        store.handle(OpenCodeEvent(id: "n", type: "session.created", properties: ["sessionID": .string("ses_late"), "info": try json(late)]))
        #expect(store.subagentFamily?.count == 3)
        #expect(await store.relatedSession("ses_parent")?.title == "Renamed main")
    }
}

// MARK: - Fixtures

private func taskPart(status: String, metadata: [String: OpenCodeJSONValue], output: String?,
                      error: String? = nil, start: Double = 1_000, end: Double? = nil,
                      tool: String = "task") throws -> OpenCodePart {
    var state: [String: OpenCodeJSONValue] = [
        "status": .string(status),
        "input": .object(["description": .string("Find callers"), "prompt": .string("Look"), "subagent_type": .string("explore")]),
        "metadata": .object(metadata),
    ]
    var time: [String: OpenCodeJSONValue] = ["start": .number(start)]
    if let end { time["end"] = .number(end) }
    state["time"] = .object(time)
    if let output { state["output"] = .string(output) }
    if let error { state["error"] = .string(error) }
    let part: OpenCodeJSONValue = .object([
        "id": .string("prt_task"), "sessionID": .string("ses_parent"), "messageID": .string("msg_a"),
        "type": .string("tool"), "callID": .string("call_task"), "tool": .string(tool), "state": .object(state),
    ])
    return try JSONDecoder().decode(OpenCodePart.self, from: JSONEncoder().encode(part))
}

private func decode<Value: Decodable>(_ json: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(json.utf8))
}

private func json(_ session: OpenCodeSession) throws -> OpenCodeJSONValue {
    try JSONDecoder().decode(OpenCodeJSONValue.self, from: JSONEncoder().encode(session))
}

private func statusEvent(_ sessionID: String, _ type: String) -> OpenCodeEvent {
    OpenCodeEvent(id: UUID().uuidString, type: "session.status", properties: [
        "sessionID": .string(sessionID), "status": .object(["type": .string(type)])])
}

private func session(_ id: String, parent: String?, created: Double = 1, archived: Double? = nil,
                     title: String? = nil) -> OpenCodeSession {
    OpenCodeSession(id: id, slug: id, projectID: "project", workspaceID: nil, directory: "/project", parentID: parent,
                    summary: nil, title: title ?? id, agent: nil, version: "1",
                    time: OpenCodeSessionTime(created: created, updated: created, compacting: nil, archived: archived))
}

private actor SubagentStoreService: OpenCodeSessionServicing, OpenCodeSessionFeatureServicing {
    let statuses: [String: OpenCodeSessionStatus]
    var detailRequests: [String] = []
    init(statuses: [String: OpenCodeSessionStatus]) { self.statuses = statuses }

    func sessionFeatureSupport() async throws -> OpenCodeSessionFeatureSupport {
        OpenCodeSessionFeatureSupport(details: true, children: true)
    }
    func sessionDetails(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSessionDetails {
        let value: OpenCodeSession
        switch sessionID {
        case "ses_parent": value = session("ses_parent", parent: nil, title: "Main")
        case "ses_child": value = session("ses_child", parent: "ses_parent", created: 10, title: "Find callers (@explore subagent)")
        default:
            detailRequests.append(sessionID)
            value = session(sessionID, parent: "ses_parent")
        }
        return OpenCodeSessionDetails(session: value, revertMessageID: nil)
    }
    func childSessions(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeSession] {
        guard sessionID == "ses_parent" else { return [] }
        return [session("ses_sibling", parent: "ses_parent", created: 20),
                session("ses_child", parent: "ses_parent", created: 10, title: "Find callers (@explore subagent)")]
    }
    func renameSession(sessionID: String, directory: String, workspace: String?, title: String) async throws -> OpenCodeSessionDetails { throw CancellationError() }
    func deleteSession(sessionID: String, directory: String, workspace: String?) async throws {}
    func archiveSession(sessionID: String, directory: String, workspace: String?) async throws {}
    func sessionTodos(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeTodo]? { nil }
    func stageSessionRevert(sessionID: String, directory: String, workspace: String?, messageID: String) async throws {}
    func clearSessionRevert(sessionID: String, directory: String, workspace: String?) async throws {}
    func commitSessionRevert(sessionID: String, directory: String, workspace: String?) async throws -> Bool { false }
    func compactSession(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?) async throws {}
    func forkSession(sessionID: String, directory: String, workspace: String?, beforeMessageID: String?) async throws -> OpenCodeSession { throw CancellationError() }
    func sessionSharePolicy(directory: String, workspace: String?) async throws -> OpenCodeSessionSharePolicy { .disabled }
    func shareSession(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSession { throw CancellationError() }
    func unshareSession(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSession { throw CancellationError() }

    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] { [] }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] {
        guard sessionID == "ses_parent" else { return [] }
        let user: OpenCodeMessageEnvelope = try decode(#"{"info":{"id":"msg_u","sessionID":"ses_parent","role":"user","time":{"created":1}},"parts":[{"id":"prt_u","sessionID":"ses_parent","messageID":"msg_u","type":"text","text":"Find callers"}]}"#)
        let part = try taskPart(status: "running", metadata: ["sessionId": .string("ses_child")], output: nil)
        let assistant = OpenCodeMessageEnvelope(
            info: try decode(#"{"id":"msg_a","sessionID":"ses_parent","role":"assistant","time":{"created":2}}"#), parts: [part])
        return [user, assistant]
    }
    func sendMessage(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String, attachments: [OpenCodePromptAttachment], promptID: UUID) async throws {}
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool { true }
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff] { [] }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] { statuses }
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest] { [] }
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest] { [] }
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] { [] }
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] { [] }
    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?, reply: OpenCodePermissionReply) async throws {}
    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws {}
    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?) async throws {}
    nonisolated func events(directory: String, workspace: String?) -> AsyncThrowingStream<OpenCodeEvent, Error> { AsyncThrowingStream { _ in } }
}
