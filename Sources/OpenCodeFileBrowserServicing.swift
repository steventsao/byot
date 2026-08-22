import Foundation

protocol OpenCodeFileBrowserServicing: Sendable {
    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities

    func listFiles(
        directory: String,
        workspace: String?,
        path: String
    ) async throws -> [OpenCodeFileEntry]

    func readFile(
        directory: String,
        workspace: String?,
        path: String
    ) async throws -> OpenCodeFileContent

    func fileStatuses(
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeFileStatus]

    func findFiles(
        directory: String,
        workspace: String?,
        query: String
    ) async throws -> [OpenCodeFileEntry]
}

extension OpenCodeClient: OpenCodeFileBrowserServicing { }
