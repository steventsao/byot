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
    var children = false
    var todoSnapshot = false
    var undo = false
    var redo = false
    var compact = false
    var fork = false
    var compactRequiresModel = false
    var undoIncludesFileChanges = false

    static func negotiated(_ context: OpenCodeFeatureContext) -> Self {
        if context.serverProtocol == .v1 {
            return Self(details: true, rename: true, delete: true, children: true,
                        todoSnapshot: true, undo: true, redo: true, compact: true,
                        fork: true, compactRequiresModel: true, undoIncludesFileChanges: true)
        }
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
                    fork: context.supports("/api/session/{sessionID}/fork", method: "post"))
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
    func childSessions(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeSession]
    func sessionTodos(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeTodo]?
    func stageSessionRevert(sessionID: String, directory: String, workspace: String?, messageID: String) async throws
    func clearSessionRevert(sessionID: String, directory: String, workspace: String?) async throws
    func commitSessionRevert(sessionID: String, directory: String, workspace: String?) async throws -> Bool
    func compactSession(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?) async throws
    func forkSession(sessionID: String, directory: String, workspace: String?, beforeMessageID: String?) async throws -> OpenCodeSession
}

struct OpenCodeSessionFeatureError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
