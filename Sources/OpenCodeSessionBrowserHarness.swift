#if DEBUG
import SwiftUI

struct OpenCodeSessionBrowserHarness: View {
    @StateObject private var store: OpenCodeProfileStore

    init() {
        _store = StateObject(wrappedValue: Self.makeStore())
    }

    private static func makeStore() -> OpenCodeProfileStore {
        let defaults = UserDefaults(suiteName: "byot.browser-ui-fixture")!
        let profiles = [
            OpenCodeServerProfile(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Mac mini", baseURL: "https://mini.example.test"),
            OpenCodeServerProfile(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Windows", baseURL: "https://windows.example.test")
        ]
        defaults.set(try! JSONEncoder().encode(profiles), forKey: "byot.opencode.profiles.v1")
        if ProcessInfo.processInfo.arguments.contains("--reset-browser") {
            defaults.set(profiles[0].id.uuidString, forKey: "byot.opencode.active-profile.v1")
            UserDefaults.standard.removeObject(forKey: "byot.sessions.group-by-project")
            UserDefaults.standard.removeObject(forKey: "byot.sessions.sort")
            UserDefaults.standard.removeObject(forKey: "byot.projects.sort")
            for profile in profiles {
                UserDefaults.standard.removeObject(forKey: "byot.opencode.attention.\(profile.id.uuidString)")
            }
        }
        return OpenCodeProfileStore(defaults: defaults)
    }

    var body: some View {
        OpenCodeRootView(openAppNavigation: {}, profileStore: store) { profile, _ in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [OpenCodeBrowserFixtureProtocol.self]
            return OpenCodeClient(profile: profile, password: "fixture", session: URLSession(configuration: config), serverProtocol: .v1)
        }
    }
}

private final class OpenCodeBrowserFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }

    override func startLoading() {
        guard let url = request.url else { return }
        let directory = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "directory" }?.value ?? "/repo/byot"
        let windows = url.host == "windows.example.test"
        let base = windows ? "C:/work" : "/repo"
        let now = Date().timeIntervalSince1970 * 1_000
        func session(_ id: String, _ title: String, _ directory: String, _ minutes: Double) -> [String: Any] {
            ["id": id, "slug": id, "projectID": directory, "directory": directory,
             "title": title, "version": "1.18.10", "time": ["created": now - minutes * 60_000, "updated": now - minutes * 60_000]]
        }
        let sessions = [
            session("active", windows ? "Windows build" : "Fix checkout", base + "/byot", 2),
            session("retry", "Review billing", base + "/byot", 8),
            session("idle", "Update documentation", base + "/docs", 25)
        ]
        let body: Any
        switch url.path {
        case "/event":
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("data: {\"type\":\"server.connected\",\"properties\":{}}\n\n".utf8))
            // Keep this fixture stream open until the conversation cancels it.
            return
        case let endpoint where endpoint.hasPrefix("/api/"):
            respond(url, body: ["message": "Unavailable"], status: 404); return
        case "/global/health": body = ["healthy": true, "version": "1.18.10"]
        case "/project": body = ["byot", "docs"].map { name in
            ["id": base + "/" + name, "worktree": base + "/" + name, "name": name,
             "vcs": "git", "sandboxes": [], "time": ["created": now - 100_000, "updated": now]] as [String: Any]
        }
        case "/session" where request.httpMethod == "POST": body = session("created", "New session", directory, 0)
        case "/session": body = sessions.filter { $0["directory"] as? String == directory }
        case "/session/status": body = ["active": ["type": "busy"], "retry": ["type": "retry", "attempt": 1, "message": "Provider rate limit", "next": now + 10_000]]
        case "/provider": body = ["all": [], "connected": [], "default": [:]] as [String: Any]
        case "/session/idle/message":
            body = [
                ["info": ["id": "user-fixture", "sessionID": "idle", "role": "user", "time": ["created": now - 1000]],
                 "parts": [["id": "part-user", "sessionID": "idle", "messageID": "user-fixture", "type": "text", "text": "Review this project"]]],
                ["info": ["id": "assistant-fixture", "sessionID": "idle", "role": "assistant", "time": ["created": now],
                          "error": ["name": "ProviderError", "data": ["message": "This model is no longer available."]]],
                 "parts": []]
            ]
        case "/experimental/capabilities":
            respond(url, body: ["message": "Unavailable"], status: 404); return
        default: body = []
        }
        respond(url, body: body, status: 200)
    }

    private func respond(_ url: URL, body: Any, status: Int) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
}
#endif
