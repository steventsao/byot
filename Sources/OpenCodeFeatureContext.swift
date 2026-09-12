import Foundation

/// Additional client features share the negotiated connection and its schema.
/// Each feature owns its typed requests; this context never probes guessed routes.
struct OpenCodeFeatureContext: Sendable {
    let serverProtocol: OpenCodeServerProtocol
    let schema: OpenCodeJSONValue?
    let transport: any OpenCodeHTTPTransport
    let profile: OpenCodeServerProfile

    func supports(_ path: String, method: String = "get") -> Bool {
        if serverProtocol == .v1 { return true }
        return schema?.objectValue?["paths"]?.objectValue?[path]?
            .objectValue?[method.lowercased()] != nil
    }
}
