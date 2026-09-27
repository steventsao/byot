import Foundation
import Testing
@testable import byot

// Current opencode publishes live session events as session.next.*
// (packages/schema/src/session-event.ts); the beta names stay supported.
@Suite("OpenCode v2 live streaming")
struct OpenCodeV2StreamingTests {
    @Test("session.next names map onto the beta reducer vocabulary")
    func canonicalNames() {
        #expect(OpenCodeV2EventReducer.canonicalType("session.next.text.delta") == "session.text.delta")
        #expect(OpenCodeV2EventReducer.canonicalType("session.next.tool.input.started") == "session.tool.input.started")
        #expect(OpenCodeV2EventReducer.canonicalType("session.text.delta") == "session.text.delta")
        #expect(OpenCodeV2EventReducer.canonicalType("message.part.delta") == "message.part.delta")
    }

    @Test("A captured session.next turn streams token by token and lands on its projection")
    func capturedTurnMatchesProjection() throws {
        let fixture = try StreamFixture.load()
        var reducer = OpenCodeTranscriptReducer()
        var streamedText: [String] = []
        var streamedInput: [String] = []
        for event in fixture.events {
            #expect(reducer.applyV2(event) != .unresolved, "\(event.type) was not placed")
            let latest = reducer.messages.last?.parts.last
            switch event.type {
            case "session.next.text.delta": streamedText.append(latest?.text ?? "")
            case "session.next.tool.input.delta": streamedInput.append(latest?.state?.raw ?? "")
            default: break
            }
        }
        #expect(streamedText == ["The README.md", "The README.md simply says", #"The README.md simply says "hi"."#])
        #expect(streamedInput.first == #"{"path": "#)
        #expect(streamedInput.last == #"{"path": "README.md"}"#)
        #expect(reducer.messages == fixture.messages)
    }

    @Test("Text and reasoning fragments route by block ID, not only by the latest block")
    func blocksRouteByID() throws {
        var stream = LiveStream()
        try stream.send("step.started", #""agent":"build","model":{"id":"m","providerID":"p"}"#)
        #expect(try stream.send("reasoning.started", #""reasoningID":"r1""#) == .changed)
        #expect(try stream.send("reasoning.delta", #""reasoningID":"r1","delta":"Plan""#) == .changed)
        try stream.send("text.started", #""textID":"t1""#)
        try stream.send("text.delta", #""textID":"t1","delta":"Hel""#)
        try stream.send("reasoning.delta", #""reasoningID":"r1","delta":" more""#)
        try stream.send("text.delta", #""textID":"t1","delta":"lo""#)
        try stream.send("text.started", #""textID":"t2""#)
        try stream.send("text.delta", #""textID":"t1","delta":"!""#)
        try stream.send("text.delta", #""textID":"t2","delta":"Next""#)
        #expect(stream.parts.map(\.text) == ["Plan more", "Hello!", "Next"])
        #expect(try stream.send("text.ended", #""textID":"t1","text":"Hello!""#) == .unchanged)
        #expect(try stream.send("reasoning.ended", #""reasoningID":"r1","text":"Plan more, revised""#) == .changed)
        #expect(stream.parts.map(\.id) == ["msg_live:reasoning:0", "msg_live:text:0", "msg_live:text:1"])
        #expect(stream.parts.map(\.text) == ["Plan more, revised", "Hello!", "Next"])
        #expect(stream.parts.map(\.type) == ["reasoning", "text", "text"])
    }

    @Test("Tool input, progress checkpoints and results update one tool part in place")
    func toolLifecycle() throws {
        var stream = LiveStream()
        try stream.send("step.started", #""agent":"build","model":{"id":"m","providerID":"p"}"#)
        try stream.send("tool.input.started", #""callID":"call_1","name":"bash""#)
        #expect(stream.tool?.state?.status == "pending")
        #expect(stream.tool?.state?.raw == "")
        try stream.send("tool.input.delta", #""callID":"call_1","delta":"{\"command\":""#)
        try stream.send("tool.input.delta", #""callID":"call_1","delta":" \"ls\"}""#)
        #expect(stream.tool?.state?.raw == #"{"command": "ls"}"#)
        try stream.send("tool.input.ended", #""callID":"call_1","text":"{\"command\":\"ls\"}""#)
        #expect(stream.tool?.state?.raw == #"{"command":"ls"}"#)
        let called = try stream.send("tool.called", #""callID":"call_1","tool":"bash","input":{"command":"ls"},"provider":{"executed":false}"#)
        #expect(called == .changed)
        #expect(stream.tool?.state?.status == "running")
        #expect(stream.tool?.state?.input?["command"] == .string("ls"))
        #expect(stream.tool?.state?.raw == nil)
        try stream.send("tool.progress", #""callID":"call_1","structured":{},"content":[{"type":"text","text":"a.txt\n"}]"#)
        #expect(stream.tool?.state?.output == "a.txt\n")
        try stream.send("tool.progress", #""callID":"call_1","structured":{},"content":[{"type":"text","text":"a.txt\nb.txt\n"}]"#)
        #expect(stream.tool?.state?.output == "a.txt\nb.txt\n")
        try stream.send("tool.success", #""callID":"call_1","structured":{"exit":0},"content":[{"type":"text","text":"a.txt\nb.txt\n"},{"type":"text","text":"Command exited with code 0."}],"provider":{"executed":false}"#)
        let tool = try #require(stream.tool)
        #expect(tool.tool == "bash")
        #expect(tool.callID == "call_1")
        #expect(tool.state?.status == "completed")
        #expect(tool.state?.output == "a.txt\nb.txt\n\nCommand exited with code 0.")
        #expect(tool.state?.time == OpenCodeToolTime(start: 6, end: 9))
        #expect(stream.parts.count == 1)
        // Late checkpoints and failures cannot reopen a settled tool.
        #expect(try stream.send("tool.progress", #""callID":"call_1","structured":{},"content":[]"#) == .unchanged)
        #expect(try stream.send("tool.failed", #""callID":"call_1","error":{"type":"unknown","message":"late"},"provider":{"executed":false}"#) == .unchanged)
        #expect(stream.tool?.state?.status == "completed")
    }

    @Test("A failed tool keeps its input and shows the server's error")
    func toolFailure() throws {
        var stream = LiveStream()
        try stream.send("step.started", #""agent":"build","model":{"id":"m","providerID":"p"}"#)
        try stream.send("tool.input.started", #""callID":"call_1","name":"edit""#)
        try stream.send("tool.called", #""callID":"call_1","tool":"edit","input":{"path":"a.swift"},"provider":{"executed":false}"#)
        try stream.send("tool.failed", #""callID":"call_1","error":{"type":"unknown","message":"Tool execution aborted"},"provider":{"executed":false}"#)
        #expect(stream.tool?.state?.status == "error")
        #expect(stream.tool?.state?.error == "Tool execution aborted")
        #expect(stream.tool?.state?.input?["path"] == .string("a.swift"))
        #expect(stream.tool?.state?.time?.end == 4)
    }

    @Test("A fragment whose block start was missed still streams, and the block end heals it")
    func missedStartHeals() throws {
        var stream = LiveStream()
        try stream.send("step.started", #""agent":"build","model":{"id":"m","providerID":"p"}"#)
        #expect(try stream.send("text.delta", #""textID":"t1","delta":"lo""#) == .changed)
        #expect(stream.parts.map(\.id) == ["msg_live:text:0"])
        #expect(stream.parts.map(\.text) == ["lo"])
        try stream.send("text.ended", #""textID":"t1","text":"Hello""#)
        #expect(stream.parts.map(\.text) == ["Hello"])
        // A fragment for an assistant the client never saw reconciles instead.
        #expect(try stream.send("text.delta", #""textID":"t1","delta":"x""#, messageID: "msg_unknown") == .unresolved)
    }

    @Test("Step boundaries settle the assistant, including failures")
    func stepSettlement() throws {
        var stream = LiveStream()
        try stream.send("step.started", #""agent":"build","model":{"id":"model-a","providerID":"provider-a"}"#)
        let started = try #require(stream.reducer.messages.first?.info)
        #expect(started.role == "assistant")
        #expect(started.agent == "build")
        #expect(started.modelID == "model-a")
        #expect(started.time.completed == nil)
        try stream.send("step.failed", #""error":{"type":"unknown","message":"Provider request failed with HTTP 400"}"#)
        let failed = try #require(stream.reducer.messages.first?.info)
        #expect(failed.finish == "error")
        #expect(failed.time == OpenCodeMessageTime(created: 1, completed: 2))
        #expect(failed.error?.displayMessage == "Provider request failed with HTTP 400")
        #expect(failed.agent == "build")
    }

    @Test("Prompt, switch, context, shell and compaction events match refetched messages")
    func projectionEventsMatchSnapshots() throws {
        var reducer = OpenCodeTranscriptReducer()
        let events = [
            #"{"id":"e1","type":"session.next.prompted","metadata":{"displayText":"Fix it"},"data":{"timestamp":1,"sessionID":"ses_live","messageID":"msg_1","prompt":{"text":"Fix @a.txt","files":[{"uri":"data:text/plain;base64,aGk=","mime":"text/plain","name":"a.txt"}]},"delivery":"queue"}}"#,
            #"{"id":"e2","type":"session.next.agent.switched","data":{"timestamp":2,"sessionID":"ses_live","messageID":"msg_2","agent":"plan"}}"#,
            #"{"id":"e3","type":"session.next.context.updated","data":{"timestamp":3,"sessionID":"ses_live","messageID":"msg_3","text":"Context refreshed"}}"#,
            #"{"id":"e4","type":"session.next.shell.started","data":{"timestamp":4,"sessionID":"ses_live","messageID":"msg_4","callID":"sh_1","command":"ls"}}"#,
            #"{"id":"e5","type":"session.next.shell.ended","data":{"timestamp":5,"sessionID":"ses_live","callID":"sh_1","output":"a.txt"}}"#,
            #"{"id":"e6","type":"session.next.compaction.started","data":{"timestamp":6,"sessionID":"ses_live","messageID":"msg_6","reason":"manual"}}"#,
            #"{"id":"e7","type":"session.next.compaction.delta","data":{"timestamp":7,"sessionID":"ses_live","messageID":"msg_6","text":"Sum"}}"#,
            #"{"id":"e8","type":"session.next.compaction.ended","data":{"timestamp":8,"sessionID":"ses_live","messageID":"msg_6","reason":"manual","text":"Summary","recent":"Recent"}}"#,
        ]
        let outcomes = try events.map { reducer.applyV2(try JSONDecoder().decode(OpenCodeEvent.self, from: Data($0.utf8))) }
        #expect(outcomes == [.changed, .changed, .changed, .changed, .changed, .unchanged, .unchanged, .changed])
        let snapshot = #"""
            [{"id":"msg_1","type":"user","metadata":{"displayText":"Fix it"},"text":"Fix @a.txt","files":[{"uri":"data:text/plain;base64,aGk=","mime":"text/plain","name":"a.txt"}],"time":{"created":1}},
             {"id":"msg_2","type":"agent-switched","agent":"plan","time":{"created":2}},
             {"id":"msg_3","type":"system","text":"Context refreshed","time":{"created":3}},
             {"id":"msg_4","type":"shell","callID":"sh_1","command":"ls","output":"a.txt","time":{"created":4,"completed":5}},
             {"id":"msg_6","type":"compaction","reason":"manual","summary":"Summary","recent":"Recent","time":{"created":8}}]
            """#
        let objects = try JSONDecoder().decode([[String: OpenCodeJSONValue]].self, from: Data(snapshot.utf8))
        let expected = objects.compactMap { OpenCodeV2Normalization.message($0, sessionID: "ses_live") }
        #expect(expected.count == 5)
        #expect(reducer.messages == expected)
        #expect(reducer.messages.first?.parts.map(\.text) == ["Fix it", nil])
        #expect(reducer.messages.first?.parts.last?.filename == "a.txt")
    }

    @Test("Admission, relocation, retries and duplicates leave the transcript untouched")
    func neutralEvents() throws {
        var stream = LiveStream()
        #expect(try stream.send("prompt.admitted", #""messageID":"msg_1","prompt":{"text":"Hi"},"delivery":"queue""#) == .unchanged)
        #expect(try stream.send("moved", #""location":{"directory":"/repo"}"#) == .unchanged)
        #expect(try stream.send("retried", #""attempt":1,"error":{"message":"Rate limited","isRetryable":true}"#) == .unchanged)
        #expect(stream.reducer.messages.isEmpty)
        try stream.send("step.started", #""agent":"build","model":{"id":"m","providerID":"p"}"#)
        try stream.send("text.started", #""textID":"t1""#)
        let delta = try stream.event("text.delta", #""textID":"t1","delta":"Hi""#)
        #expect(stream.reducer.applyV2(delta) == .changed)
        #expect(stream.reducer.applyV2(delta) == .unchanged)
        #expect(stream.parts.map(\.text) == ["Hi"])
        #expect(try stream.send("future.event", #""messageID":"msg_live""#) == .unresolved)
    }

    @Test("Beta and session.next streams build the same transcript")
    func legacyAndNextAgree() throws {
        let fields = [
            ("step.started", #""agent":"build","model":{"id":"m","providerID":"p"}"#),
            ("reasoning.started", #""reasoningID":"r""#),
            ("reasoning.delta", #""reasoningID":"r","delta":"Think""#),
            ("text.started", #""textID":"t""#),
            ("text.delta", #""textID":"t","delta":"Hi""#),
            ("text.ended", #""textID":"t","text":"Hi there""#),
            ("tool.input.started", #""callID":"c","id":"c","name":"read""#),
            ("tool.called", #""callID":"c","id":"c","tool":"read","input":{"path":"a"}"#),
            ("tool.success", #""callID":"c","id":"c","content":[{"type":"text","text":"ok"}]"#),
            ("step.ended", #""finish":"stop""#),
        ]
        var next = LiveStream()
        var beta = LiveStream(prefix: "session.", timestampKey: nil)
        for (type, payload) in fields {
            #expect(try next.send(type, payload) != .unresolved)
            #expect(try beta.send(type, payload) != .unresolved)
        }
        #expect(next.reducer.messages == beta.reducer.messages)
        #expect(next.parts.map(\.text) == ["Think", "Hi there", nil])
        #expect(next.reducer.messages.first?.info.finish == "stop")
    }

    @MainActor
    @Test("Steps drive busy, and a final step settles to idle once the server drains")
    func storeSettlesAfterFinalStep() async throws {
        let service = LiveStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        #expect(store.status == .idle)

        await service.setActive(true)
        store.handle(try LiveStream.envelope("session.next.step.started", 1, #""assistantMessageID":"msg_a","agent":"build","model":{"id":"m","providerID":"p"}"#))
        #expect(store.status == .busy)
        #expect(store.messages.map(\.id) == ["msg_a"])
        let probesBefore = await service.statusCalls
        store.handle(try LiveStream.envelope("session.next.step.ended", 2, #""assistantMessageID":"msg_a","finish":"tool-calls","cost":0,"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}"#))
        try await Task.sleep(for: .milliseconds(300))
        // A tool-calls finish is followed by another step, so nothing is probed.
        #expect(await service.statusCalls == probesBefore)
        #expect(store.status == .busy)

        store.handle(try LiveStream.envelope("session.next.step.started", 3, #""assistantMessageID":"msg_b","agent":"build","model":{"id":"m","providerID":"p"}"#))
        store.handle(try LiveStream.envelope("session.next.text.started", 4, #""assistantMessageID":"msg_b","textID":"t""#))
        store.handle(try LiveStream.envelope("session.next.text.delta", 5, #""assistantMessageID":"msg_b","textID":"t","delta":"Do""#))
        #expect(store.messages.last?.parts.first?.text == "Do")
        store.handle(try LiveStream.envelope("session.next.text.delta", 6, #""assistantMessageID":"msg_b","textID":"t","delta":"ne""#))
        #expect(store.messages.last?.parts.first?.text == "Done")
        store.handle(try LiveStream.envelope("session.next.step.ended", 7, #""assistantMessageID":"msg_b","finish":"stop","cost":0,"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}"#))
        for _ in 0..<100 where await service.statusCalls == probesBefore { try await Task.sleep(for: .milliseconds(10)) }
        // The server can still own the drain briefly after the final step.
        #expect(store.status == .busy)
        await service.setActive(false)
        for _ in 0..<300 where store.status != .idle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.status == .idle)
        #expect(store.isStatusReady)
    }

    @MainActor
    @Test("Retries show until the next step and session.next reverts hide history")
    func storeRetryAndRevert() async throws {
        let service = LiveStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        store.handle(try LiveStream.envelope("session.next.retried", 1, #""attempt":2,"error":{"message":"Rate limited","isRetryable":true}"#))
        #expect(store.status == .retry(attempt: 2, message: "Rate limited", next: 0))
        store.handle(try LiveStream.envelope("session.next.step.started", 2, #""assistantMessageID":"msg_a","agent":"build","model":{"id":"m","providerID":"p"}"#))
        #expect(store.status == .busy)
        store.handle(try LiveStream.envelope("session.next.revert.staged", 3, #""revert":{"messageID":"msg_a"}"#))
        #expect(store.revertMessageID == "msg_a")
        #expect(store.messages.isEmpty)
        store.handle(try LiveStream.envelope("session.next.revert.cleared", 4, ""))
        #expect(store.revertMessageID == nil)
        #expect(store.messages.map(\.id) == ["msg_a"])
    }

    @MainActor
    private func makeStore(_ service: LiveStoreService) -> OpenCodeSessionStore {
        OpenCodeSessionStore(
            service: service, serverID: UUID(),
            session: OpenCodeSession(id: "ses_live", slug: "ses_live", projectID: "project", workspaceID: nil,
                directory: "/repo", parentID: nil, summary: nil, title: "Live", agent: nil, version: "2",
                time: OpenCodeSessionTime(created: 1, updated: 1, compacting: nil, archived: nil)),
            directory: "/repo", defaults: UserDefaults(suiteName: "opencode-v2-streaming-\(UUID().uuidString)")!
        )
    }
}

/// Feeds hand-written session events through a transcript reducer, stamping
/// ascending event IDs and timestamps.
private struct LiveStream {
    var reducer = OpenCodeTranscriptReducer()
    private let prefix: String
    private let timestampKey: String?
    private var sequence = 0

    init(prefix: String = "session.next.", timestampKey: String? = "timestamp") {
        self.prefix = prefix
        self.timestampKey = timestampKey
    }

    var parts: [OpenCodePart] { reducer.messages.last?.parts ?? [] }
    var tool: OpenCodePart? { parts.last { $0.type == "tool" } }

    @discardableResult
    mutating func send(_ type: String, _ fields: String, messageID: String = "msg_live") throws
        -> OpenCodeV2EventReducer.Outcome {
        reducer.applyV2(try event(type, fields, messageID: messageID))
    }

    mutating func event(_ type: String, _ fields: String, messageID: String = "msg_live") throws
        -> OpenCodeEvent {
        sequence += 1
        let owner = #""assistantMessageID":"\#(messageID)""#
        let payload = fields.contains("messageID") ? fields : owner + "," + fields
        guard let timestampKey else {
            let raw = #"{"id":"evt_\#(sequence)","type":"\#(prefix + type)","created":\#(sequence),"data":{"sessionID":"ses_live",\#(payload)}}"#
            return try JSONDecoder().decode(OpenCodeEvent.self, from: Data(raw.utf8))
        }
        return try Self.envelope(prefix + type, sequence, payload, timestampKey: timestampKey)
    }

    static func envelope(_ type: String, _ sequence: Int, _ fields: String, timestampKey: String = "timestamp") throws -> OpenCodeEvent {
        let separator = fields.isEmpty ? "" : ","
        let raw = #"{"id":"evt_\#(sequence)","type":"\#(type)","data":{"sessionID":"ses_live","\#(timestampKey)":\#(sequence)\#(separator)\#(fields)}}"#
        return try JSONDecoder().decode(OpenCodeEvent.self, from: Data(raw.utf8))
    }
}

private struct StreamFixture {
    let events: [OpenCodeEvent]
    let messages: [OpenCodeMessageEnvelope]

    static func load() throws -> StreamFixture {
        let url = try #require(Bundle(for: FixtureToken.self).url(forResource: "opencode-next-stream-turn", withExtension: "json"))
        struct Document: Decodable {
            let events: [OpenCodeEvent]
            let messages: [[String: OpenCodeJSONValue]]
        }
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        let sessionID = try #require(document.events.first?.sessionID)
        return StreamFixture(
            events: document.events,
            messages: document.messages.compactMap { OpenCodeV2Normalization.message($0, sessionID: sessionID) }
        )
    }
}

private final class FixtureToken {}

private actor LiveStoreService: OpenCodeSessionServicing {
    private var active = false
    private(set) var statusCalls = 0

    func setActive(_ value: Bool) { active = value }

    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] { [] }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] { [] }
    func sendMessage(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String,
                     attachments: [OpenCodePromptAttachment], promptID: UUID) async throws {}
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool { true }
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff] { [] }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] {
        statusCalls += 1
        return active ? ["ses_live": .busy] : [:]
    }
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest] { [] }
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest] { [] }
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] { [] }
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] { [] }
    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?,
               reply: OpenCodePermissionReply) async throws {}
    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws {}
    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?) async throws {}
    nonisolated func events(directory: String, workspace: String?) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { _ in }
    }
}
