import Testing
@testable import byot

struct OpenCodeTodoPresentationTests {
    @Test("Todo progress treats completed and cancelled work as resolved")
    func progress() {
        let presentation = OpenCodeTodoPresentation(
            todos: [
                .init(content: "Inspect", status: "completed", priority: "high"),
                .init(content: "Implement", status: "in_progress", priority: "high"),
                .init(content: "Document", status: "pending", priority: "medium"),
                .init(content: "Obsolete", status: "cancelled", priority: "low"),
            ],
            support: .supported
        )

        #expect(presentation.totalCount == 4)
        #expect(presentation.resolvedCount == 2)
        #expect(presentation.activeCount == 2)
        #expect(presentation.progress == 0.5)
        #expect(presentation.headline == "Implement")
        #expect(presentation.progressAccessibilityValue == "2 of 4 resolved")
        #expect(presentation.canPresent)
    }

    @Test("Todo event projection decodes the complete ordered snapshot")
    func eventProjection() {
        let event = OpenCodeEvent(
            id: "evt_1",
            type: "todo.updated",
            properties: [
                "sessionID": .string("ses_1"),
                "todos": .array([
                    .object([
                        "content": .string("First"),
                        "status": .string("in_progress"),
                        "priority": .string("high"),
                    ]),
                    .object([
                        "content": .string("Second"),
                        "status": .string("pending"),
                        "priority": .string("low"),
                    ]),
                ]),
            ]
        )

        #expect(OpenCodeTodoEventProjection.todos(from: event)?.map(\.content) == [
            "First", "Second",
        ])
        #expect(OpenCodeTodoEventProjection.todos(
            from: OpenCodeEvent(id: "evt_2", type: "message.updated", properties: [:])
        ) == nil)
    }

    @Test("An unavailable v2 snapshot cannot erase SSE-delivered todos")
    func unavailableReconciliation() {
        #expect(
            !OpenCodeTodoReconciliation.shouldApplyFetchedSnapshot(
                support: OpenCodeV2Adapter().capabilities.sessionTodos,
                mutationBaseline: 4,
                currentMutation: 4
            )
        )
        #expect(
            OpenCodeTodoReconciliation.shouldApplyFetchedSnapshot(
                support: OpenCodeV1Adapter().capabilities.sessionTodos,
                mutationBaseline: 4,
                currentMutation: 4
            )
        )
    }

    @Test("Unavailable empty state remains explainable")
    func unavailablePresentation() {
        let support = OpenCodeV2Adapter().capabilities.sessionTodos
        let presentation = OpenCodeTodoPresentation(todos: [], support: support)

        #expect(presentation.canPresent)
        #expect(presentation.unavailableReason == support.unavailableReason)
    }
}
