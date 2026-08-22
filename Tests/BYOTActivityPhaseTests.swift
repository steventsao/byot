import Testing
@testable import byot

@Suite("BYOT activity phases")
struct BYOTActivityPhaseTests {
    @Test("Every phase has stable user-facing metadata")
    func phaseMetadata() {
        #expect(BYOTActivityPhase.allCases.count == 10)
        #expect(Set(BYOTActivityPhase.allCases.map(\.defaultTitle)).count == 10)
        #expect(BYOTActivityPhase.allCases.allSatisfy { !$0.staticSystemImage.isEmpty })
    }

    @Test("Only active phases animate")
    func animationSemantics() {
        #expect(BYOTActivityPhase.thinking.animationStyle == .wave)
        #expect(BYOTActivityPhase.working.animationStyle == .wave)
        #expect(BYOTActivityPhase.loading.animationStyle == .steppedOrbit)
        #expect(BYOTActivityPhase.reconnecting.animationStyle == .steppedOrbit)
        #expect(BYOTActivityPhase.waiting.animationStyle == .none)
        #expect(BYOTActivityPhase.queued.animationStyle == .none)
        #expect(BYOTActivityPhase.completed.animationStyle == .none)
        #expect(BYOTActivityPhase.failed.animationStyle == .none)
    }

    @Test("Lifecycle tones retain their semantic meaning")
    func semanticTones() {
        #expect(BYOTActivityPhase.thinking.tone == .accent)
        #expect(BYOTActivityPhase.retrying.tone == .warning)
        #expect(BYOTActivityPhase.waiting.tone == .muted)
        #expect(BYOTActivityPhase.queued.tone == .muted)
        #expect(BYOTActivityPhase.completed.tone == .success)
        #expect(BYOTActivityPhase.failed.tone == .error)
    }

    @Test("Accessibility descriptions omit blank details")
    func accessibilityDescription() {
        #expect(
            BYOTActivityPhase.thinking.accessibilityDescription(
                title: "OpenCode is thinking",
                detail: "Reviewing the project"
            ) == "OpenCode is thinking, Reviewing the project"
        )
        #expect(
            BYOTActivityPhase.loading.accessibilityDescription(detail: "   ")
                == "Loading"
        )
    }
}

@Suite("OpenCode activity state policy")
@MainActor
struct OpenCodeActivityStateTests {
    @Test("Thinking remains until visible assistant activity follows the latest user turn")
    func waitsForFirstVisibleActivity() {
        let transcript = [
            message(id: "assistant-old", role: "assistant", parts: [textPart(id: "old", text: "Done")]),
            message(id: "user-current", role: "user"),
            message(id: "assistant-current", role: "assistant", parts: [textPart(id: "blank", text: "  ")]),
        ]

        #expect(
            OpenCodeSessionStore.hasVisibleAssistantActivityAfterLatestUserMessage(
                in: transcript
            ) == false
        )
    }

    @Test("Reasoning and tool parts both begin visible work")
    func visibleWorkParts() {
        let reasoning = message(
            id: "assistant-reasoning",
            role: "assistant",
            parts: [part(id: "reasoning", type: "reasoning", text: "Inspecting files")]
        )
        let tool = message(
            id: "assistant-tool",
            role: "assistant",
            parts: [
                part(
                    id: "tool",
                    type: "tool",
                    state: OpenCodeToolState(
                        status: "running",
                        input: nil,
                        raw: nil,
                        title: nil,
                        output: nil,
                        error: nil,
                        time: nil
                    )
                )
            ]
        )
        let user = message(id: "user", role: "user")

        #expect(
            OpenCodeSessionStore.hasVisibleAssistantActivityAfterLatestUserMessage(
                in: [user, reasoning]
            )
        )
        #expect(
            OpenCodeSessionStore.hasVisibleAssistantActivityAfterLatestUserMessage(
                in: [user, tool]
            )
        )
    }

    @Test("Activity identities support current-turn baseline tracking")
    func activityIdentityBaseline() {
        let baseline = [
            message(id: "assistant-old", role: "assistant", parts: [textPart(id: "old", text: "Done")])
        ]
        let current = baseline + [
            message(id: "user", role: "user"),
            message(id: "assistant-new", role: "assistant", parts: [textPart(id: "new", text: "Starting")]),
        ]

        let oldIDs = OpenCodeSessionStore.visibleAssistantActivityIDs(in: baseline)
        let currentIDs = OpenCodeSessionStore.visibleAssistantActivityIDs(in: current)
        #expect(currentIDs.subtracting(oldIDs) == ["assistant-new:new"])
    }

    private func message(
        id: String,
        role: String,
        parts: [OpenCodePart] = []
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessageInfo(
                id: id,
                sessionID: "session",
                role: role,
                time: OpenCodeMessageTime(created: 0, completed: nil),
                agent: nil,
                modelID: nil,
                providerID: nil,
                finish: nil,
                error: nil
            ),
            parts: parts
        )
    }

    private func textPart(id: String, text: String) -> OpenCodePart {
        part(id: id, type: "text", text: text)
    }

    private func part(
        id: String,
        type: String,
        text: String? = nil,
        state: OpenCodeToolState? = nil
    ) -> OpenCodePart {
        OpenCodePart(
            id: id,
            sessionID: "session",
            messageID: "message",
            type: type,
            text: text,
            mime: nil,
            filename: nil,
            url: nil,
            callID: nil,
            tool: nil,
            state: state,
            files: nil,
            description: nil,
            agent: nil
        )
    }
}
