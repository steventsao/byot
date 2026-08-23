import Foundation

struct OpenCodePromptQueue: Equatable, Sendable {
    fileprivate enum TurnPhase: Equatable, Sendable {
        case idle
        case submitting(observedActive: Bool, observedCompletion: Bool)
        case awaitingActivity
        case active
        case paused
    }

    struct PauseSnapshot: Equatable, Sendable {
        fileprivate let phase: TurnPhase

        fileprivate init(phase: TurnPhase) {
            self.phase = phase
        }
    }

    private enum PausedSubmissionResult: Equatable, Sendable {
        case none
        case succeeded
        case failed
    }

    private(set) var prompts: [OpenCodeQueuedPrompt] = []
    private var phase: TurnPhase = .idle
    private var pausedSubmissionResult = PausedSubmissionResult.none

    var isTurnActive: Bool {
        switch phase {
        case .submitting, .awaitingActivity, .active: true
        case .idle, .paused: false
        }
    }

    var isPaused: Bool {
        phase == .paused
    }

    var shouldQueueNextPrompt: Bool {
        isTurnActive || !prompts.isEmpty
    }

    var hasObservedServerActivity: Bool {
        switch phase {
        case .submitting(let observedActive, _): observedActive
        case .active: true
        case .idle, .awaitingActivity, .paused: false
        }
    }

    var needsServerReconciliation: Bool {
        guard !prompts.isEmpty else { return false }
        return switch phase {
        case .awaitingActivity, .active: true
        case .idle, .submitting, .paused: false
        }
    }

    var isAwaitingActivity: Bool {
        phase == .awaitingActivity
    }

    mutating func accept(
        text: String,
        model: OpenCodeModelOption?,
        attachments: [OpenCodePromptAttachment] = [],
        serverIsActive: Bool,
        id: UUID = UUID()
    ) -> OpenCodePromptSubmission {
        let prompt = OpenCodeQueuedPrompt(
            id: id,
            text: text,
            model: model,
            attachments: attachments
        )
        if phase == .idle, serverIsActive {
            phase = .active
        }
        guard phase == .idle, prompts.isEmpty else {
            prompts.append(prompt)
            return .queued(prompt)
        }
        phase = .submitting(observedActive: false, observedCompletion: false)
        return .dispatch(prompt)
    }

    mutating func serverBecameActive() {
        switch phase {
        case .submitting(_, let observedCompletion):
            phase = .submitting(
                observedActive: true,
                observedCompletion: observedCompletion
            )
        case .idle, .awaitingActivity, .active:
            phase = .active
        case .paused:
            break
        }
    }

    mutating func serverBecameIdle() -> OpenCodeQueuedPrompt? {
        switch phase {
        case .idle, .awaitingActivity, .paused:
            return nil
        case .submitting(let observedActive, _):
            guard observedActive else { return nil }
            phase = .submitting(observedActive: true, observedCompletion: true)
            return nil
        case .active:
            return takeNextOrBecomeIdle()
        }
    }

    mutating func reconciledServerIdle() -> OpenCodeQueuedPrompt? {
        switch phase {
        case .idle, .awaitingActivity, .paused:
            return nil
        case .submitting(let observedActive, _):
            guard observedActive else { return nil }
            phase = .submitting(observedActive: true, observedCompletion: true)
            return nil
        case .active:
            return takeNextOrBecomeIdle()
        }
    }

    mutating func dispatchSucceeded() -> OpenCodeQueuedPrompt? {
        switch phase {
        case .submitting(let observedActive, let observedCompletion):
            if observedActive, observedCompletion {
                return takeNextOrBecomeIdle()
            }
            phase = observedActive ? .active : .awaitingActivity
            return nil
        case .paused:
            pausedSubmissionResult = .succeeded
            return nil
        case .idle, .awaitingActivity, .active:
            return nil
        }
    }

    mutating func dispatchFailed(
        _ prompt: OpenCodeQueuedPrompt,
        requeue: Bool
    ) {
        let failedWhilePaused = phase == .paused
        if requeue, !prompts.contains(where: { $0.id == prompt.id }) {
            prompts.insert(prompt, at: 0)
        }
        if failedWhilePaused {
            phase = .paused
            pausedSubmissionResult = .failed
        } else {
            phase = prompts.isEmpty ? .idle : .paused
            pausedSubmissionResult = .none
        }
    }

    mutating func retry(_ id: UUID) -> OpenCodeQueuedPrompt? {
        guard phase == .paused, prompts.first?.id == id else { return nil }
        phase = .submitting(observedActive: false, observedCompletion: false)
        return prompts.removeFirst()
    }

    mutating func remove(_ id: UUID) {
        prompts.removeAll { $0.id == id }
        if phase == .paused, prompts.isEmpty {
            phase = .idle
        }
    }

    mutating func pauseAwaitingActivity() {
        guard phase == .awaitingActivity else { return }
        phase = prompts.isEmpty ? .idle : .paused
    }

    mutating func pausePendingPrompts() -> PauseSnapshot {
        let snapshot = PauseSnapshot(phase: phase)
        phase = prompts.isEmpty ? .idle : .paused
        pausedSubmissionResult = .none
        return snapshot
    }

    @discardableResult
    mutating func restorePendingPrompts(
        after snapshot: PauseSnapshot
    ) -> OpenCodeQueuedPrompt? {
        guard phase == .paused else { return nil }
        let submissionResult = pausedSubmissionResult
        pausedSubmissionResult = .none
        guard case .submitting = snapshot.phase else {
            phase = snapshot.phase
            return nil
        }
        switch submissionResult {
        case .none:
            phase = snapshot.phase
            return nil
        case .succeeded:
            phase = snapshot.phase
            return dispatchSucceeded()
        case .failed:
            phase = prompts.isEmpty ? .idle : .paused
            return nil
        }
    }

    private mutating func takeNextOrBecomeIdle() -> OpenCodeQueuedPrompt? {
        guard !prompts.isEmpty else {
            phase = .idle
            return nil
        }
        phase = .submitting(observedActive: false, observedCompletion: false)
        return prompts.removeFirst()
    }
}
