import Foundation
import Testing
@testable import byot

// Accounting shapes from packages/schema/src/v1/session.ts (AssistantMessage,
// StepFinishPart), packages/schema/src/session-message.ts (v2 assistant) and
// packages/schema/src/model.ts (`limit.context`).
@Suite("Context window and session usage")
struct OpenCodeSessionUsageTests {
    private let enUS = Locale(identifier: "en_US")

    // MARK: Decoding

    @Test("v1 assistant messages decode cost, tokens and the compaction summary flag")
    func decodesV1MessageAccounting() throws {
        let assistant = try info(#"{"id":"m","sessionID":"s","role":"assistant","time":{"created":1},"modelID":"sonnet","providerID":"anthropic","mode":"build","cost":0.25,"summary":true,"tokens":{"input":900,"output":100,"reasoning":0,"cache":{"read":4000,"write":10}}}"#)
        #expect(assistant.cost == 0.25)
        #expect(assistant.tokens == OpenCodeTokenUsage(input: 900, output: 100, cacheRead: 4000, cacheWrite: 10))
        #expect(assistant.summary == true)

        // User messages reuse `summary` for an object; it must not break decoding.
        let user = try info(#"{"id":"u","sessionID":"s","role":"user","time":{"created":1},"summary":{"title":"Fix","diffs":[]},"model":{"providerID":"anthropic","modelID":"sonnet"}}"#)
        #expect(user.summary == nil)
        #expect(user.cost == nil)
        #expect(user.modelID == "sonnet")

        let odd = try info(#"{"id":"x","sessionID":"s","role":"assistant","time":{"created":1},"cost":"free","tokens":7}"#)
        #expect(odd.cost == nil)
        #expect(odd.tokens == nil)
    }

    @Test("v2 assistant snapshots and step.ended carry accounting onto the message")
    func v2MessageAccounting() throws {
        let object = try json(#"{"id":"msg_a","type":"assistant","agent":"build","model":{"id":"m","providerID":"p"},"content":[],"finish":"stop","cost":0.5,"tokens":{"input":10,"output":5,"reasoning":1,"cache":{"read":2,"write":0}},"time":{"created":1,"completed":2}}"#)
        let message = try #require(OpenCodeV2Normalization.message(object, sessionID: "ses"))
        #expect(message.info.cost == 0.5)
        #expect(message.info.tokens?.contextTokens == 18)

        var reducer = OpenCodeTranscriptReducer()
        #expect(reducer.apply(try v2Event("session.next.step.started", 1, #""assistantMessageID":"msg_b","agent":"build","model":{"id":"m","providerID":"p"}"#)))
        #expect(reducer.apply(try v2Event("session.next.step.ended", 2, #""assistantMessageID":"msg_b","finish":"stop","cost":0.02,"tokens":{"input":100,"output":20,"reasoning":0,"cache":{"read":0,"write":0}}"#)))
        let ended = try #require(reducer.messages.first)
        #expect(ended.info.cost == 0.02)
        #expect(ended.info.tokens?.contextTokens == 120)
        #expect(ended.info.modelID == "m")
    }

    @Test("Both model catalogs report the context window; zero means unknown")
    func catalogContextLimits() throws {
        let raw = #"{"all":[{"id":"anthropic","name":"Anthropic","models":{"sonnet":{"id":"sonnet","name":"Sonnet","limit":{"context":200000,"output":64000}},"local":{"id":"local","name":"Local","limit":{"context":0,"output":0}},"bare":{"id":"bare","name":"Bare"}}}],"connected":["anthropic"],"default":{}}"#
        let catalog = try JSONDecoder().decode(OpenCodeProviderCatalog.self, from: Data(raw.utf8))
        let models = Dictionary(uniqueKeysWithValues: catalog.connectedProviders.flatMap(\.models).map { ($0.modelID, $0) })
        #expect(models["sonnet"]?.contextLimit == 200_000)
        #expect(models["local"]?.contextLimit == nil)
        #expect(models["bare"]?.contextLimit == nil)
        #expect(OpenCodeModelOption.contextLimit(try json(#"{"limit":{"context":"big"}}"#)) == nil)
    }

    // MARK: Replies

    @Test("A reply sums its steps' spend and keeps the last step's context")
    func replyUsage() throws {
        var first = step("s1", cost: 0.01, tokens: OpenCodeTokenUsage(input: 1_000, output: 50, cacheRead: 500))
        first.reason = "tool-calls"
        let last = step("s2", cost: 0.02, tokens: OpenCodeTokenUsage(input: 1_200, output: 80, reasoning: 20, cacheRead: 1_500))
        let usage = try #require(OpenCodeReplyUsage(assistant("m", parts: [first, last])))
        #expect(abs(usage.cost - 0.03) < 1e-12)
        #expect(usage.tokens == OpenCodeTokenUsage(input: 2_200, output: 130, reasoning: 20, cacheRead: 2_000))
        #expect(usage.context?.contextTokens == 2_800)
    }

    @Test("Message accounting fills in when a reply has no step parts, and the larger cost wins")
    func replyFallsBackToMessage() throws {
        let tokens = OpenCodeTokenUsage(input: 300, output: 40)
        let bare = try #require(OpenCodeReplyUsage(assistant("m", cost: 0.4, tokens: tokens)))
        #expect(bare.cost == 0.4)
        #expect(bare.context == tokens)
        #expect(bare.tokens == tokens)

        // A step can arrive before the message's own summed cost catches up.
        let lagging = try #require(OpenCodeReplyUsage(assistant("m", cost: 0.01, parts: [step("s", cost: 0.05, tokens: tokens)])))
        #expect(lagging.cost == 0.05)

        #expect(OpenCodeReplyUsage(assistant("m")) == nil)
        #expect(OpenCodeReplyUsage(user("u")) == nil)
        #expect(OpenCodeReplyUsage(assistant("m", parts: [step("s", cost: 0, tokens: .zero)])) == nil)
    }

    @Test("Token usage adds part by part and keeps a reported total only when one was given")
    func tokenAddition() {
        let a = OpenCodeTokenUsage(input: 1, output: 2, reasoning: 3, cacheRead: 4, cacheWrite: 5)
        let b = OpenCodeTokenUsage(input: 10, output: 20, reportedTotal: 50)
        #expect((a + .zero).reportedTotal == nil)
        #expect((a + .zero).total == 15)
        #expect((a + b).input == 11)
        #expect((a + b).cacheWrite == 5)
        #expect((a + b).total == 65)
        #expect((a + b).contextTokens == 45)
    }

    // MARK: Session

    @Test("Context is the latest reply against its model's window; spend covers every reply")
    func sessionUsage() throws {
        let messages = [
            user("u1"),
            assistant("a1", model: "sonnet", parts: [step("s1", cost: 0.10, tokens: OpenCodeTokenUsage(input: 40_000, output: 2_000))]),
            user("u2"),
            assistant("a2", model: "sonnet", parts: [step("s2", cost: 0.05, tokens: OpenCodeTokenUsage(input: 5_000, output: 1_000, cacheRead: 44_000))]),
            assistant("a3", model: "sonnet", parts: [text("t", "Done")]),
        ]
        let usage = OpenCodeSessionUsage(messages: messages, models: [model("sonnet", limit: 200_000)])
        #expect(usage.hasUsage)
        #expect(usage.replies == 2)
        #expect(abs(usage.cost - 0.15) < 1e-12)
        #expect(usage.tokens.total == 92_000)
        #expect(usage.activeMessages == 5)
        #expect(!usage.isCompacted)
        let context = try #require(usage.context)
        #expect(context.messageID == "a2")
        #expect(context.used == 50_000)
        #expect(context.limit == 200_000)
        #expect(context.percent == 25)
        #expect(context.level == .normal)
        #expect(context.modelLabel == "Sonnet")
    }

    @Test("A reply from a model the catalog does not list still reports its tokens")
    func unknownModel() throws {
        let messages = [assistant("a", model: "mystery", parts: [step("s", cost: 0, tokens: OpenCodeTokenUsage(input: 900, output: 100))])]
        let context = try #require(OpenCodeSessionUsage(messages: messages, models: [model("sonnet", limit: 200_000)]).context)
        #expect(context.limit == nil)
        #expect(context.percent == nil)
        #expect(context.fraction == nil)
        #expect(context.level == .normal)
        #expect(context.modelLabel == "mystery")
    }

    @Test("Warning levels start at 70 and 90 percent, and a sliver of use is not 0%")
    func levels() {
        func context(_ used: Double) -> OpenCodeContextUsage {
            OpenCodeContextUsage(messageID: "m", tokens: OpenCodeTokenUsage(input: used, output: 0),
                                 providerID: "p", modelID: "m", modelName: nil, limit: 1_000)
        }
        #expect(context(699).level == .normal)
        #expect(context(700).level == .high)
        #expect(context(900).level == .critical)
        #expect(context(1_200).percent == 120)
        #expect(context(2).percent == 1)
        #expect(context(0).percent == 0)
    }

    @Test("Compaction resets the context until the next reply; the summary reply never counts as context")
    func compaction() throws {
        let models = [model("sonnet", limit: 100_000)]
        let compactionPart = OpenCodePart(id: "c", sessionID: "s", messageID: "u2", type: "compaction", text: nil, mime: nil,
                                      filename: nil, url: nil, callID: nil, tool: nil, state: nil, files: nil,
                                      description: nil, agent: nil)
        var summary = assistant("sum", model: "sonnet", parts: [step("s2", cost: 0.02, tokens: OpenCodeTokenUsage(input: 95_000, output: 3_000))])
        summary.info.summary = true
        let before = [
            user("u1"),
            assistant("a1", model: "sonnet", parts: [step("s1", cost: 0.3, tokens: OpenCodeTokenUsage(input: 90_000, output: 1_000))]),
            OpenCodeMessageEnvelope(info: user("u2").info, parts: [compactionPart]),
            summary,
        ]
        let compacted = OpenCodeSessionUsage(messages: before, models: models)
        #expect(compacted.isCompacted)
        #expect(compacted.context == nil)
        #expect(compacted.replies == 2)
        #expect(abs(compacted.cost - 0.32) < 1e-12)
        #expect(compacted.activeMessages == 0)

        let after = before + [user("u3"), assistant("a2", model: "sonnet", parts: [step("s3", cost: 0.01, tokens: OpenCodeTokenUsage(input: 6_000, output: 500))])]
        let resumed = OpenCodeSessionUsage(messages: after, models: models)
        #expect(!resumed.isCompacted)
        #expect(resumed.context?.messageID == "a2")
        #expect(resumed.context?.percent == 7)
        #expect(resumed.activeMessages == 2)

        // v2 marks compaction with its own system message.
        let v2 = OpenCodeV2Normalization.message(try json(#"{"id":"cmp","type":"compaction","reason":"auto","summary":"Earlier work","recent":"","time":{"created":9}}"#), sessionID: "s")
        let v2Usage = OpenCodeSessionUsage(messages: Array(before.prefix(2)) + [try #require(v2)], models: models)
        #expect(v2Usage.isCompacted)
    }

    @Test("A v1 compaction counts only once its summary finishes, and keeps its retained tail in context")
    func v1CompactionRules() throws {
        let models = [model("sonnet", limit: 100_000)]
        let marker = try JSONDecoder().decode(OpenCodePart.self, from: Data(
            #"{"id":"c","sessionID":"s","messageID":"u3","type":"compaction","auto":true,"tail_start_id":"u2"}"#.utf8))
        #expect(marker.tailStartID == "u2")
        func summary(finish: String?, error: OpenCodeMessageError? = nil) -> OpenCodeMessageEnvelope {
            var info = OpenCodeMessageInfo(id: "sum", sessionID: "s", role: "assistant",
                                           time: OpenCodeMessageTime(created: 2, completed: nil), agent: "compaction",
                                           modelID: "sonnet", providerID: "anthropic", finish: finish, error: error)
            info.summary = true
            return OpenCodeMessageEnvelope(info: info, parts: [])
        }
        let history = [
            user("u1"),
            assistant("a1", model: "sonnet", parts: [step("s1", cost: 0.1, tokens: OpenCodeTokenUsage(input: 40_000, output: 1_000))]),
            user("u2"),
            assistant("a2", model: "sonnet", parts: [step("s2", cost: 0.1, tokens: OpenCodeTokenUsage(input: 80_000, output: 1_000))]),
            OpenCodeMessageEnvelope(info: user("u3").info, parts: [marker]),
        ]

        // Still summarizing, or the summary failed: the old context stands.
        for pending in [summary(finish: nil), summary(finish: "error", error: OpenCodeMessageError(name: "APIError", data: nil))] {
            let usage = OpenCodeSessionUsage(messages: history + [pending], models: models)
            #expect(!usage.isCompacted)
            #expect(usage.context?.messageID == "a2")
            #expect(usage.activeMessages == 5)
        }

        // Done: the summary replaces everything before the retained tail (u2, a2).
        let done = OpenCodeSessionUsage(messages: history + [summary(finish: "stop"), user("u4")], models: models)
        #expect(done.isCompacted)
        #expect(done.activeMessages == 3)
    }

    @Test("The server's stored session totals cover history older than the loaded transcript")
    func storedSessionTotals() throws {
        let v1 = try JSONDecoder().decode(OpenCodeSession.self, from: Data(
            #"{"id":"s","slug":"s","projectID":"p","directory":"/r","title":"T","version":"1","time":{"created":1,"updated":2},"cost":4.5,"tokens":{"input":900000,"output":20000,"reasoning":0,"cache":{"read":0,"write":0}}}"#.utf8))
        #expect(v1.cost == 4.5)
        #expect(v1.tokens?.total == 920_000)
        let odd = try JSONDecoder().decode(OpenCodeSession.self, from: Data(
            #"{"id":"s","slug":"s","projectID":"p","directory":"/r","title":"T","version":"1","time":{"created":1,"updated":2},"cost":"n/a","tokens":3}"#.utf8))
        #expect(odd.cost == nil)
        #expect(odd.tokens == nil)
        let v2 = try #require(OpenCodeV2Normalization.session(try json(
            #"{"id":"s","title":"T","cost":1.5,"tokens":{"input":10,"output":5,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1,"updated":2}}"#)))
        #expect(v2.cost == 1.5)
        #expect(v2.tokens?.total == 15)

        // The loaded page shows one reply; the stored totals include older ones.
        let page = [assistant("a9", model: "sonnet", parts: [step("s9", cost: 0.5, tokens: OpenCodeTokenUsage(input: 10_000, output: 500))])]
        let long = OpenCodeSessionUsage(messages: page, models: [], session: v1)
        #expect(long.cost == 4.5)
        #expect(long.tokens.total == 920_000)
        // A reply streamed since the session was stored runs ahead of it.
        var stale = v1
        stale.cost = 0.2
        stale.tokens = OpenCodeTokenUsage(input: 100, output: 0)
        let live = OpenCodeSessionUsage(messages: page, models: [], session: stale)
        #expect(live.cost == 0.5)
        #expect(live.tokens.total == 10_500)
    }

    @Test("The server's active context replaces the local message count")
    func reconciledCount() {
        let usage = OpenCodeSessionUsage(messages: [user("u1"), user("u2"), user("u3")], models: [])
        #expect(usage.activeMessages == 3)
        #expect(usage.reconciled(activeContext: [user("u3"), assistant("a")]).activeMessages == 2)
    }

    // MARK: Presentation

    @Test("The header meter shows percent, raw tokens, or compaction, and hides without usage")
    func meterPresentation() throws {
        let known = OpenCodeSessionUsage(messages: [assistant("a", model: "sonnet", parts: [step("s", cost: 0, tokens: OpenCodeTokenUsage(input: 150_000, output: 30_000))])],
                                         models: [model("sonnet", limit: 200_000)])
        let meter = try #require(OpenCodeContextMeterPresentation(usage: known, locale: enUS))
        #expect(meter.label == "90%")
        #expect(meter.fill == 0.9)
        #expect(meter.level == .critical)
        #expect(meter.accessibilityValue == "90 percent used, 180,000 of 200,000 tokens")

        let unknown = OpenCodeSessionUsage(messages: [assistant("a", model: "x", parts: [step("s", cost: 0, tokens: OpenCodeTokenUsage(input: 48_213, output: 0))])], models: [])
        let raw = try #require(OpenCodeContextMeterPresentation(usage: unknown, locale: enUS))
        #expect(raw.label == "48.2K")
        #expect(raw.fill == 0)
        #expect(raw.accessibilityValue == "48,213 tokens. The model's context size is unknown")

        let over = OpenCodeSessionUsage(messages: [assistant("a", model: "sonnet", parts: [step("s", cost: 0, tokens: OpenCodeTokenUsage(input: 300, output: 0))])],
                                        models: [model("sonnet", limit: 200)])
        #expect(OpenCodeContextMeterPresentation(usage: over, locale: enUS)?.fill == 1)
        #expect(OpenCodeContextMeterPresentation(usage: over, locale: enUS)?.label == "150%")

        #expect(OpenCodeContextMeterPresentation(usage: OpenCodeSessionUsage()) == nil)
        let costOnly = OpenCodeSessionUsage(messages: [assistant("a", cost: 0.1)], models: [])
        #expect(costOnly.hasUsage)
        #expect(OpenCodeContextMeterPresentation(usage: costOnly) == nil)
    }

    @Test("Usage breakdown always lists input and output and skips unused kinds")
    func breakdownRows() {
        let rows = OpenCodeUsageRow.breakdown(OpenCodeTokenUsage(input: 1_234, output: 0, cacheRead: 99), locale: enUS)
        #expect(rows.map(\.label) == ["Input", "Output", "Cache read"])
        #expect(rows.map(\.value) == ["1,234", "0", "99"])
        #expect(OpenCodeStepSummary.cost(0, locale: enUS) == "$0.00")
        #expect(OpenCodeStepSummary.cost(0.004, locale: enUS) == "$0.0040")
    }

    @Test("Step footers show their share of the model window")
    func stepContextShare() throws {
        let part = step("s", cost: 0, tokens: OpenCodeTokenUsage(input: 40_000, output: 2_000, cacheRead: 8_000))
        let summary = try #require(OpenCodeStepSummary(part: part, contextLimit: 200_000, locale: enUS))
        #expect(summary.details.map(\.label) == ["Input", "Output", "Cache read", "Context"])
        #expect(summary.details.last?.value == "25% of 200K")
        #expect(OpenCodeStepSummary(part: part, locale: enUS)?.details.contains { $0.label == "Context" } == false)
    }

    @Test("A reply without step parts gets a footer from its message accounting")
    func replyFooter() throws {
        let tokens = OpenCodeTokenUsage(input: 2_000, output: 100)
        let reply = try #require(OpenCodeStepSummary(reply: assistant("a", cost: 0.02, tokens: tokens), locale: enUS))
        #expect(reply.title == "Reply · 2.1K tokens · $0.02")
        #expect(reply.accessibilityLabel == "Reply used 2,100 tokens, cost $0.02")
        // Step footers already cover replies that have them.
        #expect(OpenCodeStepSummary(reply: assistant("a", cost: 0.02, tokens: tokens, parts: [step("s", cost: 0.02, tokens: tokens)])) == nil)
        #expect(OpenCodeStepSummary(reply: user("u")) == nil)
        #expect(OpenCodeStepSummary(reply: assistant("a")) == nil)
    }

    // MARK: Active context route

    @Test("v2 reads the active context only when the schema lists the route; v1 never probes it")
    func contextRoute() async throws {
        let transport = UsageTransport(body: #"{"data":[{"id":"msg_u","type":"user","text":"Hi","time":{"created":1}},{"id":"msg_a","type":"assistant","agent":"build","model":{"id":"m","providerID":"p"},"content":[{"type":"text","text":"Hello"}],"cost":0.1,"tokens":{"input":5,"output":1,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":2}}]}"#)
        let supported = usageService(transport, v2: true, routes: ["/api/session/{sessionID}/context"])
        #expect(supported.support.contextWindow)
        let window = try #require(try await supported.contextMessages("ses_one"))
        #expect(window.map(\.info.role) == ["user", "assistant"])
        #expect(window.last?.info.cost == 0.1)
        #expect(await transport.paths == ["/api/session/ses_one/context"])

        let legacyTransport = UsageTransport(body: "{}")
        let legacy = usageService(legacyTransport, v2: false, routes: [])
        #expect(!legacy.support.contextWindow)
        #expect(try await legacy.contextMessages("ses_one") == nil)
        let betaTransport = UsageTransport(body: "{}")
        #expect(try await usageService(betaTransport, v2: true, routes: []).contextMessages("ses_one") == nil)
        #expect(await legacyTransport.paths.isEmpty)
        #expect(await betaTransport.paths.isEmpty)
    }

    // MARK: Store

    @MainActor
    @Test("The store's usage follows streamed steps and the model catalog, and adopts a fresh server context")
    func storeUsage() async throws {
        let service = UsageStoreService()
        let store = OpenCodeSessionStore(
            service: service, serverID: UUID(),
            session: OpenCodeSession(id: "ses_live", slug: "ses_live", projectID: "project", workspaceID: nil,
                directory: "/repo", parentID: nil, summary: nil, title: "Live", agent: nil, version: "2",
                time: OpenCodeSessionTime(created: 1, updated: 1, compacting: nil, archived: nil)),
            directory: "/repo", defaults: UserDefaults(suiteName: "opencode-usage-\(UUID().uuidString)")!)
        await store.start()
        defer { store.stop() }
        for _ in 0..<200 where store.providerModels.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.modelContextLimits == ["p/m": 1_000])
        #expect(!store.usage.hasUsage)

        store.handle(try v2Event("session.next.step.started", 1, #""assistantMessageID":"msg_a","agent":"build","model":{"id":"m","providerID":"p"}"#))
        store.handle(try v2Event("session.next.step.ended", 2, #""assistantMessageID":"msg_a","finish":"stop","cost":0.25,"tokens":{"input":400,"output":50,"reasoning":0,"cache":{"read":0,"write":0}}"#))
        #expect(store.usage.context?.percent == 45)
        #expect(store.usage.cost == 0.25)
        #expect(store.usage.activeMessages == 1)

        await store.refreshSessionFeatures()
        await store.refreshContextWindow()
        #expect(store.usage.activeMessages == 3)
        #expect(await service.contextReads == 1)

        // A newer reply makes the server's snapshot stale until it is read again.
        store.handle(try v2Event("session.next.step.started", 3, #""assistantMessageID":"msg_b","agent":"build","model":{"id":"m","providerID":"p"}"#))
        #expect(store.usage.activeMessages == 2)
    }

    // MARK: Helpers

    private func info(_ raw: String) throws -> OpenCodeMessageInfo {
        try JSONDecoder().decode(OpenCodeMessageInfo.self, from: Data(raw.utf8))
    }

    private func json(_ raw: String) throws -> [String: OpenCodeJSONValue] {
        try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: Data(raw.utf8))
    }

    private func v2Event(_ type: String, _ sequence: Int, _ fields: String) throws -> OpenCodeEvent {
        let raw = #"{"id":"evt_\#(sequence)","type":"\#(type)","data":{"sessionID":"ses_live","timestamp":\#(sequence),\#(fields)}}"#
        return try JSONDecoder().decode(OpenCodeEvent.self, from: Data(raw.utf8))
    }

    private func model(_ id: String, limit: Int?) -> OpenCodeModelOption {
        OpenCodeModelOption(providerID: "anthropic", providerName: "Anthropic", modelID: id,
                            modelName: id.capitalized, status: nil, contextLimit: limit)
    }

    private func step(_ id: String, cost: Double, tokens: OpenCodeTokenUsage) -> OpenCodePart {
        var part = OpenCodePart(id: id, sessionID: "s", messageID: "m", type: "step-finish", text: nil, mime: nil,
                                filename: nil, url: nil, callID: nil, tool: nil, state: nil, files: nil,
                                description: nil, agent: nil)
        part.cost = cost
        part.tokens = tokens
        return part
    }

    private func text(_ id: String, _ value: String?) -> OpenCodePart {
        OpenCodePart(id: id, sessionID: "s", messageID: "m", type: "text", text: value, mime: nil, filename: nil,
                     url: nil, callID: nil, tool: nil, state: nil, files: nil, description: nil, agent: nil)
    }

    private func user(_ id: String) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessageInfo(id: id, sessionID: "s", role: "user", time: OpenCodeMessageTime(created: 1, completed: nil),
                                      agent: nil, modelID: nil, providerID: nil, finish: nil, error: nil),
            parts: [text(id + ":t", "Prompt")])
    }

    private func assistant(_ id: String, model: String? = nil, cost: Double? = nil, tokens: OpenCodeTokenUsage? = nil,
                           parts: [OpenCodePart] = []) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessageInfo(id: id, sessionID: "s", role: "assistant",
                                      time: OpenCodeMessageTime(created: 2, completed: 3), agent: "build",
                                      modelID: model, providerID: model == nil ? nil : "anthropic", finish: "stop",
                                      error: nil, cost: cost, tokens: tokens),
            parts: parts)
    }
}

private func usageService(_ transport: UsageTransport, v2: Bool, routes: [String]) -> OpenCodeSessionFeatureService {
    let schema: OpenCodeJSONValue = .object(["paths": .object(Dictionary(uniqueKeysWithValues: routes.map {
        ($0, OpenCodeJSONValue.object(["get": .object([:])]))
    }))])
    return OpenCodeSessionFeatureService(context: OpenCodeFeatureContext(
        serverProtocol: v2 ? .v2 : .v1, schema: schema, transport: transport,
        profile: OpenCodeServerProfile(name: "Test", baseURL: "https://usage.test", directory: "/project")))
}

private actor UsageTransport: OpenCodeHTTPTransport {
    let body: String
    var paths: [String] = []
    init(body: String) { self.body = body }
    nonisolated func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://usage.test/" + path.joined(separator: "/"))!)
        request.httpMethod = method
        return request
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        paths.append(request.url!.path)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                 headerFields: ["Content-Type": "application/json"])!)
    }
    nonisolated func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { _ in }
    }
}

private actor UsageStoreService: OpenCodeSessionServicing, OpenCodeSessionFeatureServicing {
    private(set) var contextReads = 0

    func sessionContextMessages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope]? {
        contextReads += 1
        func message(_ id: String, _ role: String) -> OpenCodeMessageEnvelope {
            OpenCodeMessageEnvelope(info: OpenCodeMessageInfo(id: id, sessionID: sessionID, role: role,
                time: OpenCodeMessageTime(created: 1, completed: nil), agent: nil, modelID: nil, providerID: nil,
                finish: nil, error: nil), parts: [])
        }
        return [message("msg_u1", "user"), message("msg_x", "assistant"), message("msg_a", "assistant")]
    }
    func sessionFeatureSupport() async throws -> OpenCodeSessionFeatureSupport { OpenCodeSessionFeatureSupport(contextWindow: true) }
    func sessionDetails(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSessionDetails {
        throw OpenCodeSessionFeatureError(message: "unused")
    }
    func renameSession(sessionID: String, directory: String, workspace: String?, title: String) async throws -> OpenCodeSessionDetails {
        throw OpenCodeSessionFeatureError(message: "unused")
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
        throw OpenCodeSessionFeatureError(message: "unused")
    }

    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v2 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] {
        [OpenCodeProviderModels(providerID: "p", providerName: "Provider", models: [
            OpenCodeModelOption(providerID: "p", providerName: "Provider", modelID: "m", modelName: "Model", status: nil,
                                contextLimit: 1_000),
            OpenCodeModelOption(providerID: "p", providerName: "Provider", modelID: "n", modelName: "No limit", status: nil),
        ])]
    }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] { [] }
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
