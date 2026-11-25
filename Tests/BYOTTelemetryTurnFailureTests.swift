import Foundation
import Testing
@testable import byot

/// OpenCode 2 sends `SessionError.Error` (`{type, message, status?,
/// response?, retryAfterMs?}`, packages/schema/src/session-error.ts upstream).
/// The types below are the ones upstream constructs.
@Suite("Usage data for failed turns")
struct BYOTTelemetryTurnFailureTests {
    private static func v2(_ type: String, status: Int? = nil, retryAfterMs: Int? = nil,
                           message: String = "Something broke for steven@example.com") -> OpenCodeMessageError {
        var data: [String: OpenCodeJSONValue] = [
            "type": .string(type), "message": .string(message),
            "response": .object(["body": .string("{\"error\":\"secret body\"}")]),
        ]
        if let status { data["status"] = .number(Double(status)) }
        if let retryAfterMs { data["retryAfterMs"] = .number(Double(retryAfterMs)) }
        return BYOTTelemetryOpenCode.messageError(details: data)
    }

    @Test("Each OpenCode 2 error type maps to a failure class", arguments: [
        // packages/core/src/session/runner/step.ts, runner/llm.ts
        ("aborted", "aborted"),
        // packages/core/src/session/runner/llm.ts, compaction.ts
        ("compaction.interrupted", "aborted"),
        // packages/core/src/session/to-session-error.ts
        ("provider.auth", "provider_auth"),
        ("provider.rate-limit", "throttled"),
        ("provider.quota", "throttled"),
        ("provider.free-limit", "throttled"),
        ("provider.budget-limit", "throttled"),
        ("provider.model-budget-limit", "throttled"),
        ("provider.go-limit", "throttled"),
        ("provider.chatgpt-limit", "throttled"),
        ("provider.chatgpt-workspace-limit", "throttled"),
        ("provider.no-route", "model_unavailable"),
        ("provider.unknown", "model_unavailable"),
        ("provider.content-filter", "provider_api"),
        ("provider.transport", "provider_api"),
        ("provider.internal", "provider_api"),
        ("provider.invalid-output", "provider_api"),
        ("provider.invalid-request", "provider_api"),
        ("provider.unsupported-operation", "provider_api"),
        ("provider.timeout", "provider_api"),
        // packages/core/src/session/runner/llm.ts
        ("output-limit", "output_length"),
        // No existing class: tool, permission, compaction and unknown failures.
        ("tool.execution", "turn_failed"),
        ("tool.result-missing", "turn_failed"),
        ("tool.input-json", "turn_failed"),
        ("tool.input-incomplete", "turn_failed"),
        ("permission.rejected", "turn_failed"),
        ("compaction.failed", "turn_failed"),
        ("compaction.unavailable", "turn_failed"),
        ("unknown", "turn_failed"),
    ])
    func v2Types(type: String, expected: String) {
        #expect(BYOTTelemetryOpenCode.failureClass(Self.v2(type, message: "It failed")) == expected)
    }

    @Test("Status 429 or a retry delay is throttled, whatever the type")
    func throttled() {
        #expect(BYOTTelemetryOpenCode.failureClass(Self.v2("provider.transport", status: 429)) == "throttled")
        #expect(BYOTTelemetryOpenCode.failureClass(Self.v2("provider.internal", retryAfterMs: 30_000)) == "throttled")
        #expect(BYOTTelemetryOpenCode.failureClass(Self.v2("provider.internal", retryAfterMs: 0)) == "throttled")
        #expect(BYOTTelemetryOpenCode.failureClass(Self.v2("provider.internal", status: 503)) == "provider_api")
        // A stop stays a stop.
        #expect(BYOTTelemetryOpenCode.failureClass(Self.v2("aborted", retryAfterMs: 1_000)) == "aborted")
        // v1 APIError carries statusCode.
        let v1 = OpenCodeMessageError(name: "APIError", data: ["statusCode": .number(429), "message": .string("slow down")])
        #expect(BYOTTelemetryOpenCode.failureClass(v1) == "throttled")
    }

    @Test("A gone model is model_unavailable")
    func goneModel() {
        #expect(BYOTTelemetryOpenCode.failureClass(Self.v2("provider.invalid-request", status: 410)) == "model_unavailable")
    }

    @Test("v1 error names keep their classes")
    func v1Names() {
        func cls(_ name: String) -> String {
            BYOTTelemetryOpenCode.failureClass(OpenCodeMessageError(name: name, data: ["message": .string("x")]))
        }
        #expect(cls("MessageAbortedError") == "aborted")
        #expect(cls("ProviderAuthError") == "provider_auth")
        #expect(cls("MessageOutputLengthError") == "output_length")
        #expect(cls("APIError") == "provider_api")
        #expect(cls("ContextOverflowError") == "context_overflow")
        #expect(cls("UnknownError") == "turn_failed")
    }

    @Test("HTTP status buckets", arguments: [
        (400, "4xx"), (401, "4xx"), (410, "4xx"), (429, "429"), (499, "4xx"), (500, "5xx"), (529, "5xx"),
    ])
    func buckets(status: Int, expected: String) {
        #expect(BYOTTelemetryOpenCode.httpStatusBucket(Self.v2("provider.internal", status: status)) == expected)
    }

    @Test("No status, or a non-error status, has no bucket")
    func noBucket() {
        #expect(BYOTTelemetryOpenCode.httpStatusBucket(Self.v2("provider.internal")) == nil)
        #expect(BYOTTelemetryOpenCode.httpStatusBucket(Self.v2("provider.internal", status: 302)) == nil)
    }

    private static let turn = BYOTTelemetryTurn(
        prompt: OpenCodeQueuedPrompt(text: "fix the tests", model: OpenCodeModelOption(
            providerID: "anthropic", providerName: "Anthropic", modelID: "claude-sonnet-4-5",
            modelName: "Claude Sonnet", status: nil), agent: "build"),
        startedAt: Date(timeIntervalSinceNow: -5))

    private static func reply(error: OpenCodeMessageError?) -> [OpenCodeMessageEnvelope] {
        [OpenCodeMessageEnvelope(info: OpenCodeMessageInfo(id: turn.prompt.messageID, sessionID: "s", role: "user",
            time: OpenCodeMessageTime(created: 1, completed: 1), agent: nil, modelID: nil, providerID: nil,
            finish: nil, error: nil), parts: []),
         OpenCodeMessageEnvelope(info: OpenCodeMessageInfo(id: "a1", sessionID: "s", role: "assistant",
            time: OpenCodeMessageTime(created: 2, completed: 3), agent: nil, modelID: nil, providerID: nil,
            finish: "error", error: error), parts: [])]
    }

    @Test("A failed turn carries its class and status bucket, never the message or body")
    func failedTurnProperties() throws {
        let failure = Self.v2("provider.internal", status: 503)
        let properties = BYOTTelemetryOpenCode.turnCompleted(Self.turn, result: "failed", failure: failure,
                                                             messages: [], now: .now)
        #expect(properties["failure_class"] as? String == "provider_api")
        #expect(properties["http_status_bucket"] as? String == "5xx")
        let validated = try #require(BYOTTelemetry.validate(.turnCompleted, properties))
        let values = validated.values.compactMap { $0 as? String }
        #expect(values.allSatisfy { !$0.contains("steven") && !$0.contains("secret") })
        #expect(validated["message"] == nil && validated["response"] == nil)
    }

    @Test("A failed turn falls back to its reply's error, then to turn_failed")
    func failedTurnFallbacks() {
        let fromReply = BYOTTelemetryOpenCode.turnCompleted(
            Self.turn, result: "failed", messages: Self.reply(error: Self.v2("provider.auth", status: 401)), now: .now)
        #expect(fromReply["failure_class"] as? String == "provider_auth")
        #expect(fromReply["http_status_bucket"] as? String == "4xx")
        let bare = BYOTTelemetryOpenCode.turnCompleted(Self.turn, result: "failed", messages: [], now: .now)
        #expect(bare["failure_class"] as? String == "turn_failed")
        #expect(bare["http_status_bucket"] == nil)
    }

    @Test("Completed and stopped turns carry no failure properties")
    func nonFailedTurns() {
        for result in ["completed", "stopped"] {
            let properties = BYOTTelemetryOpenCode.turnCompleted(
                Self.turn, result: result, failure: Self.v2("aborted"),
                messages: Self.reply(error: Self.v2("aborted")), now: .now)
            #expect(properties["failure_class"] == nil)
            #expect(properties["http_status_bucket"] == nil)
        }
    }

    @Test("The failed-turn error_occurred event uses the same class")
    func errorOccurredMatches() {
        let properties = BYOTTelemetryOpenCode.turnFailed(details: [
            "type": .string("provider.rate-limit"), "message": .string("slow down"), "retryAfterMs": .number(2_000),
        ])
        #expect(properties["error_class"] as? String == "throttled")
        #expect(BYOTTelemetry.validate(.errorOccurred, properties) != nil)
    }
}

@Suite("Usage data provider rule")
struct BYOTTelemetryProviderRuleTests {
    @Test("Public catalog providers report their id", arguments: [
        // Added to models.dev since the hand-kept list.
        "302ai", "ollama-cloud", "siliconflow", "novita-ai", "kilo", "poe", "sap-ai-core", "snowflake-cortex",
        "databricks", "modal", "neon", "llmgateway", "cloudflare-ai-gateway", "digitalocean", "opencode-go",
        // OpenCode built-ins models.dev does not list.
        "claude-agent", "ollama", "vllm",
        // Earlier list.
        "anthropic", "openai", "openrouter", "github-copilot",
    ])
    func catalog(id: String) {
        #expect(BYOTTelemetryOpenCode.provider(id) == id)
        let model = OpenCodeModelOption(providerID: id, providerName: id, modelID: "Some-Model", modelName: "M", status: nil)
        #expect(BYOTTelemetryOpenCode.model(model) == "some-model")
    }

    @Test("Custom providers and their models stay other")
    func custom() {
        for id in ["acme-internal", "my-lab-gateway", "steven-local"] {
            #expect(BYOTTelemetryOpenCode.provider(id) == "other")
            let model = OpenCodeModelOption(providerID: id, providerName: id, modelID: "secret", modelName: "S", status: nil)
            #expect(BYOTTelemetryOpenCode.model(model) == "other")
        }
        #expect(BYOTTelemetryOpenCode.provider("") == "none")
    }

    @Test("Every catalog id fits the usage data string limit")
    func idsFit() {
        for id in BYOTTelemetryOpenCode.knownProviders {
            #expect(id == id.lowercased() && !id.isEmpty && id.count <= BYOTTelemetry.maximumStringLength)
        }
    }
}
