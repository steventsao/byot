import Foundation
import XCTest
@testable import byot

// Opt in through the test run environment. These exercise the production HTTPS
// transport against isolated real servers and a local deterministic model.
final class OpenCodeLiveServerTests: XCTestCase {
    func testLiveBetaPromptStreamSnapshotRetryFormsAndInterrupt() async throws {
        guard ProcessInfo.processInfo.environment["BYOT_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Requires the isolated live server fixture") }
        let directory = "/tmp/byot-v2-runtime-19242/project"
        let client = OpenCodeClient(profile: OpenCodeServerProfile(name: "Live beta", baseURL: "https://localhost:4199", directory: directory), password: "byot-local-fixture-only")
        _ = try await client.probeCompatibility()
        let projects = try await client.listProjects()
        XCTAssertFalse(projects.isEmpty)
        let providers = try await client.connectedProviderModels(directory: directory)
        let model = try XCTUnwrap(providers.first { $0.providerID == "fixture" }?.models.first)
        let session = try await client.createSession(directory: directory, title: "BYOT iOS live acceptance")
        XCTAssertEqual(session.title, "BYOT iOS live acceptance")
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
        try await client.sendMessage(sessionID: session.id, directory: directory, model: model, text: "Say BYOT live beta verified.", promptID: promptID)
        for _ in 0..<150 {
            if await collector.finished { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        let events = await collector.events
        XCTAssertTrue(events.contains { $0.type == "session.execution.succeeded" }, "Events: \(events.map(\.type))")
        var reducer = OpenCodeTranscriptReducer()
        for event in events where event.isV2 { _ = reducer.apply(event) }
        XCTAssertTrue(reducer.messages.flatMap(\.parts).contains { $0.text == "BYOT live beta verified." })
        let snapshot = try await client.messages(sessionID: session.id, directory: directory)
        XCTAssertTrue(snapshot.flatMap(\.parts).contains { $0.text == "BYOT live beta verified." })
        let expectedID = "msg_" + promptID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        XCTAssertEqual(snapshot.filter { $0.id == expectedID }.count, 1)
        // Replay the same admission ID, as a retry after an ambiguous response.
        try await client.sendMessage(sessionID: session.id, directory: directory, text: "Say BYOT live beta verified.", promptID: promptID)
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
        let interrupted = try await client.abort(sessionID: session.id, directory: directory)
        XCTAssertTrue(interrupted)
        let statuses = try await client.sessionStatuses(directory: directory)
        XCTAssertNil(statuses[session.id])
    }

    private func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://localhost:4199" + path)!)
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
