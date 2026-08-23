import Foundation

enum OpenCodeSessionHistoryAction: String, Equatable, Sendable {
    case revert
    case unrevert
    case summarize
    case fork
}

enum OpenCodeSessionHistoryActionAvailability {
    static func canRestore(
        hasRevertedMessages: Bool,
        actionInFlight: OpenCodeSessionHistoryAction?
    ) -> Bool {
        hasRevertedMessages && actionInFlight == nil
    }
}

enum OpenCodeSessionHistoryEventMutation: Equatable, Sendable {
    case staged(OpenCodeSessionHistoryMutation)
    case cleared
    case committed
}

struct OpenCodeSessionRevertTarget: Equatable, Sendable {
    let messageID: String
    let partID: String?
    let files: Bool?

    init(messageID: String, partID: String? = nil, files: Bool? = nil) {
        self.messageID = messageID
        self.partID = partID
        self.files = files
    }
}

struct OpenCodeSessionHistoryMutation: Equatable, Sendable {
    let session: OpenCodeSession?
    let revert: OpenCodeSessionRevertState?
    let diffs: [OpenCodeDiff]?

    init(
        session: OpenCodeSession? = nil,
        revert: OpenCodeSessionRevertState? = nil,
        diffs: [OpenCodeDiff]? = nil
    ) {
        self.session = session
        self.revert = revert
        self.diffs = diffs
    }
}

struct OpenCodeSessionHistoryFileDiff: Codable, Equatable, Sendable {
    let path: String
    let status: String
    let additions: Int
    let deletions: Int
    let patch: String

    var normalized: OpenCodeDiff {
        OpenCodeDiff(
            file: path,
            patch: patch,
            additions: additions,
            deletions: deletions,
            status: status
        )
    }
}

enum OpenCodeSessionHistoryEventProjection {
    static func mutation(from event: OpenCodeEvent) -> OpenCodeSessionHistoryEventMutation? {
        switch event.type {
        case "session.next.revert.staged":
            guard let value = event.properties["revert"],
                  let data = try? JSONEncoder().encode(value),
                  let revert = try? JSONDecoder().decode(EventRevert.self, from: data)
            else { return nil }
            return .staged(
                OpenCodeSessionHistoryMutation(
                    revert: revert.normalized,
                    diffs: revert.files?.map(\.normalized)
                )
            )
        case "session.next.revert.cleared":
            return .cleared
        case "session.next.revert.committed":
            return .committed
        default:
            return nil
        }
    }

    private struct EventRevert: Decodable {
        let messageID: String
        let partID: String?
        let snapshot: String?
        let diff: String?
        let files: [OpenCodeSessionHistoryFileDiff]?

        var normalized: OpenCodeSessionRevertState {
            OpenCodeSessionRevertState(
                messageID: messageID,
                partID: partID,
                snapshot: snapshot,
                diff: diff
            )
        }
    }
}

enum OpenCodeSessionHistoryReconciliation {
    static func keepsBoundaryUntilRefresh(
        for mutation: OpenCodeSessionHistoryEventMutation
    ) -> Bool {
        mutation == .committed
    }

    static func acceptsFetchedSession(
        mutationBaseline: Int,
        currentMutation: Int
    ) -> Bool {
        mutationBaseline == currentMutation
    }

    static func acceptsFetchedSession(
        mutationBaseline: Int,
        currentMutation: Int,
        clearsBoundary: Bool,
        transcriptAccepted: Bool
    ) -> Bool {
        acceptsFetchedSession(
            mutationBaseline: mutationBaseline,
            currentMutation: currentMutation
        ) && (!clearsBoundary || transcriptAccepted)
    }

    static func diffs(
        delivered: [OpenCodeDiff]?,
        current: [OpenCodeDiff],
        capabilities: OpenCodeProtocolCapabilities?
    ) -> [OpenCodeDiff] {
        if let delivered { return delivered }
        return capabilities?.sessionDiff.isSupported == false ? [] : current
    }
}

struct OpenCodeSessionReconciliationVersion: Equatable, Sendable {
    private var value = 0

    mutating func begin() -> Int {
        value &+= 1
        return value
    }

    func accepts(_ request: Int) -> Bool {
        request == value
    }
}

enum OpenCodeSessionHistoryRollbackPolicy {
    struct Preparation: Equatable, Sendable {
        let queueSnapshot: OpenCodePromptQueue.PauseSnapshot
        let requiresRemoteAbort: Bool
    }

    static func prepare(
        status: OpenCodeSessionStatus,
        hasInFlightPrompt: Bool = false,
        queue: inout OpenCodePromptQueue
    ) -> Preparation {
        Preparation(
            queueSnapshot: queue.pausePendingPrompts(),
            requiresRemoteAbort: status.isActive || hasInFlightPrompt
        )
    }

    @discardableResult
    static func restore(
        _ preparation: Preparation,
        remoteAbortSucceeded: Bool = false,
        interruptedPrompt: OpenCodeQueuedPrompt? = nil,
        queue: inout OpenCodePromptQueue
    ) -> OpenCodeQueuedPrompt? {
        if remoteAbortSucceeded {
            if let interruptedPrompt {
                queue.dispatchFailed(interruptedPrompt, requeue: true)
            }
            return queue.resumePendingPromptsAfterCompletedInterruption()
        }
        return queue.restorePendingPrompts(after: preparation.queueSnapshot)
    }
}

struct OpenCodeSessionHistoryPolicy: Equatable, Sendable {
    let canRevert: Bool
    let canUnrevert: Bool
    let canSummarize: Bool
    let canFork: Bool
    let summarizeRequiresModel: Bool

    init(capabilities: OpenCodeProtocolCapabilities) {
        canRevert = capabilities.sessionRevert.isSupported
        canUnrevert = capabilities.sessionUnrevert.isSupported
        canSummarize = capabilities.sessionSummarize.isSupported
        canFork = capabilities.sessionFork.isSupported
        summarizeRequiresModel = capabilities.sessionSummarizeRequiresModel
    }
}

enum OpenCodeSessionHistoryRefreshScope: Equatable, Sendable {
    case messages
    case session
}

struct OpenCodeSessionHistoryContinuationPolicy: Equatable, Sendable {
    static func refreshScope(
        requested: OpenCodeSessionHistoryRefreshScope,
        revert: OpenCodeSessionRevertState?
    ) -> OpenCodeSessionHistoryRefreshScope {
        revert == nil ? requested : .session
    }
}

struct OpenCodeSessionHistoryProjection: Equatable, Sendable {
    private var revertMessageID: String?
    private var capturedVisibleMessageIDs: Set<String>?
    private var capturedRevertedUserMessageIDs: Set<String>?

    mutating func reconcile(
        messages: [OpenCodeMessageEnvelope],
        revert: OpenCodeSessionRevertState?
    ) {
        guard let messageID = revert?.messageID else {
            revertMessageID = nil
            capturedVisibleMessageIDs = nil
            capturedRevertedUserMessageIDs = nil
            return
        }
        if revertMessageID != messageID {
            revertMessageID = messageID
            capturedVisibleMessageIDs = nil
            capturedRevertedUserMessageIDs = nil
        }
        guard let boundary = messages.firstIndex(where: { $0.id == messageID }) else {
            return
        }
        capturedVisibleMessageIDs = Set(messages[..<boundary].map(\.id))
        capturedRevertedUserMessageIDs = Set(
            messages[boundary...]
                .filter { $0.info.role.lowercased() == "user" }
                .map(\.id)
        )
    }

    func visibleMessages(
        in messages: [OpenCodeMessageEnvelope],
        revert: OpenCodeSessionRevertState?
    ) -> [OpenCodeMessageEnvelope] {
        guard let messageID = revert?.messageID else { return messages }
        if let boundary = messages.firstIndex(where: { $0.id == messageID }) {
            return Array(messages[..<boundary])
        }
        guard revertMessageID == messageID,
              let capturedVisibleMessageIDs
        else { return [] }
        return messages.filter { capturedVisibleMessageIDs.contains($0.id) }
    }

    func revertedUserMessages(
        in messages: [OpenCodeMessageEnvelope],
        revert: OpenCodeSessionRevertState?
    ) -> [OpenCodeMessageEnvelope] {
        guard let messageID = revert?.messageID else { return [] }
        let userMessages = messages.filter { $0.info.role.lowercased() == "user" }
        if let boundary = userMessages.firstIndex(where: { $0.id == messageID }) {
            return Array(userMessages[boundary...])
        }
        guard revertMessageID == messageID,
              let capturedRevertedUserMessageIDs
        else { return [] }
        return userMessages.filter { capturedRevertedUserMessageIDs.contains($0.id) }
    }
}

struct OpenCodeSessionHistoryPresentation: Equatable, Sendable {
    let messages: [OpenCodeMessageEnvelope]
    let revert: OpenCodeSessionRevertState?
    let capabilities: OpenCodeProtocolCapabilities?
    private let projection: OpenCodeSessionHistoryProjection

    init(
        messages: [OpenCodeMessageEnvelope],
        revert: OpenCodeSessionRevertState?,
        capabilities: OpenCodeProtocolCapabilities?,
        projection: OpenCodeSessionHistoryProjection = .init()
    ) {
        self.messages = messages
        self.revert = revert
        self.capabilities = capabilities
        var projection = projection
        projection.reconcile(messages: messages, revert: revert)
        self.projection = projection
    }

    var policy: OpenCodeSessionHistoryPolicy? {
        capabilities.map(OpenCodeSessionHistoryPolicy.init)
    }

    var userMessages: [OpenCodeMessageEnvelope] {
        messages.filter { $0.info.role.lowercased() == "user" }
    }

    var visibleMessages: [OpenCodeMessageEnvelope] {
        projection.visibleMessages(in: messages, revert: revert)
    }

    var visibleUserMessages: [OpenCodeMessageEnvelope] {
        visibleMessages.filter { $0.info.role.lowercased() == "user" }
    }

    var revertedUserMessages: [OpenCodeMessageEnvelope] {
        projection.revertedUserMessages(in: messages, revert: revert)
    }

    var latestRevertTarget: OpenCodeSessionRevertTarget? {
        visibleUserMessages.last.map { revertTarget(messageID: $0.id) }
    }

    func revertTarget(messageID: String) -> OpenCodeSessionRevertTarget {
        OpenCodeSessionRevertTarget(messageID: messageID, files: true)
    }

    var latestForkMessageID: String? {
        visibleUserMessages.last?.id
    }

    var canRestore: Bool {
        revert != nil && policy?.canUnrevert == true
    }
}

extension OpenCodeMessageEnvelope {
    var historyPreview: String {
        let text = parts
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined(separator: " ")
        return text
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

enum OpenCodeSessionHistoryError: LocalizedError, Equatable, Sendable {
    case modelRequired

    var errorDescription: String? {
        switch self {
        case .modelRequired:
            "Choose a model before compacting this OpenCode v1 session."
        }
    }
}
