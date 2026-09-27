import Foundation

enum OpenCodeSessionAction: String, CaseIterable, Identifiable, Sendable {
    case undo, redo, compact, fork
    var id: String { rawValue }
    var title: String {
        switch self {
        case .undo: "Undo last turn"
        case .redo: "Redo turn"
        case .compact: "Compact conversation"
        case .fork: "Fork conversation"
        }
    }
    var symbol: String {
        switch self {
        case .undo: "arrow.uturn.backward"
        case .redo: "arrow.uturn.forward"
        case .compact: "arrow.down.right.and.arrow.up.left"
        case .fork: "arrow.triangle.branch"
        }
    }
}

struct OpenCodeSessionFeatureSupport: Equatable, Sendable {
    var details = false
    var rename = false
    var delete = false
    var archive = false
    var children = false
    var todoSnapshot = false
    var undo = false
    var redo = false
    var compact = false
    var fork = false
    var compactRequiresModel = false
    var undoIncludesFileChanges = false
    /// The server lists the messages still in the model's context. v1 has no
    /// such route; the transcript's last compaction marks the same boundary.
    var contextWindow = false
    /// Direct shell commands (`!` in OpenCode's composers), never an LLM prompt.
    var shell = false
    /// Publishing a read-only web link (`/share`, `/unshare`).
    var share = false

    static func negotiated(_ context: OpenCodeFeatureContext) -> Self {
        if context.serverProtocol == .v1 {
            return Self(details: true, rename: true, delete: true, archive: true, children: true,
                        todoSnapshot: true, undo: true, redo: true, compact: true,
                        fork: true, compactRequiresModel: true, undoIncludesFileChanges: true, shell: true,
                        share: true)
        }
        // The v2 session API has no publish operation; sharing stays hidden.
        let details = context.supports("/api/session/{sessionID}")
        let inbox = context.supports("/api/session/{sessionID}/inbox")
            && context.supports("/api/session/{sessionID}/inbox/{inboxID}", method: "delete")
        let stage = context.supports("/api/session/{sessionID}/revert/stage", method: "post")
        let commit = context.supports("/api/session/{sessionID}/revert/commit", method: "post")
        return Self(details: details,
                    rename: details && context.supports("/api/session/{sessionID}/rename", method: "post"),
                    delete: context.supports("/api/session/{sessionID}", method: "delete"),
                    children: context.supports("/api/session"),
                    todoSnapshot: false,
                    undo: details && inbox && stage && commit,
                    redo: details && inbox && stage && commit && context.supports("/api/session/{sessionID}/revert/clear", method: "post"),
                    compact: context.supports("/api/session/{sessionID}/compact", method: "post"),
                    fork: context.supports("/api/session/{sessionID}/fork", method: "post"),
                    contextWindow: context.supports("/api/session/{sessionID}/context"),
                    shell: OpenCodeShellDispatch.isSupported(context))
    }
}

struct OpenCodeSessionDetails: Sendable {
    let session: OpenCodeSession
    let revertMessageID: String?
}

struct OpenCodeRestoredPrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: OpenCodeMessageEnvelope
}

struct OpenCodeTodo: Codable, Equatable, Sendable {
    let content: String
    let status: String
    let priority: String?
    var isResolved: Bool { status == "completed" || status == "cancelled" }
    var statusLabel: String { status.replacingOccurrences(of: "_", with: " ").capitalized }
    var symbol: String {
        switch status {
        case "completed": "checkmark.circle.fill"
        case "cancelled": "xmark.circle"
        case "in_progress": "circle.lefthalf.filled"
        default: "circle"
        }
    }
}

struct OpenCodeTodoProgress: Equatable, Sendable {
    // nil means the server has not supplied an authoritative snapshot.
    var items: [OpenCodeTodo]?
    var isStale = false
    var error: String?
    var resolvedCount: Int { items?.filter(\.isResolved).count ?? 0 }
    var totalCount: Int { items?.count ?? 0 }
    var summary: String {
        guard items != nil else { return "Task progress unavailable" }
        guard totalCount > 0 else { return "No tasks reported" }
        return "\(resolvedCount) of \(totalCount) tasks resolved"
    }
}

protocol OpenCodeSessionFeatureServicing: Sendable {
    func sessionFeatureSupport() async throws -> OpenCodeSessionFeatureSupport
    func sessionDetails(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSessionDetails
    func renameSession(sessionID: String, directory: String, workspace: String?, title: String) async throws -> OpenCodeSessionDetails
    func deleteSession(sessionID: String, directory: String, workspace: String?) async throws
    func archiveSession(sessionID: String, directory: String, workspace: String?) async throws
    func childSessions(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeSession]
    func sessionTodos(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeTodo]?
    func stageSessionRevert(sessionID: String, directory: String, workspace: String?, messageID: String) async throws
    func clearSessionRevert(sessionID: String, directory: String, workspace: String?) async throws
    func commitSessionRevert(sessionID: String, directory: String, workspace: String?) async throws -> Bool
    func compactSession(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?) async throws
    func forkSession(sessionID: String, directory: String, workspace: String?, beforeMessageID: String?) async throws -> OpenCodeSession
    /// Messages after the last compaction, or nil when the server cannot say.
    func sessionContextMessages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope]?
    func sessionSharePolicy(directory: String, workspace: String?) async throws -> OpenCodeSessionSharePolicy
    func shareSession(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSession
    func unshareSession(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSession
}

extension OpenCodeSessionFeatureServicing {
    func sessionContextMessages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope]? {
        nil
    }
}

struct OpenCodeSessionFeatureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
