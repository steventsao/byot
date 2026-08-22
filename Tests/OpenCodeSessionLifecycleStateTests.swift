import Testing
@testable import byot

struct OpenCodeSessionLifecycleStateTests {
    @Test("Renaming replaces the session and preserves newest-first ordering")
    func renameState() {
        var state = OpenCodeSessionLifecycleState(
            sessions: [
                makeSession(id: "ses_2", title: "Second", updated: 20),
                makeSession(id: "ses_1", title: "First", updated: 10),
            ],
            statuses: ["ses_1": .idle, "ses_2": .busy]
        )

        state.upsert(makeSession(id: "ses_1", title: "Renamed", updated: 30))

        #expect(state.sessions.map(\.id) == ["ses_1", "ses_2"])
        #expect(state.sessions.first?.title == "Renamed")
        #expect(state.statuses["ses_1"] == .idle)
    }

    @Test("Deleting removes both the row and its status")
    func deleteState() {
        var state = OpenCodeSessionLifecycleState(
            sessions: [makeSession(id: "ses_1", title: "First", updated: 10)],
            statuses: ["ses_1": .busy]
        )

        state.remove(sessionID: "ses_1")

        #expect(state.sessions.isEmpty)
        #expect(state.statuses.isEmpty)
    }

    @Test("Lifecycle controls follow detected protocol capability")
    func lifecyclePolicy() {
        let v1 = OpenCodeSessionLifecyclePolicy(capabilities: .v1)
        let v2 = OpenCodeSessionLifecyclePolicy(capabilities: .v2)

        #expect(v1.canRename)
        #expect(v1.canDelete)
        #expect(v1.canListChildren)
        #expect(v1.canAbort)
        #expect(!v2.canRename)
        #expect(!v2.canDelete)
        #expect(!v2.canListChildren)
        #expect(v2.canAbort)
    }

    @Test("Remote stop is available only for active, non-stopping sessions")
    func abortPolicy() {
        #expect(OpenCodeSessionAbortPolicy.canRequest(status: .busy, isRequesting: false))
        #expect(OpenCodeSessionAbortPolicy.canRequest(
            status: .retry(attempt: 2, message: "retry", next: 3),
            isRequesting: false
        ))
        #expect(!OpenCodeSessionAbortPolicy.canRequest(status: .idle, isRequesting: false))
        #expect(!OpenCodeSessionAbortPolicy.canRequest(status: .busy, isRequesting: true))
    }

    private func makeSession(
        id: String,
        title: String,
        updated: Double
    ) -> OpenCodeSession {
        OpenCodeSession(
            id: id,
            slug: id,
            projectID: "proj_1",
            workspaceID: nil,
            directory: "/repo",
            parentID: nil,
            summary: nil,
            title: title,
            agent: nil,
            version: "1",
            time: OpenCodeSessionTime(
                created: 1,
                updated: updated,
                compacting: nil,
                archived: nil
            )
        )
    }
}
