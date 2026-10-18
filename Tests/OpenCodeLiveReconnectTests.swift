import Foundation
import Testing
@testable import byot

@Suite("Live updates after a silent drop", .serialized)
struct OpenCodeEventStallTests {
    @Test("An OpenCode 2 stream that went silent after a heartbeat ends so the caller reconnects",
          .bug(id: "anomalyco/opencode#55673"))
    func silentAfterHeartbeatComment() async throws {
        SSEStreamStub.reset([.init(after: 0, ": heartbeat\n\n")], finishes: false)
        let outcome = await read(timeout: .milliseconds(400))
        #expect(outcome.stalled)
        #expect(outcome.elapsed < .seconds(3))
        // The request itself is cancelled; URLSession tells the stub a moment later.
        let deadline = ContinuousClock.now + .seconds(2)
        while SSEStreamStub.stopCount() == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(SSEStreamStub.stopCount() >= 1)
    }

    @Test("An OpenCode 1 stream that went silent after a heartbeat event ends too")
    func silentAfterHeartbeatEvent() async throws {
        SSEStreamStub.reset([
            .init(after: 0, #"data: {"type":"server.connected","properties":{}}"# + "\n\n"),
            .init(after: 0.05, #"data: {"type":"server.heartbeat","properties":{}}"# + "\n\n"),
        ], finishes: false)
        let outcome = await read(timeout: .milliseconds(400))
        #expect(outcome.stalled)
        #expect(outcome.types == ["server.connected", "server.heartbeat"])
    }

    @Test("A stream that never sent a heartbeat is not cut off for being quiet")
    func quietStreamWithoutHeartbeats() async throws {
        SSEStreamStub.reset([
            .init(after: 0, #"data: {"type":"server.connected","properties":{}}"# + "\n\n"),
            .init(after: 1.0, #"data: {"type":"session.idle","properties":{}}"# + "\n\n"),
        ], finishes: true)
        let outcome = await read(timeout: .milliseconds(300))
        #expect(!outcome.stalled)
        #expect(outcome.failure == nil)
        #expect(outcome.types == ["server.connected", "session.idle"])
    }

    @Test("Regular heartbeats keep a stream open")
    func heartbeatsKeepStreamOpen() async throws {
        SSEStreamStub.reset(Array(repeating: .init(after: 0.1, ": heartbeat\n\n"), count: 12), finishes: true)
        let outcome = await read(timeout: .milliseconds(400))
        #expect(!outcome.stalled)
        #expect(outcome.failure == nil)
        #expect(outcome.elapsed >= .milliseconds(1_100))
    }

    private struct Outcome {
        var types: [String] = []
        var stalled = false
        var failure: Error?
        var elapsed: Duration = .zero
    }

    private func read(timeout: Duration) async -> Outcome {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SSEStreamStub.self]
        let transport = OpenCodeTransport(
            profile: OpenCodeServerProfile(name: "Stub", baseURL: "https://stall.example.ts.net", username: "opencode"),
            password: "test",
            session: URLSession(configuration: configuration),
            eventStallTimeout: timeout
        )
        var outcome = Outcome()
        let started = ContinuousClock.now
        do {
            for try await event in transport.events(path: ["event"], query: []) { outcome.types.append(event.type) }
        } catch {
            if case OpenCodeConnectionError.eventStreamStalled = error { outcome.stalled = true }
            else { outcome.failure = error }
        }
        outcome.elapsed = ContinuousClock.now - started
        return outcome
    }
}

@Suite("Coming back to an open conversation")
@MainActor
struct OpenCodeForegroundReconnectTests {
    @Test("A dropped stream reconnects on return instead of waiting out its backoff",
          .bug(id: "anomalyco/opencode#55673"))
    func dropReconnectsOnForeground() async throws {
        let service = ReconnectingService(failsEveryStream: true)
        let store = makeStore(service)
        let load = Task { await store.start() }
        defer { store.stop() }
        try await wait { await service.streamCount >= 1 }
        await load.value
        // The first retry waits a second; returning to the app goes now.
        store.refreshAfterForeground()
        try await wait(for: .milliseconds(500)) { await service.streamCount >= 2 }
    }

    @Test("A live stream is left open on return")
    func liveStreamStaysOpen() async throws {
        let service = ReconnectingService(failsEveryStream: false)
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        try await wait { store.isEventConnected }
        store.refreshAfterForeground()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await service.streamCount == 1)
        #expect(store.isEventConnected)
    }

    private func makeStore(_ service: ReconnectingService) -> OpenCodeSessionStore {
        OpenCodeSessionStore(service: service, serverID: UUID(), session: OpenCodeSession(
            id: "session", slug: "session", projectID: "project", workspaceID: nil,
            directory: "/project", parentID: nil, summary: nil, title: "Reconnect",
            agent: nil, version: "1", time: OpenCodeSessionTime(created: 1, updated: 2, compacting: nil, archived: nil)
        ), directory: "/project")
    }

    private func wait(for limit: Duration = .seconds(1), until predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out after \(limit)")
    }
}

private actor ReconnectingService: OpenCodeSessionServicing {
    private let failsEveryStream: Bool
    private(set) var streamCount = 0

    init(failsEveryStream: Bool) { self.failsEveryStream = failsEveryStream }

    private func opened() -> Int {
        streamCount += 1
        return streamCount
    }

    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] { [] }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] { [] }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] { [:] }
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff] { [] }
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest] { [] }
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest] { [] }
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] { [] }
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] { [] }
    func sendMessage(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String, attachments: [OpenCodePromptAttachment], promptID: UUID) async throws {}
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool { true }
    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?, reply: OpenCodePermissionReply) async throws {}
    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws {}
    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?) async throws {}
    nonisolated func events(directory: String, workspace: String?) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                _ = await self.opened()
                if self.failsEveryStream {
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                } else {
                    continuation.yield(OpenCodeEvent(id: "connected", type: "server.connected", properties: [:]))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Answers every request with an event stream that sends `steps` over time,
/// then either finishes or stays open until the request is cancelled. An open
/// stream still closes after five seconds, so a missing stall check fails the
/// test instead of hanging it.
final class SSEStreamStub: URLProtocol, @unchecked Sendable {
    struct Step: Sendable {
        let after: TimeInterval
        let text: String
        init(after: TimeInterval, _ text: String) {
            self.after = after
            self.text = text
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var steps: [Step] = []
    nonisolated(unsafe) private static var finishes = false
    nonisolated(unsafe) private static var stops = 0
    private var timers: [Timer] = []

    static func reset(_ steps: [Step], finishes: Bool) {
        lock.withLock {
            self.steps = steps
            self.finishes = finishes
            stops = 0
        }
    }

    static func stopCount() -> Int { lock.withLock { stops } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (steps, finishes) = Self.lock.withLock { (Self.steps, Self.finishes) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var at: TimeInterval = 0
        for step in steps {
            at += step.after
            let data = Data(step.text.utf8)
            schedule(at: at) { $0.client?.urlProtocol($0, didLoad: data) }
        }
        schedule(at: at + (finishes ? 0.01 : 5)) { $0.client?.urlProtocolDidFinishLoading($0) }
    }

    override func stopLoading() {
        timers.forEach { $0.invalidate() }
        Self.lock.withLock { Self.stops += 1 }
    }

    /// On the loading thread's run loop, where URLProtocol's client expects calls.
    private func schedule(at delay: TimeInterval, _ action: @escaping @Sendable (SSEStreamStub) -> Void) {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            action(self)
        }
        RunLoop.current.add(timer, forMode: .common)
        timers.append(timer)
    }
}
