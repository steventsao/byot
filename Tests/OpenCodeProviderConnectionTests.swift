import Foundation
import Testing
@testable import byot

struct OpenCodeProviderConnectionPolicyTests {
    @Test("Conditional OAuth prompts advance through only matching inputs")
    func conditionalPrompts() {
        let method = OpenCodeProviderAuthMethod(
            id: "oauth-workspace",
            kind: .oauth,
            label: "Workspace login",
            prompts: [
                OpenCodeProviderAuthPrompt(
                    kind: .select,
                    key: "account",
                    message: "Account type",
                    options: [
                        OpenCodeProviderAuthPromptOption(label: "Personal", value: "personal"),
                        OpenCodeProviderAuthPromptOption(label: "Enterprise", value: "enterprise"),
                    ]
                ),
                OpenCodeProviderAuthPrompt(
                    kind: .text,
                    key: "hostname",
                    message: "Enterprise hostname",
                    placeholder: "company.example",
                    condition: OpenCodeProviderAuthPromptCondition(
                        key: "account",
                        operation: .equal,
                        value: "enterprise"
                    )
                ),
            ]
        )

        #expect(method.visiblePrompts(inputs: [:]).map(\.key) == ["account"])
        #expect(method.visiblePrompts(inputs: ["account": "personal"]).map(\.key) == ["account"])
        #expect(method.visiblePrompts(inputs: ["account": "enterprise"]).map(\.key) == ["account", "hostname"])
        #expect(method.missingRequiredInput(inputs: ["account": "enterprise"]) == "hostname")
        #expect(method.missingRequiredInput(inputs: ["account": "enterprise", "hostname": "acme.example"]) == nil)
    }
}

@MainActor
@Suite(.serialized)
struct OpenCodeProviderConnectionStoreTests {
    @Test("Store drives API key and code OAuth flows through an injectable service")
    func connectionFlows() async {
        let provider = OpenCodeProviderConnection(
            id: "openai",
            name: "OpenAI",
            isConnected: false,
            methods: [
                OpenCodeProviderAuthMethod(id: "key", kind: .key, label: "API key"),
                OpenCodeProviderAuthMethod(id: "oauth", kind: .oauth, label: "Sign in"),
            ]
        )
        let service = MockProviderConnectionService(providers: [provider])
        let store = OpenCodeProviderConnectionStore(
            service: service,
            directory: "/repo",
            workspace: "wrk_1"
        )

        await store.load()
        store.selectProvider(provider)
        store.selectMethod(provider.methods[0])
        await store.connectKey("  secret-key  ")

        #expect(service.steps.contains(.connectKey(providerID: "openai", key: "secret-key")))
        #expect(store.phase == .connected(providerID: "openai"))

        store.selectProvider(provider)
        store.selectMethod(provider.methods[1])
        await store.beginOAuth()

        #expect(store.phase == .oauthCode)
        #expect(store.authorization?.attemptID == "attempt_1")
        await store.completeOAuth(code: "  device-code  ")

        #expect(service.steps.contains(.completeOAuth(attemptID: "attempt_1", code: "device-code")))
        #expect(store.phase == .connected(providerID: "openai"))
    }
}

private final class MockProviderConnectionService: OpenCodeProviderConnectionServicing, @unchecked Sendable {
    enum Step: Equatable {
        case load
        case connectKey(providerID: String, key: String)
        case startOAuth(providerID: String, methodID: String)
        case completeOAuth(attemptID: String, code: String?)
        case status(attemptID: String)
        case cancel(attemptID: String)
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var recordedSteps: [Step] = []
    private let providers: [OpenCodeProviderConnection]

    init(providers: [OpenCodeProviderConnection]) {
        self.providers = providers
    }

    var steps: [Step] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSteps
    }

    func providerConnections(directory: String, workspace: String?) async throws -> [OpenCodeProviderConnection] {
        record(.load)
        return providers
    }

    func connectProviderKey(
        providerID: String,
        key: String,
        directory: String,
        workspace: String?
    ) async throws {
        record(.connectKey(providerID: providerID, key: key))
    }

    func startProviderOAuth(
        providerID: String,
        methodID: String,
        inputs: [String: String],
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeProviderOAuthAuthorization {
        record(.startOAuth(providerID: providerID, methodID: methodID))
        return OpenCodeProviderOAuthAuthorization(
            attemptID: "attempt_1",
            url: URL(string: "https://auth.example.test")!,
            instructions: "Paste the code",
            mode: .code,
            createdAt: 1,
            expiresAt: 2
        )
    }

    func completeProviderOAuth(
        providerID: String,
        attemptID: String,
        code: String?,
        directory: String,
        workspace: String?
    ) async throws {
        record(.completeOAuth(attemptID: attemptID, code: code))
    }

    func providerOAuthStatus(
        providerID: String,
        attemptID: String,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeProviderOAuthStatus {
        record(.status(attemptID: attemptID))
        return .pending
    }

    func cancelProviderOAuth(
        providerID: String,
        attemptID: String,
        directory: String,
        workspace: String?
    ) async throws {
        record(.cancel(attemptID: attemptID))
    }

    private func record(_ step: Step) {
        lock.lock()
        recordedSteps.append(step)
        lock.unlock()
    }
}
