import Foundation

struct OpenCodeModelOption: Identifiable, Equatable, Hashable, Sendable {
    let providerID: String
    let providerName: String
    let modelID: String
    let modelName: String
    let status: String?

    var id: String { qualifiedID }

    var qualifiedID: String {
        "\(providerID)/\(modelID)"
    }
}
