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

    @Test("OAuth start failure returns to a retryable phase with its error visible")
    func oauthStartFailure() async {
        let provider = oauthProvider()
        let service = MockProviderConnectionService(
            providers: [provider],
            startError: TestProviderConnectionError.startFailed
        )
        let store = makeStore(service: service)

        await store.load()
        store.selectProvider(provider)
        await store.beginOAuth()

        #expect(store.phase == .oauthReady)
        #expect(store.errorMessage == TestProviderConnectionError.startFailed.localizedDescription)
        #expect(!store.isSubmitting)
    }

    @Test("Navigation invalidates an in-flight OAuth completion")
    func navigationInvalidatesSubmission() async {
        let provider = oauthProvider()
        let barrier = ProviderConnectionBarrier()
        let service = MockProviderConnectionService(
            providers: [provider],
            startBarrier: barrier
        )
        let store = makeStore(service: service)

        await store.load()
        store.selectProvider(provider)
        let request = Task { await store.beginOAuth() }
        await barrier.waitForArrival()
        store.backToProviders()
        await barrier.release()
        await request.value

        #expect(store.phase == .providerSelection)
        #expect(store.authorization == nil)
        #expect(!store.isSubmitting)
    }

    @Test("Leaving an active OAuth flow cancels its server attempt")
    func leavingOAuthCancelsAttempt() async {
        let provider = oauthProvider()
        let service = MockProviderConnectionService(providers: [provider])
        let store = makeStore(service: service)

        await store.load()
        store.selectProvider(provider)
        await store.beginOAuth()
        await store.leaveToMethods()

        #expect(service.steps.contains(.cancel(attemptID: "attempt_1")))
        #expect(store.phase == .methodSelection)
        #expect(store.authorization == nil)
    }

    @Test("A failed server cancellation cannot trap the OAuth sheet")
    func cancellationFailureStillLeavesFlow() async {
        let provider = oauthProvider()
        let service = MockProviderConnectionService(
            providers: [provider],
            cancelError: TestProviderConnectionError.cancelFailed
        )
        let store = makeStore(service: service)

        await store.load()
        store.selectProvider(provider)
        await store.beginOAuth()
        await store.cancelOAuth()

        #expect(service.steps.contains(.cancel(attemptID: "attempt_1")))
        #expect(store.phase == .providerSelection)
        #expect(store.authorization == nil)
        #expect(!store.isSubmitting)
    }

    @Test("OAuth submits only currently visible conditional inputs")
    func hiddenInputsAreNotSubmitted() async {
        let method = OpenCodeProviderAuthMethod(
            id: "oauth",
            kind: .oauth,
            label: "Sign in",
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
                    message: "Hostname",
                    condition: OpenCodeProviderAuthPromptCondition(
                        key: "account",
                        operation: .equal,
                        value: "enterprise"
                    )
                ),
            ]
        )
        let provider = OpenCodeProviderConnection(
            id: "openai",
            name: "OpenAI",
            isConnected: false,
            methods: [method]
        )
        let service = MockProviderConnectionService(providers: [provider])
        let store = makeStore(service: service)

        await store.load()
        store.selectProvider(provider)
        store.setInput("enterprise", for: "account")
        store.setInput(" stale.example ", for: "hostname")
        store.setInput("personal", for: "account")
        await store.beginOAuth()

        #expect(
            service.steps.contains(
                .startOAuth(
                    providerID: "openai",
                    methodID: "oauth",
                    inputs: ["account": "personal"]
                )
            )
        )
    }

    private func oauthProvider() -> OpenCodeProviderConnection {
        OpenCodeProviderConnection(
            id: "openai",
            name: "OpenAI",
            isConnected: false,
            methods: [
                OpenCodeProviderAuthMethod(id: "oauth", kind: .oauth, label: "Sign in")
            ]
        )
    }

    private func makeStore(
        service: MockProviderConnectionService
    ) -> OpenCodeProviderConnectionStore {
        OpenCodeProviderConnectionStore(
            service: service,
            directory: "/repo",
            workspace: "wrk_1"
        )
    }
}

private enum TestProviderConnectionError: LocalizedError {
    case startFailed
    case cancelFailed

    var errorDescription: String? {
        switch self {
        case .startFailed: "Could not start provider sign-in."
        case .cancelFailed: "Could not cancel provider sign-in."
        }
    }
}

private actor ProviderConnectionBarrier {
    private var hasArrived = false
    private var isReleased = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        hasArrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForArrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private final class MockProviderConnectionService: OpenCodeProviderConnectionServicing, @unchecked Sendable {
    enum Step: Equatable {
        case load
        case connectKey(providerID: String, key: String)
        case startOAuth(providerID: String, methodID: String, inputs: [String: String])
        case completeOAuth(attemptID: String, code: String?)
        case status(attemptID: String)
        case cancel(attemptID: String)
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var recordedSteps: [Step] = []
    private let providers: [OpenCodeProviderConnection]
    private let startBarrier: ProviderConnectionBarrier?
    private let startError: TestProviderConnectionError?
    private let cancelError: TestProviderConnectionError?

    init(
        providers: [OpenCodeProviderConnection],
        startBarrier: ProviderConnectionBarrier? = nil,
        startError: TestProviderConnectionError? = nil,
        cancelError: TestProviderConnectionError? = nil
    ) {
        self.providers = providers
        self.startBarrier = startBarrier
        self.startError = startError
        self.cancelError = cancelError
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
        record(.startOAuth(providerID: providerID, methodID: methodID, inputs: inputs))
        await startBarrier?.arriveAndWait()
        if let startError { throw startError }
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
        if let cancelError { throw cancelError }
    }

    private func record(_ step: Step) {
        lock.lock()
        recordedSteps.append(step)
        lock.unlock()
    }
}
