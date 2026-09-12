import Foundation

struct OpenCodeEventRoute: Equatable, Sendable {
    let path: [String]
    let query: [URLQueryItem]
}

protocol OpenCodeProtocolAdapting: Sendable {
    var apiSchema: OpenCodeJSONValue? { get }
    var serverProtocol: OpenCodeServerProtocol { get }
    var usesForms: Bool { get }
    var capabilities: OpenCodeProtocolCapabilities { get }

    func listProjects() async throws -> [OpenCodeProject]

    func listSessions(
        directory: String
    ) async throws -> [OpenCodeSession]

    func createSession(
        directory: String,
        title: String?
    ) async throws -> OpenCodeSession

    func connectedProviderModels(
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeProviderModels]

    func messages(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeMessageEnvelope]

    func sendMessage(
        sessionID: String,
        directory: String,
        workspace: String?,
        model: OpenCodeModelOption?,
        text: String,
        attachments: [OpenCodePromptAttachment],
        promptID: UUID
    ) async throws

    func diffs(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeDiff]

    func sessionStatuses(
        directory: String,
        workspace: String?
    ) async throws -> [String: OpenCodeSessionStatus]

    func abortSession(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> Bool

    func eventRoute(directory: String, workspace: String?) -> OpenCodeEventRoute
}

extension OpenCodeProtocolAdapting {
    var apiSchema: OpenCodeJSONValue? { nil }
}
