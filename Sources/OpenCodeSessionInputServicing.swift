import Foundation

protocol OpenCodeSessionInputServicing: Sendable {
    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities
    func commands(
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeCommandOption]
    func agents(
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeAgentOption]
}

extension OpenCodeClient: OpenCodeSessionInputServicing { }
