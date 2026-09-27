import Foundation
import Testing
@testable import byot

@MainActor
struct OpenCodeSessionListLiveTests {
    // MARK: Wire format

    @Test("v1 global events unwrap their payload and keep the instance directory")
    func globalEnvelope() throws {
        let json = """
        {"directory":"/repo","project":"global","payload":{"id":"evt_1","type":"session.created",
         "properties":{"sessionID":"ses_new","info":{"id":"ses_new","slug":"quick-engine","version":"1.18.21",
         "projectID":"global","directory":"/repo","title":"Live test","time":{"created":1,"updated":2}}}}}
        """
        let event = try JSONDecoder().decode(OpenCodeEvent.self, from: Data(json.utf8))
        #expect(event.id == "evt_1")
        #expect(event.type == "session.created")
        #expect(event.directory == "/repo")
        #expect(!event.isV2)
        guard case .upserted(let session) = OpenCodeSessionListEvent(event) else {
            Issue.record("Expected an upsert")
            return
        }
        #expect(session.title == "Live test")
        #expect(try JSONDecoder().decode(OpenCodeEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test("Bare v1 events without an ID decode instead of dropping the stream")
    func bareEventWithoutID() throws {
        let event = try JSONDecoder().decode(OpenCodeEvent.self, from: Data("""
        {"type":"server.connected","properties":{}}
        """.utf8))
        #expect(event.id.isEmpty)
        #expect(event.type == "server.connected")
        #expect(!event.isV2)
    }

    @Test("Payloads without an ID decode, and sync duplicates are ignored")
    func globalEnvelopeEdges() throws {
        let connected = try JSONDecoder().decode(OpenCodeEvent.self, from: Data("""
        {"payload":{"id":"evt_0","type":"server.connected","properties":{}}}
        """.utf8))
        #expect(connected.directory == nil)
        #expect(OpenCodeSessionListEvent(connected) == .connected)
        let upgrade = try JSONDecoder().decode(OpenCodeEvent.self, from: Data("""
        {"directory":"global","payload":{"type":"installation.updated","properties":{"version":"2"}}}
        """.utf8))
        #expect(upgrade.id.isEmpty)
        #expect(OpenCodeSessionListEvent(upgrade) == nil)
        let sync = try JSONDecoder().decode(OpenCodeEvent.self, from: Data("""
        {"directory":"/repo","payload":{"type":"sync","syncEvent":{"id":"evt_1","type":"session.created.1",
         "data":{"sessionID":"ses_1"}}}}
        """.utf8))
        #expect(OpenCodeSessionListEvent(sync) == nil)
    }

    @Test("v2 events carry their location directory")
    func v2Location() throws {
        let event = try JSONDecoder().decode(OpenCodeEvent.self, from: Data("""
        {"id":"evt_2","type":"session.deleted","durable":{"aggregateID":"ses_1","seq":2,"version":1},
         "location":{"directory":"/repo"},"data":{"sessionID":"ses_1","info":{"id":"ses_1"}}}
        """.utf8))
        #expect(event.isV2)
        #expect(event.directory == "/repo")
        #expect(OpenCodeSessionListEvent(event) == .removed(sessionID: "ses_1"))
        #expect(try JSONDecoder().decode(OpenCodeEvent.self, from: JSONEncoder().encode(event)) == event)
    }

    @Test("Status, failure and input events map to list changes")
    func eventMapping() {
        #expect(parse("server.connected", [:]) == .connected)
        #expect(parse("global.disposed", [:]) == .disposed)
        #expect(parse("server.instance.disposed", ["directory": .string("/repo")]) == .disposed)
        #expect(parse("session.status", ["sessionID": .string("s"), "status": .object([
            "type": .string("retry"), "attempt": .number(2), "message": .string("Rate limited"), "next": .number(5)])])
            == .status(sessionID: "s", .retry(attempt: 2, message: "Rate limited", next: 5)))
        #expect(parse("session.idle", ["sessionID": .string("s")]) == .status(sessionID: "s", .idle))
        #expect(parse("session.error", ["sessionID": .string("s"), "error": .object([
            "name": .string("MessageAbortedError"), "data": .object(["message": .string("Aborted")])])]) == nil,
            "Stopping a turn is not a failure")
        #expect(parse("session.error", ["sessionID": .string("s"), "error": .object([
            "name": .string("ProviderError"), "data": .object(["message": .string("Model retired")])])])
            == .failed(sessionID: "s", message: "Model retired"))
        #expect(parse("session.error", ["sessionID": .string("s")]) == .failed(sessionID: "s", message: "The last turn failed."),
                "A failure without details still flags the session")
        #expect(parse("permission.asked", ["id": .string("per_1"), "sessionID": .string("s")])
            == .inputRequested(sessionID: "s", requestID: "per_1"))
        #expect(parse("permission.v2.asked", ["id": .string("per_2"), "sessionID": .string("s")], v2: true)
            == .inputRequested(sessionID: "s", requestID: "per_2"))
        #expect(parse("question.replied", ["sessionID": .string("s"), "requestID": .string("que_1")])
            == .inputResolved(sessionID: "s", requestID: "que_1"))
        #expect(parse("session.execution.started", ["sessionID": .string("s")], v2: true) == .status(sessionID: "s", .busy))
        #expect(parse("session.next.step.started", ["sessionID": .string("s")], v2: true)
            == .activity(sessionID: "s", mayHaveSettled: false))
        #expect(parse("session.next.step.ended", ["sessionID": .string("s")], v2: true)
            == .activity(sessionID: "s", mayHaveSettled: true))
        #expect(parse("session.next.text.delta", ["sessionID": .string("s")], v2: true) == nil,
                "Token deltas never reach the list")
        #expect(parse("session.next.tool.progress", ["sessionID": .string("s")], v2: true) == nil)
        #expect(parse("message.part.delta", ["sessionID": .string("s")]) == nil, "Transcript deltas never reach the list")
    }

    // MARK: Applying changes

    @Test("Created, renamed, archived and deleted sessions update the list in place")
    func lifecycle() async {
        let service = LiveListService(sessions: ["/repo": [session("a")]])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/repo")])
        let revision = store.liveRevision

        #expect(store.apply(.upserted(session("b", updated: 5))) == .init())
        #expect(Set(store.sessions.map(\.id)) == ["a", "b"])
        #expect(store.liveRevision > revision, "Live changes animate")
        store.apply(.upserted(session("b", title: "Renamed", updated: 6)))
        #expect(store.sessions.first { $0.id == "b" }?.title == "Renamed")
        store.apply(.renamed(sessionID: "a", title: "Retitled"))
        #expect(store.sessions.first { $0.id == "a" }?.title == "Retitled")
        store.apply(.upserted(session("b", archived: 7)))
        #expect(store.sessions.map(\.id) == ["a"])
        store.apply(.removed(sessionID: "a"))
        #expect(store.sessions.isEmpty)
    }

    @Test("A session in a sandbox of a listed project joins that project")
    func sandboxSession() async {
        let service = LiveListService(sessions: ["/repo": []])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/repo")])
        var sandboxed = session("s", directory: "/repo-sandbox")
        sandboxed = OpenCodeSession(id: sandboxed.id, slug: sandboxed.slug, projectID: "/repo", workspaceID: nil,
                                    directory: "/repo-sandbox", parentID: nil, summary: nil, title: "Sandbox",
                                    agent: nil, version: "1", time: sandboxed.time)
        #expect(store.apply(.upserted(sandboxed)).reconcile == nil)
        #expect(store.sessions.map(\.id) == ["s"])
    }

    @Test("A session outside every listed project reconciles once")
    func unplacedSession() async {
        let service = LiveListService(sessions: ["/repo": []])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/repo")])
        #expect(store.apply(.upserted(session("x", directory: "/elsewhere"))).reconcile == .projects)
        #expect(store.apply(.upserted(session("x", directory: "/elsewhere", updated: 9))).reconcile == nil)
        #expect(store.sessions.isEmpty)
    }

    @Test("Status changes update rows and report a settled turn")
    func statusChanges() async {
        let service = LiveListService(sessions: ["/repo": [session("a")]])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/repo")])
        store.apply(.status(sessionID: "a", .busy))
        #expect(store.statuses["a"] == .busy)
        #expect(store.apply(.status(sessionID: "a", .busy)).settled == nil)
        #expect(store.apply(.activity(sessionID: "a", mayHaveSettled: false)).refreshStatus == nil,
                "A busy session needs no refresh until a step ends")
        #expect(store.apply(.activity(sessionID: "a", mayHaveSettled: true)).refreshStatus == "a")
        #expect(store.apply(.status(sessionID: "a", .idle)).settled == "a")
        #expect(store.statuses["a"] == .idle)
        #expect(store.apply(.status(sessionID: "a", .idle)).settled == nil, "Already idle")
        #expect(store.apply(.activity(sessionID: "a", mayHaveSettled: false)).refreshStatus == "a")
        #expect(store.apply(.activity(sessionID: "child", mayHaveSettled: true)).refreshStatus == nil,
                "Unlisted sessions never trigger a refresh")
    }

    @Test("Only a listed conversation's failure is flagged, and a failed busy turn rechecks status")
    func failures() async {
        let service = LiveListService(sessions: ["/repo": [session("a")]])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/repo")])
        #expect(store.apply(.failed(sessionID: "a", message: "Model retired"))
            == .init(failure: .init(sessionID: "a", message: "Model retired")))
        #expect(store.apply(.failed(sessionID: "child", message: "Tool failed")).failure == nil)
        store.apply(.status(sessionID: "a", .busy))
        #expect(store.apply(.failed(sessionID: "a", message: "Model retired")).refreshStatus == "a")
    }

    @Test("A subagent's permission request flags its root conversation until answered")
    func subagentInput() async {
        let service = LiveListService(sessions: ["/repo": [session("a")]])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/repo")])
        store.apply(.upserted(session("child", parent: "a")))
        #expect(store.sessions.map(\.id) == ["a"], "Children stay out of the list")
        #expect(store.apply(.inputRequested(sessionID: "child", requestID: "per_1")).lookUpParent == nil)
        store.apply(.inputRequested(sessionID: "a", requestID: "que_1"))
        #expect(store.needsInputIDs == ["a"])
        store.apply(.inputResolved(sessionID: "child", requestID: "per_1"))
        #expect(store.needsInputIDs == ["a"])
        store.apply(.inputResolved(sessionID: "a", requestID: nil))
        #expect(store.needsInputIDs.isEmpty)
    }

    @Test("A subagent announced after its request flags the conversation on screen")
    func subagentAnnouncedLate() async {
        let service = LiveListService(sessions: ["/repo": [session("a")]])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/repo")])
        store.apply(.inputRequested(sessionID: "child", requestID: "per_1"))
        #expect(store.needsInputIDs == ["child"], "Unknown until its parent is known")
        let revision = store.liveRevision
        store.apply(.upserted(session("child", parent: "a")))
        #expect(store.needsInputIDs == ["a"])
        #expect(store.liveRevision != revision, "The list must redraw to show the parent flagged")
    }

    @Test("A request from a subagent the list never saw is traced to its conversation")
    func unknownSubagentInput() async throws {
        let service = LiveListService(sessions: ["/repo": [session("a")]], parents: ["grandchild": "child", "child": "a"])
        let store = OpenCodeSessionBrowserStore(service: service, timing: fastTiming)
        await store.load(projects: [project("/repo")])
        service.script([.init(events: [
            event("permission.asked", ["id": .string("per_1"), "sessionID": .string("grandchild")]),
        ], end: .hold)])
        let following = Task { await store.followLiveUpdates(.init(reconcile: { _ in })) }
        try await waitUntil { store.needsInputIDs == ["a"] }
        #expect(service.parentLookups == ["grandchild", "child"])
        following.cancel()
        _ = await following.value
    }

    @Test("A v1 load seeds pending input, and a fresh snapshot clears answered requests")
    func seededInput() async {
        let service = LiveListService(sessions: ["/repo": [session("a")]],
                                      directoryInput: ["child": ["per_1"]], parents: ["child": "a"])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/repo")])
        #expect(store.needsInputIDs == ["a"], "The subagent's parent is looked up")
        service.setDirectoryInput([:])
        await store.load(projects: [project("/repo")])
        #expect(store.needsInputIDs.isEmpty)
        #expect(service.parentLookups == ["child"], "Each session is looked up once")
    }

    @Test("v2 loads keep live requests and recheck only flagged sessions")
    func v2PendingInput() async {
        let service = LiveListService(sessions: ["/repo": [session("a"), session("b")]], directoryInput: nil)
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/repo")])
        store.apply(.inputRequested(sessionID: "a", requestID: "per_1"))
        store.apply(.inputRequested(sessionID: "b", requestID: "que_1"))
        service.setSessionInput(["a": ["per_1"]])
        await store.load(projects: [project("/repo")])
        #expect(store.needsInputIDs == ["a"], "b was answered while the stream was away")
        #expect(Set(service.sessionInputChecks) == ["a", "b"])
    }

    @Test("Live changes made during a load survive the older snapshot")
    func liveEditsDuringLoad() async throws {
        let service = LiveListService(sessions: ["/repo": [session("a"), session("b")]])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/repo")])
        service.holdListing()
        let loading = Task { await store.load(projects: [project("/repo")], showsProgress: false) }
        try await waitUntil { service.isListingHeld }
        #expect(!store.isLoading, "Background reconciliation shows no progress")
        store.apply(.upserted(session("c", title: "Created during load", updated: 3)))
        store.apply(.removed(sessionID: "b"))
        store.apply(.renamed(sessionID: "a", title: "Renamed during load"))
        store.apply(.inputRequested(sessionID: "c", requestID: "per_1"))
        service.releaseListing()
        await loading.value
        #expect(Set(store.sessions.map(\.id)) == ["a", "c"])
        #expect(store.sessions.first { $0.id == "a" }?.title == "Renamed during load")
        #expect(store.needsInputIDs == ["c"])
    }

    // MARK: Stream lifecycle

    @Test("The list follows one stream, applies its events and reconciles on connect")
    func followsOneStream() async throws {
        let service = LiveListService(sessions: ["/repo": [session("a")]])
        service.script([.init(events: [
            event("server.connected", [:]),
            event("session.created", ["sessionID": .string("b"), "info": encoded(session("b", title: "From the TUI"))]),
            event("message.part.delta", ["sessionID": .string("b"), "delta": .string("hi")]),
            event("session.status", ["sessionID": .string("a"), "status": .object(["type": .string("busy")])]),
        ], end: .hold)])
        let store = OpenCodeSessionBrowserStore(service: service, timing: fastTiming)
        await store.load(projects: [project("/repo")])
        let reconciles = Recorder()
        let following = Task {
            await store.followLiveUpdates(.init(reconcile: { reconciles.values.append("\($0)") }))
        }
        try await waitUntil { store.statuses["a"] == .busy }
        #expect(store.liveState == .live)
        #expect(store.sessions.contains { $0.title == "From the TUI" })
        try await waitUntil { reconciles.values == ["sessions"] }
        #expect(service.subscriptions == 1)
        following.cancel()
        #expect(await following.value == .off)
        #expect(store.liveState == .off)
        #expect(service.activeSubscriptions == 0, "Leaving the list closes its stream")
    }

    @Test("A new follower takes over; two streams never run at once")
    func singleStream() async throws {
        let service = LiveListService(sessions: [:])
        service.script([.init(events: [event("server.connected", [:])], end: .hold),
                        .init(events: [event("server.connected", [:])], end: .hold)])
        let store = OpenCodeSessionBrowserStore(service: service, timing: fastTiming)
        let first = Task { await store.followLiveUpdates(.init(reconcile: { _ in })) }
        try await waitUntil { store.liveState == .live }
        let second = Task { await store.followLiveUpdates(.init(reconcile: { _ in })) }
        #expect(await first.value == .off, "The earlier follower stops")
        try await waitUntil { service.subscriptions == 2 && store.liveState == .live }
        #expect(service.maximumActiveSubscriptions == 1)
        second.cancel()
        #expect(await second.value == .off)
        #expect(service.activeSubscriptions == 0)
    }

    @Test("Failures from the stream are reported through the handlers")
    func failureHandler() async throws {
        let service = LiveListService(sessions: ["/repo": [session("a")]])
        service.script([.init(events: [
            event("session.error", ["sessionID": .string("a"), "error": .object([
                "name": .string("ProviderError"), "data": .object(["message": .string("Model retired")])])]),
        ], end: .hold)])
        let store = OpenCodeSessionBrowserStore(service: service, timing: fastTiming)
        await store.load(projects: [project("/repo")])
        let failures = Recorder()
        let following = Task {
            await store.followLiveUpdates(.init(reconcile: { _ in }, failure: { id, message in
                failures.values.append("\(id): \(message)")
            }))
        }
        try await waitUntil { failures.values == ["a: Model retired"] }
        following.cancel()
        _ = await following.value
    }

    @Test("v2 activity refreshes only the project that lists the session, coalesced")
    func coalescedStatusRefresh() async throws {
        let service = LiveListService(sessions: ["/repo": [session("a")], "/other": [session("o", directory: "/other")]])
        service.script([.init(events: [
            event("session.next.step.started", ["sessionID": .string("a")], v2: true),
            event("session.next.text.started", ["sessionID": .string("a")], v2: true),
            event("session.next.tool.called", ["sessionID": .string("a")], v2: true),
        ], end: .hold)])
        var timing = fastTiming
        timing.statusDebounce = .milliseconds(50)
        let store = OpenCodeSessionBrowserStore(service: service, timing: timing)
        await store.load(projects: [project("/repo"), project("/other")])
        service.setStatuses(["a": .busy])
        let before = service.statusRequests
        let following = Task { await store.followLiveUpdates(.init(reconcile: { _ in })) }
        try await waitUntil { store.statuses["a"] == .busy }
        try await Task.sleep(for: .milliseconds(120))
        #expect(service.statusRequests.dropFirst(before.count) == ["/repo"])
        following.cancel()
        _ = await following.value
    }

    @Test("Reconnects back off and stop after the attempt budget")
    func boundedReconnect() async {
        let service = LiveListService(sessions: [:])
        let store = OpenCodeSessionBrowserStore(service: service, timing: fastTiming)
        let outcome = await store.followLiveUpdates(.init(reconcile: { _ in }))
        #expect(outcome == .polling)
        #expect(store.liveState == .polling)
        #expect(service.subscriptions == fastTiming.maximumAttempts)

        let standard = OpenCodeSessionListLiveTiming.standard
        #expect((1...7).map(standard.delay(afterFailure:)) == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
    }

    @Test("Healthy connections reset the reconnect budget")
    func healthyConnectionsResetBudget() async throws {
        let service = LiveListService(sessions: [:])
        service.script(Array(repeating: .init(events: [event("server.connected", [:])], end: .finish), count: 20))
        var timing = fastTiming
        timing.healthyConnection = .zero
        let store = OpenCodeSessionBrowserStore(service: service, timing: timing)
        let following = Task { await store.followLiveUpdates(.init(reconcile: { _ in })) }
        try await waitUntil { service.subscriptions > timing.maximumAttempts * 2 }
        following.cancel()
        #expect(await following.value == .off)
    }

    @Test("A server without a usable stream is not retried",
          arguments: [OpenCodeConnectionError.httpStatus(404, nil), .unexpectedEventContentType])
    func unsupportedStream(error: OpenCodeConnectionError) async {
        let service = LiveListService(sessions: [:])
        service.script([.init(events: [], end: .fail(error))])
        let store = OpenCodeSessionBrowserStore(service: service, timing: fastTiming)
        #expect(await store.followLiveUpdates(.init(reconcile: { _ in })) == .unsupported)
        #expect(service.subscriptions == 1)
    }

    // MARK: Client

    @Test("v1 follows the server-wide global event route")
    func v1Route() async throws {
        let transport = RoutingTransport()
        let client = OpenCodeClient(profile: Self.profile, transport: transport, serverProtocol: .v1)
        for try await _ in client.sessionListEvents() {}
        #expect(transport.eventPaths == [["global", "event"]])
    }

    @Test("v2 follows the server event route")
    func v2Route() async throws {
        let transport = RoutingTransport(responses: ["/openapi.json": Self.v2Schema])
        let client = OpenCodeClient(profile: Self.profile, transport: transport, serverProtocol: .v2)
        for try await _ in client.sessionListEvents() {}
        #expect(transport.eventPaths == [["api", "event"]])
    }

    @Test("v1 lists pending permissions and questions per directory, tolerating servers without questions")
    func v1PendingInput() async throws {
        let transport = RoutingTransport(responses: [
            "/permission": #"[{"id":"per_1","sessionID":"a","permission":"bash","patterns":[],"metadata":{},"always":[]}]"#,
            "/question": #"[{"id":"que_1","sessionID":"b","questions":[]}]"#,
            "/session/child": #"{"id":"child","slug":"c","projectID":"p","directory":"/repo","parentID":"a","title":"Sub","version":"1","time":{"created":1,"updated":1}}"#,
        ])
        let client = OpenCodeClient(profile: Self.profile, transport: transport, serverProtocol: .v1)
        #expect(try await client.pendingInputRequests(directory: "/repo") == ["a": ["per_1"], "b": ["que_1"]])
        #expect(try await client.pendingInputRequests(sessionID: "a") == nil, "v1 answers per directory")
        #expect(try await client.parentSessionID(of: "child", directory: nil) == "a")

        let older = RoutingTransport(responses: [
            "/permission": #"[{"id":"per_1","sessionID":"a","permission":"bash","patterns":[],"metadata":{},"always":[]}]"#,
        ])
        let olderClient = OpenCodeClient(profile: Self.profile, transport: older, serverProtocol: .v1)
        #expect(try await olderClient.pendingInputRequests(directory: "/repo") == ["a": ["per_1"]])
    }

    @Test("v2 lists pending input per session and resolves parents from the session route")
    func v2PendingInputClient() async throws {
        let transport = RoutingTransport(responses: [
            "/openapi.json": Self.v2Schema,
            "/api/session/a/permission": #"{"data":[]}"#,
            "/api/session/a/question": #"{"data":[{"id":"que_1","sessionID":"a","questions":[]}]}"#,
            "/api/session/child": #"{"data":{"id":"child","parentID":"a","projectID":"p","title":"Sub","time":{"created":1,"updated":1},"location":{"directory":"/repo"}}}"#,
        ])
        let client = OpenCodeClient(profile: Self.profile, transport: transport, serverProtocol: .v2)
        #expect(try await client.pendingInputRequests(directory: "/repo") == nil, "v2 has no directory listing")
        #expect(try await client.pendingInputRequests(sessionID: "a") == ["que_1"])
        #expect(try await client.parentSessionID(of: "child", directory: nil) == "a")
    }

    @Test("v2 servers that list requests per location answer per directory")
    func v2LocationPendingInput() async throws {
        let transport = RoutingTransport(responses: [
            "/openapi.json": Self.v2RequestListSchema,
            "/api/permission/request": #"{"location":{"directory":"/repo"},"data":[{"id":"per_1","sessionID":"a","action":"bash","resources":["git push"]}]}"#,
            "/api/question/request": #"{"location":{"directory":"/repo"},"data":[{"id":"que_1","sessionID":"b","questions":[]}]}"#,
        ])
        let client = OpenCodeClient(profile: Self.profile, transport: transport, serverProtocol: .v2)
        #expect(try await client.pendingInputRequests(directory: "/repo") == ["a": ["per_1"], "b": ["que_1"]])
        #expect(transport.queries["/api/permission/request"] == [URLQueryItem(name: "location[directory]", value: "/repo")])
        #expect(transport.queries["/api/question/request"] == [URLQueryItem(name: "location[directory]", value: "/repo")])
    }

    @Test("Location request lists are negotiated from the v2 schema")
    func v2RequestListContract() throws {
        func contract(_ schema: String) throws -> OpenCodeV2Contract {
            try OpenCodeV2Contract(schema: JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(schema.utf8)))
        }
        #expect(try contract(Self.v2RequestListSchema).pendingRequestLists)
        #expect(try !contract(Self.v2Schema).pendingRequestLists)
    }

    // MARK: Fixtures

    private static let profile = OpenCodeServerProfile(name: "Fixture", baseURL: "https://fixture.invalid")

    private static let v2Schema = """
    {"paths":{"/api/session/{sessionID}/prompt":{"post":{"requestBody":{"content":{"application/json":
     {"schema":{"properties":{"text":{}}}}}}}}}}
    """

    private static let v2RequestListSchema = """
    {"paths":{"/api/session/{sessionID}/prompt":{"post":{"requestBody":{"content":{"application/json":
     {"schema":{"properties":{"text":{}}}}}}}},
     "/api/permission/request":{"get":{}},"/api/question/request":{"get":{}}}}
    """

    private var fastTiming: OpenCodeSessionListLiveTiming {
        var timing = OpenCodeSessionListLiveTiming()
        timing.initialDelay = .milliseconds(1)
        timing.maximumDelay = .milliseconds(4)
        timing.maximumAttempts = 3
        timing.healthyConnection = .seconds(60)
        timing.statusDebounce = .milliseconds(1)
        return timing
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(4)) }
        #expect(condition())
    }

    private func parse(_ type: String, _ properties: [String: OpenCodeJSONValue], v2: Bool = false) -> OpenCodeSessionListEvent? {
        OpenCodeSessionListEvent(event(type, properties, v2: v2))
    }

    private func event(_ type: String, _ properties: [String: OpenCodeJSONValue], v2: Bool = false) -> OpenCodeEvent {
        OpenCodeEvent(id: "evt_\(UUID().uuidString)", type: type, properties: properties, isV2: v2)
    }

    private func encoded(_ session: OpenCodeSession) -> OpenCodeJSONValue {
        try! JSONDecoder().decode(OpenCodeJSONValue.self, from: JSONEncoder().encode(session))
    }

    private func project(_ directory: String) -> OpenCodeProject {
        OpenCodeProject(id: directory, worktree: directory, vcs: nil, name: nil,
                        time: OpenCodeProjectTime(created: 1, updated: 2), sandboxes: [])
    }

    private func session(_ id: String, title: String = "Session", directory: String = "/repo", updated: Double = 1,
                         parent: String? = nil, archived: Double? = nil) -> OpenCodeSession {
        OpenCodeSession(id: id, slug: id, projectID: directory, workspaceID: nil, directory: directory, parentID: parent,
                        summary: nil, title: title, agent: nil, version: "1.18.21",
                        time: OpenCodeSessionTime(created: 1, updated: updated, compacting: nil, archived: archived))
    }
}

@MainActor
private final class Recorder { var values: [String] = [] }

/// Scripted server-wide streams; each subscription consumes the next script.
/// With no script left a subscription fails as a dropped connection would.
private final class LiveListService: OpenCodeSessionBrowsing, @unchecked Sendable {
    struct Script {
        enum End { case finish, hold, fail(Error) }
        var events: [OpenCodeEvent]
        var end: End
    }

    private let lock = NSLock()
    private let sessions: [String: [OpenCodeSession]]
    private let parents: [String: String]
    private var directoryInput: [String: Set<String>]?
    private var sessionInput: [String: Set<String>] = [:]
    private var statuses: [String: OpenCodeSessionStatus] = [:]
    private var scripts: [Script] = []
    private var subscriptionCount = 0
    private var active = 0
    private var maximumActive = 0
    private var lookups: [String] = []
    private var inputChecks: [String] = []
    private var statusCalls: [String] = []
    private var listingGate: CheckedContinuation<Void, Never>?
    private var holdsListing = false

    /// `directoryInput` nil behaves like v2, which lists pending input per session only.
    init(sessions: [String: [OpenCodeSession]], directoryInput: [String: Set<String>]? = [:],
         parents: [String: String] = [:]) {
        self.sessions = sessions
        self.directoryInput = directoryInput
        self.parents = parents
    }

    var subscriptions: Int { lock.withLock { subscriptionCount } }
    var activeSubscriptions: Int { lock.withLock { active } }
    var maximumActiveSubscriptions: Int { lock.withLock { maximumActive } }
    var parentLookups: [String] { lock.withLock { lookups } }
    var sessionInputChecks: [String] { lock.withLock { inputChecks } }
    var statusRequests: [String] { lock.withLock { statusCalls } }
    var isListingHeld: Bool { lock.withLock { listingGate != nil } }
    func script(_ scripts: [Script]) { lock.withLock { self.scripts = scripts } }
    func setDirectoryInput(_ value: [String: Set<String>]?) { lock.withLock { directoryInput = value } }
    func setSessionInput(_ value: [String: Set<String>]) { lock.withLock { sessionInput = value } }
    func setStatuses(_ value: [String: OpenCodeSessionStatus]) { lock.withLock { statuses = value } }
    func holdListing() { lock.withLock { holdsListing = true } }
    func releaseListing() {
        let gate = lock.withLock {
            holdsListing = false
            defer { listingGate = nil }
            return listingGate
        }
        gate?.resume()
    }

    func listSessions(directory: String) async throws -> [OpenCodeSession] {
        if lock.withLock({ holdsListing }) {
            await withCheckedContinuation { continuation in lock.withLock { listingGate = continuation } }
        }
        return sessions[directory] ?? []
    }

    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] {
        lock.withLock {
            statusCalls.append(directory)
            let listed = Set((sessions[directory] ?? []).map(\.id))
            return statuses.filter { listed.contains($0.key) }
        }
    }

    func pendingInputRequests(directory: String) async throws -> [String: Set<String>]? {
        lock.withLock { directoryInput }
    }

    func pendingInputRequests(sessionID: String) async throws -> Set<String>? {
        lock.withLock {
            inputChecks.append(sessionID)
            return directoryInput == nil ? sessionInput[sessionID] ?? [] : nil
        }
    }

    func parentSessionID(of sessionID: String, directory: String?) async throws -> String? {
        lock.withLock {
            lookups.append(sessionID)
            return parents[sessionID]
        }
    }

    func sessionListEvents() -> AsyncThrowingStream<OpenCodeEvent, Error> {
        let script: Script? = lock.withLock {
            subscriptionCount += 1
            return scripts.isEmpty ? nil : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            guard let script else {
                continuation.finish(throwing: URLError(.networkConnectionLost))
                return
            }
            lock.withLock {
                active += 1
                maximumActive = max(maximumActive, active)
            }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock { active -= 1 }
            }
            for event in script.events { continuation.yield(event) }
            switch script.end {
            case .finish: continuation.finish()
            case .hold: break
            case .fail(let error): continuation.finish(throwing: error)
            }
        }
    }
}

/// Serves canned JSON by path and records event subscriptions; anything else is a 404.
private final class RoutingTransport: OpenCodeHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [String: String]
    private var recorded: [[String]] = []
    private var recordedQueries: [String: [URLQueryItem]] = [:]
    var eventPaths: [[String]] { lock.withLock { recorded } }
    var queries: [String: [URLQueryItem]] { lock.withLock { recordedQueries } }

    init(responses: [String: String] = [:]) { self.responses = responses }

    func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        var components = URLComponents(string: "https://fixture.invalid/" + path.joined(separator: "/"))!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        return request
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        lock.withLock { recordedQueries[url.path] = items }
        let body = responses[url.path]
        let response = HTTPURLResponse(url: url, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        return (Data((body ?? #"{"message":"Not found"}"#).utf8), response)
    }

    func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        lock.withLock { recorded.append(path) }
        return AsyncThrowingStream { $0.finish() }
    }
}
