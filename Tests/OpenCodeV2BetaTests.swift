import Foundation
import XCTest
@testable import byot

// Wire expectations captured from opencode2 0.0.0-beta-19242 /openapi.json.
final class OpenCodeV2BetaTests: XCTestCase {
    func testAutoDetectedBetaCreatesSessionWithoutRequiringATitle() async throws {
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }
        _ = try await client.probeCompatibility()
        let created = try await client.createSession(directory: "/repo", title: nil)
        XCTAssertEqual(created.id, "ses_beta")
        XCTAssertFalse(created.title.isEmpty)
        let request = try XCTUnwrap(BetaURLProtocol.requests().last)
        XCTAssertEqual(request.url?.path, "/api/session")
        let body = try bodyObject(request)
        XCTAssertEqual((body["location"] as? [String: Any])?["directory"] as? String, "/repo")
    }

    func testAutoDetectedBetaSendsFlatPromptAndAcceptsInboxAdmission() async throws {
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }
        _ = try await client.probeCompatibility()
        try await client.sendMessage(sessionID: "ses_beta", directory: "/repo", text: "Hello")
        let request = try XCTUnwrap(BetaURLProtocol.requests().last)
        XCTAssertEqual(request.url?.path, "/api/session/ses_beta/prompt")
        let body = try bodyObject(request)
        XCTAssertEqual(body["text"] as? String, "Hello")
        XCTAssertNil(body["prompt"])
        XCTAssertEqual(body["delivery"] as? String, "queue")
        XCTAssertTrue((body["id"] as? String)?.hasPrefix("msg_") == true)
    }

    func testAutoDetectedBetaNormalizesTextWithoutPartIDsAndKeepsAttachments() async throws {
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }
        _ = try await client.probeCompatibility()
        let messages = try await client.messages(sessionID: "ses_beta", directory: "/repo")
        XCTAssertEqual(messages.map(\.info.role), ["user", "assistant"])
        XCTAssertEqual(messages[0].parts.last?.filename, "note.txt")
        XCTAssertEqual(messages[0].parts.last?.url, "data:text/plain;base64,aGk=")
        XCTAssertEqual(messages[1].parts.map(\.text), ["First", "Thinking", "Second"])
        XCTAssertEqual(Set(messages[1].parts.map(\.id)).count, 3)
    }

    func testBetaProjectsUseCanonicalDirectoryEvenWithoutSessions() async throws {
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }
        let projects = try await client.listProjects()
        XCTAssertEqual(projects.first?.worktree, "/repo")
    }

    func testBetaFormsKeepOptionValuesAndReplyByFieldKey() async throws {
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }
        _ = try await client.probeCompatibility()
        let questions = try await client.v2Questions(sessionID: "ses_beta")
        let request = try XCTUnwrap(questions.first)
        XCTAssertEqual(request.questions[0].options[0].id, "fast")
        try await client.answer(request, directory: "/repo", answers: [["fast"], ["unit", "ui"]])
        let reply = try XCTUnwrap(BetaURLProtocol.requests().last)
        XCTAssertEqual(reply.url?.path, "/api/session/ses_beta/form/frm_test/reply")
        let answer = try XCTUnwrap(try bodyObject(reply)["answer"] as? [String: Any])
        XCTAssertEqual(answer["speed"] as? String, "fast")
        XCTAssertEqual(answer["checks"] as? [String], ["unit", "ui"])
        try await client.reject(request, directory: "/repo")
        XCTAssertEqual(BetaURLProtocol.requests().last?.url?.path, "/api/session/ses_beta/form/frm_test/cancel")
    }

    func testBetaLiveTextReusesSnapshotIDsAndIgnoresDuplicateDeltas() throws {
        var reducer = OpenCodeTranscriptReducer()
        let events = [
            #"{"id":"evt_1","type":"session.step.started","created":1,"data":{"sessionID":"ses_beta","assistantMessageID":"msg_a","agent":"build","model":{"id":"test","providerID":"fixture"}}}"#,
            #"{"id":"evt_2","type":"session.text.started","created":2,"data":{"sessionID":"ses_beta","assistantMessageID":"msg_a"}}"#,
            #"{"id":"evt_3","type":"session.text.delta","created":3,"data":{"sessionID":"ses_beta","assistantMessageID":"msg_a","delta":"Hello"}}"#,
            #"{"id":"evt_3","type":"session.text.delta","created":3,"data":{"sessionID":"ses_beta","assistantMessageID":"msg_a","delta":"Hello"}}"#,
            #"{"id":"evt_4","type":"session.reasoning.started","created":4,"data":{"sessionID":"ses_beta","assistantMessageID":"msg_a"}}"#,
            #"{"id":"evt_5","type":"session.reasoning.ended","created":5,"data":{"sessionID":"ses_beta","assistantMessageID":"msg_a","text":"Thinking"}}"#,
            #"{"id":"evt_6","type":"session.text.started","created":6,"data":{"sessionID":"ses_beta","assistantMessageID":"msg_a"}}"#,
            #"{"id":"evt_7","type":"session.text.ended","created":7,"data":{"sessionID":"ses_beta","assistantMessageID":"msg_a","text":"Second"}}"#
        ]
        for raw in events {
            let event = try JSONDecoder().decode(OpenCodeEvent.self, from: Data(raw.utf8))
            XCTAssertEqual(event.sessionID, "ses_beta")
            XCTAssertTrue(reducer.apply(event))
        }
        let parts = try XCTUnwrap(reducer.messages.first).parts
        XCTAssertEqual(parts.map(\.text), ["Hello", "Thinking", "Second"])
        XCTAssertEqual(parts.map(\.id), ["msg_a:text:0", "msg_a:reasoning:0", "msg_a:text:1"])
    }

    func testBetaSessionPaginationDoesNotResendOrderWithCursor() async throws {
        let (client, session) = makeClient()
        defer { session.invalidateAndCancel() }
        let sessions = try await client.listSessions(directory: "/repo")
        XCTAssertEqual(sessions.map(\.id), ["ses_beta"])
        let pages = BetaURLProtocol.requests().filter { $0.url?.path == "/api/session" }
        XCTAssertEqual(pages.count, 2)
        let query = URLComponents(url: try XCTUnwrap(pages.last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertFalse(query?.contains { $0.name == "order" } ?? true)
    }

    func testBetaPermissionToolSourceAcceptsIDWithoutBreakingCallID() throws {
        let current = #"{"id":"per_a","sessionID":"ses_beta","action":"edit","resources":["README.md"],"source":{"type":"tool","messageID":"msg_a","id":"call_a"}}"#
        let request = try JSONDecoder().decode(OpenCodePermissionV2Request.self, from: Data(current.utf8))
        XCTAssertEqual(request.normalized.source?.callID, "call_a")
        let old = current.replacingOccurrences(of: "\"id\":\"call_a\"", with: "\"callID\":\"call_a\"")
        XCTAssertEqual(try JSONDecoder().decode(OpenCodePermissionV2Request.self, from: Data(old.utf8)).source?.callID, "call_a")
    }

    private func makeClient() -> (OpenCodeClient, URLSession) {
        BetaURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BetaURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (OpenCodeClient(profile: OpenCodeServerProfile(name: "Beta", baseURL: "https://beta-contract.test"), password: "fixture", session: session), session)
    }

    private func bodyObject(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class BetaURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static func reset() { lock.lock(); defer { lock.unlock() }; recorded = [] }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "beta-contract.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }
    override func startLoading() {
        Self.lock.lock(); Self.recorded.append(request); Self.lock.unlock()
        let path = request.url!.path
        var body: String
        var contentType = "application/json"
        var statusCode = 200
        switch path {
        case "/api/health": body = #"{"healthy":true,"version":"0.0.0-beta-19242","pid":123}"#
        case "/openapi.json":
            let url = Bundle(for: OpenCodeV2BetaTests.self).url(forResource: "opencode2-beta-19242-openapi", withExtension: "json")!
            body = try! String(contentsOf: url, encoding: .utf8)
        case "/api/project": body = #"[{"id":"proj_1","canonical":"/repo","time":{"created":1,"updated":1},"sandboxes":[]}]"#
        case "/api/session/ses_beta/form": body = #"{"data":[{"id":"frm_test","sessionID":"ses_beta","title":"Choose","fields":[{"key":"speed","type":"string","title":"Speed","options":[{"label":"Quick","value":"fast"}],"custom":false},{"key":"checks","type":"multiselect","options":[{"label":"Unit","value":"unit"},{"label":"UI","value":"ui"}]}]}]}"#
        case "/api/session/ses_beta/form/frm_test/reply", "/api/session/ses_beta/form/frm_test/cancel": body = ""
        case "/api/session" where request.httpMethod == "GET":
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "cursor" }) {
                if query.contains(where: { $0.name == "order" }) {
                    statusCode = 400; body = #"{"message":"order cannot be combined with cursor"}"#
                } else { body = #"{"data":[],"cursor":{}}"# }
            } else { body = #"{"data":[{"id":"ses_beta","projectID":"proj_1","time":{"created":1,"updated":1},"location":{"directory":"/repo"}}],"cursor":{"next":"next-page"}}"# }
        case "/api/session":
            body = #"{"data":{"id":"ses_beta","projectID":"proj_1","time":{"created":1,"updated":1},"location":{"directory":"/repo"}}}"#
        case "/api/session/ses_beta/prompt":
            body = #"{"data":{"id":"msg_admitted","sessionID":"ses_beta","timeCreated":1,"type":"user","payload":{"text":"Hello"},"delivery":"queue"}}"#
        case "/api/session/ses_beta/message":
            body = #"{"data":[{"id":"msg_u","type":"user","time":{"created":1},"text":"Hello","files":[{"data":"aGk=","mime":"text/plain","name":"note.txt","source":{"type":"data"}}]},{"id":"msg_a","type":"assistant","time":{"created":2,"completed":3},"agent":"build","model":{"id":"test","providerID":"fixture"},"content":[{"type":"text","text":"First"},{"type":"reasoning","text":"Thinking"},{"type":"text","text":"Second"}]}],"cursor":{}}"#
        default: body = "<!doctype html><html></html>"; contentType = "text/html"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
