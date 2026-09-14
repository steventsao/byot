#if DEBUG
import SwiftUI

/// Deterministic OpenCode v1 server for the App Store and README screenshots.
/// Launch with `--app-store-screenshots -BYOTStorePhase <live|question|permission|done>`;
/// AppStoreScreenshotUITests walks one session through every phase.
struct OpenCodeAppStoreScreenshotHarness: View {
    @StateObject private var store: OpenCodeProfileStore

    init() {
        _store = StateObject(wrappedValue: Self.makeStore())
    }

    private static func makeStore() -> OpenCodeProfileStore {
        // Every phase starts from the same persisted state, whatever ran before.
        let standard = UserDefaults.standard
        for key in standard.dictionaryRepresentation().keys where key.hasPrefix("byot.") && key != "byot.appearance" {
            standard.removeObject(forKey: key)
        }
        let server = AppStoreFixture.macMiniID.uuidString
        standard.set("local/coder-32b", forKey: "byot.opencode.model.default.\(server)")
        standard.set("build", forKey: "byot.opencode.agent.default.\(server)")
        standard.set("high", forKey: "byot.opencode.variant.default.\(server).local/coder-32b")
        let defaults = UserDefaults(suiteName: "byot.app-store-fixture")!
        let profiles = [
            OpenCodeServerProfile(id: AppStoreFixture.macMiniID, name: "Mac mini", baseURL: "https://mac-mini.tail2c9e.ts.net"),
            OpenCodeServerProfile(id: AppStoreFixture.studioID, name: "Studio", baseURL: "https://studio.tail2c9e.ts.net")
        ]
        defaults.set(try! JSONEncoder().encode(profiles), forKey: "byot.opencode.profiles.v1")
        defaults.set(profiles[0].id.uuidString, forKey: "byot.opencode.active-profile.v1")
        return OpenCodeProfileStore(defaults: defaults)
    }

    var body: some View {
        OpenCodeRootView(openAppNavigation: {}, profileStore: store) { profile, _ in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [OpenCodeAppStoreFixtureProtocol.self]
            return OpenCodeClient(profile: profile, password: "fixture", session: URLSession(configuration: config), serverProtocol: .v1)
        }
    }
}

private enum AppStoreFixture {
    enum Phase: String { case live, question, permission, done }

    static let macMiniID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    static let studioID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    static let api = "/Users/me/code/acme-api"
    static let web = "/Users/me/code/acme-web"
    static let sessionID = "ses_upload"
    static let now = Date().timeIntervalSince1970 * 1_000

    static var phase: Phase {
        Phase(rawValue: UserDefaults.standard.string(forKey: "BYOTStorePhase") ?? "") ?? .done
    }

    // MARK: Workspace

    static var projects: [[String: Any]] {
        [api, web].map { directory in
            ["id": directory, "worktree": directory, "name": URL(fileURLWithPath: directory).lastPathComponent,
             "vcs": "git", "sandboxes": [String](), "time": ["created": now - 86_400_000, "updated": now]]
        }
    }

    static func session(_ id: String, _ title: String, _ directory: String, minutesAgo: Double) -> [String: Any] {
        let updated = now - minutesAgo * 60_000
        return ["id": id, "slug": id, "projectID": directory, "directory": directory, "title": title,
                "version": "1.18.29", "time": ["created": updated - 900_000, "updated": updated]]
    }

    static var sessions: [[String: Any]] {
        [session(sessionID, "Add rate limiting to uploads", api, minutesAgo: 1),
         session("ses_checkout", "Fix flaky checkout test", web, minutesAgo: 4),
         session("ses_node", "Upgrade CI to Node 22", api, minutesAgo: 48),
         session("ses_webhooks", "Document the webhooks API", web, minutesAgo: 190)]
    }

    static var statuses: [String: Any] {
        var statuses: [String: Any] = ["ses_checkout": ["type": "busy"]]
        if phase != .done { statuses[sessionID] = ["type": "busy"] }
        return statuses
    }

    static var providers: [String: Any] {
        let model: [String: Any] = ["id": "coder-32b", "name": "Coder 32B", "variants": ["high": [String: Any](), "max": [String: Any]()]]
        return ["all": [["id": "local", "name": "Local", "models": ["coder-32b": model]]],
                "connected": ["local"], "default": ["local": "coder-32b"]]
    }

    nonisolated(unsafe) static let agents: [[String: Any]] = [
        ["name": "build", "mode": "primary", "description": "Makes changes with full tool access"],
        ["name": "plan", "mode": "primary", "description": "Plans without editing files"]
    ]

    nonisolated(unsafe) static let commands: [[String: Any]] = [
        ["name": "review", "description": "Review uncommitted changes"],
        ["name": "test", "description": "Run the test suite"]
    ]

    // MARK: Transcript

    static func part(_ id: String, message: String = "msg_agent", _ fields: [String: Any]) -> [String: Any] {
        fields.merging(["id": id, "sessionID": sessionID, "messageID": message]) { _, fixture in fixture }
    }

    static func text(_ id: String, message: String = "msg_agent", _ text: String) -> [String: Any] {
        part(id, message: message, ["type": "text", "text": text])
    }

    static func tool(_ id: String, _ name: String, _ status: String, _ input: [String: Any], output: String? = nil) -> [String: Any] {
        var state: [String: Any] = ["status": status, "input": input, "time": ["start": now - 90_000]]
        if status == "completed" { state["time"] = ["start": now - 90_000, "end": now - 80_000] }
        if let output { state["output"] = output }
        return part(id, ["type": "tool", "tool": name, "callID": "call_\(id)", "state": state])
    }

    static var messages: [[String: Any]] {
        let prompt: [String: Any] = [
            "info": ["id": "msg_user", "sessionID": sessionID, "role": "user", "time": ["created": now - 240_000],
                     "model": ["providerID": "local", "modelID": "coder-32b"]],
            "parts": [text("prt_prompt", message: "msg_user",
                           "Add rate limiting to the upload route, 10 uploads a minute per client, then run the upload tests.")]
        ]
        var parts: [[String: Any]] = [
            part("prt_reasoning", ["type": "reasoning", "text": "Uploads are handled in `src/routes/upload.ts`. An in-memory limiter keyed by client IP avoids a new dependency, and it has to run before the multipart parser so rejected requests never buffer a file."]),
            tool("grep", "grep", "completed", ["pattern": "upload.single", "path": "src"],
                 output: "src/routes/upload.ts:9: router.post(\"/upload\", upload.single(\"file\"), handleUpload);"),
            tool("read", "read", "completed", ["filePath": api + "/src/routes/upload.ts"])
        ]
        if phase == .question {
            parts.append(tool("question", "question", "running", ["questions": question["questions"] ?? []]))
        } else {
            parts += [
                text("prt_choice", "Going with a token bucket: short bursts stay fast, sustained floods get a `429` with `Retry-After`."),
                tool("write_limiter", "write", "completed", ["filePath": api + "/src/middleware/rateLimit.ts"]),
                tool("edit_route", "edit", phase == .live ? "running" : "completed", ["filePath": api + "/src/routes/upload.ts"])
            ]
        }
        if phase == .permission || phase == .done {
            parts += [
                tool("write_tests", "write", "completed", ["filePath": api + "/tests/upload.test.ts"]),
                part("prt_patch", ["type": "patch", "files": diffs.compactMap { $0["file"] }]),
                tool("bash", "bash", phase == .done ? "completed" : "running",
                     ["command": "npm test -- upload", "description": "Run the upload tests"],
                     output: phase == .done ? testOutput : nil)
            ]
        }
        if phase == .done {
            parts.append(text("prt_summary", """
                All 4 upload tests pass.

                - **`src/middleware/rateLimit.ts`**: token-bucket limiter, 10 uploads a minute per client, with `RateLimit-*` and `Retry-After` headers
                - **`src/routes/upload.ts`**: the limiter runs before the multipart parser
                - **`tests/upload.test.ts`**: covers bursts, the 429 response, and per-client isolation
                """))
        }
        var info: [String: Any] = ["id": "msg_agent", "sessionID": sessionID, "role": "assistant", "agent": "build",
                                   "providerID": "local", "modelID": "coder-32b", "time": ["created": now - 230_000]]
        if phase == .done {
            info["time"] = ["created": now - 230_000, "completed": now - 20_000]
            info["finish"] = "stop"
        }
        return [prompt, ["info": info, "parts": parts]]
    }

    static let testOutput = """
        PASS tests/upload.test.ts
          ✓ accepts uploads under the limit (38 ms)
          ✓ returns 429 after 10 uploads in a minute (12 ms)
          ✓ sets RateLimit and Retry-After headers (4 ms)
          ✓ tracks clients separately (6 ms)

        Tests: 4 passed, 4 total
        """

    static var todos: [[String: Any]] {
        let steps = ["Find the upload route", "Choose a rate limit strategy",
                     "Add the limiter ahead of the multipart parser", "Run the upload tests"]
        let finished = switch phase { case .question: 1; case .live: 2; case .permission: 3; case .done: 4 }
        return steps.enumerated().map { index, step in
            let status = index < finished ? "completed" : index == finished ? "in_progress" : "pending"
            return ["content": step, "status": status, "priority": "high"]
        }
    }

    // MARK: Pending actions

    nonisolated(unsafe) static let permission: [String: Any] = [
        "id": "per_tests", "sessionID": sessionID, "permission": "bash",
        "patterns": ["npm test -- upload"], "metadata": [String: Any](), "always": ["npm test *"]
    ]

    nonisolated(unsafe) static let question: [String: Any] = [
        "id": "que_limiter", "sessionID": sessionID,
        "questions": [[
            "question": "Which limiter should the upload route use?",
            "header": "Rate limit strategy",
            "options": [
                ["label": "Token bucket", "description": "Allows short bursts while enforcing a steady refill rate."],
                ["label": "Fixed window", "description": "Counts uploads per minute. Simplest to reason about."],
                ["label": "Sliding window", "description": "Tracks timestamps for precise rolling limits."]
            ],
            "multiple": false, "custom": true
        ]],
        "tool": ["messageID": "msg_agent", "callID": "call_question"]
    ]

    // MARK: Changes

    static func diff(_ file: String, status: String, _ patch: String) -> [String: Any] {
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        let additions = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
        let deletions = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        return ["file": file, "patch": patch, "additions": additions, "deletions": deletions, "status": status]
    }

    static var diffs: [[String: Any]] {
        switch phase {
        case .question: return []
        case .live: return [limiterDiff]
        case .permission, .done: return [limiterDiff, routeDiff, testsDiff]
        }
    }

    nonisolated(unsafe) static let limiterDiff = diff("src/middleware/rateLimit.ts", status: "added", """
        --- /dev/null
        +++ b/src/middleware/rateLimit.ts
        @@ -0,0 +1,25 @@
        +import type { RequestHandler } from "express";
        +
        +export function rateLimit({ limit = 10, windowMs = 60_000 } = {}): RequestHandler {
        +  const buckets = new Map<string, { tokens: number; at: number }>();
        +  const refill = limit / windowMs;
        +
        +  return (req, res, next) => {
        +    const key = req.ip ?? "unknown";
        +    const now = Date.now();
        +    const bucket = buckets.get(key) ?? { tokens: limit, at: now };
        +    bucket.tokens = Math.min(limit, bucket.tokens + (now - bucket.at) * refill);
        +    bucket.at = now;
        +    buckets.set(key, bucket);
        +
        +    res.setHeader("RateLimit-Limit", limit);
        +    res.setHeader("RateLimit-Remaining", Math.max(0, Math.floor(bucket.tokens) - 1));
        +    if (bucket.tokens < 1) {
        +      res.setHeader("Retry-After", Math.ceil((1 - bucket.tokens) / refill / 1000));
        +      return res.status(429).json({ error: "Too many uploads. Try again shortly." });
        +    }
        +    bucket.tokens -= 1;
        +    next();
        +  };
        +}
        """)

    nonisolated(unsafe) static let routeDiff = diff("src/routes/upload.ts", status: "modified", """
        --- a/src/routes/upload.ts
        +++ b/src/routes/upload.ts
        @@ -1,11 +1,13 @@
         import { Router } from "express";
         import multer from "multer";
        +import { rateLimit } from "../middleware/rateLimit";
         import { handleUpload } from "../handlers/upload";

         const router = Router();
         const upload = multer({ dest: "uploads/" });
        +const uploadLimit = rateLimit({ limit: 10, windowMs: 60_000 });

        -router.post("/upload", upload.single("file"), handleUpload);
        +router.post("/upload", uploadLimit, upload.single("file"), handleUpload);

         export default router;
        """)

    nonisolated(unsafe) static let testsDiff = diff("tests/upload.test.ts", status: "added", """
        --- /dev/null
        +++ b/tests/upload.test.ts
        @@ -0,0 +1,18 @@
        +import request from "supertest";
        +import { app } from "../src/app";
        +
        +describe("POST /upload rate limit", () => {
        +  it("returns 429 after 10 uploads in a minute", async () => {
        +    for (let i = 0; i < 10; i++) {
        +      await request(app).post("/upload").attach("file", Buffer.from("ok"), "a.txt").expect(201);
        +    }
        +    const limited = await request(app).post("/upload").attach("file", Buffer.from("ok"), "a.txt");
        +    expect(limited.status).toBe(429);
        +    expect(limited.headers["retry-after"]).toBeDefined();
        +  });
        +
        +  it("tracks clients separately", async () => {
        +    await request(app).post("/upload").set("X-Forwarded-For", "10.0.0.2").expect(201);
        +  });
        +});
        """)
}

private final class OpenCodeAppStoreFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }

    override func startLoading() {
        guard let url = request.url else { return }
        let phase = AppStoreFixture.phase
        let session = "/session/" + AppStoreFixture.sessionID
        let body: Any
        switch url.path {
        case "/event":
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("data: {\"id\":\"evt_connected\",\"type\":\"server.connected\",\"properties\":{}}\n\n".utf8))
            // Keep this fixture stream open until the conversation cancels it.
            return
        case let path where path.hasPrefix("/api/") || path == "/experimental/capabilities":
            respond(url, body: ["message": "Unavailable"], status: 404); return
        case "/global/health": body = ["healthy": true, "version": "1.18.29"]
        case "/project": body = AppStoreFixture.projects
        case "/session/status": body = AppStoreFixture.statuses
        case "/session":
            let directory = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "directory" }?.value
            body = AppStoreFixture.sessions.filter { $0["directory"] as? String == directory }
        case session: body = AppStoreFixture.sessions[0]
        case session + "/message": body = AppStoreFixture.messages
        case session + "/diff": body = AppStoreFixture.diffs
        case session + "/todo": body = AppStoreFixture.todos
        case "/permission": body = phase == .permission ? [AppStoreFixture.permission] : []
        case "/question": body = phase == .question ? [AppStoreFixture.question] : []
        case "/provider": body = AppStoreFixture.providers
        case "/agent": body = AppStoreFixture.agents
        case "/command": body = AppStoreFixture.commands
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
