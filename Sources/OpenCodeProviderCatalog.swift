import Foundation

struct OpenCodeProviderCatalog: Decodable, Equatable, Sendable {
    let connectedProviders: [OpenCodeProviderModels]

    private enum CodingKeys: String, CodingKey {
        case all
        case connected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawProviders = try container.decode([OpenCodeJSONValue].self, forKey: .all)
        let connectedProviderIDs = Set(
            try container.decode([String].self, forKey: .connected)
        )

        connectedProviders = rawProviders.compactMap { rawProvider -> OpenCodeProviderModels? in
            guard case .object(let provider) = rawProvider,
                  let providerID = provider["id"]?.stringValue,
                  connectedProviderIDs.contains(providerID),
                  case .object(let rawModels) = provider["models"]
            else { return nil }

            let providerName = provider["name"]?.stringValue ?? providerID
            let models = rawModels.compactMap { modelKey, rawModel -> OpenCodeModelOption? in
                guard case .object(let model) = rawModel else { return nil }
                let modelID = model["id"]?.stringValue ?? modelKey
                return OpenCodeModelOption(
                    providerID: providerID,
                    providerName: providerName,
                    modelID: modelID,
                    modelName: model["name"]?.stringValue ?? modelID,
                    status: model["status"]?.stringValue
                )
            }
            .sorted {
                $0.modelName.localizedStandardCompare($1.modelName) == .orderedAscending
            }
            guard !models.isEmpty else { return nil }
            return OpenCodeProviderModels(
                providerID: providerID,
                providerName: providerName,
                models: models
            )
        }
        .sorted {
            $0.providerName.localizedStandardCompare($1.providerName) == .orderedAscending
        }
    }
}
