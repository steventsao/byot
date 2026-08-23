import Foundation

struct OpenCodeSessionLifecycleState: Equatable, Sendable {
    private(set) var sessions: [OpenCodeSession]
    private(set) var statuses: [String: OpenCodeSessionStatus]

    init(
        sessions: [OpenCodeSession] = [],
        statuses: [String: OpenCodeSessionStatus] = [:]
    ) {
        self.sessions = sessions.sorted { $0.time.updated > $1.time.updated }
        self.statuses = statuses
    }

    mutating func replace(
        sessions: [OpenCodeSession],
        statuses: [String: OpenCodeSessionStatus]
    ) {
        self.sessions = sessions.sorted { $0.time.updated > $1.time.updated }
        self.statuses = statuses
    }

    mutating func upsert(_ session: OpenCodeSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        sessions.sort { $0.time.updated > $1.time.updated }
        if statuses[session.id] == nil {
            statuses[session.id] = .idle
        }
    }

    mutating func remove(sessionID: String) {
        sessions.removeAll { $0.id == sessionID }
        statuses.removeValue(forKey: sessionID)
    }
}

struct OpenCodeSessionLifecyclePolicy: Equatable, Sendable {
    let capabilities: OpenCodeProtocolCapabilities

    var canRename: Bool { capabilities.sessionRename.isSupported }
    var canDelete: Bool { capabilities.sessionDelete.isSupported }
    var canListChildren: Bool { capabilities.sessionChildren.isSupported }
    var canAbort: Bool { capabilities.sessionAbort.isSupported }
}

struct OpenCodeSessionLifecycleRequestVersion: Equatable, Sendable {
    private var value = 0

    mutating func beginLoad() -> Int {
        value &+= 1
        return value
    }

    mutating func beginMutation() {
        value &+= 1
    }

    func accepts(load: Int) -> Bool {
        load == value
    }
}

enum OpenCodeSessionAbortPolicy {
    static func canRequest(
        status: OpenCodeSessionStatus,
        isRequesting: Bool
    ) -> Bool {
        status.isActive && !isRequesting
    }

    static func prepareQueueForRequest(
        _ queue: inout OpenCodePromptQueue
    ) -> OpenCodePromptQueue.PauseSnapshot {
        queue.pausePendingPrompts()
    }

    @discardableResult
    static func restoreQueueAfterFailedRequest(
        _ queue: inout OpenCodePromptQueue,
        snapshot: OpenCodePromptQueue.PauseSnapshot
    ) -> OpenCodeQueuedPrompt? {
        queue.restorePendingPrompts(after: snapshot)
    }

    static func shouldRestoreQueue(
        isRunning: Bool,
        requestGeneration: Int,
        currentGeneration: Int
    ) -> Bool {
        isRunning && requestGeneration == currentGeneration
    }
}
