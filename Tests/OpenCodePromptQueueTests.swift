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

    @Test("A submission completed during a pending stop restores as awaiting activity")
    func completedSubmissionDuringPauseDoesNotRestoreSubmitting() throws {
        var queue = OpenCodePromptQueue()
        let first = try #require(
            queue.accept(
                text: "First",
                model: nil,
                serverIsActive: false
            ).dispatchedPrompt
        )
        _ = queue.accept(text: "Second", model: nil, serverIsActive: false)
        let snapshot = queue.pausePendingPrompts()

        #expect(queue.dispatchSucceeded() == nil)
        _ = first
        queue.restorePendingPrompts(after: snapshot)

        #expect(queue.isTurnActive)
        #expect(queue.needsServerReconciliation)
        #expect(queue.prompts.map(\.text) == ["Second"])
    }

    @Test("Server activity completed during a pending stop drains after restoration")
    func completedActivityDuringPauseDrainsOnRestore() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(text: "First", model: nil, serverIsActive: false)
        _ = queue.accept(text: "Second", model: nil, serverIsActive: false)
        let snapshot = queue.pausePendingPrompts()

        #expect(queue.dispatchSucceeded() == nil)
        queue.serverBecameActive()
        #expect(queue.serverBecameIdle() == nil)
        let next = queue.restorePendingPrompts(after: snapshot)

        #expect(next?.text == "Second")
        #expect(queue.prompts.isEmpty)
        #expect(queue.isTurnActive)
    }

    @Test("A submission failed during a pending stop stays safely paused")
    func failedSubmissionDuringPauseStaysPaused() throws {
        var queue = OpenCodePromptQueue()
        let first = try #require(
            queue.accept(
                text: "First",
                model: nil,
                serverIsActive: false
            ).dispatchedPrompt
        )
        _ = queue.accept(text: "Second", model: nil, serverIsActive: false)
        let snapshot = queue.pausePendingPrompts()

        queue.dispatchFailed(first, requeue: true)
        queue.restorePendingPrompts(after: snapshot)

        #expect(queue.isPaused)
        #expect(queue.prompts.map(\.text) == ["First", "Second"])
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

    @Test("Queued prompts retain attachments and agent for later dispatch and retry")
    func queuedPromptCapturesAttachmentsAndAgent() throws {
        var queue = OpenCodePromptQueue()
        let attachment = OpenCodePromptAttachment(
            filename: "design.png",
            mimeType: "image/png",
            data: Data([0x01, 0x02, 0x03])
        )

        let result = queue.accept(
            intent: .prompt(""),
            model: nil,
            agent: "build",
            attachments: [attachment],
            serverIsActive: true
        )
        let prompt = try #require(result.queuedPrompt)

        #expect(prompt.text.isEmpty)
        #expect(prompt.agent == "build")
        #expect(prompt.attachments == [attachment])
        #expect(queue.serverBecameIdle()?.attachments == [attachment])
    }

    @Test("Queued inputs retain command intent and agent selected at submission")
    func queuedInputCapturesIntentAndAgent() throws {
        var queue = OpenCodePromptQueue()
        let intent = OpenCodeSessionInputIntent.command(
            name: "review",
            arguments: "staged changes"
        )

        let result = queue.accept(
            intent: intent,
            model: nil,
            agent: "plan",
            serverIsActive: true
        )
        let prompt = try #require(result.queuedPrompt)

        #expect(prompt.intent == intent)
        #expect(prompt.agent == "plan")
        #expect(prompt.text == "/review staged changes")
    }

    @Test("A synchronous shell response immediately releases the next queued turn")
    func shellCompletionDrainsQueue() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(
            intent: .shell("git status"),
            model: nil,
            agent: "build",
            serverIsActive: false
        )
        _ = queue.accept(text: "Explain that", model: nil, serverIsActive: false)

        #expect(
            queue.dispatchSucceeded(completesSynchronously: true)?.text
                == "Explain that"
        )
        #expect(queue.prompts.isEmpty)
    }
}

private extension OpenCodePromptSubmission {
    var queuedPrompt: OpenCodeQueuedPrompt? {
        guard case .queued(let prompt) = self else { return nil }
        return prompt
    }

    var dispatchedPrompt: OpenCodeQueuedPrompt? {
        guard case .dispatch(let prompt) = self else { return nil }
        return prompt
    }
}
