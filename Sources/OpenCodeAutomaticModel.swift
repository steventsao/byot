import Foundation

/// The model the server runs when a prompt names none, so "Automatic" can say
/// which model that is. The order follows the server's own selection:
///
/// - v2 (`packages/core/src/session/runner/model.ts`): the session's model, then
///   the agent's model, then `Model.default()` — the configured `model`, else
///   the first available model (`packages/core/src/model.ts`).
/// - v1 (`session/prompt.ts`): the agent's model, then the session's last user
///   model, then `Provider.defaultModel()` — the configured `model`, else the
///   first connected provider's default.
///
/// The web app (`packages/app/src/providers/models/selection.tsx`) resolves the
/// same agent → config → first available order. Each step must name a model the
/// server lists as available; otherwise the next step decides, as upstream's
/// `firstModel(...)` and `find(...)` do.
enum OpenCodeAutomaticModel {
    static func resolve(
        serverProtocol: OpenCodeServerProtocol?,
        sessionModelID: String?,
        agentModelID: String?,
        configuredModelID: String?,
        providers: [OpenCodeProviderModels]
    ) -> OpenCodeModelOption? {
        let models = providers.flatMap(\.models)
        func available(_ id: String?) -> OpenCodeModelOption? {
            guard let id else { return nil }
            return models.first { $0.qualifiedID == id }
        }
        let ordered = serverProtocol == .v1
            ? [agentModelID, sessionModelID, configuredModelID]
            : [sessionModelID, agentModelID, configuredModelID]
        for id in ordered { if let model = available(id) { return model } }
        return fallback(providers)
    }

    /// The server's last resort: the provider marked with the lowest rank.
    static func fallback(_ providers: [OpenCodeProviderModels]) -> OpenCodeModelOption? {
        providers
            .compactMap { provider -> (Int, OpenCodeModelOption)? in
                guard let rank = provider.fallbackRank, let id = provider.fallbackModelID,
                      let model = provider.models.first(where: { $0.modelID == id }) else { return nil }
                return (rank, model)
            }
            .min { $0.0 < $1.0 }?.1
    }

    /// A config `model`: v1's `provider/model` string or v2's `{providerID, model}` object.
    static func configuredModelID(_ value: OpenCodeJSONValue?) -> String? {
        if let string = value?.stringValue?.trimmedNonEmpty { return string }
        guard let object = value?.objectValue,
              let provider = object["providerID"]?.stringValue?.trimmedNonEmpty,
              let model = (object["model"] ?? object["modelID"] ?? object["id"])?.stringValue?.trimmedNonEmpty
        else { return nil }
        return "\(provider)/\(model)"
    }

    /// An agent's or session's model reference: v1 `{providerID, modelID}`, v2 `{providerID, id}`.
    static func referenceID(_ value: OpenCodeJSONValue?) -> String? {
        guard let object = value?.objectValue,
              let provider = object["providerID"]?.stringValue?.trimmedNonEmpty,
              let model = (object["modelID"] ?? object["id"])?.stringValue?.trimmedNonEmpty else { return nil }
        return "\(provider)/\(model)"
    }

    /// v2 config entries run lowest priority first; the last document naming a model wins
    /// (upstream `useConfiguredModel` uses `findLast`).
    static func configuredModelID(v2Entries entries: [OpenCodeJSONValue]) -> String? {
        entries.reversed().lazy.compactMap { entry -> String? in
            guard let object = entry.objectValue, object["type"]?.stringValue == "document" else { return nil }
            return configuredModelID(object["info"]?.objectValue?["model"])
        }.first
    }

    /// v1 falls back to the session's last user message model.
    static func lastUserModelID(_ messages: [OpenCodeMessageEnvelope]) -> String? {
        messages.last { $0.info.role == "user" && $0.info.providerID != nil && $0.info.modelID != nil }
            .map { "\($0.info.providerID!)/\($0.info.modelID!)" }
    }
}
