import Foundation

struct OpenCodePromptQueue: Equatable, Sendable {
    private enum TurnPhase: Equatable, Sendable {
        case idle
        case submitting(observedActive: Bool, observedCompletion: Bool)
        case awaitingActivity
        case active
        case paused
    }

    private(set) var prompts: [OpenCodeQueuedPrompt] = []
    private var phase: TurnPhase = .idle
    private var pauseAfterCurrentTurn = false

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
        return switch phase {
        case .awaitingActivity: true
        case .active: prompts.isEmpty == false
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

    mutating func beginExplicitDispatch(
        text: String,
        model: OpenCodeModelOption?,
        attachments: [OpenCodePromptAttachment] = [],
        id: UUID = UUID()
    ) -> OpenCodeQueuedPrompt? {
        guard phase == .idle || phase == .paused else { return nil }
        let prompt = OpenCodeQueuedPrompt(
            id: id,
            text: text,
            model: model,
            attachments: attachments
        )
        pauseAfterCurrentTurn = phase == .paused && prompts.isEmpty == false
        phase = .submitting(observedActive: false, observedCompletion: false)
        return prompt
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
        case .idle, .awaitingActivity, .active, .paused:
            return nil
        }
    }

    mutating func dispatchFailed(
        _ prompt: OpenCodeQueuedPrompt,
        requeue: Bool
    ) {
        pauseAfterCurrentTurn = false
        if requeue, !prompts.contains(where: { $0.id == prompt.id }) {
            prompts.insert(prompt, at: 0)
        }
        phase = prompts.isEmpty ? .idle : .paused
    }

    mutating func retry(_ id: UUID) -> OpenCodeQueuedPrompt? {
        guard phase == .paused, prompts.first?.id == id else { return nil }
        pauseAfterCurrentTurn = false
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
        pauseAfterCurrentTurn = false
        phase = prompts.isEmpty ? .idle : .paused
    }

    mutating func pausePendingPrompts() {
        pauseAfterCurrentTurn = false
        phase = prompts.isEmpty ? .idle : .paused
    }

    private mutating func takeNextOrBecomeIdle() -> OpenCodeQueuedPrompt? {
        if pauseAfterCurrentTurn {
            pauseAfterCurrentTurn = false
            phase = prompts.isEmpty ? .idle : .paused
            return nil
        }
        guard !prompts.isEmpty else {
            phase = .idle
            return nil
        }
        phase = .submitting(observedActive: false, observedCompletion: false)
        return prompts.removeFirst()
    }
}
