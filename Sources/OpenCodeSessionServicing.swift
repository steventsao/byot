import Foundation

protocol OpenCodeSessionBrowsing: Sendable {
    func listSessions(directory: String) async throws -> [OpenCodeSession]
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String:
        OpenCodeSessionStatus]
    /// Pending permission/question request IDs by the session that asked, for
    /// every session in `directory`; nil where requests are listed per session.
    func pendingInputRequests(directory: String) async throws -> [String: Set<String>]?
    /// One session's pending request IDs; nil where requests are listed per directory.
    func pendingInputRequests(sessionID: String) async throws -> Set<String>?
    /// The conversation a subagent session belongs to, or nil for a top-level session.
    func parentSessionID(of sessionID: String, directory: String?) async throws -> String?
    /// The session list's single server-wide event stream.
    func sessionListEvents() -> AsyncThrowingStream<OpenCodeEvent, Error>
}

// Services without live list support (fixtures, older harnesses) poll: no
// pending-input snapshot and a stream that reports the route as unsupported.
extension OpenCodeSessionBrowsing {
    func pendingInputRequests(directory: String) async throws -> [String: Set<String>]? { nil }
    func pendingInputRequests(sessionID: String) async throws -> Set<String>? { nil }
    func parentSessionID(of sessionID: String, directory: String?) async throws -> String? { nil }
    func sessionListEvents() -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: OpenCodeConnectionError.httpStatus(404, nil)) }
    }
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
