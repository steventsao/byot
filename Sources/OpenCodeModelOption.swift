import Foundation

struct OpenCodeModelOption: Identifiable, Equatable, Hashable, Codable, Sendable {
    let providerID: String
    let providerName: String
    let modelID: String
    let modelName: String
    let status: String?

    var variants: [String] = []
    /// The model's context window in tokens, when the catalog reports one.
    var contextLimit: Int? = nil

    var id: String { qualifiedID }

    var qualifiedID: String {
        "\(providerID)/\(modelID)"
    }
}

extension OpenCodeModelOption {
    /// Both catalogs describe a model's window as `limit.context`; zero means unknown.
    static func contextLimit(_ model: [String: OpenCodeJSONValue]) -> Int? {
        guard let value = model["limit"]?.objectValue?["context"]?.numberValue, value >= 1 else { return nil }
        return Int(value)
    }
}
