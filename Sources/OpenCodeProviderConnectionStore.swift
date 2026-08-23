import Combine
import Foundation

enum OpenCodeProviderConnectionPhase: Equatable, Sendable {
    case providerSelection
    case methodSelection
    case keyEntry
    case oauthPrompts
    case oauthReady
    case startingOAuth
    case oauthCode
    case oauthWaiting
    case connected(providerID: String)
}

@MainActor
final class OpenCodeProviderConnectionStore: ObservableObject {
    @Published private(set) var providers: [OpenCodeProviderConnection] = []
    @Published private(set) var selectedProviderID: String?
    @Published private(set) var selectedMethodID: String?
    @Published private(set) var inputs: [String: String] = [:]
    @Published private(set) var authorization: OpenCodeProviderOAuthAuthorization?
    @Published private(set) var phase: OpenCodeProviderConnectionPhase = .providerSelection
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var errorMessage: String?

    private let service: any OpenCodeProviderConnectionServicing
    private let directory: String
    private let workspace: String?
    private var loadGeneration = 0
    private var flowGeneration = 0

    init(client: OpenCodeClient, directory: String, workspace: String?) {
        service = client
        self.directory = directory
        self.workspace = workspace
    }

    init(
        service: any OpenCodeProviderConnectionServicing,
        directory: String,
        workspace: String?
    ) {
        self.service = service
        self.directory = directory
        self.workspace = workspace
    }

    var selectedProvider: OpenCodeProviderConnection? {
        providers.first { $0.id == selectedProviderID }
    }

    var selectedMethod: OpenCodeProviderAuthMethod? {
        selectedProvider?.methods.first { $0.id == selectedMethodID }
    }

    var visiblePrompts: [OpenCodeProviderAuthPrompt] {
        selectedMethod?.visiblePrompts(inputs: inputs) ?? []
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let providers = try await service.providerConnections(
                directory: directory,
                workspace: workspace
            )
            guard generation == loadGeneration else { return }
            self.providers = providers
            if let selectedProviderID,
               !providers.contains(where: { $0.id == selectedProviderID }) {
                resetSelection()
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func selectProvider(_ provider: OpenCodeProviderConnection) {
        guard providers.contains(where: { $0.id == provider.id }) else { return }
        invalidateFlow()
        selectedProviderID = provider.id
        selectedMethodID = nil
        inputs = [:]
        authorization = nil
        errorMessage = nil
        phase = .methodSelection
        if provider.methods.count == 1, let method = provider.methods.first {
            selectMethod(method)
        }
    }

    func selectMethod(_ method: OpenCodeProviderAuthMethod) {
        guard selectedProvider?.methods.contains(where: { $0.id == method.id }) == true else { return }
        invalidateFlow()
        selectedMethodID = method.id
        inputs = [:]
        authorization = nil
        errorMessage = nil
        switch method.kind {
        case .key: phase = .keyEntry
        case .oauth: phase = method.prompts.isEmpty ? .oauthReady : .oauthPrompts
        }
    }

    func setInput(_ value: String, for key: String) {
        guard selectedMethod?.prompts.contains(where: { $0.key == key }) == true else { return }
        inputs[key] = value
        errorMessage = nil
    }

    func connectKey(_ key: String) async {
        guard let provider = selectedProvider, selectedMethod?.kind == .key else { return }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            errorMessage = OpenCodeProviderConnectionError.missingKey.localizedDescription
            return
        }
        if let _: Void = await submit({
            try await service.connectProviderKey(
                providerID: provider.id,
                key: key,
                directory: directory,
                workspace: workspace
            )
        }) {
            finishConnection(providerID: provider.id)
        }
    }

    func beginOAuth() async {
        guard let provider = selectedProvider,
              let method = selectedMethod,
              method.kind == .oauth
        else { return }
        if let missing = method.missingRequiredInput(inputs: inputs) {
            errorMessage = OpenCodeProviderConnectionError.missingInput(missing).localizedDescription
            phase = .oauthPrompts
            return
        }
        let retryPhase: OpenCodeProviderConnectionPhase = method.prompts.isEmpty
            ? .oauthReady
            : .oauthPrompts
        let generation = flowGeneration
        let inputs = normalizedVisibleInputs(for: method)
        phase = .startingOAuth
        let authorization: OpenCodeProviderOAuthAuthorization? = await submit {
            try await service.startProviderOAuth(
                providerID: provider.id,
                methodID: method.id,
                inputs: inputs,
                directory: directory,
                workspace: workspace
            )
        }
        guard generation == flowGeneration else { return }
        guard let authorization else {
            phase = retryPhase
            return
        }
        self.authorization = authorization
        phase = authorization.mode == .code ? .oauthCode : .oauthWaiting
    }

    func completeOAuth(code: String?) async {
        guard let provider = selectedProvider, let authorization else { return }
        let code = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        if authorization.mode == .code, code?.isEmpty != false {
            errorMessage = OpenCodeProviderConnectionError.missingCode.localizedDescription
            return
        }
        if let _: Void = await submit({
            try await service.completeProviderOAuth(
                providerID: provider.id,
                attemptID: authorization.attemptID,
                code: code,
                directory: directory,
                workspace: workspace
            )
        }) {
            finishConnection(providerID: provider.id)
        }
    }

    func pollOAuthOnce() async {
        guard let provider = selectedProvider, let authorization else { return }
        let generation = flowGeneration
        do {
            let status = try await service.providerOAuthStatus(
                providerID: provider.id,
                attemptID: authorization.attemptID,
                directory: directory,
                workspace: workspace
            )
            guard generation == flowGeneration else { return }
            switch status {
            case .pending:
                phase = .oauthWaiting
            case .complete:
                finishConnection(providerID: provider.id)
            case .failed(let message):
                failOAuthAttempt(message: message)
            case .expired:
                failOAuthAttempt(message: "Provider authorization expired. Start again.")
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == flowGeneration else { return }
            failOAuthAttempt(message: error.localizedDescription)
        }
    }

    private func failOAuthAttempt(message: String) {
        authorization = nil
        phase = selectedMethod?.prompts.isEmpty == false ? .oauthPrompts : .oauthReady
        errorMessage = message
    }

    func cancelOAuth() async {
        guard !isConnected else { return }
        guard await cancelActiveOAuthIfNeeded() else { return }
        backToProviders()
    }

    func leaveToMethods() async {
        guard !isConnected else { return }
        guard await cancelActiveOAuthIfNeeded() else { return }
        backToMethods()
    }

    func leaveToProviders() async {
        guard !isConnected else { return }
        guard await cancelActiveOAuthIfNeeded() else { return }
        backToProviders()
    }

    func prepareToDismiss() async -> Bool {
        await cancelActiveOAuthIfNeeded()
    }

    private var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    func backToMethods() {
        guard selectedProvider != nil else {
            backToProviders()
            return
        }
        guard authorization == nil else { return }
        invalidateFlow()
        selectedMethodID = nil
        inputs = [:]
        authorization = nil
        errorMessage = nil
        phase = .methodSelection
    }

    func backToProviders() {
        guard authorization == nil else { return }
        invalidateFlow()
        resetSelection()
        errorMessage = nil
    }

    private func normalizedVisibleInputs(
        for method: OpenCodeProviderAuthMethod
    ) -> [String: String] {
        let visibleKeys = Set(method.visiblePrompts(inputs: inputs).map(\.key))
        return inputs.reduce(into: [:]) { result, element in
            guard visibleKeys.contains(element.key) else { return }
            result[element.key] = element.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func submit<Value: Sendable>(
        _ operation: () async throws -> Value
    ) async -> Value? {
        guard !isSubmitting else { return nil }
        let generation = flowGeneration
        isSubmitting = true
        errorMessage = nil
        defer {
            if generation == flowGeneration { isSubmitting = false }
        }
        do {
            let value = try await operation()
            guard generation == flowGeneration else { return nil }
            return value
        } catch is CancellationError {
            return nil
        } catch {
            guard generation == flowGeneration else { return nil }
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func cancelActiveOAuthIfNeeded() async -> Bool {
        guard let provider = selectedProvider, let authorization else {
            invalidateFlow()
            return true
        }
        invalidateFlow()
        let generation = flowGeneration
        isSubmitting = true
        errorMessage = nil
        defer {
            if generation == flowGeneration { isSubmitting = false }
        }
        do {
            try await service.cancelProviderOAuth(
                providerID: provider.id,
                attemptID: authorization.attemptID,
                directory: directory,
                workspace: workspace
            )
        } catch is OpenCodeFeatureUnavailableError {
            // V1 has no cancellation route; leaving the flow is the supported fallback.
        } catch is CancellationError {
            guard generation == flowGeneration else { return false }
            self.authorization = nil
            return true
        } catch {
            guard generation == flowGeneration else { return false }
            errorMessage = error.localizedDescription
            self.authorization = nil
            return true
        }
        guard generation == flowGeneration else { return false }
        self.authorization = nil
        return true
    }

    private func invalidateFlow() {
        flowGeneration &+= 1
        isSubmitting = false
    }

    private func finishConnection(providerID: String) {
        if let index = providers.firstIndex(where: { $0.id == providerID }) {
            providers[index] = providers[index].markingConnected()
        }
        authorization = nil
        errorMessage = nil
        phase = .connected(providerID: providerID)
    }

    private func resetSelection() {
        selectedProviderID = nil
        selectedMethodID = nil
        inputs = [:]
        authorization = nil
        phase = .providerSelection
    }
}
