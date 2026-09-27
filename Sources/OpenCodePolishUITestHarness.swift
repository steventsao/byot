#if DEBUG
import SwiftUI

/// Exercises the real navigation and session views against a local, deterministic server fixture.
struct OpenCodePolishUITestHarness: View {
    private let client: OpenCodeClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodePolishURLProtocol.self]
        client = OpenCodeClient(
            profile: OpenCodeServerProfile(
                name: "UI tests",
                baseURL: "https://polish.invalid",
                username: "opencode"
            ),
            password: "fixture",
            session: URLSession(configuration: configuration),
            serverProtocol: .v1
        )

    }

    var body: some View {
        NavigationStack {
            OpenCodeProjectSessionsView(
                client: client,
                name: "Polish project",
                directory: "/fixture"
            )
        }
    }
}

private final class OpenCodePolishURLProtocol: URLProtocol, @unchecked Sendable {
    private let eventLock = NSLock()
    private var eventTask: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "polish.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        if path == "/event" {
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Keep the event stream open until the view stops it.
            client?.urlProtocol(self, didLoad: Data("data: {\"id\":\"evt_connected\",\"type\":\"server.connected\",\"properties\":{}}\n\n".utf8))
            if ProcessInfo.processInfo.arguments.contains("--streaming") {
                eventLock.withLock {
                    eventTask = Task { @Sendable [weak self] in
                        do { try await Task.sleep(for: .seconds(12)) } catch { return }
                        guard let self else { return }
                        let event: [String: Any] = [
                            "id": "evt_updated",
                            "type": "message.part.updated",
                            "properties": ["part": [
                                "id": "part_24", "sessionID": "ses_history", "messageID": "msg_24",
                                "type": "text", "text": "Streaming update arrived. " + String(repeating: "New details from OpenCode. ", count: 30),
                            ]],
                        ]
                        let data = try! JSONSerialization.data(withJSONObject: event)
                        eventLock.withLock {
                            guard !Task.isCancelled else { return }
                            client?.urlProtocol(self, didLoad: Data("data: ".utf8) + data + Data("\n\n".utf8))
                        }
                    }
                }
            }
            return
        }

        let body: Any
        var status = 200
        switch path {
        case "/session" where request.httpMethod == "POST":
            if ProcessInfo.processInfo.arguments.contains("--creation-error") {
                status = 503
                body = ["message": "Fixture server unavailable"]
            } else {
                body = Self.session("ses_new", title: "New session")
            }
        case "/session":
            var sessions = [Self.session("ses_draft", title: "Draft session"),
                            Self.session("ses_history", title: "Long conversation")]
            if ProcessInfo.processInfo.arguments.contains("--transcript-parts") {
                sessions.append(Self.session("ses_parts", title: "Rich transcript"))
            }
            if ProcessInfo.processInfo.arguments.contains("--usage") {
                sessions.append(Self.session("ses_usage", title: "Token budget"))
            }
            body = sessions
        case "/session/ses_parts/message":
            body = Self.richTranscript()
        case "/session/ses_usage/message":
            body = Self.usageTranscript()
        case "/session/ses_parts/diff":
            body = [["file": "Sources/App.swift", "additions": 3, "deletions": 1, "status": "modified",
                     "patch": "@@ -1,3 +1,5 @@\n import SwiftUI\n+// Guard the empty state.\n+let isEmpty = items.isEmpty\n"]]
        case "/session/status":
            body = [String: String]()
        case "/session/ses_history/message":
            body = (1...24).map { index -> [String: Any] in
                ["info": ["id": "msg_\(index)", "sessionID": "ses_history", "role": "assistant",
                          "time": ["created": index * 1000, "completed": index * 1000 + 500]],
                 "parts": [["id": "part_\(index)", "sessionID": "ses_history", "messageID": "msg_\(index)",
                            "type": "text", "text": "Update \(index). Reviewed the project and checked the implementation. This message provides enough detail to exercise scrolling through a longer conversation."]]]
            }
        case "/permission" where ProcessInfo.processInfo.arguments.contains("--pending-action"):
            body = [["id": "per_1", "sessionID": "ses_history", "permission": "edit",
                     "patterns": ["Sources/App.swift"], "metadata": [:], "always": ["Sources/*"]]] as [[String: Any]]
        case "/provider" where ProcessInfo.processInfo.arguments.contains("--usage"):
            body = ["all": [["id": "anthropic", "name": "Anthropic", "models": [
                "claude-sonnet-4-5": ["id": "claude-sonnet-4-5", "name": "Claude Sonnet 4.5",
                                      "limit": ["context": 200_000, "output": 64_000]],
            ]]], "connected": ["anthropic"], "default": [:]] as [String: Any]
        case "/provider":
            body = ["all": [], "connected": [], "default": [:]] as [String: Any]
        case let path where path.hasPrefix("/api/"):
            body = ["data": []] as [String: Any]
        default:
            body = [] as [String]
        }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        eventLock.withLock {
            eventTask?.cancel()
            eventTask = nil
        }
    }

    /// One of every transcript part type, as a v1 server stores them.
    private static func richTranscript() -> [[String: Any]] {
        func part(_ id: String, _ message: String, _ fields: [String: Any]) -> [String: Any] {
            fields.merging(["id": id, "sessionID": "ses_parts", "messageID": message]) { $1 }
        }
        func message(_ id: String, role: String, at time: Int, _ parts: [[String: Any]]) -> [String: Any] {
            ["info": ["id": id, "sessionID": "ses_parts", "role": role, "agent": "build",
                      "time": ["created": time, "completed": time + 500]], "parts": parts]
        }
        func image(_ color: UIColor, size: CGSize) -> String {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let png = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.white.withAlphaComponent(0.8).setFill()
                context.fill(CGRect(x: size.width * 0.1, y: size.height * 0.1, width: size.width * 0.5, height: size.height * 0.12))
            }
            return "data:image/png;base64," + png.base64EncodedString()
        }
        return [
            message("msg_p1", role: "user", at: 1_000, [
                part("p1_text", "msg_p1", ["type": "text", "text": "@explore why does the empty state crash?"]),
                part("p1_agent", "msg_p1", ["type": "agent", "name": "explore"]),
                part("p1_image", "msg_p1", ["type": "file", "mime": "image/png", "filename": "crash.png",
                                           "url": image(.systemIndigo, size: CGSize(width: 1_170, height: 800))]),
                part("p1_image2", "msg_p1", ["type": "file", "mime": "image/png", "filename": "console.png",
                                            "url": image(.systemTeal, size: CGSize(width: 600, height: 900))]),
            ]),
            message("msg_p2", role: "assistant", at: 2_000, [
                part("p2_start", "msg_p2", ["type": "step-start", "snapshot": "444a8fa98e219b9e"]),
                part("p2_retry", "msg_p2", ["type": "retry", "attempt": 1, "time": ["created": 2_100],
                                           "error": ["name": "APIError", "data": ["message": "Rate limit exceeded, retrying shortly.",
                                                                                  "statusCode": 429, "isRetryable": true]]]),
                part("p2_text", "msg_p2", ["type": "text", "text": "The list reads `items.first!` before checking for an empty array. I guarded it."]),
                part("p2_finish", "msg_p2", ["type": "step-finish", "reason": "stop", "cost": 0.0123,
                                            "tokens": ["input": 12_480, "output": 356, "reasoning": 120,
                                                       "cache": ["read": 8_192, "write": 0]]]),
                part("p2_patch", "msg_p2", ["type": "patch", "hash": "9c1e2d4",
                                           "files": ["/fixture/Sources/App.swift", "/fixture/README.md"]]),
                part("p2_snapshot", "msg_p2", ["type": "snapshot", "snapshot": "9c1e2d4b7a0f"]),
            ]),
            message("msg_p3", role: "user", at: 3_000, [
                part("p3_compaction", "msg_p3", ["type": "compaction", "auto": true, "overflow": true]),
            ]),
            message("msg_p4", role: "assistant", at: 4_000, [
                part("p4_text", "msg_p4", ["type": "text", "text": "Summary: fixed the empty-state crash in `Sources/App.swift`."]),
            ]),
        ]
    }

    /// Two turns on a model with a 200K window; the latest reply fills 72% of it.
    private static func usageTranscript() -> [[String: Any]] {
        func message(_ id: String, role: String, at time: Int, cost: Double = 0, parts: [[String: Any]]) -> [String: Any] {
            var info: [String: Any] = ["id": id, "sessionID": "ses_usage", "role": role, "agent": "build",
                                       "time": ["created": time, "completed": time + 500]]
            if role == "assistant" {
                info.merge(["providerID": "anthropic", "modelID": "claude-sonnet-4-5", "mode": "build", "cost": cost]) { $1 }
            }
            return ["info": info, "parts": parts.map { $0.merging(["sessionID": "ses_usage", "messageID": id]) { $1 } }]
        }
        func step(_ id: String, cost: Double, input: Int, output: Int, cacheRead: Int) -> [String: Any] {
            ["id": id, "type": "step-finish", "reason": "stop", "cost": cost,
             "tokens": ["input": input, "output": output, "reasoning": 0, "cache": ["read": cacheRead, "write": 0]]]
        }
        return [
            message("msg_u1", role: "user", at: 1_000, parts: [["id": "u1_text", "type": "text", "text": "Map the upload pipeline."]]),
            message("msg_a1", role: "assistant", at: 2_000, cost: 0.84, parts: [
                ["id": "a1_text", "type": "text", "text": "Uploads flow through `UploadQueue`, then `ChunkWriter`, then the storage adapter."],
                step("a1_step", cost: 0.84, input: 96_000, output: 2_400, cacheRead: 0),
            ]),
            message("msg_u2", role: "user", at: 3_000, parts: [["id": "u2_text", "type": "text", "text": "Add retries with backoff."]]),
            message("msg_a2", role: "assistant", at: 4_000, cost: 0.4, parts: [
                ["id": "a2_text", "type": "text", "text": "Added exponential backoff with jitter to `ChunkWriter`, capped at five attempts."],
                step("a2_step", cost: 0.4, input: 12_000, output: 3_200, cacheRead: 128_800),
            ]),
        ]
    }

    private static func session(_ id: String, title: String) -> [String: Any] {
        ["id": id, "slug": id, "projectID": "pro_fixture", "directory": "/fixture",
         "title": title, "version": "1.18.10", "time": ["created": 1000, "updated": 1000]]
    }
}
#endif
