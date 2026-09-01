import Foundation
import Testing
@testable import byot

struct OpenCodePromptQueueTests {
    @Test("Follow-ups wait for each active turn and preserve FIFO order")
    func followUpsWaitForIdleInFIFOOrder() throws {
        var queue = OpenCodePromptQueue()
        let firstID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        )
        let secondID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")
        )
        let thirdID = try #require(
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")
        )

        let first = queue.accept(
            text: "First",
            model: nil,
            serverIsActive: false,
            id: firstID
        )
        let second = queue.accept(
            text: "Second",
            model: nil,
            serverIsActive: true,
            id: secondID
        )
        let third = queue.accept(
            text: "Third",
            model: nil,
            serverIsActive: true,
            id: thirdID
        )

        #expect(first == .dispatch(OpenCodeQueuedPrompt(id: firstID, text: "First", model: nil)))
        #expect(second == .queued(OpenCodeQueuedPrompt(id: secondID, text: "Second", model: nil)))
        #expect(third == .queued(OpenCodeQueuedPrompt(id: thirdID, text: "Third", model: nil)))
        #expect(queue.prompts.map(\.text) == ["Second", "Third"])

        #expect(queue.dispatchSucceeded() == nil)
        queue.serverBecameActive()
        #expect(queue.serverBecameIdle()?.text == "Second")
        #expect(queue.prompts.map(\.text) == ["Third"])

        #expect(queue.dispatchSucceeded() == nil)
        queue.serverBecameActive()
        #expect(queue.serverBecameIdle()?.text == "Third")
        #expect(queue.dispatchSucceeded() == nil)
        queue.serverBecameActive()
        #expect(queue.serverBecameIdle() == nil)
        #expect(queue.isTurnActive == false)
        #expect(queue.prompts.isEmpty)
    }

    @Test("A follow-up submitted to an already-working server waits for idle")
    func busyServerQueuesFollowUp() {
        var queue = OpenCodePromptQueue()
        let result = queue.accept(
            text: "Follow up",
            model: nil,
            serverIsActive: true
        )

        #expect(result.queuedPrompt?.text == "Follow up")
        #expect(queue.serverBecameIdle()?.text == "Follow up")
        #expect(queue.prompts.isEmpty)
    }

    @Test("Idle before a new active signal cannot double-dispatch the queue")
    func duplicateIdleDuringSubmissionIsIgnored() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "First", model: nil, serverIsActive: false)
        _ = queue.accept(text: "Second", model: nil, serverIsActive: false)

        #expect(queue.serverBecameIdle() == nil)
        #expect(queue.dispatchSucceeded() == nil)
        #expect(queue.serverBecameIdle() == nil)
        queue.serverBecameActive()
        #expect(queue.serverBecameIdle()?.text == "Second")
        #expect(queue.prompts.isEmpty)
    }

    @Test("Idle reconciliation cannot release an unconfirmed async prompt")
    func reconciledIdleWaitsForConfirmedActivity() throws {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "First", model: nil, serverIsActive: false)
        _ = queue.accept(text: "Second", model: nil, serverIsActive: true)

        #expect(queue.dispatchSucceeded() == nil)
        #expect(queue.serverBecameIdle() == nil)
        #expect(queue.reconciledServerIdle() == nil)
        #expect(queue.prompts.map(\.text) == ["Second"])

        queue.pauseAwaitingActivity()
        let queued = try #require(queue.prompts.first)
        #expect(queue.isPaused)
        #expect(queue.retry(queued.id)?.text == "Second")
    }

    @Test("Authoritative idle releases a turn whose activity was confirmed")
    func reconciledIdleReleasesConfirmedActivity() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "First", model: nil, serverIsActive: false)
        _ = queue.accept(text: "Second", model: nil, serverIsActive: true)

        queue.serverBecameActive()
        #expect(queue.dispatchSucceeded() == nil)
        #expect(queue.reconciledServerIdle()?.text == "Second")
        #expect(queue.prompts.isEmpty)
    }

    @Test("A turn that becomes active and idle during its POST drains after success")
    func completedTurnDuringSubmissionDrainsAfterResponse() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "First", model: nil, serverIsActive: false)
        _ = queue.accept(text: "Second", model: nil, serverIsActive: false)

        queue.serverBecameActive()
        #expect(queue.serverBecameIdle() == nil)
        #expect(queue.dispatchSucceeded()?.text == "Second")
        #expect(queue.prompts.isEmpty)
    }

    @Test("A follow-up during a completed POST preserves the pending completion")
    func followUpDuringCompletedSubmissionDrainsAfterResponse() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "First", model: nil, serverIsActive: false)

        queue.serverBecameActive()
        #expect(queue.serverBecameIdle() == nil)
        let followUp = queue.accept(
            text: "Second",
            model: nil,
            serverIsActive: true
        )

        #expect(followUp.queuedPrompt?.text == "Second")
        #expect(queue.dispatchSucceeded()?.text == "Second")
        #expect(queue.prompts.isEmpty)
    }

    @Test("A failed queued dispatch stays first and can be retried")
    func failedQueuedDispatchCanRetry() throws {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "First", model: nil, serverIsActive: true)
        let nextPrompt = queue.serverBecameIdle()
        let queued = try #require(nextPrompt)

        queue.dispatchFailed(queued, requeue: true)

        #expect(queue.isPaused)
        #expect(queue.prompts.map(\.text) == ["First"])
        #expect(queue.retry(queued.id) == queued)
        #expect(queue.prompts.isEmpty)
        #expect(queue.isTurnActive)
    }

    @Test("Delayed server activity cannot auto-send an ambiguously failed prompt")
    func delayedActivityAfterFailureStaysPaused() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "First", model: nil, serverIsActive: true)
        let prompt = queue.serverBecameIdle()
        guard let prompt else {
            Issue.record("Expected the queued prompt to become dispatchable")
            return
        }

        queue.dispatchFailed(prompt, requeue: true)
        queue.serverBecameActive()

        #expect(queue.serverBecameIdle() == nil)
        #expect(queue.isPaused)
        #expect(queue.prompts == [prompt])
    }

    @Test("The queue distinguishes optimistic submission from confirmed server work")
    func observedServerActivity() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "First", model: nil, serverIsActive: false)

        #expect(queue.hasObservedServerActivity == false)
        queue.serverBecameActive()
        #expect(queue.hasObservedServerActivity)
    }

    @Test("Queued prompts retain the model selected when they were submitted")
    func queuedPromptCapturesModel() throws {
        var queue = OpenCodePromptQueue()
        let model = OpenCodeModelOption(
            providerID: "kimi-for-coding",
            providerName: "Kimi For Coding",
            modelID: "k3",
            modelName: "Kimi K3",
            status: "active"
        )

        let result = queue.accept(
            text: "Use Kimi",
            model: model,
            serverIsActive: true
        )
        let prompt = try #require(result.queuedPrompt)

        #expect(prompt.model == model)
    }

    @Test("An explicit recovery dispatch stays ahead of paused follow-ups")
    func recoveredPromptPreservesPausedFollowUps() throws {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "Follow-up one", model: nil, serverIsActive: true)
        _ = queue.accept(text: "Follow-up two", model: nil, serverIsActive: true)
        queue.pausePendingPrompts()

        let pendingRecovered = queue.beginExplicitDispatch(
            text: "Recovered",
            model: nil
        )
        let recovered = try #require(pendingRecovered)

        #expect(recovered.text == "Recovered")
        #expect(queue.prompts.map(\.text) == ["Follow-up one", "Follow-up two"])
        queue.serverBecameActive()
        #expect(queue.dispatchSucceeded() == nil)
        #expect(queue.serverBecameIdle() == nil)
        #expect(queue.isPaused)
        #expect(queue.prompts.map(\.text) == ["Follow-up one", "Follow-up two"])
    }

    @Test("A failed recovery dispatch is requeued before paused follow-ups")
    func failedRecoveredPromptIsFirst() throws {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "Follow-up", model: nil, serverIsActive: true)
        queue.pausePendingPrompts()
        let pendingRecovered = queue.beginExplicitDispatch(
            text: "Recovered",
            model: nil
        )
        let recovered = try #require(pendingRecovered)

        queue.dispatchFailed(recovered, requeue: true)

        #expect(queue.isPaused)
        #expect(queue.prompts.map(\.text) == ["Recovered", "Follow-up"])
    }

    @Test("A direct async prompt reconciles even without queued follow-ups")
    func awaitingActivityAlwaysNeedsReconciliation() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "Only prompt", model: nil, serverIsActive: false)
        #expect(queue.dispatchSucceeded() == nil)

        #expect(queue.isAwaitingActivity)
        #expect(queue.prompts.isEmpty)
        #expect(queue.needsServerReconciliation)
    }
}

private extension OpenCodePromptSubmission {
    var queuedPrompt: OpenCodeQueuedPrompt? {
        guard case .queued(let prompt) = self else { return nil }
        return prompt
    }
}
