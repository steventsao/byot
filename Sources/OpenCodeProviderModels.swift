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

    init(
        providerID: String,
        providerName: String,
        models: [OpenCodeModelOption],
        connectionState: ConnectionState = .confirmed
    ) {
        self.providerID = providerID
        self.providerName = providerName
        self.models = models
        self.connectionState = connectionState
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
            connectionState: connectionState
        )
    }
}
