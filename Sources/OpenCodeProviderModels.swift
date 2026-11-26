import Foundation

struct OpenCodeProviderModels: Identifiable, Equatable, Sendable {
    enum ConnectionState: Equatable, Sendable {
        case confirmed
        case unreported
    }

    let providerID: String
    let providerName: String
    let models: [OpenCodeModelOption]
    let connectionState: ConnectionState
    /// Where this provider stands in the server's own fallback when a prompt names
    /// no model, with the model it would run; lowest rank wins. See `OpenCodeAutomaticModel`.
    var fallbackRank: Int? = nil
    var fallbackModelID: String? = nil

    init(
        providerID: String,
        providerName: String,
        models: [OpenCodeModelOption],
        connectionState: ConnectionState = .confirmed,
        fallbackRank: Int? = nil,
        fallbackModelID: String? = nil
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.models = models
        self.connectionState = connectionState
        self.fallbackRank = fallbackRank
        self.fallbackModelID = fallbackModelID
    }

    var id: String { providerID }

    func matching(_ query: String) -> OpenCodeProviderModels? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return self }
        if providerName.localizedStandardContains(trimmedQuery)
            || providerID.localizedStandardContains(trimmedQuery) {
            return self
        }
        let matchingModels = models.filter {
            $0.modelName.localizedStandardContains(trimmedQuery)
                || $0.modelID.localizedStandardContains(trimmedQuery)
                || $0.qualifiedID.localizedStandardContains(trimmedQuery)
        }
        guard !matchingModels.isEmpty else { return nil }
        return OpenCodeProviderModels(
            providerID: providerID,
            providerName: providerName,
            models: matchingModels,
            connectionState: connectionState,
            fallbackRank: fallbackRank,
            fallbackModelID: fallbackModelID
        )
    }
}
