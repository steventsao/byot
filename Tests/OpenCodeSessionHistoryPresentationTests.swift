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
        #expect(presentation.canRestore)
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
