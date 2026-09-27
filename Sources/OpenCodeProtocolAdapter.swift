import Foundation

struct OpenCodeEventRoute: Equatable, Sendable {
    let path: [String]
    let query: [URLQueryItem]
}

protocol OpenCodeProtocolAdapting: Sendable {
    var apiSchema: OpenCodeJSONValue? { get }
    var serverProtocol: OpenCodeServerProtocol { get }
    var usesForms: Bool { get }
    var listsPendingRequestsByLocation: Bool { get }
    var capabilities: OpenCodeProtocolCapabilities { get }

    func listProjects() async throws -> [OpenCodeProject]

    func listSessions(
        directory: String
    ) async throws -> [OpenCodeSession]

    func createSession(
        directory: String,
        title: String?
    ) async throws -> OpenCodeSession

    /// One session by ID, including subagent sessions the list omits.
    func session(
        id: String,
        directory: String?
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

    /// One server-wide stream that carries every project's session lifecycle.
    var sessionListEventRoute: OpenCodeEventRoute { get }
}

extension OpenCodeProtocolAdapting {
    var apiSchema: OpenCodeJSONValue? { nil }
    /// v2 servers that list pending permissions and questions per location.
    var listsPendingRequestsByLocation: Bool { false }
}
