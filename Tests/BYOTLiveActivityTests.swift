import Foundation
import Testing
@testable import byot

@MainActor
struct BYOTLiveActivityTests {
    // MARK: Turn mapping

    @Test("A running tool shows its label and file name, timed from the prompt")
    func runningTool() throws {
        let turn = try #require(BYOTTurnSnapshot.make(status: .busy, permissions: [], questions: [], messages: [
            user(created: 1_000_000),
            assistant(parts: [tool("edit", status: "running", input: ["filePath": .string("/repo/Sources/LoginView.swift")])]),
        ]))
        #expect(turn.phase == .working)
        #expect(turn.tool == "Edit file")
        #expect(turn.detail == "LoginView.swift")
        #expect(turn.startedAt == Date(timeIntervalSince1970: 1_000))
    }

    @Test("Shell commands never reach the Lock Screen; the agent's description does")
    func shellDescription() throws {
        let turn = try #require(BYOTTurnSnapshot.make(status: .busy, permissions: [], questions: [], messages: [
            user(), assistant(parts: [tool("bash", status: "running", input: [
                "command": .string("API_TOKEN=secret npm test"), "description": .string("Run unit tests"),
            ])]),
        ]))
        #expect(turn.tool == "Shell command")
        #expect(turn.detail == "Run unit tests")
        #expect(BYOTTurnSnapshot.detail(tool: "bash", input: ["command": .string("rm -rf build")]) == nil)
        #expect(BYOTTurnSnapshot.detail(tool: "webfetch", input: ["url": .string("https://example.com/a?b")]) == "example.com")
    }

    @Test("Before any output the turn is thinking; streamed text reads as writing a reply")
    func thinkingThenWriting() throws {
        let thinking = try #require(BYOTTurnSnapshot.make(status: .busy, permissions: [], questions: [],
                                                          messages: [user(), assistant(parts: [])]))
        #expect(thinking.phase == .thinking)
        let finishedTool = tool("read", status: "completed", input: ["filePath": .string("/repo/a.swift")])
        let writing = try #require(BYOTTurnSnapshot.make(status: .busy, permissions: [], questions: [],
            messages: [user(), assistant(parts: [finishedTool, text("Here is the fix")])]))
        #expect(writing.phase == .working)
        #expect(writing.tool == nil)
        #expect(state(writing).headline == "Writing a reply")
    }

    @Test("A waiting permission or question outranks the running status")
    func pendingRequests() throws {
        let approval = try #require(BYOTTurnSnapshot.make(status: .busy, permissions: [permission("bash")],
                                                          questions: [question()], messages: [user()]))
        #expect(approval.phase == .needsResponse)
        #expect(approval.response == .approval)
        #expect(approval.tool == "Shell command")
        #expect(approval.pendingCount == 2)
        #expect(state(approval).statusLine == "Approval needed · 2 waiting")

        let answer = try #require(BYOTTurnSnapshot.make(status: .busy, permissions: [], questions: [question()],
                                                        messages: [user()]))
        #expect(answer.response == .answer)
        #expect(state(answer).statusLine == "Question for you")
    }

    @Test("Retry, completion, failure, and stop map to their own phases")
    func finishingPhases() throws {
        let retry = try #require(BYOTTurnSnapshot.make(status: .retry(attempt: 2, message: "Rate limited", next: 0),
                                                       permissions: [], questions: [], messages: [user()]))
        #expect(retry.phase == .retrying)
        #expect(state(retry).statusLine == "Retrying · Attempt 2")
        #expect(BYOTTurnSnapshot.make(status: .idle, permissions: [], questions: [],
                                      messages: [user(), assistant(parts: [text("Done")])])?.phase == .completed)
        #expect(BYOTTurnSnapshot.make(status: .idle, permissions: [], questions: [],
                                      messages: [user(), assistant(error: "ProviderAuthError")])?.phase == .failed)
        #expect(BYOTTurnSnapshot.make(status: .idle, permissions: [], questions: [],
                                      messages: [user(), assistant(error: "MessageAbortedError")])?.phase == .stopped)
        #expect(BYOTTurnSnapshot.make(status: .idle, permissions: [], questions: [], messages: []) == nil)
    }

    // MARK: Controller

    @Test("An activity starts only for an active turn while byot is in the foreground")
    func startConditions() {
        let host = FakeActivityHost()
        let controller = controller(host)
        controller.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .completed), canStart: true)
        controller.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .working), canStart: false)
        controller.drive(attributes(), snapshot: nil, canStart: true)
        #expect(host.started.isEmpty)
        host.enabled = false
        controller.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .working), canStart: true)
        #expect(host.started.isEmpty)
        host.enabled = true
        controller.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .working, tool: "Edit file"), canStart: true)
        #expect(host.started.count == 1)
        #expect(controller.activeKeys == [attributes().key])
    }

    @Test("A build without the widget extension or with the setting off never starts one")
    func unsupportedOrDisabled() {
        let host = FakeActivityHost()
        let unsupported = BYOTLiveActivityController(host: host, defaults: defaults(), isSupported: false)
        unsupported.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .working), canStart: true)
        let disabled = controller(host)
        disabled.isEnabled = false
        disabled.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .working), canStart: true)
        #expect(host.started.isEmpty)
    }

    @Test("Identical states are not re-sent; changes update and a finish ends with a delayed dismissal")
    func updatesAndEnd() throws {
        let host = FakeActivityHost()
        let controller = controller(host)
        let now = Date(timeIntervalSince1970: 10_000)
        let start = now - 30
        controller.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .thinking, startedAt: start), canStart: true, now: now)
        controller.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .thinking, startedAt: start), canStart: true, now: now + 1)
        #expect(host.updates.isEmpty)
        controller.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .working, tool: "Read file", startedAt: start),
                         canStart: false, now: now + 2)
        let update = try #require(host.updates.last)
        #expect(update.state.tool == "Read file")
        #expect(update.state.startedAt == start)
        #expect(update.staleDate == now + 2 + BYOTLiveActivityController.staleInterval)
        controller.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .completed, startedAt: start), canStart: false, now: now + 60)
        let end = try #require(host.ends.last)
        #expect(end.state.phase == .completed)
        #expect(end.state.duration == 90)
        #expect(end.dismissAt == now + 60 + BYOTLiveActivityController.finishedDismissal)
        #expect(controller.activeKeys.isEmpty)
    }

    @Test("A server clock ahead of the phone never starts the timer in the future")
    func futureStart() throws {
        let host = FakeActivityHost()
        let now = Date(timeIntervalSince1970: 10_000)
        controller(host).drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .working, startedAt: now + 120),
                               canStart: true, now: now)
        #expect(try #require(host.started.first).state.startedAt == now)
    }

    @Test("After the conversation closes, polling finishes the activity with the session's last update")
    func reconcileAfterRelease() throws {
        let host = FakeActivityHost()
        let controller = controller(host)
        let server = attributes().serverID
        let now = Date(timeIntervalSince1970: 10_000)
        controller.drive(attributes(), snapshot: BYOTTurnSnapshot(phase: .working, startedAt: now - 100), canStart: true, now: now)
        // Still open: the conversation's live events win over a polled status.
        controller.reconcile(serverID: server, sessions: [session(updated: now)], statuses: ["s1": .idle],
                             pendingSessionIDs: [], failures: [:], now: now + 5)
        #expect(host.ends.isEmpty)

        controller.release(serverID: server, sessionID: "s1")
        controller.reconcile(serverID: server, sessions: [session(updated: now)], statuses: ["s1": .busy],
                             pendingSessionIDs: ["s1"], failures: [:], now: now + 10)
        #expect(host.updates.last?.state.phase == .needsResponse)
        controller.reconcile(serverID: UUID(), sessions: [], statuses: ["s1": .idle],
                             pendingSessionIDs: [], failures: [:], now: now + 20)
        #expect(host.ends.isEmpty)
        controller.reconcile(serverID: server, sessions: [session(updated: now + 30)], statuses: ["s1": .idle],
                             pendingSessionIDs: [], failures: ["s1": "Model retired"], now: now + 900)
        let end = try #require(host.ends.last)
        #expect(end.state.phase == .failed)
        #expect(end.state.endedAt == now + 30)
        #expect(controller.activeKeys.isEmpty)
    }

    @Test("Activities from a previous launch are adopted and can be ended per server")
    func adoptionAndEndAll() {
        let host = FakeActivityHost()
        let other = BYOTTurnActivityAttributes(serverID: UUID(), serverName: "Other", sessionID: "s2", sessionTitle: "Other",
                                               projectName: "repo", directory: "/repo", workspace: nil)
        host.running = [
            ("a1", attributes(), .init(phase: .working, startedAt: .now)),
            ("a2", other, .init(phase: .thinking, startedAt: .now)),
        ]
        let controller = controller(host)
        #expect(controller.activeKeys == [attributes().key, other.key])
        controller.endAll(serverID: other.serverID)
        #expect(host.ends.map(\.id) == ["a2"])
        #expect(host.ends.first?.dismissAt == nil)
        controller.isEnabled = false
        #expect(host.ends.map(\.id) == ["a2", "a1"])
    }

    @Test("Concurrent activities stay under the system limit")
    func concurrencyLimit() {
        let host = FakeActivityHost()
        let controller = controller(host)
        for index in 0..<(BYOTLiveActivityController.maximumActivities + 2) {
            let attributes = BYOTTurnActivityAttributes(serverID: UUID(), serverName: "S", sessionID: "s\(index)",
                sessionTitle: "T", projectName: "p", directory: "/p", workspace: nil)
            controller.drive(attributes, snapshot: BYOTTurnSnapshot(phase: .working), canStart: true)
        }
        #expect(host.started.count == BYOTLiveActivityController.maximumActivities)
    }

    // MARK: Helpers

    private func state(_ snapshot: BYOTTurnSnapshot) -> BYOTTurnActivityAttributes.ContentState {
        .init(phase: snapshot.phase, response: snapshot.response, tool: snapshot.tool, detail: snapshot.detail,
              pendingCount: snapshot.pendingCount, startedAt: .now)
    }

    private func controller(_ host: FakeActivityHost) -> BYOTLiveActivityController {
        BYOTLiveActivityController(host: host, defaults: defaults(), isSupported: true)
    }

    private func defaults() -> UserDefaults {
        let suite = "live-activity-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static let server = UUID()

    private func attributes() -> BYOTTurnActivityAttributes {
        BYOTTurnActivityAttributes(serverID: Self.server, serverName: "Studio", sessionID: "s1", sessionTitle: "Fix login",
                                   projectName: "repo", directory: "/repo", workspace: nil)
    }

    private func session(updated: Date) -> OpenCodeSession {
        OpenCodeSession(id: "s1", slug: "s1", projectID: "/repo", workspaceID: nil, directory: "/repo", parentID: nil,
                        summary: nil, title: "Fix login", agent: nil, version: "1.18.29",
                        time: OpenCodeSessionTime(created: 1, updated: updated.timeIntervalSince1970 * 1000,
                                                  compacting: nil, archived: nil))
    }

    private func user(created: Double = 1) -> OpenCodeMessageEnvelope {
        message("u", role: "user", created: created, parts: [])
    }

    private func assistant(parts: [OpenCodePart] = [], error: String? = nil) -> OpenCodeMessageEnvelope {
        message("a", role: "assistant", created: 2, parts: parts,
                error: error.map { OpenCodeMessageError(name: $0, data: nil) })
    }

    private func message(_ id: String, role: String, created: Double, parts: [OpenCodePart],
                         error: OpenCodeMessageError? = nil) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(info: OpenCodeMessageInfo(id: id, sessionID: "s1", role: role,
            time: OpenCodeMessageTime(created: created, completed: nil), agent: nil, modelID: nil,
            providerID: nil, finish: nil, error: error), parts: parts)
    }

    private func tool(_ name: String, status: String, input: [String: OpenCodeJSONValue]) -> OpenCodePart {
        OpenCodePart(id: "t-\(name)-\(status)", sessionID: "s1", messageID: "a", type: "tool", text: nil, mime: nil,
                     filename: nil, url: nil, callID: "c", tool: name,
                     state: OpenCodeToolState(status: status, input: input, raw: nil, title: nil, output: nil,
                                              error: nil, time: nil),
                     files: nil, description: nil, agent: nil)
    }

    private func text(_ value: String) -> OpenCodePart {
        OpenCodePart(id: "text", sessionID: "s1", messageID: "a", type: "text", text: value, mime: nil, filename: nil,
                     url: nil, callID: nil, tool: nil, state: nil, files: nil, description: nil, agent: nil)
    }

    private func permission(_ kind: String) -> OpenCodePermissionRequest {
        OpenCodePermissionRequest(id: "p1", sessionID: "s1", permission: kind, patterns: ["npm test"], metadata: [:],
                                  always: [])
    }

    private func question() -> OpenCodeQuestionRequest {
        OpenCodeQuestionRequest(id: "q1", sessionID: "s1", questions: [])
    }
}

@MainActor
final class FakeActivityHost: BYOTLiveActivityHosting {
    typealias State = BYOTTurnActivityAttributes.ContentState
    var enabled = true
    var running: [(id: String, attributes: BYOTTurnActivityAttributes, state: State)] = []
    private(set) var started: [(attributes: BYOTTurnActivityAttributes, state: State)] = []
    private(set) var updates: [(id: String, state: State, staleDate: Date?)] = []
    private(set) var ends: [(id: String, state: State, dismissAt: Date?)] = []

    var areActivitiesEnabled: Bool { enabled }

    func existing() -> [(id: String, attributes: BYOTTurnActivityAttributes, state: State)] { running }

    func start(_ attributes: BYOTTurnActivityAttributes, state: State, staleDate: Date) throws -> String {
        started.append((attributes, state))
        return "activity-\(started.count)"
    }

    func update(id: String, state: State, staleDate: Date?) { updates.append((id, state, staleDate)) }

    func end(id: String, state: State, dismissAt: Date?) { ends.append((id, state, dismissAt)) }
}
