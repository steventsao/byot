import Foundation

protocol OpenCodeServerContextServicing: Sendable {
    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities

    func serverConfiguration(
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeConfiguration

    func updateServerConfiguration(
        _ configuration: OpenCodeConfiguration,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeConfiguration

    func vcsInfo(
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeVCSInfo

    func pathInfo(
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeServerPaths

    func mcpStatuses(
        directory: String,
        workspace: String?
    ) async throws -> [String: OpenCodeMCPStatus]

    func lspStatuses(
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeLSPStatus]

    func formatterStatuses(
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeFormatterStatus]
}

extension OpenCodeClient: OpenCodeServerContextServicing { }
