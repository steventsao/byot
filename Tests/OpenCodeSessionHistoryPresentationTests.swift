import Testing
@testable import byot

struct OpenCodeSessionHistoryPresentationTests {
    @Test("A revert boundary hides that turn and every later turn")
    func revertedBoundaryProjection() {
        let messages = [
            message(id: "msg_user_1", role: "user", text: "First prompt"),
            message(id: "msg_assistant_1", role: "assistant", text: "First answer"),
            message(id: "msg_user_2", role: "user", text: "Second prompt"),
            message(id: "msg_assistant_2", role: "assistant", text: "Second answer"),
            message(id: "msg_user_3", role: "user", text: "Third prompt"),
        ]
        let presentation = OpenCodeSessionHistoryPresentation(
            messages: messages,
            revert: OpenCodeSessionRevertState(
                messageID: "msg_user_2",
                partID: nil,
                snapshot: "snap_1",
                diff: "diff"
            ),
            capabilities: .v2
        )

        #expect(presentation.visibleMessages.map(\.id) == [
            "msg_user_1", "msg_assistant_1",
        ])
        #expect(presentation.revertedUserMessages.map(\.id) == [
            "msg_user_2", "msg_user_3",
        ])
        #expect(presentation.latestRevertTarget?.messageID == "msg_user_1")
        #expect(presentation.latestRevertTarget?.files == true)
        #expect(presentation.revertTarget(messageID: "msg_user_1").files == true)
        #expect(presentation.canRestore)
    }

    @Test("A removed revert boundary cannot reveal turns awaiting cleanup")
    func removedBoundaryRetainsVisiblePrefix() {
        let revert = OpenCodeSessionRevertState(
            messageID: "msg_user_2",
            partID: nil,
            snapshot: "snap_1",
            diff: "diff"
        )
        var projection = OpenCodeSessionHistoryProjection()
        projection.reconcile(
            messages: [
                message(id: "msg_user_1", role: "user", text: "First prompt"),
                message(id: "msg_assistant_1", role: "assistant", text: "First answer"),
                message(id: "msg_user_2", role: "user", text: "Second prompt"),
                message(id: "msg_assistant_2", role: "assistant", text: "Second answer"),
                message(id: "msg_user_3", role: "user", text: "Third prompt"),
            ],
            revert: revert
        )
        let cleanupInProgress = [
            message(id: "msg_user_1", role: "user", text: "First prompt"),
            message(id: "msg_assistant_1", role: "assistant", text: "First answer"),
            message(id: "msg_assistant_2", role: "assistant", text: "Second answer"),
            message(id: "msg_user_3", role: "user", text: "Third prompt"),
        ]
        projection.reconcile(messages: cleanupInProgress, revert: revert)
        let presentation = OpenCodeSessionHistoryPresentation(
            messages: cleanupInProgress,
            revert: revert,
            capabilities: .v2,
            projection: projection
        )

        #expect(presentation.visibleMessages.map(\.id) == [
            "msg_user_1", "msg_assistant_1",
        ])
        #expect(presentation.revertedUserMessages.map(\.id) == ["msg_user_3"])
    }

    @Test("A missing uncaptured revert boundary fails closed")
    func unknownRemovedBoundaryFailsClosed() {
        let presentation = OpenCodeSessionHistoryPresentation(
            messages: [
                message(id: "msg_assistant_2", role: "assistant", text: "Hidden answer"),
                message(id: "msg_user_3", role: "user", text: "Hidden prompt"),
            ],
            revert: OpenCodeSessionRevertState(
                messageID: "msg_user_2",
                partID: nil,
                snapshot: nil,
                diff: nil
            ),
            capabilities: .v1
        )

        #expect(presentation.visibleMessages.isEmpty)
        #expect(presentation.revertedUserMessages.isEmpty)
    }

    @Test("Continuing a reverted session reconciles the session and transcript together")
    func revertedContinuationReconciliation() {
        let revert = OpenCodeSessionRevertState(
            messageID: "msg_user_2",
            partID: nil,
            snapshot: nil,
            diff: nil
        )

        #expect(
            OpenCodeSessionHistoryContinuationPolicy.refreshScope(revert: revert) == .session
        )
        #expect(
            OpenCodeSessionHistoryContinuationPolicy.refreshScope(revert: nil) == .messages
        )
    }

    @Test("History policy describes protocol parity without leaking routes")
    func protocolPolicy() {
        let v1 = OpenCodeSessionHistoryPolicy(capabilities: .v1)
        let v2 = OpenCodeSessionHistoryPolicy(capabilities: .v2)

        #expect(v1.canRevert)
        #expect(v1.canUnrevert)
        #expect(v1.canSummarize)
        #expect(v1.canFork)
        #expect(v1.summarizeRequiresModel)
        #expect(v2.canRevert)
        #expect(v2.canUnrevert)
        #expect(v2.canSummarize)
        #expect(!v2.canFork)
        #expect(!v2.summarizeRequiresModel)
    }

    @Test("Message previews use visible prompt text and remain deterministic")
    func messagePreview() {
        let presentation = OpenCodeSessionHistoryPresentation(
            messages: [message(id: "msg_user_1", role: "user", text: "  Ship the fix\nnow  ")],
            revert: nil,
            capabilities: .v1
        )

        #expect(presentation.userMessages.first?.historyPreview == "Ship the fix now")
        #expect(presentation.latestForkMessageID == "msg_user_1")
        #expect(!presentation.canRestore)
    }

    @Test("V2 revert events project staged files and clear boundaries")
    func eventProjection() {
        let staged = OpenCodeEvent(
            id: "evt_stage",
            type: "session.next.revert.staged",
            properties: [
                "sessionID": .string("ses_1"),
                "revert": .object([
                    "messageID": .string("msg_user_2"),
                    "snapshot": .string("snap_1"),
                    "files": .array([
                        .object([
                            "path": .string("Sources/App.swift"),
                            "status": .string("modified"),
                            "additions": .number(2),
                            "deletions": .number(1),
                            "patch": .string("@@"),
                        ]),
                    ]),
                ]),
            ]
        )
        let cleared = OpenCodeEvent(
            id: "evt_clear",
            type: "session.next.revert.cleared",
            properties: ["sessionID": .string("ses_1")]
        )

        guard case .staged(let mutation) = OpenCodeSessionHistoryEventProjection.mutation(
            from: staged
        ) else {
            Issue.record("Expected staged history mutation")
            return
        }
        #expect(mutation.revert?.messageID == "msg_user_2")
        #expect(mutation.diffs?.first?.file == "Sources/App.swift")
        #expect(OpenCodeSessionHistoryEventProjection.mutation(from: cleared) == .cleared)
    }

    @Test("Committed reverts retain their boundary until the session snapshot refreshes")
    func committedBoundaryReconciliation() {
        #expect(
            OpenCodeSessionHistoryReconciliation.keepsBoundaryUntilRefresh(for: .committed)
        )
        #expect(
            !OpenCodeSessionHistoryReconciliation.keepsBoundaryUntilRefresh(for: .cleared)
        )
        #expect(
            OpenCodeSessionHistoryReconciliation.acceptsFetchedSession(
                mutationBaseline: 4,
                currentMutation: 4
            )
        )
        #expect(
            !OpenCodeSessionHistoryReconciliation.acceptsFetchedSession(
                mutationBaseline: 4,
                currentMutation: 5
            )
        )
        #expect(
            !OpenCodeSessionHistoryReconciliation.acceptsFetchedSession(
                mutationBaseline: 4,
                currentMutation: 4,
                clearsBoundary: true,
                transcriptAccepted: false
            )
        )
        #expect(
            OpenCodeSessionHistoryReconciliation.acceptsFetchedSession(
                mutationBaseline: 4,
                currentMutation: 4,
                clearsBoundary: true,
                transcriptAccepted: true
            )
        )
    }

    @Test("A newer reconciliation supersedes an in-flight committed-boundary refresh")
    func reconciliationVersioning() {
        var version = OpenCodeSessionReconciliationVersion()
        let stale = version.begin()
        let current = version.begin()

        #expect(!version.accepts(stale))
        #expect(version.accepts(current))
    }

    @Test("V2 history mutations clear stale diffs when files are omitted")
    func omittedV2FilesClearDiffs() {
        let stale = [
            OpenCodeDiff(
                file: "Old.swift",
                patch: "@@",
                additions: 1,
                deletions: 0,
                status: "modified"
            ),
        ]

        #expect(
            OpenCodeSessionHistoryReconciliation.diffs(
                delivered: nil,
                current: stale,
                capabilities: .v2
            ).isEmpty
        )
        #expect(
            OpenCodeSessionHistoryReconciliation.diffs(
                delivered: nil,
                current: stale,
                capabilities: .v1
            ) == stale
        )
    }

    @Test("Idle history rollback pauses follow-ups without requesting an abort")
    func idleRollbackPreparationPausesQueue() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(
            text: "Wait until rollback finishes",
            model: nil,
            serverIsActive: true
        )

        let preparation = OpenCodeSessionHistoryRollbackPolicy.prepare(
            status: .idle,
            queue: &queue
        )

        #expect(queue.isPaused)
        #expect(!preparation.requiresRemoteAbort)
        #expect(queue.prompts.map(\.text) == ["Wait until rollback finishes"])
    }

    @Test("Active history rollback pauses follow-ups and requests an abort")
    func activeRollbackPreparationRequiresAbort() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(
            text: "Wait until rollback finishes",
            model: nil,
            serverIsActive: true
        )

        let preparation = OpenCodeSessionHistoryRollbackPolicy.prepare(
            status: .busy,
            queue: &queue
        )

        #expect(preparation.requiresRemoteAbort)
    }

    @Test("A submitting prompt requires rollback abort before the server reports active")
    func inFlightRollbackPreparationRequiresAbort() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(
            text: "Still submitting",
            model: nil,
            serverIsActive: false
        )

        let preparation = OpenCodeSessionHistoryRollbackPolicy.prepare(
            status: .idle,
            hasInFlightPrompt: true,
            queue: &queue
        )

        #expect(preparation.requiresRemoteAbort)
    }

    @Test("A failed history mutation restores its prepared follow-up queue")
    func failedMutationRestoresPreparedQueue() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(
            text: "Continue after failure",
            model: nil,
            serverIsActive: true
        )
        let preparation = OpenCodeSessionHistoryRollbackPolicy.prepare(
            status: .idle,
            queue: &queue
        )

        let next = OpenCodeSessionHistoryRollbackPolicy.restore(
            preparation,
            queue: &queue
        )

        #expect(next == nil)
        #expect(!queue.isPaused)
        #expect(queue.serverBecameIdle()?.text == "Continue after failure")
    }

    @Test("A failed mutation after a successful abort releases its first follow-up")
    func failedMutationAfterAbortReleasesQueue() {
        var queue = OpenCodePromptQueue()
        _ = queue.accept(
            text: "Continue after aborted rollback",
            model: nil,
            serverIsActive: true
        )
        let preparation = OpenCodeSessionHistoryRollbackPolicy.prepare(
            status: .busy,
            queue: &queue
        )

        let next = OpenCodeSessionHistoryRollbackPolicy.restore(
            preparation,
            remoteAbortSucceeded: true,
            queue: &queue
        )

        #expect(next?.text == "Continue after aborted rollback")
        #expect(queue.prompts.isEmpty)
    }

    @Test("A failed rollback replays the interrupted prompt before follow-ups")
    func failedMutationAfterAbortRestoresInterruptedPrompt() {
        var queue = OpenCodePromptQueue()
        let submission = queue.accept(
            text: "Interrupted prompt",
            model: nil,
            serverIsActive: false
        )
        guard case .dispatch(let interrupted) = submission else {
            Issue.record("Expected the first prompt to dispatch")
            return
        }
        _ = queue.accept(
            text: "Queued follow-up",
            model: nil,
            serverIsActive: false
        )
        let preparation = OpenCodeSessionHistoryRollbackPolicy.prepare(
            status: .busy,
            queue: &queue
        )

        let next = OpenCodeSessionHistoryRollbackPolicy.restore(
            preparation,
            remoteAbortSucceeded: true,
            interruptedPrompt: interrupted,
            queue: &queue
        )

        #expect(next == interrupted)
        #expect(queue.prompts.map(\.text) == ["Queued follow-up"])
    }

    @Test("Restore is unavailable while any history action owns the lock")
    func restoreActionAvailability() {
        #expect(
            OpenCodeSessionHistoryActionAvailability.canRestore(
                hasRevertedMessages: true,
                actionInFlight: nil
            )
        )
        for action in [
            OpenCodeSessionHistoryAction.revert,
            .unrevert,
            .summarize,
            .fork,
        ] {
            #expect(
                !OpenCodeSessionHistoryActionAvailability.canRestore(
                    hasRevertedMessages: true,
                    actionInFlight: action
                )
            )
        }
    }

    private func message(
        id: String,
        role: String,
        text: String
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessageInfo(
                id: id,
                sessionID: "ses_1",
                role: role,
                time: OpenCodeMessageTime(created: 1, completed: 2),
                agent: nil,
                modelID: nil,
                providerID: nil,
                finish: nil,
                error: nil
            ),
            parts: [
                OpenCodePart(
                    id: "part_\(id)",
                    sessionID: "ses_1",
                    messageID: id,
                    type: "text",
                    text: text,
                    mime: nil,
                    filename: nil,
                    url: nil,
                    callID: nil,
                    tool: nil,
                    state: nil,
                    files: nil,
                    description: nil,
                    agent: nil
                ),
            ]
        )
    }
}
