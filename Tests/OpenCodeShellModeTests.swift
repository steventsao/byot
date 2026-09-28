import Foundation
import Testing
@testable import byot

@Suite("Composer shell mode")
struct OpenCodeShellModeTests {
    // MARK: Input

    @Test("Only a typed ! into an empty composer enters shell mode")
    func bangEntersShellMode() {
        #expect(OpenCodeShellInput.entersShellMode(from: "", to: "!"))
        #expect(!OpenCodeShellInput.entersShellMode(from: "hi", to: "hi!"))
        #expect(!OpenCodeShellInput.entersShellMode(from: "", to: "!git status"), "Pasted text stays a message")
        #expect(!OpenCodeShellInput.entersShellMode(from: "!", to: "!!"))
    }

    @Test("Keyboard smart punctuation is undone so commands run as typed")
    func normalizesSmartPunctuation() {
        #expect(OpenCodeShellInput.normalized("  echo \u{201C}hi\u{201D} \u{2018}x\u{2019} \n") == "echo \"hi\" 'x'")
        #expect(OpenCodeShellInput.normalized("ls \u{2014}all") == "ls --all")
        #expect(OpenCodeShellInput.normalized("   ").isEmpty)
    }

    // MARK: Wire contract

    @Test("v1 posts the command with the session agent and model to the legacy shell route")
    func v1Request() async throws {
        let transport = ShellTransport()
        let context = OpenCodeFeatureContext(serverProtocol: .v1, schema: nil, transport: transport, profile: Self.profile)
        #expect(OpenCodeShellDispatch.isSupported(context))
        try await OpenCodeShellDispatch(context: context).run(sessionID: "ses_a", directory: "/repo", workspace: "wrk",
            shell: OpenCodeShellCommand(command: "git status", agent: "plan", model: Self.model))
        let request = try #require(await transport.requests.first)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        #expect(request.httpMethod == "POST")
        #expect(components.path == "/session/ses_a/shell")
        #expect(components.queryItems == [URLQueryItem(name: "directory", value: "/repo"), URLQueryItem(name: "workspace", value: "wrk")])
        #expect(request.timeoutInterval == OpenCodeShellDispatch.requestTimeout)
        let body = try Self.body(request)
        #expect(body == [
            "command": .string("git status"), "agent": .string("plan"),
            "model": .object(["providerID": .string("fixture"), "modelID": .string("m")]),
        ])
    }

    @Test("v1 requires an agent and never sends an empty command")
    func v1Validation() {
        let dispatch = OpenCodeShellDispatch(context: OpenCodeFeatureContext(
            serverProtocol: .v1, schema: nil, transport: ShellTransport(), profile: Self.profile))
        #expect(throws: OpenCodeShellError.agentRequired) {
            try dispatch.body(OpenCodeShellCommand(command: "ls", agent: nil, model: nil))
        }
        #expect(throws: OpenCodeShellError.emptyCommand) {
            try dispatch.body(OpenCodeShellCommand(command: "", agent: "build", model: nil))
        }
        let automatic = try? dispatch.body(OpenCodeShellCommand(command: "ls", agent: "build", model: nil)).objectValue
        #expect(automatic?["model"] == nil, "Automatic model selection lets the server choose")
    }

    @Test("v2 posts only the command to the schema-listed route")
    func v2Request() async throws {
        let transport = ShellTransport(status: 204)
        let context = OpenCodeFeatureContext(serverProtocol: .v2, schema: try Self.betaSchema(), transport: transport, profile: Self.profile)
        #expect(OpenCodeShellDispatch.isSupported(context))
        #expect(OpenCodeSessionFeatureSupport.negotiated(context).shell)
        try await OpenCodeShellDispatch(context: context).run(sessionID: "ses_a", directory: "/repo", workspace: nil,
            shell: OpenCodeShellCommand(command: "ls -la", agent: "build", model: Self.model))
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/api/session/ses_a/shell")
        #expect(request.url?.query == nil)
        #expect(try Self.body(request) == ["command": .string("ls -la")])
    }

    @Test("v2 without a shell route hides shell mode and sends nothing")
    func v2Unsupported() async throws {
        let schema: OpenCodeJSONValue = .object(["paths": .object([
            "/api/session/{sessionID}/prompt": .object(["post": .object([:])]),
        ])])
        let transport = ShellTransport()
        let context = OpenCodeFeatureContext(serverProtocol: .v2, schema: schema, transport: transport, profile: Self.profile)
        #expect(!OpenCodeShellDispatch.isSupported(context))
        #expect(!OpenCodeSessionFeatureSupport.negotiated(context).shell)
        await #expect(throws: OpenCodeShellError.unsupported) {
            try await OpenCodeShellDispatch(context: context).run(sessionID: "ses_a", directory: "/repo", workspace: nil,
                shell: OpenCodeShellCommand(command: "ls", agent: nil, model: nil))
        }
        #expect(await transport.requests.isEmpty)
        #expect(OpenCodeSessionFeatureSupport.negotiated(OpenCodeFeatureContext(
            serverProtocol: .v1, schema: nil, transport: transport, profile: Self.profile)).shell)
    }

    @Test("Failures say whether the command may still have run")
    func failureClassification() {
        let busy = OpenCodeConnectionError.httpStatus(409, "Session is busy: ses_a")
        #expect(OpenCodeShellError.certainlyDidNotRun(busy))
        #expect(OpenCodeShellError.failureMessage(for: busy).contains("busy"))
        #expect(OpenCodeShellError.certainlyDidNotRun(OpenCodeConnectionError.httpStatus(400, "Missing key")))
        let timeout = URLError(.timedOut)
        #expect(!OpenCodeShellError.certainlyDidNotRun(timeout))
        #expect(OpenCodeShellError.failureMessage(for: timeout).contains("may have run"))
        #expect(!OpenCodeShellError.certainlyDidNotRun(OpenCodeConnectionError.httpStatus(502, nil)))
    }

    // MARK: Transcript

    @Test("A v1 shell turn collapses into one card that keeps the user message id")
    func v1TranscriptRow() throws {
        let messages = try Self.v1ShellTurn(status: "completed", output: "hi\na.txt\n")
        let rows = OpenCodeShellTranscript.rows(for: [Self.text("msg_0", role: "user", "Earlier")] + messages)
        #expect(rows.count == 2)
        guard case .shell(let run) = rows.last else { Issue.record("Expected a shell row"); return }
        #expect(run.id == "msg_user")
        #expect(run.command == "echo hi; ls")
        #expect(run.output == "hi\na.txt")
        #expect(run.status == .exited(code: nil))
        #expect(run.statusLabel == "Done")
        #expect(OpenCodeShellTranscript.command(forMarker: "msg_user", in: messages) == "echo hi; ls")
        #expect(OpenCodeShellTranscript.command(forMarker: "msg_0", in: messages) == nil)
    }

    @Test("A running v1 shell streams metadata output and an abort reads as stopped")
    func v1RunningAndStopped() throws {
        let running = try Self.v1ShellTurn(status: "running", output: nil, metadataOutput: "partial\n")
        guard case .shell(let live) = OpenCodeShellTranscript.rows(for: running).first else { Issue.record("No row"); return }
        #expect(live.isRunning)
        #expect(live.output == "partial")
        let aborted = try Self.v1ShellTurn(status: "completed",
            output: "\n\n<metadata>\nUser aborted the command\n</metadata>")
        guard case .shell(let stopped) = OpenCodeShellTranscript.rows(for: aborted).first else { Issue.record("No row"); return }
        #expect(stopped.status == .stopped)
        #expect(stopped.output.isEmpty)
    }

    @Test("Tool metadata keeps only the fields shell cards read")
    func toolMetadataIsNarrow() throws {
        let json = #"""
        {"status":"completed","input":{},"output":"ok","metadata":{"output":"ok","exit":2,"truncated":true,
         "filediff":{"file":"a.swift","before":"old body","after":"new body"}}}
        """#
        let state = try JSONDecoder().decode(OpenCodeToolState.self, from: Data(json.utf8))
        #expect(state.shellMetadata == OpenCodeToolMetadata(output: "ok", exit: 2, truncated: true))
        #expect(state.metadata?["filediff"] == nil)
        // A tool that uses these names for other shapes still decodes.
        let other = try JSONDecoder().decode(OpenCodeToolState.self, from: Data(
            #"{"status":"completed","metadata":{"output":{"lines":3},"exit":"1"}}"#.utf8))
        #expect(other.shellMetadata == OpenCodeToolMetadata())
    }

    @Test("The server's shell bookkeeping text is never shown as something the user typed")
    func v1MarkerAloneIsHidden() throws {
        let marker = try #require(try Self.v1ShellTurn(status: "running", output: nil).first)
        #expect(OpenCodeShellTranscript.rows(for: [marker]).isEmpty)
        let typed = Self.text("msg_typed", role: "user", OpenCodeShellTranscript.v1MarkerText)
        #expect(OpenCodeShellTranscript.rows(for: [typed]) == [.message(typed)], "Only synthetic text is bookkeeping")
    }

    @Test("A fetched v2 shell message normalizes to a shell card with exit status and truncation")
    func v2FetchedMessage() throws {
        let raw: OpenCodeJSONValue = try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data("""
        {"id":"msg_shell","type":"shell","shellID":"sh_1","command":"npm test","status":"exited","exit":2,
         "output":{"output":"FAIL one\\n","cursor":9,"size":9,"truncated":true},"time":{"created":5,"completed":9}}
        """.utf8))
        let message = try #require(OpenCodeV2Normalization.message(raw.objectValue!, sessionID: "ses_a"))
        #expect(message.info.role == "system", "A shell run is not an unanswered user prompt")
        guard case .shell(let run) = OpenCodeShellTranscript.rows(for: [message]).first else { Issue.record("No row"); return }
        #expect(run == OpenCodeShellRun(id: "msg_shell", command: "npm test", output: "FAIL one",
                                        status: .exited(code: 2), isTruncated: true))
        #expect(run.isFailure)
        #expect(run.statusLabel == "Exit 2")
    }

    @Test("A current v2 shell record and its session.next events become the same shell card")
    func v2CurrentShellRecord() throws {
        let raw: OpenCodeJSONValue = try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data("""
        {"id":"msg_run","type":"shell","callID":"call_1","command":"ls","output":"a.txt\\n","time":{"created":4,"completed":5}}
        """.utf8))
        let message = try #require(OpenCodeV2Normalization.message(raw.objectValue!, sessionID: "ses_a"))
        #expect(message.info.role == "system")
        guard case .shell(let run) = OpenCodeShellTranscript.rows(for: [message]).first else { Issue.record("No row"); return }
        #expect(run == OpenCodeShellRun(id: "msg_run", command: "ls", output: "a.txt", status: .exited(code: nil), isTruncated: false))

        var reducer = OpenCodeTranscriptReducer()
        _ = reducer.applyV2(OpenCodeEvent(id: "e1", type: "session.next.shell.started", properties: [
            "sessionID": .string("ses_a"), "messageID": .string("msg_run"), "callID": .string("call_1"),
            "command": .string("ls"), "timestamp": .number(4)], isV2: true))
        guard case .shell(let running) = OpenCodeShellTranscript.rows(for: reducer.messages).first else { Issue.record("No row"); return }
        #expect(running.isRunning)
        _ = reducer.applyV2(OpenCodeEvent(id: "e2", type: "session.next.shell.ended", properties: [
            "sessionID": .string("ses_a"), "callID": .string("call_1"), "output": .string("a.txt\n"),
            "timestamp": .number(5)], isV2: true))
        #expect(reducer.messages == [message])
    }

    @Test("An exported transcript keeps a shell run's command and output")
    func shellExport() throws {
        let raw: OpenCodeJSONValue = try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data("""
        {"id":"msg_run","type":"shell","callID":"call_1","command":"git status","output":"clean\\n","time":{"created":4,"completed":5}}
        """.utf8))
        let message = try #require(OpenCodeV2Normalization.message(raw.objectValue!, sessionID: "ses_a"))
        let session = OpenCodeSession(id: "ses_a", slug: "a", projectID: "p", workspaceID: nil, directory: "/repo",
            parentID: nil, summary: nil, title: "Shell", agent: nil, version: "2",
            time: OpenCodeSessionTime(created: 1, updated: 5, compacting: nil, archived: nil))
        let markdown = OpenCodeTranscriptExport(session: session, messages: [message]).markdown(.init())
        #expect(markdown.contains("## System\n\n**Shell:** `git status`\n\n```\nclean\n```\n"))
    }

    @Test("v2 shell events insert a running card and complete it with output")
    func v2Events() throws {
        var reducer = OpenCodeTranscriptReducer()
        let shell: OpenCodeJSONValue = .object(["id": .string("sh_1"), "status": .string("running"),
            "command": .string("pwd"), "cwd": .string("/repo"), "shell": .string("zsh"), "file": .string("/tmp/out"),
            "metadata": .object([:]), "time": .object(["started": .number(10)])])
        let started = reducer.apply(OpenCodeEvent(id: "evt_abc", type: "session.shell.started",
            properties: ["sessionID": .string("ses_a"), "shell": shell], created: 10, isV2: true))
        #expect(started)
        guard case .shell(let running) = OpenCodeShellTranscript.rows(for: reducer.messages).first else {
            Issue.record("No row"); return
        }
        #expect(running.id == "msg_abc", "Upstream derives the message id from the event id")
        #expect(running.isRunning)

        var ended = shell.objectValue!
        ended["status"] = .string("exited"); ended["exit"] = .number(0)
        let finished = reducer.apply(OpenCodeEvent(id: "evt_def", type: "session.shell.ended", properties: [
            "sessionID": .string("ses_a"), "shell": .object(ended),
            "output": .object(["output": .string("/repo\n"), "cursor": .number(6), "size": .number(6), "truncated": .bool(false)]),
        ], created: 12, isV2: true))
        #expect(finished)
        guard case .shell(let done) = OpenCodeShellTranscript.rows(for: reducer.messages).first else { Issue.record("No row"); return }
        #expect(done == OpenCodeShellRun(id: "msg_abc", command: "pwd", output: "/repo", status: .exited(code: 0), isTruncated: false))
        #expect(reducer.messages.count == 1)
    }

    @Test("A local card shows until the server's record of the same command arrives")
    func localCard() throws {
        let earlier = try Self.v1ShellTurn(status: "completed", output: "old", command: "ls", idPrefix: "old")
        var local = OpenCodeLocalShell(id: UUID(), command: "ls", baselineMessageIDs: Set(earlier.map(\.id)))
        let pending = OpenCodeShellTranscript.rows(for: earlier, local: local)
        #expect(pending.count == 2, "An older identical command does not satisfy the new run")
        guard case .shell(let card) = pending.last else { Issue.record("No card"); return }
        #expect(card.isRunning)

        let arrived = earlier + (try Self.v1ShellTurn(status: "running", output: nil, command: "ls", idPrefix: "new"))
        #expect(OpenCodeShellTranscript.rows(for: arrived, local: local).count == 2)

        local.phase = .failed("OpenCode was busy with another turn.")
        guard case .shell(let failed) = OpenCodeShellTranscript.rows(for: earlier, local: local).last else {
            Issue.record("No failure card"); return
        }
        #expect(failed.status == .notRun("OpenCode was busy with another turn."))
        #expect(failed.statusLabel == "Didn’t run")
    }

    @Test("Collapsed output keeps the last lines, like a terminal")
    func outputWindow() {
        let lines = OpenCodeShellRunView.lines((1...20).map(String.init).joined(separator: "\n"))
        let collapsed = OpenCodeShellRunView.visibleOutput(lines, expanded: false)
        #expect(collapsed.hiddenLeadingLines == 8)
        #expect(collapsed.text.hasPrefix("9\n"))
        #expect(collapsed.text.hasSuffix("\n20"))
        #expect(OpenCodeShellRunView.visibleOutput(lines, expanded: true).hiddenLeadingLines == 0)
        #expect(OpenCodeShellRunView.lines("").isEmpty)
    }

    @Test("Drafts remember shell mode and older drafts still load")
    func draftMode() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "shell-draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OpenCodeComposerDraftStore(serverID: Self.profile.id, sessionID: "ses_a", directory: "/repo",
                                               workspace: nil, root: root)
        try store.save(OpenCodeComposerDraft(text: "git log", isShellMode: true))
        #expect(try store.load().0.isShellMode == true)
        struct LegacyDraft: Encodable { let text: String; let references: [OpenCodePromptFileReference] }
        let legacy = try PropertyListDecoder().decode(OpenCodeComposerDraft.self, from: PropertyListEncoder().encode(
            LegacyDraft(text: "hello", references: [])))
        #expect(legacy.text == "hello")
        #expect(legacy.isShellMode == nil)
    }

    // MARK: Store

    @MainActor
    @Test("A shell run holds prompts behind it, then releases them")
    func storeRunsAndReleasesQueue() async throws {
        let service = ShellStoreService()
        let store = try await Self.startedStore(service)
        defer { store.stop() }
        #expect(store.supportsShell)
        #expect(store.shellUnavailableReason == nil)

        #expect(store.runShell("git \u{201C}status\u{201D}"))
        #expect(store.isShellSending)
        #expect(store.shellUnavailableReason != nil)
        #expect(!store.runShell("ls"), "One command at a time")
        try await Self.until { await service.startedCommands.count == 1 }
        #expect(await service.startedCommands.first?.command == "git \"status\"")
        #expect(await service.startedCommands.first?.agent == "build")

        #expect(store.willQueueNextPrompt)
        #expect(store.send("after the command"))
        #expect(store.queuedPrompts.map(\.text) == ["after the command"])
        #expect(await service.sentTexts.isEmpty)

        await service.finishShell(with: nil)
        try await Self.until { store.localShell == nil }
        try await Self.until { await service.sentTexts == ["after the command"] }
        #expect(store.restoredShellCommand == nil)
    }

    @MainActor
    @Test("A refused command comes back to the composer and stays visible in the transcript")
    func storeRestoresRefusedCommand() async throws {
        let service = ShellStoreService()
        let store = try await Self.startedStore(service)
        defer { store.stop() }
        #expect(store.runShell("make"))
        try await Self.until { await service.startedCommands.count == 1 }
        await service.finishShell(with: OpenCodeConnectionError.httpStatus(409, "Session is busy"))
        try await Self.until { store.localShell?.isSending == false }
        #expect(store.restoredShellCommand == "make")
        guard case .failed(let message)? = store.localShell?.phase else { Issue.record("Expected a refusal"); return }
        #expect(message.contains("busy"))
        store.consumeRestoredShellCommand()
        store.dismissShellFailure()
        #expect(store.localShell == nil)
    }

    @MainActor
    @Test("Busy sessions and servers without shell support never run a command")
    func storeGating() async throws {
        let service = ShellStoreService()
        let store = try await Self.startedStore(service)
        defer { store.stop() }
        store.handle(OpenCodeEvent(id: "evt_busy", type: "session.status", properties: [
            "sessionID": .string("ses_a"), "status": .object(["type": .string("busy")])]))
        #expect(store.shellUnavailableReason?.contains("idle") == true)
        #expect(!store.runShell("ls"))

        let unsupported = ShellStoreService(supportsShell: false)
        let hidden = try await Self.startedStore(unsupported)
        defer { hidden.stop() }
        #expect(!hidden.supportsShell)
        #expect(!hidden.runShell("ls"))
        #expect(await unsupported.startedCommands.isEmpty)
    }

    @MainActor
    @Test("Undo restores a v1 run as a command, but redo that clears the composer does not")
    func storeRestoresOnlyRealShellTurns() async throws {
        let turn = try Self.v1ShellTurn(status: "completed", output: "hi\n")
        let service = ShellStoreService(history: turn)
        let store = try await Self.startedStore(service)
        defer { store.stop() }
        try await Self.until { store.messages.count == 2 }
        #expect(store.shellCommand(restoring: turn[0]) == "echo hi; ls")
        let cleared = OpenCodeMessageEnvelope(info: turn[0].info, parts: [])
        #expect(store.shellCommand(restoring: cleared) == nil)
    }

    @MainActor
    @Test("Shell support is unknown until the server's session features load")
    func storeShellSupportKnown() async throws {
        let service = ShellStoreService()
        let store = OpenCodeSessionStore(service: service, serverID: Self.profile.id, session: Self.session,
                                         directory: "/repo", defaults: try #require(UserDefaults(suiteName: "shell-known-\(UUID())")))
        #expect(!store.isShellSupportKnown)
        await store.refreshSessionFeatures()
        #expect(store.isShellSupportKnown)
        #expect(store.supportsShell)
    }

    // MARK: Fixtures

    fileprivate static let profile = OpenCodeServerProfile(
        id: UUID(uuidString: "63636363-6363-6363-6363-636363636363")!, name: "Fixture", baseURL: "https://fixture.test")
    private static let model = OpenCodeModelOption(providerID: "fixture", providerName: "Fixture", modelID: "m",
                                                   modelName: "M", status: nil, variants: [])
    fileprivate static let session = OpenCodeSession(
        id: "ses_a", slug: "a", projectID: "pro", workspaceID: nil, directory: "/repo", parentID: nil,
        summary: nil, title: "Shell", agent: nil, version: "1.18.21",
        time: OpenCodeSessionTime(created: 1, updated: 1, compacting: nil, archived: nil))

    private static func betaSchema() throws -> OpenCodeJSONValue {
        let url = try #require(Bundle(for: ShellBundleToken.self).url(forResource: "opencode2-beta-19242-openapi", withExtension: "json"))
        return try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(contentsOf: url))
    }

    private static func body(_ request: URLRequest) throws -> [String: OpenCodeJSONValue] {
        try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: #require(request.httpBody))
    }

    static func text(_ id: String, role: String, _ text: String) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessageInfo(id: id, sessionID: "ses_a", role: role, time: OpenCodeMessageTime(created: 1, completed: nil),
                                      agent: nil, modelID: nil, providerID: nil, finish: nil, error: nil),
            parts: [OpenCodePart(id: "\(id)-text", sessionID: "ses_a", messageID: id, type: "text", text: text, mime: nil,
                                 filename: nil, url: nil, callID: nil, tool: nil, state: nil, files: nil, description: nil, agent: nil)])
    }

    /// Shaped like OpenCode 1.18.21's live `POST /session/{id}/shell` records.
    private static func v1ShellTurn(status: String, output: String?, metadataOutput: String? = nil,
                                    command: String = "echo hi; ls", idPrefix: String = "") throws -> [OpenCodeMessageEnvelope] {
        var state: [String: OpenCodeJSONValue] = ["status": .string(status), "input": .object(["command": .string(command)]),
                                                  "time": .object(["start": .number(2)])]
        if let output { state["output"] = .string(output); state["title"] = .string("") }
        if let streamed = metadataOutput ?? output { state["metadata"] = .object(["output": .string(streamed)]) }
        let raw: OpenCodeJSONValue = .array([
            .object(["info": .object(["id": .string("msg_\(idPrefix)user"), "sessionID": .string("ses_a"), "role": .string("user"),
                                      "time": .object(["created": .number(1)]), "agent": .string("build"),
                                      "model": .object(["providerID": .string("nvidia"), "modelID": .string("gpt-oss")])]),
                     "parts": .array([.object(["id": .string("prt_\(idPrefix)marker"), "sessionID": .string("ses_a"),
                                               "messageID": .string("msg_\(idPrefix)user"), "type": .string("text"),
                                               "text": .string(OpenCodeShellTranscript.v1MarkerText), "synthetic": .bool(true)])])]),
            .object(["info": .object(["id": .string("msg_\(idPrefix)reply"), "sessionID": .string("ses_a"), "role": .string("assistant"),
                                      "time": .object(["created": .number(2)]), "agent": .string("build"), "mode": .string("build"),
                                      "modelID": .string("gpt-oss"), "providerID": .string("nvidia"), "cost": .number(0)]),
                     "parts": .array([.object(["id": .string("prt_\(idPrefix)tool"), "sessionID": .string("ses_a"),
                                               "messageID": .string("msg_\(idPrefix)reply"), "type": .string("tool"),
                                               "callID": .string("01M3"), "tool": .string("bash"), "state": .object(state)])])]),
        ])
        return try JSONDecoder().decode([OpenCodeMessageEnvelope].self, from: JSONEncoder().encode(raw))
    }

    @MainActor
    private static func startedStore(_ service: ShellStoreService) async throws -> OpenCodeSessionStore {
        let suite = "shell-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let store = OpenCodeSessionStore(service: service, serverID: profile.id, session: session,
                                         directory: "/repo", defaults: defaults)
        await store.reloadComposerCatalog()
        await store.start()
        return store
    }

    @MainActor
    private static func until(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for the condition")
    }
}

private final class ShellBundleToken {}

private actor ShellTransport: OpenCodeHTTPTransport {
    var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    nonisolated func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        var components = URLComponents(string: "https://fixture.test/" + path.joined(separator: "/"))!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.httpBody = body
        return request
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let body = status == 204 ? Data() : Data(#"{"info":{},"parts":[]}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                      headerFields: ["Content-Type": "application/json"])!)
    }
    nonisolated func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor ShellStoreService: OpenCodeSessionServicing, OpenCodeSessionFeatureServicing, OpenCodeShellServicing {
    let supportsShell: Bool
    let history: [OpenCodeMessageEnvelope]
    var startedCommands: [OpenCodeShellCommand] = []
    var sentTexts: [String] = []
    private var shellContinuation: CheckedContinuation<Error?, Never>?
    init(supportsShell: Bool = true, history: [OpenCodeMessageEnvelope] = []) {
        self.supportsShell = supportsShell
        self.history = history
    }

    func finishShell(with error: Error?) {
        shellContinuation?.resume(returning: error)
        shellContinuation = nil
    }

    func runShell(sessionID: String, directory: String, workspace: String?, shell: OpenCodeShellCommand) async throws {
        startedCommands.append(shell)
        let error = await withCheckedContinuation { shellContinuation = $0 }
        if let error { throw error }
    }

    func composerCatalog(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeComposerCatalog {
        OpenCodeComposerCatalog(agents: [OpenCodeAgentOption(id: "build", name: "build", description: nil)], defaultAgentID: "build")
    }
    func sendPrompt(sessionID: String, directory: String, workspace: String?, prompt: OpenCodeQueuedPrompt) async throws {
        sentTexts.append(prompt.text)
    }
    func sessionFeatureSupport() async throws -> OpenCodeSessionFeatureSupport {
        OpenCodeSessionFeatureSupport(shell: supportsShell)
    }
    func sessionDetails(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSessionDetails {
        OpenCodeSessionDetails(session: OpenCodeShellModeTests.session, revertMessageID: nil)
    }
    func renameSession(sessionID: String, directory: String, workspace: String?, title: String) async throws -> OpenCodeSessionDetails {
        OpenCodeSessionDetails(session: OpenCodeShellModeTests.session, revertMessageID: nil)
    }
    func deleteSession(sessionID: String, directory: String, workspace: String?) async throws {}
    func archiveSession(sessionID: String, directory: String, workspace: String?) async throws {}
    func childSessions(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeSession] { [] }
    func sessionTodos(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeTodo]? { nil }
    func stageSessionRevert(sessionID: String, directory: String, workspace: String?, messageID: String) async throws {}
    func clearSessionRevert(sessionID: String, directory: String, workspace: String?) async throws {}
    func commitSessionRevert(sessionID: String, directory: String, workspace: String?) async throws -> Bool { false }
    func compactSession(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?) async throws {}
    func forkSession(sessionID: String, directory: String, workspace: String?, beforeMessageID: String?) async throws -> OpenCodeSession {
        OpenCodeShellModeTests.session
    }
    func sessionSharePolicy(directory: String, workspace: String?) async throws -> OpenCodeSessionSharePolicy { .manual }
    func shareSession(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSession {
        OpenCodeShellModeTests.session
    }
    func unshareSession(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSession {
        OpenCodeShellModeTests.session
    }
    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] { [] }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] { history }
    func sendMessage(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String,
                     attachments: [OpenCodePromptAttachment], promptID: UUID) async throws {}
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool { true }
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff] { [] }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] { [:] }
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
