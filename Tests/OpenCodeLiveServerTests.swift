import Foundation
import XCTest
@testable import byot

// Opt in through the test run environment. These exercise the production HTTPS
// transport against isolated real servers and a local deterministic model.
final class OpenCodeLiveServerTests: XCTestCase {
    func testLiveBetaPromptStreamSnapshotRetryFormsAndInterrupt() async throws {
        guard ProcessInfo.processInfo.environment["BYOT_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Requires the isolated live server fixture") }
        let directory = try fixtureDirectory("v2")
        let client = OpenCodeClient(profile: OpenCodeServerProfile(name: "Live beta", baseURL: "https://127.0.0.1:4199", directory: directory), password: "byot-local-fixture-only")
        _ = try await client.probeCompatibility()
        let projects = try await client.listProjects()
        XCTAssertFalse(projects.isEmpty)
        let providers = try await client.connectedProviderModels(directory: directory)
        let model = try XCTUnwrap(providers.first { $0.providerID == "fixture" }?.models.first)
        let session = try await client.createSession(directory: directory, title: "BYOT iOS live acceptance")
        XCTAssertEqual(session.title, "BYOT iOS live acceptance")
        let sessions = try await client.listSessions(directory: directory)
        XCTAssertTrue(sessions.contains { $0.id == session.id })
        let collector = LiveEvents()
        let stream = Task {
            for try await event in client.events(directory: directory) {
                await collector.record(event, sessionID: session.id)
            }
        }
        defer { stream.cancel() }
        for _ in 0..<50 {
            if await collector.connected { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let connected = await collector.connected
        XCTAssertTrue(connected)
        let promptID = UUID()
        try await client.sendMessage(sessionID: session.id, directory: directory, model: model, text: "Say BYOT upstream compatibility verified.", promptID: promptID)
        for _ in 0..<150 {
            if await collector.finished { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let events = await collector.events
        XCTAssertTrue(events.contains { $0.type == "session.execution.succeeded" }, "Events: \(events.map(\.type))")
        var reducer = OpenCodeTranscriptReducer()
        for event in events where event.isV2 { _ = reducer.apply(event) }
        XCTAssertTrue(reducer.messages.flatMap(\.parts).contains { $0.text == "BYOT upstream compatibility verified." })
        let snapshot = try await client.messages(sessionID: session.id, directory: directory)
        XCTAssertTrue(snapshot.flatMap(\.parts).contains { $0.text == "BYOT upstream compatibility verified." })
        let expectedID = "msg_" + promptID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        XCTAssertEqual(snapshot.filter { $0.id == expectedID }.count, 1)
        // Replay the same admission ID, as a retry after an ambiguous response.
        try await client.sendMessage(sessionID: session.id, directory: directory, text: "Say BYOT upstream compatibility verified.", promptID: promptID)
        let retried = try await client.messages(sessionID: session.id, directory: directory)
        XCTAssertEqual(retried.filter { $0.id == expectedID }.count, 1)
        let formBody: [String: Any] = ["title": "Live form", "fields": [["key": "speed", "type": "string", "required": true, "options": [["value": "fast", "label": "Quick"]]]]]
        let created = try await request("/api/session/\(session.id)/form", body: formBody)
        let formID = try XCTUnwrap((created["data"] as? [String: Any])?["id"] as? String)
        let questions = try await client.v2Questions(sessionID: session.id)
        let question = try XCTUnwrap(questions.first { $0.id == formID })
        try await client.answer(question, directory: directory, answers: [["fast"]])
        let state = try await request("/api/session/\(session.id)/form/\(formID)/state")
        XCTAssertEqual((state["data"] as? [String: Any])?["status"] as? String, "answered")
        let cancelCreated = try await request("/api/session/\(session.id)/form", body: formBody)
        let cancelID = try XCTUnwrap((cancelCreated["data"] as? [String: Any])?["id"] as? String)
        let cancelQuestions = try await client.v2Questions(sessionID: session.id)
        try await client.reject(try XCTUnwrap(cancelQuestions.first { $0.id == cancelID }), directory: directory)
        let cancelled = try await request("/api/session/\(session.id)/form/\(cancelID)/state")
        XCTAssertEqual((cancelled["data"] as? [String: Any])?["status"] as? String, "cancelled")
        let permissionCreated = try await request("/api/session/\(session.id)/permission", body: [
            "action": "byot_acceptance", "resources": ["fixture.txt"],
            "source": ["type": "tool", "messageID": "msg_fixture", "id": "call_fixture"]])
        let permissionID = try XCTUnwrap((permissionCreated["data"] as? [String: Any])?["id"] as? String)
        let pending = try await client.v2Permissions(sessionID: session.id)
        let permission = try XCTUnwrap(pending.first { $0.id == permissionID })
        XCTAssertEqual(permission.source?.callID, "call_fixture")
        try await client.reply(to: permission, directory: directory, reply: .once)
        let remaining = try await client.v2Permissions(sessionID: session.id)
        XCTAssertFalse(remaining.contains { $0.id == permissionID })
        let interrupted = try await client.abort(sessionID: session.id, directory: directory)
        XCTAssertTrue(interrupted)
        let statuses = try await client.sessionStatuses(directory: directory)
        XCTAssertNil(statuses[session.id])
    }

    func testLiveV1ExistingProtocolStillSendsAndReloads() async throws {
        guard ProcessInfo.processInfo.environment["BYOT_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Requires isolated v1 fixture") }
        let directory = try fixtureDirectory("v1")
        let client = OpenCodeClient(profile: OpenCodeServerProfile(name: "Live v1", baseURL: "https://127.0.0.1:4195", directory: directory), password: "byot-local-fixture-only")
        _ = try await client.probeCompatibility()
        let providers = try await client.connectedProviderModels(directory: directory)
        let model = try XCTUnwrap(providers.first { $0.providerID == "fixture" }?.models.first)
        let session = try await client.createSession(directory: directory, title: "BYOT v1 acceptance")
        try await client.sendMessage(sessionID: session.id, directory: directory, model: model, text: "Verify v1 compatibility")
        var snapshot: [OpenCodeMessageEnvelope] = []
        for _ in 0..<100 {
            snapshot = try await client.messages(sessionID: session.id, directory: directory)
            if snapshot.flatMap(\.parts).contains(where: { $0.text == "BYOT upstream compatibility verified." }) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(snapshot.flatMap(\.parts).contains { $0.text == "BYOT upstream compatibility verified." })
        XCTAssertEqual(snapshot.filter { $0.info.role == "user" }.count, 1)
        let questions = try await client.questions(directory: directory)
        let permissions = try await client.permissions(directory: directory)
        XCTAssertTrue(questions.isEmpty && permissions.isEmpty)
    }

    func testLiveBetaAttachmentOnlyPromptRoundTripsFile() async throws {
        guard ProcessInfo.processInfo.environment["BYOT_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Requires isolated beta fixture") }
        let directory = try fixtureDirectory("v2")
        let client = OpenCodeClient(profile: OpenCodeServerProfile(name: "Live beta", baseURL: "https://127.0.0.1:4199", directory: directory), password: "byot-local-fixture-only")
        let session = try await client.createSession(directory: directory, title: "BYOT attachment acceptance")
        let attachment = OpenCodePromptAttachment(filename: "acceptance.txt", mimeType: "text/plain", data: Data("BYOT attachment fixture".utf8))
        try await client.sendMessage(sessionID: session.id, directory: directory, text: "", attachments: [attachment])
        var messages: [OpenCodeMessageEnvelope] = []
        for _ in 0..<100 {
            messages = try await client.messages(sessionID: session.id, directory: directory)
            if messages.contains(where: { $0.info.role == "assistant" && $0.info.time.completed != nil }) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let file = try XCTUnwrap(messages.first { $0.info.role == "user" }?.parts.first { $0.type == "file" })
        XCTAssertEqual(file.filename, "acceptance.txt")
        XCTAssertEqual(file.mime, "text/plain")
        XCTAssertEqual(file.url, attachment.dataURL)
        XCTAssertTrue(messages.flatMap(\.parts).contains { $0.text == "BYOT upstream compatibility verified." })
    }

    private func fixtureDirectory(_ major: String) throws -> String {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["BYOT_LIVE_ROOT"], "Run scripts/test-opencode-upstream.sh")
        return root + "/" + major + "/project"
    }

    private func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:4199" + path)!)
        request.setValue("Basic " + Data("opencode:byot-local-fixture-only".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains((response as! HTTPURLResponse).statusCode), String(decoding: data, as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor LiveEvents {
    var connected = false
    var finished = false
    var events: [OpenCodeEvent] = []
    func record(_ event: OpenCodeEvent, sessionID: String) {
        if event.type == "server.connected" { connected = true }
        guard event.sessionID == sessionID else { return }
        events.append(event)
        if ["session.execution.succeeded", "session.execution.failed"].contains(event.type) { finished = true }
    }
}
