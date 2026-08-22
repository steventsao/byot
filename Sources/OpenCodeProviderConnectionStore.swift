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
        await submit {
            try await service.connectProviderKey(
                providerID: provider.id,
                key: key,
                directory: directory,
                workspace: workspace
            )
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
        phase = .startingOAuth
        await submit {
            let authorization = try await service.startProviderOAuth(
                providerID: provider.id,
                methodID: method.id,
                inputs: normalizedInputs,
                directory: directory,
                workspace: workspace
            )
            self.authorization = authorization
            phase = authorization.mode == .code ? .oauthCode : .oauthWaiting
        }
    }

    func completeOAuth(code: String?) async {
        guard let provider = selectedProvider, let authorization else { return }
        let code = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        if authorization.mode == .code, code?.isEmpty != false {
            errorMessage = OpenCodeProviderConnectionError.missingCode.localizedDescription
            return
        }
        await submit {
            try await service.completeProviderOAuth(
                providerID: provider.id,
                attemptID: authorization.attemptID,
                code: code,
                directory: directory,
                workspace: workspace
            )
            finishConnection(providerID: provider.id)
        }
    }

    func pollOAuthOnce() async {
        guard let provider = selectedProvider, let authorization else { return }
        do {
            switch try await service.providerOAuthStatus(
                providerID: provider.id,
                attemptID: authorization.attemptID,
                directory: directory,
                workspace: workspace
            ) {
            case .pending:
                phase = .oauthWaiting
            case .complete:
                finishConnection(providerID: provider.id)
            case .failed(let message):
                errorMessage = message
            case .expired:
                errorMessage = "Provider authorization expired. Start again."
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelOAuth() async {
        guard let provider = selectedProvider, let authorization else {
            backToProviders()
            return
        }
        do {
            try await service.cancelProviderOAuth(
                providerID: provider.id,
                attemptID: authorization.attemptID,
                directory: directory,
                workspace: workspace
            )
        } catch is OpenCodeFeatureUnavailableError {
            // V1 has no cancellation route; leaving the flow is the only supported action.
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        backToProviders()
    }

    func backToMethods() {
        guard selectedProvider != nil else {
            backToProviders()
            return
        }
        selectedMethodID = nil
        inputs = [:]
        authorization = nil
        errorMessage = nil
        phase = .methodSelection
    }

    func backToProviders() {
        resetSelection()
        errorMessage = nil
    }

    private var normalizedInputs: [String: String] {
        inputs.reduce(into: [:]) { result, element in
            result[element.key] = element.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func submit(_ operation: () async throws -> Void) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishConnection(providerID: String) {
        if let index = providers.firstIndex(where: { $0.id == providerID }) {
            providers[index] = providers[index].markingConnected()
        }
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
