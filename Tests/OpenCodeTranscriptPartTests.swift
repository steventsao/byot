import Foundation
import Testing
import UIKit
@testable import byot

// Parts from packages/schema/src/v1/session.ts and their v2 counterparts.
@Suite("Transcript part rendering")
struct OpenCodeTranscriptPartTests {
    private let enUS = Locale(identifier: "en_US")

    // MARK: Decoding

    @Test("v1 compaction, retry, agent, step-finish, snapshot and patch parts decode their fields")
    func decodesV1Parts() throws {
        let compaction = try part(#""type":"compaction","auto":true,"overflow":true"#)
        #expect(compaction.auto == true)
        #expect(compaction.overflow == true)

        let retry = try part(#""type":"retry","attempt":2,"time":{"created":5},"error":{"name":"APIError","data":{"message":"Rate limited","statusCode":429,"isRetryable":true}}"#)
        #expect(retry.attempt == 2)
        #expect(retry.error?.name == "APIError")
        #expect(retry.error?.displayMessage == "Rate limited")

        let agent = try part(#""type":"agent","name":"explore","source":{"value":"@explore","start":0,"end":8}"#)
        #expect(agent.name == "explore")

        let step = try part(#""type":"step-finish","reason":"stop","snapshot":"abc","cost":0.0123,"tokens":{"input":4020,"output":21,"reasoning":15,"cache":{"read":100,"write":2}}"#)
        #expect(step.reason == "stop")
        #expect(step.cost == 0.0123)
        #expect(step.snapshot == "abc")
        #expect(step.tokens == OpenCodeTokenUsage(input: 4020, output: 21, reasoning: 15, cacheRead: 100, cacheWrite: 2))
        #expect(step.tokens?.total == 4158)

        let snapshot = try part(#""type":"snapshot","snapshot":"444a8fa98e219b9e""#)
        #expect(snapshot.snapshot == "444a8fa98e219b9e")

        let patch = try part(#""type":"patch","hash":"deadbeef","files":["/repo/a.swift","/repo/b.swift"]"#)
        #expect(patch.hash == "deadbeef")
        #expect(patch.files == ["/repo/a.swift", "/repo/b.swift"])
    }

    @Test("An unfamiliar field shape keeps the part instead of dropping it")
    func lenientDecoding() throws {
        let step = try part(#""type":"step-finish","reason":7,"cost":"free","tokens":"many""#)
        #expect(step.type == "step-finish")
        #expect(step.reason == nil)
        #expect(step.cost == nil)
        #expect(step.tokens == nil)
        let total = try part(#""type":"step-finish","tokens":{"total":900,"input":1,"output":2,"reasoning":0,"cache":{"read":0,"write":0}}"#)
        #expect(total.tokens?.total == 900)
    }

    @Test("Legacy part events carry the new fields through the transcript reducer")
    func reducerKeepsFields() throws {
        var reducer = OpenCodeTranscriptReducer()
        let raw = #"{"id":"e1","type":"message.part.updated","properties":{"part":{"id":"p1","sessionID":"s","messageID":"m","type":"retry","attempt":3,"error":{"name":"APIError","data":{"message":"Overloaded","isRetryable":true}},"time":{"created":1}}}}"#
        #expect(reducer.apply(try JSONDecoder().decode(OpenCodeEvent.self, from: Data(raw.utf8))))
        let info = #"{"id":"e2","type":"message.updated","properties":{"info":{"id":"m","sessionID":"s","role":"assistant","time":{"created":1}}}}"#
        #expect(reducer.apply(try JSONDecoder().decode(OpenCodeEvent.self, from: Data(info.utf8))))
        let retry = try #require(reducer.messages.first?.parts.first)
        #expect(retry.attempt == 3)
        #expect(OpenCodeRetryPresentation(part: retry).detail == "Overloaded")
    }

    // MARK: Layout

    @Test("Adjacent images group into one gallery and silent parts are dropped")
    func layoutGroupsImages() {
        let parts = [
            make("t1", "text", text: "Look"),
            make("i1", "file", mime: "image/png", url: "data:image/png;base64,iVBORw0KGgo="),
            make("i2", "file", mime: "image/jpeg", url: "file:///repo/shot.jpg"),
            make("s1", "step-start"),
            make("f1", "file", mime: "text/plain", url: "file:///repo/a.txt"),
            make("i3", "file", mime: "image/png", url: "data:image/png;base64,iVBORw0KGgo="),
            make("e1", "text", text: ""),
            make("c1", "compaction"),
        ]
        let items = OpenCodeTranscriptLayout.items(for: parts)
        #expect(items.map(\.id) == ["t1", "images:i1", "f1", "images:i3", "c1"])
        guard case .images(let run) = items[1] else { Issue.record("Expected a gallery"); return }
        #expect(run.map(\.id) == ["i1", "i2"])
        #expect(items.map(\.isBanner) == [false, false, false, false, true])
    }

    @Test("Vector images and remote URLs keep the attachment row")
    func inlineCandidates() {
        #expect(!OpenCodeInlineImage.isInlineCandidate(make("a", "file", mime: "image/svg+xml", url: "data:image/svg+xml;base64,PHN2Zz4=")))
        #expect(!OpenCodeInlineImage.isInlineCandidate(make("b", "file", mime: "image/png", url: "https://example.com/a.png")))
        #expect(OpenCodeInlineImage.isInlineCandidate(make("c", "file", mime: "application/octet-stream", url: "data:image/webp;base64,UklGRg==")))
        #expect(!OpenCodeInlineImage.isInlineCandidate(make("d", "file", mime: "image/png", url: nil)))
    }

    // Checks the height helper only, not that the view applies it, so it
    // carries no feedback id.
    @Test("A short transcript fills its viewport so following never pushes it down")
    func shortTranscriptFillsViewport() throws {
        // The reported screen: 431.55 pt of rows in a 541.7 pt viewport.
        let reported = try #require(OpenCodeTranscriptLayout.minimumContentHeight(viewportHeight: 541.7))
        #expect(reported == 541.7)
        #expect(reported > 431.55)
        // Until the viewport has been measured there is nothing to fill.
        #expect(OpenCodeTranscriptLayout.minimumContentHeight(viewportHeight: .infinity) == nil)
        #expect(OpenCodeTranscriptLayout.minimumContentHeight(viewportHeight: 0) == nil)
    }

    @Test(
        "A reply with nothing to show yet takes no transcript row",
        .bug(id: "ASC-AAqE8eljRs3pWq5_qSfEZ0I"),
        .bug(id: "ASC-AL-iOayl1hthD-usBql8OKE")
    )
    func emptyMessagesTakeNoRow() throws {
        var reducer = OpenCodeTranscriptReducer()
        var sent = 0
        func send(_ type: String, _ fields: String) throws {
            sent += 1
            let raw = #"{"id":"e\#(sent)","type":"session.next.\#(type)","data":{"sessionID":"s","timestamp":\#(sent),\#(fields)}}"#
            #expect(reducer.applyV2(try JSONDecoder().decode(OpenCodeEvent.self, from: Data(raw.utf8))) == .changed)
        }
        func rows() -> [String] { OpenCodeShellTranscript.rows(for: reducer.messages).map(\.id) }
        let model = #""agent":"build","model":{"id":"m","providerID":"p"}"#

        try send("step.started", #""assistantMessageID":"msg_a",\#(model)"#)
        try send("text.started", #""assistantMessageID":"msg_a","textID":"t""#)
        #expect(reducer.messages.map(\.id) == ["msg_a"])
        #expect(rows().isEmpty)
        try send("text.delta", #""assistantMessageID":"msg_a","textID":"t","delta":"Cloning""#)
        #expect(rows() == ["msg_a"])

        // The reported session: a prompt, three settled steps, and a fourth
        // that has only started.
        reducer = OpenCodeTranscriptReducer()
        try send("prompted", #""messageID":"msg_u","prompt":{"text":"Git clone the repo"}"#)
        for step in 1...3 {
            let message = #""assistantMessageID":"msg_\#(step)""#
            try send("step.started", "\(message),\(model)")
            try send("tool.called", #"\#(message),"callID":"call_\#(step)","name":"read","input":{"filePath":"/dev"}"#)
            try send("tool.success", #"\#(message),"callID":"call_\#(step)","content":[{"type":"text","text":"byot/"}]"#)
            try send("step.ended", #"\#(message),"finish":"tool-calls","tokens":{"input":8500,"output":20,"reasoning":0,"cache":{"read":0,"write":0}}"#)
        }
        try send("step.started", #""assistantMessageID":"msg_4",\#(model)"#)
        #expect(reducer.messages.count == 5)
        #expect(rows() == ["msg_u", "msg_1", "msg_2", "msg_3"])
        try send("tool.called", #""assistantMessageID":"msg_4","callID":"call_4","name":"read","input":{"filePath":"/dev/byot"}"#)
        #expect(rows() == ["msg_u", "msg_1", "msg_2", "msg_3", "msg_4"])

        // v1 opens each step with a part that draws nothing.
        func reply(_ id: String, parts: [OpenCodePart] = [], error: OpenCodeMessageError? = nil,
                   tokens: OpenCodeTokenUsage? = nil) -> OpenCodeMessageEnvelope {
            OpenCodeMessageEnvelope(
                info: OpenCodeMessageInfo(id: id, sessionID: "s", role: "assistant",
                                          time: OpenCodeMessageTime(created: 1, completed: nil), agent: nil, modelID: nil,
                                          providerID: nil, finish: nil, error: error, tokens: tokens),
                parts: parts)
        }
        #expect(OpenCodeShellTranscript.rows(for: [reply("m1", parts: [make("s1", "step-start"), make("t1", "text", text: "")])]).isEmpty)
        let failed = reply("m2", error: OpenCodeMessageError(name: "APIError", data: ["message": .string("Overloaded")]))
        #expect(OpenCodeShellTranscript.rows(for: [failed]) == [.message(failed)])
        let counted = reply("m3", tokens: OpenCodeTokenUsage(input: 10, output: 5, reasoning: 0, cacheRead: 0, cacheWrite: 0))
        #expect(OpenCodeShellTranscript.rows(for: [counted]) == [.message(counted)])
    }

    // MARK: Presentations

    @Test("Compaction explains why context was summarized")
    func compaction() {
        var part = make("c", "compaction")
        #expect(OpenCodeCompactionPresentation(part: part).detail == nil)
        part.auto = false
        #expect(OpenCodeCompactionPresentation(part: part).detail == "Requested")
        part.auto = true
        #expect(OpenCodeCompactionPresentation(part: part).detail == "Automatic")
        part.overflow = true
        let presentation = OpenCodeCompactionPresentation(part: part)
        #expect(presentation.title == "Context compacted")
        #expect(presentation.detail == "Automatic · context limit reached")
        #expect(presentation.accessibilityLabel.contains("context limit"))
    }

    @Test("Retry notices name the attempt, status and readable provider message")
    func retry() {
        var part = make("r", "retry")
        part.attempt = 2
        part.error = OpenCodeMessageError(name: "APIError", data: [
            "message": .string("Too many requests"), "statusCode": .number(429), "isRetryable": .bool(true),
        ])
        let presentation = OpenCodeRetryPresentation(part: part)
        #expect(presentation.title == "Retried after an error · attempt 2")
        #expect(presentation.detail == "HTTP 429 · Too many requests")
        #expect(presentation.accessibilityLabel == "Retried after an error, attempt 2. HTTP 429 · Too many requests")
    }

    @Test("Agent parts read as a mention in a prompt and a switch elsewhere")
    func switches() throws {
        var agent = make("a", "agent")
        agent.name = "plan"
        let mention = try #require(OpenCodeSwitchPresentation(part: agent, inPrompt: true))
        #expect(mention.title == "plan")
        #expect(mention.accessibilityLabel == "Sent to the plan agent")
        #expect(OpenCodeSwitchPresentation(part: agent, inPrompt: false)?.title == "Switched to plan")
        var model = make("m", "model")
        model.name = "claude-sonnet"
        #expect(OpenCodeSwitchPresentation(part: model, inPrompt: false)?.accessibilityLabel == "Switched to model claude-sonnet")
        #expect(OpenCodeSwitchPresentation(part: make("x", "agent"), inPrompt: false) == nil)
    }

    @Test("Step summaries show compact tokens and cost, with the full breakdown")
    func stepSummary() throws {
        var part = make("s", "step-finish")
        part.reason = "tool-calls"
        part.cost = 0.0042
        part.tokens = OpenCodeTokenUsage(input: 4020, output: 21, reasoning: 15, cacheRead: 0, cacheWrite: 0)
        let summary = try #require(OpenCodeStepSummary(part: part, locale: enUS))
        #expect(summary.title == "Step · 4.1K tokens · $0.0042")
        #expect(summary.outcome == nil)
        #expect(summary.details.map(\.label) == ["Input", "Output", "Reasoning", "Cost"])
        #expect(summary.details.map(\.value) == ["4,020", "21", "15", "$0.0042"])
        #expect(summary.accessibilityLabel == "Step used 4,056 tokens, cost $0.0042")
    }

    @Test("Unusual finishes are called out and free steps omit cost")
    func stepOutcome() throws {
        var part = make("s", "step-finish")
        part.reason = "length"
        part.cost = 0
        part.tokens = OpenCodeTokenUsage(input: 186, output: 10, reasoning: 0, cacheRead: 3968, cacheWrite: 0)
        let summary = try #require(OpenCodeStepSummary(part: part, locale: enUS))
        #expect(summary.title == "Step · 4.2K tokens")
        #expect(summary.outcome == "Stopped at the output limit")
        #expect(summary.details.map(\.label) == ["Input", "Output", "Cache read", "Finish"])
        #expect(OpenCodeStepSummary.outcome("content-filter") == "Stopped by the content filter")
        #expect(OpenCodeStepSummary.outcome("stop") == nil)
        #expect(OpenCodeStepSummary.outcome("provider_timeout") == "Provider timeout")
        #expect(OpenCodeStepSummary.cost(1.5, locale: enUS) == "$1.50")
        #expect(OpenCodeStepSummary.compact(999, locale: enUS) == "999")
    }

    @Test("Empty step accounting renders nothing")
    func emptyStep() {
        var part = make("s", "step-finish")
        #expect(OpenCodeStepSummary(part: part) == nil)
        part.tokens = OpenCodeTokenUsage(input: 0, output: 0)
        part.cost = 0
        #expect(OpenCodeStepSummary(part: part) == nil)
        #expect(!OpenCodeTranscriptLayout.isVisible(part))
    }

    @Test("Snapshots show a short checkpoint hash")
    func snapshot() {
        var part = make("s", "snapshot")
        #expect(OpenCodeSnapshotPresentation(part: part) == nil)
        part.snapshot = "444a8fa98e219b9ee8585973bba9425676aba452"
        #expect(OpenCodeSnapshotPresentation(part: part)?.title == "Checkpoint · 444a8fa")
    }

    // MARK: Patches

    @Test("Patch files are shown relative to the project and matched to session diffs")
    func patchFiles() {
        let diffs = [
            OpenCodeDiff(file: "Sources/App.swift", patch: "", additions: 3, deletions: 1, status: "modified"),
            OpenCodeDiff(file: "README.md", patch: "", additions: 1, deletions: 0, status: "added"),
            OpenCodeDiff(file: "app/README.md", patch: "", additions: 1, deletions: 0, status: "added"),
        ]
        let files = OpenCodePatchFile.resolve(
            ["/repo/app/Sources/App.swift", "/repo/app/README.md", "/repo/app/Sources/App.swift", "/elsewhere/x.txt",
             "./notes/todo.md", "C:\\repo\\app\\README.md"],
            directory: "/repo/app/", diffs: diffs)
        // A path outside the session directory shows the shorter diff path it matched.
        #expect(files.map(\.displayPath) == ["Sources/App.swift", "README.md", "/elsewhere/x.txt", "notes/todo.md", "app/README.md"])
        #expect(files.map(\.diffID) == ["Sources/App.swift", "README.md", nil, nil, "app/README.md"])
        #expect(files[0].filename == "App.swift")
        #expect(files[0].folder == "Sources")
        #expect(files[1].folder == nil)
    }

    @Test("Worktree files above the session directory show their worktree path")
    func patchFilesAboveDirectory() {
        let diffs = [OpenCodeDiff(file: "lib/Util.swift", patch: "", additions: 1, deletions: 1, status: "modified")]
        let files = OpenCodePatchFile.resolve(["/repo/lib/Util.swift"], directory: "/repo/app", diffs: diffs)
        #expect(files.map(\.displayPath) == ["lib/Util.swift"])
        #expect(files.map(\.diffID) == ["lib/Util.swift"])
    }

    // MARK: Images

    @Test("Data URLs decode base64 and percent-encoded payloads")
    func dataURLs() throws {
        let base64 = try #require(OpenCodeDataURL.decode("data:image/png;base64,aGVsbG8="))
        #expect(base64.mime == "image/png")
        #expect(base64.data == Data("hello".utf8))
        let plain = try #require(OpenCodeDataURL.decode("data:,a%20b"))
        #expect(plain.mime == "text/plain")
        #expect(plain.data == Data("a b".utf8))
        #expect(OpenCodeDataURL.decode("data:image/png;base64,") == nil)
        #expect(OpenCodeDataURL.decode("file:///a.png") == nil)
    }

    @Test("Server image references resolve inside the session's project only")
    func serverImages() {
        let scope = OpenCodeRemoteFileScope(serverID: UUID(), serverName: "Mac", projectID: "p", directory: "/repo", workspaceID: nil)
        let inside = make("a", "file", mime: "image/png", url: "file:///repo/assets/shot%201.png")
        #expect(OpenCodeInlineImage.resolve(inside, scope: scope) == .serverFile(path: "assets/shot 1.png"))
        #expect(OpenCodeInlineImage.resolve(inside, scope: nil) == nil)
        #expect(OpenCodeInlineImage.resolve(make("b", "file", mime: "image/png", url: "file:///etc/a.png"), scope: scope) == nil)
        #expect(OpenCodeInlineImage.displayName(for: inside) == "shot 1.png")
        let inline = make("c", "file", mime: "image/png", url: "data:image/png;base64,aGVsbG8=")
        #expect(OpenCodeInlineImage.resolve(inline, scope: nil) == .data(Data("hello".utf8)))
    }

    @Test("Images decode downsampled to the requested size")
    func downsample() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        let png = renderer.pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let image = try #require(OpenCodeInlineImageLoader.decode(png, maxPixelSize: 100))
        #expect(max(image.width, image.height) == 100)
        #expect(image.width == 2 * image.height)
        #expect(OpenCodeInlineImageLoader.decode(Data("not an image".utf8), maxPixelSize: 100) == nil)
    }

    // MARK: v2

    @Test("v2 assistant messages carry step accounting and changed files as parts")
    func v2StepParts() throws {
        let object = try json(#"""
            {"id":"msg_a","type":"assistant","agent":"build","model":{"id":"m","providerID":"p"},
             "content":[{"type":"text","id":"t","text":"Done"}],
             "snapshot":{"start":"a","end":"b","files":["Sources/App.swift"]},
             "finish":"stop","cost":0.5,"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}},
             "time":{"created":1,"completed":2}}
            """#)
        let message = try #require(OpenCodeV2Normalization.message(object, sessionID: "s"))
        #expect(message.parts.map(\.type) == ["text", "step-finish", "patch"])
        #expect(message.parts[1].tokens?.total == 15)
        #expect(message.parts[1].cost == 0.5)
        #expect(message.parts[1].reason == "stop")
        #expect(message.parts[2].files == ["Sources/App.swift"])
    }

    @Test("step.ended adds the same parts live, and content snapshots keep them")
    func v2LiveStepParts() throws {
        var reducer = OpenCodeTranscriptReducer()
        func send(_ id: Int, _ type: String, _ fields: String) throws -> OpenCodeV2EventReducer.Outcome {
            let raw = #"{"id":"e\#(id)","type":"session.next.\#(type)","data":{"sessionID":"s","timestamp":\#(id),"assistantMessageID":"msg_a",\#(fields)}}"#
            return reducer.applyV2(try JSONDecoder().decode(OpenCodeEvent.self, from: Data(raw.utf8)))
        }
        #expect(try send(1, "step.started", #""agent":"build","model":{"id":"m","providerID":"p"}"#) == .changed)
        #expect(try send(2, "text.started", #""textID":"t""#) == .changed)
        #expect(try send(3, "text.ended", #""textID":"t","text":"Done""#) == .changed)
        #expect(try send(4, "step.ended", #""finish":"stop","cost":0.5,"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}},"files":["Sources/App.swift"]"#) == .changed)
        let projection = try #require(OpenCodeV2Normalization.message(try json(#"""
            {"id":"msg_a","type":"assistant","agent":"build","model":{"id":"m","providerID":"p"},
             "content":[{"type":"text","id":"t","text":"Done"}],"snapshot":{"files":["Sources/App.swift"]},
             "finish":"stop","cost":0.5,"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}},
             "time":{"created":1,"completed":4}}
            """#), sessionID: "s"))
        #expect(reducer.messages == [projection])
        #expect(try send(5, "step.ended", #""finish":"stop","cost":0.5,"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}},"files":["Sources/App.swift"]"#) == .changed)
        #expect(reducer.messages.first?.parts.filter { $0.type == "patch" }.count == 1)
        let content = #"{"id":"e6","type":"session.message.content.updated","created":6,"data":{"sessionID":"s","messageID":"msg_a","content":[{"type":"text","text":"Done!"}]}}"#
        #expect(reducer.applyV2(try JSONDecoder().decode(OpenCodeEvent.self, from: Data(content.utf8))) == .changed)
        #expect(reducer.messages.first?.parts.map(\.type) == ["text", "step-finish", "patch"])
        #expect(reducer.messages.first?.parts.first?.text == "Done!")
    }

    @Test("v2 compaction and switch messages become compaction, agent and model parts")
    func v2Markers() throws {
        let compaction = try #require(OpenCodeV2Normalization.message(try json(
            #"{"id":"m1","type":"compaction","reason":"auto","summary":"We fixed the build.","recent":"","time":{"created":1}}"#),
            sessionID: "s"))
        #expect(compaction.info.role == "system")
        #expect(compaction.parts.map(\.type) == ["compaction"])
        #expect(compaction.parts.first?.auto == true)
        #expect(OpenCodeCompactionPresentation(part: try #require(compaction.parts.first)).summary == "We fixed the build.")

        let agent = try #require(OpenCodeV2Normalization.message(try json(
            #"{"id":"m2","type":"agent-switched","agent":"plan","time":{"created":2}}"#), sessionID: "s"))
        #expect(agent.parts.map(\.type) == ["agent"])
        #expect(agent.parts.first?.name == "plan")

        let model = try #require(OpenCodeV2Normalization.message(try json(
            #"{"id":"m3","type":"model-switched","model":{"id":"gpt-5","providerID":"openai"},"time":{"created":3}}"#),
            sessionID: "s"))
        #expect(model.parts.map(\.type) == ["model"])
        #expect(model.parts.first?.name == "gpt-5")
    }

    @Test("v2 prompt agent mentions become agent parts, from the projection and live")
    func v2AgentMentions() throws {
        let user = try #require(OpenCodeV2Normalization.message(try json(
            #"{"id":"m1","type":"user","text":"@explore look","agents":[{"name":"explore"},{"name":""}],"time":{"created":1}}"#),
            sessionID: "s"))
        #expect(user.parts.map(\.type) == ["text", "agent"])
        #expect(user.parts.last?.name == "explore")
        #expect(OpenCodeSwitchPresentation(part: try #require(user.parts.last), inPrompt: true)?.title == "explore")

        var reducer = OpenCodeTranscriptReducer()
        let raw = #"{"id":"e1","type":"session.next.prompted","data":{"sessionID":"s","timestamp":1,"messageID":"m1","prompt":{"text":"@explore look","agents":[{"name":"explore"}]}}}"#
        #expect(reducer.applyV2(try JSONDecoder().decode(OpenCodeEvent.self, from: Data(raw.utf8))) == .changed)
        #expect(reducer.messages.first?.parts.map(\.type) == ["text", "agent"])
        #expect(reducer.messages.first?.parts.last?.name == "explore")
    }

    // MARK: Synthetic context

    @Test("Prompts hide the synthetic text OpenCode adds for attachments and keep what the user wrote")
    func promptsHideSyntheticText() throws {
        let typed = try part(#""type":"text","text":"Summarize this file""#, id: "p1")
        let read = try part(#""type":"text","synthetic":true,"text":"Called the Read tool with the following input: {\"filePath\":\"notes.txt\"}""#, id: "p2")
        let contents = try part(#""type":"text","synthetic":true,"text":"1: hello""#, id: "p3")
        let ignored = try part(#""type":"text","ignored":true,"text":"/compact""#, id: "p4")
        let file = make("p5", "file", mime: "text/plain", url: "file:///repo/notes.txt")
        #expect(read.synthetic == true)
        #expect(ignored.ignored == true)
        #expect(typed.synthetic == nil)

        let prompt = OpenCodeTranscriptLayout.items(for: [typed, read, contents, ignored, file], inPrompt: true)
        #expect(prompt.map(\.id) == ["p1", "p4", "p5"])

        // Only authored text is restored into the composer or resent.
        #expect([typed, read, contents, ignored, file].filter(\.isAuthoredText).map(\.id) == ["p1"])
    }

    @Test("Synthetic text outside a prompt is collapsed context, not agent prose")
    func syntheticContextOutsidePrompt() throws {
        let note = try part(#""type":"text","synthetic":true,"text":"<env>\ncwd: /repo\n</env>""#)
        #expect(OpenCodeTranscriptLayout.items(for: [note]).count == 1)
        let context = try #require(OpenCodeSyntheticContextPresentation(part: note))
        #expect(context.title == "Added context")
        #expect(context.text == "<env>\ncwd: /repo\n</env>")
        #expect(context.accessibilityLabel == "Context OpenCode added for the model, 3 lines")

        #expect(OpenCodeSyntheticContextPresentation(part: make("t", "text", text: "Plain reply")) == nil)
        let blank = try part(#""type":"text","synthetic":true,"text":"  \n ""#)
        #expect(OpenCodeTranscriptLayout.items(for: [blank]).isEmpty)

        let long = try part(#""type":"text","synthetic":true,"text":"\#(String(repeating: "x", count: 5_000))""#)
        let clipped = try #require(OpenCodeSyntheticContextPresentation(part: long))
        #expect(clipped.text.count == OpenCodeSyntheticContextPresentation.characterLimit + 2)
        #expect(clipped.text.hasSuffix("\n…"))
    }

    @Test("v2 system and synthetic messages become synthetic context; prompts stay authored")
    func v2SyntheticMessages() throws {
        for type in ["system", "synthetic"] {
            let message = try #require(OpenCodeV2Normalization.message(try json(
                #"{"id":"m1","type":"\#(type)","text":"Today is Monday.","time":{"created":1}}"#), sessionID: "s"))
            #expect(message.parts.map(\.type) == ["text"])
            #expect(message.parts.first?.synthetic == true)
            #expect(message.parts.first?.isAuthoredText == false)
            #expect(message.isSyntheticContext)
        }
        let user = try #require(OpenCodeV2Normalization.message(try json(
            #"{"id":"m2","type":"user","text":"Hello","time":{"created":2}}"#), sessionID: "s"))
        #expect(user.parts.first?.synthetic == nil)
        #expect(user.parts.first?.isAuthoredText == true)
        #expect(!user.isSyntheticContext)

        var reducer = OpenCodeTranscriptReducer()
        let raw = #"{"id":"e1","type":"session.next.context.updated","data":{"sessionID":"s","timestamp":1,"messageID":"m3","text":"Date changed."}}"#
        #expect(reducer.applyV2(try JSONDecoder().decode(OpenCodeEvent.self, from: Data(raw.utf8))) == .changed)
        #expect(reducer.messages.first?.parts.first?.synthetic == true)
    }

    @Test("Context OpenCode adds after a prompt does not count as the reply starting")
    @MainActor
    func syntheticContextIsNotActivity() throws {
        let user = OpenCodeMessageEnvelope(
            info: OpenCodeMessageInfo(id: "m1", sessionID: "s", role: "user", time: OpenCodeMessageTime(created: 1, completed: nil),
                                      agent: nil, modelID: nil, providerID: nil, finish: nil, error: nil),
            parts: [make("u", "text", text: "Go")])
        let system = try #require(OpenCodeV2Normalization.message(try json(
            #"{"id":"m2","type":"system","text":"Date changed.","time":{"created":2}}"#), sessionID: "s"))
        #expect(OpenCodeSessionStore.hasVisibleAssistantActivityAfterLatestUserMessage(in: [user, system]) == false)
        #expect(OpenCodeSessionStore.visibleAssistantActivityIDs(in: [user, system]).isEmpty)
    }

    // MARK: Helpers

    private func part(_ fields: String, id: String = "p") throws -> OpenCodePart {
        let raw = #"{"id":"\#(id)","sessionID":"s","messageID":"m",\#(fields)}"#
        return try JSONDecoder().decode(OpenCodePart.self, from: Data(raw.utf8))
    }

    private func json(_ raw: String) throws -> [String: OpenCodeJSONValue] {
        try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: Data(raw.utf8))
    }

    private func make(_ id: String, _ type: String, text: String? = nil, mime: String? = nil, url: String? = nil) -> OpenCodePart {
        OpenCodePart(id: id, sessionID: "s", messageID: "m", type: type, text: text, mime: mime, filename: nil,
                     url: url, callID: nil, tool: nil, state: nil, files: nil, description: nil, agent: nil)
    }
}
