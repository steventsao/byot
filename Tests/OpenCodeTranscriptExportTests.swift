import Foundation
import Testing
@testable import byot

// Markdown shape from packages/tui/src/util/transcript.ts (the TUI's /export
// and /copy); parts from packages/schema/src/v1/session.ts; /init from
// packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts,
// which runs the built-in `init` command.
@Suite("Transcript export and AGENTS.md setup")
struct OpenCodeTranscriptExportTests {
    // MARK: Markdown

    @Test("A v1 conversation exports as the TUI writes it, without context OpenCode added")
    func v1TranscriptMatchesTUI() throws {
        let markdown = try export(Self.v1Conversation).markdown(OpenCodeTranscriptExportOptions())
        let (header, body) = try split(markdown)
        #expect(header.hasPrefix("# Fix the empty state\n\n**Session ID:** ses_1234abcd5678\n**Created:** Nov 14, 2023"))
        #expect(header.contains("**Updated:** Nov 14, 2023"))
        #expect(body == """
        ## User

        Why does the empty list crash?

        _Attached: crash.png_

        ---

        ## Assistant (Build · Claude Sonnet 4.5 · 2.5s)

        **Tool: read**

        The list reads `items.first!` before checking for an empty array.

        ---

        _Conversation compacted._

        ---

        ## Assistant (Build · gpt-5)

        Summary: fixed the crash.

        **Error:** The operation was aborted.

        ---


        """)
        #expect(!markdown.contains("Contents of App.swift"), "synthetic text stays out")
        #expect(!markdown.contains("considering"), "thinking is off by default")
    }

    @Test("Thinking and tool details follow the options; fences outgrow backticks in the output")
    func optionsAddThinkingAndToolDetails() throws {
        let markdown = try export(Self.v1Conversation).markdown(
            OpenCodeTranscriptExportOptions(thinking: true, toolDetails: true, assistantMetadata: false))
        #expect(markdown.contains("## Assistant\n\n_Thinking:_\n\nconsidering the guard\n\n**Tool: read**\n"))
        #expect(markdown.contains("\n**Input:**\n```json\n{\n  \"filePath\" : \"/repo/Sources/App.swift\"\n}\n```\n"))
        #expect(markdown.contains("\n**Output:**\n````\nlet a = ```code```\n````\n\n"))
        #expect(!markdown.contains("(Build"))
    }

    @Test("Failed tools export their error only with tool details")
    func toolErrors() throws {
        let messages = try decode(#"[{"info":{"id":"a","sessionID":"s","role":"assistant","time":{"created":1}},"parts":[{"id":"t","sessionID":"s","messageID":"a","type":"tool","callID":"c","tool":"bash","state":{"status":"error","input":{"command":"swift test"},"error":"exit 1"}}]}]"#)
        let export = OpenCodeTranscriptExport(session: Self.session(), messages: messages)
        #expect(try split(export.markdown(.init())).1 == "## Assistant\n\n**Tool: bash**\n\n---\n\n")
        #expect(export.markdown(.init(toolDetails: true)).contains("\n**Error:**\n```\nexit 1\n```\n"))
    }

    @Test("v2 system records keep their role; synthetic context messages and empty turns drop out")
    func v2SystemMessages() throws {
        let shell = try #require(OpenCodeV2Normalization.message(try json(#"{"id":"msg_s","type":"shell","command":"git status","output":"clean","status":"completed","time":{"created":1}}"#), sessionID: "ses"))
        let context = try #require(OpenCodeV2Normalization.message(try json(#"{"id":"msg_c","type":"synthetic","text":"Reminder for the model","time":{"created":2}}"#), sessionID: "ses"))
        let empty = OpenCodeMessageEnvelope(info: OpenCodeMessageInfo(id: "msg_e", sessionID: "ses", role: "assistant",
            time: OpenCodeMessageTime(created: 3, completed: nil), agent: nil, modelID: nil, providerID: nil, finish: nil, error: nil), parts: [])
        let export = OpenCodeTranscriptExport(session: Self.session(), messages: [shell, context, empty])
        let body = try split(export.markdown(.init())).1
        #expect(body.hasPrefix("## System\n\nShell (completed)\n\ngit status\n\nclean\n\n---\n\n"))
        #expect(!body.contains("Reminder for the model"))
        #expect(!body.contains("## Assistant"))
        #expect(export.messageCount(.init()) == 1)
    }

    @Test("The file is named for the conversation, else its session ID")
    func filenames() {
        #expect(OpenCodeTranscriptExport(session: Self.session(title: "Fix: the empty-state crash!"), messages: []).filename
                == "fix-the-empty-state-crash.md")
        #expect(OpenCodeTranscriptExport(session: Self.session(title: "  ?! "), messages: []).filename == "session-ses_1234.md")
        let long = OpenCodeTranscriptExport(session: Self.session(title: String(repeating: "word ", count: 40)), messages: []).filename
        #expect(long.count <= 63 && long.hasSuffix(".md") && !long.contains("-.md"))
    }

    @Test("Untitled sessions and multi-line titles still produce one heading")
    func titles() {
        #expect(OpenCodeTranscriptExport(session: Self.session(title: " "), messages: []).markdown(.init()).hasPrefix("# Untitled session\n"))
        #expect(OpenCodeTranscriptExport(session: Self.session(title: "One\nTwo"), messages: []).markdown(.init()).hasPrefix("# One Two\n"))
    }

    @Test("Fences, JSON and title case match the TUI's helpers")
    func helpers() {
        #expect(OpenCodeTranscriptExport.fenced("plain\n") == "```\nplain\n```\n")
        #expect(OpenCodeTranscriptExport.fenced("````inner", language: "md") == "`````md\n````inner\n`````\n")
        #expect(OpenCodeTranscriptExport.json(.object(["b": .number(2), "a": .string("x/y")])) == "{\n  \"a\" : \"x/y\",\n  \"b\" : 2\n}")
        #expect(OpenCodeTranscriptExport.titlecase("build") == "Build")
        #expect(OpenCodeTranscriptExport.titlecase("code-reviewer v2") == "Code-Reviewer V2")
    }

    @Test("Export choices persist for the next export and for Copy transcript")
    func optionsPersist() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        #expect(OpenCodeTranscriptExportOptions(defaults: defaults) == OpenCodeTranscriptExportOptions())
        OpenCodeTranscriptExportOptions(thinking: true, toolDetails: true, assistantMetadata: false).save(to: defaults)
        #expect(OpenCodeTranscriptExportOptions(defaults: defaults)
                == OpenCodeTranscriptExportOptions(thinking: true, toolDetails: true, assistantMetadata: false))
    }

    @Test("The share file holds the Markdown and is removed with the sheet")
    func shareFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try OpenCodeTranscriptFile(markdown: "# Title\n", filename: "../escape.md", root: root)
        #expect(file.url.deletingLastPathComponent() == file.directory)
        #expect(file.url.lastPathComponent == "transcript.md")
        #expect(try String(contentsOf: file.url, encoding: .utf8) == "# Title\n")
        file.remove()
        #expect(!FileManager.default.fileExists(atPath: file.directory.path))
    }

    @Test("The store exports only the visible conversation, with catalog model names")
    @MainActor
    func storeExport() async throws {
        let service = TranscriptStoreService(messages: try decode(Self.v1Conversation), commands: [])
        let store = OpenCodeSessionStore(service: service, serverID: UUID(), session: Self.session(), directory: "/repo",
                                         defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        #expect(store.transcriptUnavailableReason != nil)
        await store.start()
        defer { store.stop() }
        // start() loads the model catalog in the background, and reloadModels()
        // returns at once while that load is in flight.
        for _ in 0..<200 where store.providerModels.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.transcriptUnavailableReason == nil)
        let export = store.transcriptExport
        #expect(export.messages.map(\.id) == store.messages.map(\.id))
        #expect(export.modelNames["anthropic/claude-sonnet-4-5"] == "Claude Sonnet 4.5")
    }

    // MARK: AGENTS.md setup

    @Test("The setup prompt carries an optional one-line focus as the command's arguments")
    func setupPrompt() {
        #expect(OpenCodeAgentsSetup.prompt(focus: "") == "/init")
        #expect(OpenCodeAgentsSetup.prompt(focus: "  ") == "/init")
        #expect(OpenCodeAgentsSetup.prompt(focus: " the test layout\nand CI ") == "/init the test layout and CI")
    }

    @Test("AGENTS.md setup is hidden unless the server lists the init command")
    @MainActor
    func setupRequiresInitCommand() async throws {
        let skillOnly = [OpenCodeSlashCommand(name: "init", description: nil, kind: .skill)]
        let service = TranscriptStoreService(messages: [], commands: skillOnly)
        let store = OpenCodeSessionStore(service: service, serverID: UUID(), session: Self.session(), directory: "/repo",
                                         defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        await store.start()
        defer { store.stop() }
        await store.reloadComposerCatalog()
        #expect(!store.supportsAgentsSetup)
        #expect(!store.startAgentsSetup())
        #expect(store.errorMessage == "This server does not offer AGENTS.md setup.")
        #expect(await service.sentPrompts.isEmpty)
    }

    @Test("Starting AGENTS.md setup sends the init command with the focus as arguments")
    @MainActor
    func setupSendsInitCommand() async throws {
        let commands = [OpenCodeSlashCommand(name: "init", description: "guided AGENTS.md setup", kind: .command)]
        let service = TranscriptStoreService(messages: [], commands: commands)
        let store = OpenCodeSessionStore(service: service, serverID: UUID(), session: Self.session(), directory: "/repo",
                                         defaults: try #require(UserDefaults(suiteName: UUID().uuidString)))
        #expect(store.agentsSetupUnavailableReason != nil, "not before the session connects")
        await store.start()
        defer { store.stop() }
        await store.reloadComposerCatalog()
        #expect(store.supportsAgentsSetup)
        #expect(store.agentsSetupUnavailableReason == nil)
        #expect(store.startAgentsSetup(focus: "the release scripts"))
        for _ in 0..<200 where await service.sentPrompts.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        let prompt = try #require(await service.sentPrompts.first)
        #expect(prompt.command == OpenCodeCommandInvocation(name: "init", arguments: "the release scripts", kind: .command))
        #expect(prompt.text == "/init the release scripts")
    }

    // MARK: Fixtures

    private static func session(title: String = "Fix the empty state") -> OpenCodeSession {
        OpenCodeSession(id: "ses_1234abcd5678", slug: "fix", projectID: "project", workspaceID: nil, directory: "/repo",
                        parentID: nil, summary: nil, title: title, agent: nil, version: "1",
                        time: OpenCodeSessionTime(created: 1_700_000_000_000, updated: 1_700_000_600_000,
                                                  compacting: nil, archived: nil))
    }

    /// One of each part a transcript writes or leaves out, as v1 stores them.
    private static let v1Conversation = #"""
    [{"info":{"id":"m1","sessionID":"ses_1234abcd5678","role":"user","time":{"created":1000}},"parts":[
      {"id":"p1","sessionID":"ses_1234abcd5678","messageID":"m1","type":"text","text":"Why does the empty list crash?\n"},
      {"id":"p2","sessionID":"ses_1234abcd5678","messageID":"m1","type":"text","text":"Contents of App.swift","synthetic":true},
      {"id":"p3","sessionID":"ses_1234abcd5678","messageID":"m1","type":"file","mime":"image/png","filename":"crash.png","url":"data:image/png;base64,AA=="}]},
     {"info":{"id":"m2","sessionID":"ses_1234abcd5678","role":"assistant","agent":"build","providerID":"anthropic","modelID":"claude-sonnet-4-5","time":{"created":2000,"completed":4500}},"parts":[
      {"id":"p4","sessionID":"ses_1234abcd5678","messageID":"m2","type":"step-start"},
      {"id":"p5","sessionID":"ses_1234abcd5678","messageID":"m2","type":"reasoning","text":"considering the guard"},
      {"id":"p6","sessionID":"ses_1234abcd5678","messageID":"m2","type":"tool","callID":"c1","tool":"read","state":{"status":"completed","input":{"filePath":"/repo/Sources/App.swift"},"output":"let a = ```code```","title":"App.swift"}},
      {"id":"p7","sessionID":"ses_1234abcd5678","messageID":"m2","type":"text","text":"The list reads `items.first!` before checking for an empty array."},
      {"id":"p8","sessionID":"ses_1234abcd5678","messageID":"m2","type":"step-finish","reason":"stop","cost":0.01,"tokens":{"input":1,"output":1,"reasoning":0,"cache":{"read":0,"write":0}}}]},
     {"info":{"id":"m3","sessionID":"ses_1234abcd5678","role":"user","time":{"created":5000}},"parts":[
      {"id":"p9","sessionID":"ses_1234abcd5678","messageID":"m3","type":"compaction","auto":true}]},
     {"info":{"id":"m4","sessionID":"ses_1234abcd5678","role":"assistant","agent":"build","providerID":"openai","modelID":"gpt-5","time":{"created":6000},"error":{"name":"MessageAbortedError","data":{"message":"The operation was aborted."}}},"parts":[
      {"id":"p10","sessionID":"ses_1234abcd5678","messageID":"m4","type":"text","text":"Summary: fixed the crash."}]}]
    """#

    private func export(_ raw: String) throws -> OpenCodeTranscriptExport {
        OpenCodeTranscriptExport(session: Self.session(), messages: try decode(raw),
                                 modelNames: ["anthropic/claude-sonnet-4-5": "Claude Sonnet 4.5"],
                                 locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
    }

    private func split(_ markdown: String) throws -> (String, String) {
        let range = try #require(markdown.range(of: "---\n\n"))
        return (String(markdown[..<range.lowerBound]), String(markdown[range.upperBound...]))
    }

    private func decode(_ raw: String) throws -> [OpenCodeMessageEnvelope] {
        try JSONDecoder().decode([OpenCodeMessageEnvelope].self, from: Data(raw.utf8))
    }

    private func json(_ raw: String) throws -> [String: OpenCodeJSONValue] {
        try #require(try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(raw.utf8)).objectValue)
    }
}

private actor TranscriptStoreService: OpenCodeSessionServicing {
    let storedMessages: [OpenCodeMessageEnvelope]
    let commands: [OpenCodeSlashCommand]
    var sentPrompts: [OpenCodeQueuedPrompt] = []

    init(messages: [OpenCodeMessageEnvelope], commands: [OpenCodeSlashCommand]) {
        storedMessages = messages
        self.commands = commands
    }

    func composerCatalog(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeComposerCatalog {
        OpenCodeComposerCatalog(commands: commands)
    }
    func sendPrompt(sessionID: String, directory: String, workspace: String?, prompt: OpenCodeQueuedPrompt) async throws {
        sentPrompts.append(prompt)
    }
    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] {
        [OpenCodeProviderModels(providerID: "anthropic", providerName: "Anthropic", models: [
            OpenCodeModelOption(providerID: "anthropic", providerName: "Anthropic", modelID: "claude-sonnet-4-5",
                                modelName: "Claude Sonnet 4.5", status: nil),
        ])]
    }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] { storedMessages }
    func sendMessage(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String,
                     attachments: [OpenCodePromptAttachment], promptID: UUID) async throws {}
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool { true }
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff] { [] }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] { [:] }
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest] { [] }
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest] { [] }
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] { [] }
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] { [] }
    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?, reply: OpenCodePermissionReply) async throws {}
    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws {}
    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?) async throws {}
    nonisolated func events(directory: String, workspace: String?) -> AsyncThrowingStream<OpenCodeEvent, Error> { AsyncThrowingStream { _ in } }
}
