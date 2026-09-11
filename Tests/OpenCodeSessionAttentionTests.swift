import Foundation
import Testing
@testable import byot

@MainActor
struct OpenCodeSessionAttentionTests {
    @Test("Attention persists per server and refreshes after a second conversation store writes")
    func persistenceAndScope() throws {
        let suite = "attention-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = UUID()
        let first = OpenCodeSessionAttentionStore(serverID: server, defaults: defaults)
        let second = OpenCodeSessionAttentionStore(serverID: server, defaults: defaults)
        second.record(sessionID: "same-id", message: "Model retired")
        first.reload()
        #expect(first.failures["same-id"] == "Model retired")
        #expect(OpenCodeSessionAttentionStore(serverID: UUID(), defaults: defaults).failures.isEmpty)
        second.record(sessionID: "same-id", message: nil)
        first.reload()
        #expect(first.failures.isEmpty)
    }

    @Test("Only the latest user turn can contribute a final provider error")
    func latestTurn() throws {
        let user = message("u", role: "user")
        let failure = message("a", error: "Model retired")
        #expect(OpenCodeSessionAttentionStore.message(in: [user, failure]) == "Model retired")
        #expect(OpenCodeSessionAttentionStore.message(in: [user, failure, message("u2", role: "user")]) == nil)
        #expect(OpenCodeSessionAttentionStore.message(in: [user, failure, message("a2")]) == nil)
        #expect(OpenCodeSessionAttentionStore.message(in: [failure]) == nil)
    }

    @Test("Refresh inspects only known failures, preserves them on network failure, and clears recovered turns")
    func reconcileKnownFailures() async throws {
        let suite = "attention-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = OpenCodeServerProfile(name: "Fixture", baseURL: "https://fixture.invalid")
        let transport = AttentionTransport()
        let client = OpenCodeClient(profile: profile, transport: transport, serverProtocol: .v1)
        let store = OpenCodeSessionAttentionStore(serverID: profile.id, defaults: defaults)
        store.record(sessionID: "failed", message: "Model retired")
        await transport.configure(messages: [], fails: true)
        await store.refresh(sessions: [session("failed"), session("ordinary")], service: client)
        #expect(store.failures["failed"] == "Model retired")
        #expect(await transport.paths == ["/session/failed/message"])
        await transport.configure(messages: [message("u", role: "user"), message("a")])
        await store.refresh(sessions: [session("failed")], service: client)
        #expect(store.failures.isEmpty)
    }

    @Test("A delayed reconciliation cannot overwrite a newly observed conversation failure")
    func staleRefresh() async throws {
        let suite = "attention-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = OpenCodeServerProfile(name: "Fixture", baseURL: "https://fixture.invalid")
        let transport = AttentionTransport()
        let client = OpenCodeClient(profile: profile, transport: transport, serverProtocol: .v1)
        let store = OpenCodeSessionAttentionStore(serverID: profile.id, defaults: defaults)
        store.record(sessionID: "failed", message: "Old failure")
        await transport.configure(messages: [], suspend: true)
        let refresh = Task { await store.refresh(sessions: [session("failed")], service: client) }
        for _ in 0..<1000 {
            if await transport.isSuspended { break }
            await Task.yield()
        }
        #expect(await transport.isSuspended)
        store.record(sessionID: "failed", message: "New failure")
        await transport.release()
        await refresh.value
        #expect(store.failures["failed"] == "New failure")
    }

    private func message(_ id: String, role: String = "assistant", error: String? = nil) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(info: OpenCodeMessageInfo(id: id, sessionID: "failed", role: role,
            time: OpenCodeMessageTime(created: 1, completed: 2), agent: nil, modelID: nil,
            providerID: nil, finish: nil,
            error: error.map { OpenCodeMessageError(name: "ProviderError", data: ["message": .string($0)]) }), parts: [])
    }
    private func session(_ id: String) -> OpenCodeSession {
        OpenCodeSession(id: id, slug: id, projectID: "/repo", workspaceID: nil, directory: "/repo",
            parentID: nil, summary: nil, title: id, agent: nil, version: "1.18.29",
            time: OpenCodeSessionTime(created: 1, updated: 2, compacting: nil, archived: nil))
    }
}

private actor AttentionTransport: OpenCodeHTTPTransport {
    private var messages: [OpenCodeMessageEnvelope] = []
    private var fails = false
    private var suspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var paths: [String] = []
    var isSuspended: Bool { continuation != nil }
    func configure(messages: [OpenCodeMessageEnvelope], fails: Bool = false, suspend: Bool = false) {
        self.messages = messages; self.fails = fails; self.suspend = suspend
    }
    func release() { continuation?.resume(); continuation = nil }
    nonisolated func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        URLRequest(url: URL(string: "https://fixture.invalid/" + path.joined(separator: "/"))!)
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        paths.append(request.url!.path)
        let body = try JSONEncoder().encode(messages)
        if suspend { await withCheckedContinuation { continuation = $0 } }
        if fails { throw OpenCodeConnectionError.httpStatus(503, nil) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!)
    }
    nonisolated func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
