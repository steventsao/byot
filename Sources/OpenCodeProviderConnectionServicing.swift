import Foundation

protocol OpenCodeProviderConnectionServicing: Sendable {
    func providerConnections(
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeProviderConnection]

    func connectProviderKey(
        providerID: String,
        key: String,
        directory: String,
        workspace: String?
    ) async throws

    func startProviderOAuth(
        providerID: String,
        methodID: String,
        inputs: [String: String],
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeProviderOAuthAuthorization

    func completeProviderOAuth(
        providerID: String,
        attemptID: String,
        code: String?,
        directory: String,
        workspace: String?
    ) async throws

    func providerOAuthStatus(
        providerID: String,
        attemptID: String,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeProviderOAuthStatus

    func cancelProviderOAuth(
        providerID: String,
        attemptID: String,
        directory: String,
        workspace: String?
    ) async throws
}

extension OpenCodeClient: OpenCodeProviderConnectionServicing { }
