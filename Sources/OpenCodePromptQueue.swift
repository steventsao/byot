import Foundation

struct OpenCodePromptQueue: Equatable, Sendable {
    fileprivate enum TurnPhase: Equatable, Sendable {
        case idle
        case submitting(observedActive: Bool, observedCompletion: Bool)
        case awaitingActivity
        case awaitingSynchronousIdle
        case active
        case paused
    }

    struct PauseSnapshot: Equatable, Sendable {
        fileprivate let phase: TurnPhase

        fileprivate init(phase: TurnPhase) {
            self.phase = phase
        }
    }

    private(set) var prompts: [OpenCodeQueuedPrompt] = []
    private var phase: TurnPhase = .idle
    private var pausedResumePhase: TurnPhase?
    private var pausedShouldAdvance = false
    private var pausedSubmissionFailed = false

    var isTurnActive: Bool {
        switch phase {
        case .submitting, .awaitingActivity, .awaitingSynchronousIdle, .active: true
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
        case .idle, .awaitingActivity, .awaitingSynchronousIdle, .paused: false
        }
    }

    var needsServerReconciliation: Bool {
        guard !prompts.isEmpty else { return false }
        return switch phase {
        case .awaitingActivity, .awaitingSynchronousIdle, .active: true
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
        accept(
            intent: .prompt(text),
            model: model,
            agent: nil,
            attachments: attachments,
            serverIsActive: serverIsActive,
            id: id
        )
    }

    mutating func accept(
        intent: OpenCodeSessionInputIntent,
        model: OpenCodeModelOption?,
        agent: String?,
        attachments: [OpenCodePromptAttachment] = [],
        serverIsActive: Bool,
        id: UUID = UUID()
    ) -> OpenCodePromptSubmission {
        let prompt = OpenCodeQueuedPrompt(
            id: id,
            intent: intent,
            model: model,
            agent: agent,
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
        case .idle, .awaitingActivity, .awaitingSynchronousIdle, .active:
            phase = .active
        case .paused:
            recordPausedServerActive()
        }
    }

    mutating func serverBecameIdle() -> OpenCodeQueuedPrompt? {
        switch phase {
        case .idle, .awaitingActivity:
            return nil
        case .paused:
            recordPausedServerIdle()
            return nil
        case .awaitingSynchronousIdle:
            return takeNextOrBecomeIdle()
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
        case .idle, .awaitingActivity:
            return nil
        case .paused:
            recordPausedServerIdle()
            return nil
        case .awaitingSynchronousIdle:
            return takeNextOrBecomeIdle()
        case .submitting(let observedActive, _):
            guard observedActive else { return nil }
            phase = .submitting(observedActive: true, observedCompletion: true)
            return nil
        case .active:
            return takeNextOrBecomeIdle()
        }
    }

    mutating func dispatchSucceeded(
        completesSynchronously: Bool = false
    ) -> OpenCodeQueuedPrompt? {
        switch phase {
        case .submitting(let observedActive, let observedCompletion):
            if completesSynchronously {
                if observedActive, observedCompletion {
                    return takeNextOrBecomeIdle()
                }
                if prompts.isEmpty {
                    phase = .idle
                } else {
                    phase = .awaitingSynchronousIdle
                }
                return nil
            }
            if observedActive, observedCompletion {
                return takeNextOrBecomeIdle()
            }
            phase = observedActive ? .active : .awaitingActivity
            return nil
        case .paused:
            recordPausedDispatchSucceeded()
            return nil
        case .idle, .awaitingActivity, .awaitingSynchronousIdle, .active:
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
            pausedResumePhase = .paused
            pausedShouldAdvance = false
            pausedSubmissionFailed = true
        } else {
            phase = prompts.isEmpty ? .idle : .paused
            resetPausedTransition()
        }
    }

    mutating func retry(_ id: UUID) -> OpenCodeQueuedPrompt? {
        guard phase == .paused, prompts.first?.id == id else { return nil }
        phase = .submitting(observedActive: false, observedCompletion: false)
        resetPausedTransition()
        return prompts.removeFirst()
    }

    mutating func remove(_ id: UUID) {
        prompts.removeAll { $0.id == id }
        guard prompts.isEmpty else { return }
        switch phase {
        case .paused, .awaitingSynchronousIdle:
            phase = .idle
            resetPausedTransition()
        case .idle, .submitting, .awaitingActivity, .active:
            break
        }
    }

    mutating func pauseAwaitingActivity() {
        guard phase == .awaitingActivity else { return }
        phase = prompts.isEmpty ? .idle : .paused
    }

    mutating func pausePendingPrompts() -> PauseSnapshot {
        let snapshot = PauseSnapshot(phase: phase)
        phase = prompts.isEmpty ? .idle : .paused
        pausedResumePhase = phase == .paused ? snapshot.phase : nil
        pausedShouldAdvance = false
        pausedSubmissionFailed = false
        return snapshot
    }

    @discardableResult
    mutating func restorePendingPrompts(
        after snapshot: PauseSnapshot
    ) -> OpenCodeQueuedPrompt? {
        guard phase == .paused else { return nil }
        let resumePhase = pausedResumePhase ?? snapshot.phase
        let shouldAdvance = pausedShouldAdvance
        let submissionFailed = pausedSubmissionFailed
        resetPausedTransition()
        if submissionFailed {
            phase = prompts.isEmpty ? .idle : .paused
            return nil
        }
        if shouldAdvance {
            phase = .active
            return takeNextOrBecomeIdle()
        }
        phase = resumePhase
        return nil
    }

    private mutating func recordPausedServerActive() {
        guard !pausedSubmissionFailed, !pausedShouldAdvance else { return }
        switch pausedResumePhase {
        case .submitting(_, let observedCompletion):
            pausedResumePhase = .submitting(
                observedActive: true,
                observedCompletion: observedCompletion
            )
        case .idle, .awaitingActivity, .active:
            pausedResumePhase = .active
        case .paused, nil:
            break
        }
    }

    private mutating func recordPausedServerIdle() {
        guard !pausedSubmissionFailed, !pausedShouldAdvance else { return }
        switch pausedResumePhase {
        case .submitting(let observedActive, _):
            guard observedActive else { return }
            pausedResumePhase = .submitting(
                observedActive: true,
                observedCompletion: true
            )
        case .active:
            pausedShouldAdvance = true
        case .idle, .awaitingActivity, .paused, nil:
            break
        }
    }

    private mutating func recordPausedDispatchSucceeded() {
        guard !pausedSubmissionFailed, !pausedShouldAdvance else { return }
        guard case .submitting(let observedActive, let observedCompletion) = pausedResumePhase
        else { return }
        if observedActive, observedCompletion {
            pausedShouldAdvance = true
        } else {
            pausedResumePhase = observedActive ? .active : .awaitingActivity
        }
    }

    private mutating func resetPausedTransition() {
        pausedResumePhase = nil
        pausedShouldAdvance = false
        pausedSubmissionFailed = false
    }

    mutating func resumePendingPromptsAfterCompletedInterruption() -> OpenCodeQueuedPrompt? {
        guard phase == .paused else { return nil }
        resetPausedTransition()
        phase = .active
        return takeNextOrBecomeIdle()
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
