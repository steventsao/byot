import Foundation

protocol OpenCodeSessionSharingServicing: Sendable {
    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities

    func shareSession(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeSession

    func unshareSession(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeSession
}

extension OpenCodeClient: OpenCodeSessionSharingServicing { }
