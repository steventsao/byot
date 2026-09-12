import Foundation

protocol OpenCodeSessionBrowsing: Sendable {
    func listSessions(directory: String) async throws -> [OpenCodeSession]
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String:
        OpenCodeSessionStatus]
}

protocol OpenCodeProjectServicing: OpenCodeSessionBrowsing {
    func createSession(directory: String, title: String?) async throws -> OpenCodeSession
}

/// The session store consumes normalized domain operations. It needs neither
/// credentials nor knowledge of the selected protocol's routes and wire DTOs.
protocol OpenCodeSessionServicing: Sendable {
    func composerCatalog(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeComposerCatalog
    func sendPrompt(sessionID: String, directory: String, workspace: String?, prompt: OpenCodeQueuedPrompt) async throws
    func capabilities() async throws -> OpenCodeProtocolCapabilities
    func connectedProviderModels(directory: String, workspace: String?) async throws
        -> [OpenCodeProviderModels]
    func messages(sessionID: String, directory: String, workspace: String?) async throws
        -> [OpenCodeMessageEnvelope]
    func sendMessage(
        sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String,
        attachments: [OpenCodePromptAttachment], promptID: UUID) async throws
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff]
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String:
        OpenCodeSessionStatus]
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest]
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest]
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest]
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest]
    func reply(
        to permission: OpenCodePermissionRequest, directory: String, workspace: String?,
        reply: OpenCodePermissionReply) async throws
    func answer(
        _ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]])
        async throws
    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?) async throws
    func events(directory: String, workspace: String?) -> AsyncThrowingStream<OpenCodeEvent, Error>
}

extension OpenCodeClient: OpenCodeProjectServicing, OpenCodeSessionServicing {}

// Lightweight test/harness services can retain their existing basic prompt implementation.
extension OpenCodeSessionServicing {
    func composerCatalog(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeComposerCatalog {
        OpenCodeComposerCatalog()
    }
    func sendPrompt(sessionID: String, directory: String, workspace: String?, prompt: OpenCodeQueuedPrompt) async throws {
        try await sendMessage(sessionID: sessionID, directory: directory, workspace: workspace,
                              model: prompt.model, text: prompt.text, attachments: prompt.attachments, promptID: prompt.id)
    }
}
