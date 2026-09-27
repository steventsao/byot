#if DEBUG
import os
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
        let sharing = ProcessInfo.processInfo.arguments.contains("--share")
        switch path {
        case "/session/ses_history/share" where sharing:
            // OpenCode answers both publish and unpublish with the whole session.
            let published = request.httpMethod == "POST"
            Self.isHistoryShared.withLock { $0 = published }
            body = Self.session("ses_history", title: "Long conversation", shared: published)
        case "/session/ses_history" where sharing:
            body = Self.session("ses_history", title: "Long conversation", shared: Self.isHistoryShared.withLock { $0 })
        case "/config" where sharing:
            body = ["share": "manual"]
        case "/session" where request.httpMethod == "POST":
            if ProcessInfo.processInfo.arguments.contains("--creation-error") {
                status = 503
                body = ["message": "Fixture server unavailable"]
            } else {
                body = Self.session("ses_new", title: "New session")
            }
        case "/session":
            body = [Self.session("ses_draft", title: "Draft session"),
                    Self.session("ses_history", title: "Long conversation", shared: Self.isHistoryShared.withLock { $0 })]
        case "/session/status":
            body = [String: String]()
        case "/session/ses_history/message":
            body = (1...24).map { index -> [String: Any] in
                ["info": ["id": "msg_\(index)", "sessionID": "ses_history", "role": "assistant",
                          "time": ["created": index * 1000, "completed": index * 1000 + 500]],
                 "parts": [["id": "part_\(index)", "sessionID": "ses_history", "messageID": "msg_\(index)",
                            "type": "text", "text": "Update \(index). Reviewed the project and checked the implementation. This message provides enough detail to exercise scrolling through a longer conversation."]]]
            } + (ProcessInfo.processInfo.arguments.contains("--shell") ? Self.shellTurn() : [])
        case "/agent" where ProcessInfo.processInfo.arguments.contains("--shell"):
            body = [["name": "build", "mode": "primary"], ["name": "plan", "mode": "primary"]]
        case "/session/ses_history/shell" where request.httpMethod == "POST":
            // Shaped like OpenCode 1.18.21: 409 while another turn runs.
            status = 409
            body = ["_tag": "SessionBusyError", "message": "Session is busy: ses_history"]
        case "/permission" where ProcessInfo.processInfo.arguments.contains("--pending-action"):
            body = [["id": "per_1", "sessionID": "ses_history", "permission": "edit",
                     "patterns": ["Sources/App.swift"], "metadata": [:], "always": ["Sources/*"]]] as [[String: Any]]
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

    /// A finished v1 shell run as OpenCode 1.18.21 records it.
    private static func shellTurn() -> [[String: Any]] {
        let output = (1...16).map { "Sources/File\($0).swift | \($0 * 3) +++--" }.joined(separator: "\n")
            + "\n 16 files changed, 128 insertions(+), 40 deletions(-)\n"
        return [
            ["info": ["id": "msg_shell_user", "sessionID": "ses_history", "role": "user", "agent": "build",
                      "time": ["created": 25_000]],
             "parts": [["id": "prt_shell_marker", "sessionID": "ses_history", "messageID": "msg_shell_user",
                        "type": "text", "text": "The following tool was executed by the user", "synthetic": true]]],
            ["info": ["id": "msg_shell_reply", "sessionID": "ses_history", "role": "assistant", "agent": "build",
                      "time": ["created": 25_100, "completed": 25_900]],
             "parts": [["id": "prt_shell_tool", "sessionID": "ses_history", "messageID": "msg_shell_reply",
                        "type": "tool", "callID": "01SHELL", "tool": "bash",
                        "state": ["status": "completed", "input": ["command": "git diff --stat"], "title": "",
                                  "output": output, "metadata": ["output": output],
                                  "time": ["start": 25_100, "end": 25_900]]]]],
        ]
    }

    private static let isHistoryShared = OSAllocatedUnfairLock(initialState: false)

    private static func session(_ id: String, title: String, shared: Bool = false) -> [String: Any] {
        var session: [String: Any] = ["id": id, "slug": id, "projectID": "pro_fixture", "directory": "/fixture",
                                      "title": title, "version": "1.18.10", "time": ["created": 1000, "updated": 1000]]
        if shared { session["share"] = ["url": "https://opncd.ai/share/fixture-history"] }
        return session
    }
}
#endif
