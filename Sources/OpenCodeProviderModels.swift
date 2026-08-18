import Foundation

struct OpenCodeProviderModels: Identifiable, Equatable, Sendable {
    let providerID: String
    let providerName: String
    let models: [OpenCodeModelOption]

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
            models: matchingModels
        )
    }
}
