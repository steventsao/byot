import Foundation
import Testing
@testable import byot

@Suite("OpenCode offline cache")
struct OpenCodeOfflineCacheTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "OfflineCacheTests-\(UUID().uuidString)")
    private let server = UUID()

    // MARK: Cache

    @Test("A saved session list comes back only for the same server address")
    func sessionListRoundTrip() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let groups = [OpenCodeCachedSessionList.Group(project: project("/one"), sessions: [session("a", directory: "/one")])]
        let savedAt = Date(timeIntervalSince1970: 1_000)
        cache.saveSessionList(groups, serverID: server, fingerprint: "print", savedAt: savedAt)
        await cache.flush()
        let restored = try #require(cache.sessionList(serverID: server, fingerprint: "print"))
        #expect(restored.groups == groups)
        #expect(restored.savedAt == savedAt)
        #expect(cache.sessionList(serverID: server, fingerprint: "other") == nil)
        #expect(cache.sessionList(serverID: UUID(), fingerprint: "print") == nil)
    }

    @Test("Session lists keep the most recent sessions of the first projects")
    func sessionListBounds() async throws {
        var limits = OpenCodeOfflineCache.Limits()
        limits.projects = 2
        limits.sessionsPerProject = 2
        let cache = OpenCodeOfflineCache(root: root, limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = [session("old", updated: 1), session("new", updated: 3), session("mid", updated: 2)]
        let groups = ["/a", "/b", "/c"].map { OpenCodeCachedSessionList.Group(project: project($0), sessions: sessions) }
        cache.saveSessionList(groups, serverID: server, fingerprint: "print")
        await cache.flush()
        let restored = try #require(cache.sessionList(serverID: server, fingerprint: "print"))
        #expect(restored.groups.map(\.project.worktree) == ["/a", "/b"])
        #expect(restored.groups[0].sessions.map(\.id) == ["new", "mid"])
    }

    @Test("A transcript is stored per session and address")
    func transcriptRoundTrip() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = [message("m1", role: "user"), message("m2", role: "assistant")]
        cache.saveTranscript(messages, serverID: server, fingerprint: "print", sessionID: "ses", directory: "/one", workspace: nil)
        let restored = try #require(await cache.transcript(serverID: server, fingerprint: "print", sessionID: "ses", directory: "/one", workspace: nil))
        #expect(restored.messages == messages)
        #expect(!restored.isTruncated)
        #expect(await cache.transcript(serverID: server, fingerprint: "print", sessionID: "ses", directory: "/two", workspace: nil) == nil)
        #expect(await cache.transcript(serverID: server, fingerprint: "print", sessionID: "ses", directory: "/one", workspace: "wrk") == nil)
        #expect(await cache.transcript(serverID: server, fingerprint: "moved", sessionID: "ses", directory: "/one", workspace: nil) == nil)
        cache.removeTranscript(serverID: server, sessionID: "ses", directory: "/one", workspace: nil)
        #expect(await cache.transcript(serverID: server, fingerprint: "print", sessionID: "ses", directory: "/one", workspace: nil) == nil)
    }

    @Test("A long transcript keeps its newest turns and starts at a prompt")
    func transcriptMessageBound() throws {
        var limits = OpenCodeOfflineCache.Limits()
        limits.messagesPerTranscript = 3
        let messages = [message("u1", role: "user"), message("a1", role: "assistant"),
                        message("u2", role: "user"), message("a2", role: "assistant"), message("a3", role: "assistant")]
        let data = try #require(OpenCodeOfflineCache.encodeTranscript(
            messages, limits: limits, savedAt: Date(), fingerprint: "print", sessionID: "ses"))
        let saved = try JSONDecoder().decode(OpenCodeCachedTranscript.self, from: data)
        #expect(saved.messages.map(\.id) == ["u2", "a2", "a3"])
        #expect(saved.isTruncated)
    }

    @Test("A transcript over the byte budget drops older messages, and one that can't fit is not kept")
    func transcriptByteBound() async throws {
        var limits = OpenCodeOfflineCache.Limits()
        limits.bytesPerTranscript = 4_000
        let messages = (0..<8).map { message("m\($0)", role: $0.isMultiple(of: 2) ? "user" : "assistant", text: String(repeating: "x", count: 800)) }
        let data = try #require(OpenCodeOfflineCache.encodeTranscript(
            messages, limits: limits, savedAt: Date(), fingerprint: "print", sessionID: "ses"))
        #expect(data.count <= limits.bytesPerTranscript)
        let saved = try JSONDecoder().decode(OpenCodeCachedTranscript.self, from: data)
        #expect(saved.isTruncated)
        #expect(saved.messages.last?.id == "m7")
        #expect(saved.messages.first?.info.role == "user")

        let cache = OpenCodeOfflineCache(root: root, limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        cache.saveTranscript(Array(messages.prefix(2)), serverID: server, fingerprint: "print", sessionID: "ses", directory: "/one", workspace: nil)
        #expect(await cache.transcript(serverID: server, fingerprint: "print", sessionID: "ses", directory: "/one", workspace: nil) != nil)
        let huge = [message("big", role: "user", text: String(repeating: "y", count: 10_000))]
        cache.saveTranscript(huge, serverID: server, fingerprint: "print", sessionID: "ses", directory: "/one", workspace: nil)
        #expect(await cache.transcript(serverID: server, fingerprint: "print", sessionID: "ses", directory: "/one", workspace: nil) == nil)
    }

    @Test("Least recently used transcripts are evicted beyond each server's count")
    func transcriptCountEviction() async throws {
        var limits = OpenCodeOfflineCache.Limits()
        limits.transcriptsPerServer = 2
        let cache = OpenCodeOfflineCache(root: root, limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let other = UUID()
        for id in ["one", "two"] {
            cache.saveTranscript([message(id, role: "user")], serverID: server, fingerprint: "print", sessionID: id, directory: "/p", workspace: nil)
            await cache.flush()
            try await Task.sleep(for: .milliseconds(20))
        }
        cache.saveTranscript([message("x", role: "user")], serverID: other, fingerprint: "print", sessionID: "x", directory: "/p", workspace: nil)
        // Opening "one" makes "two" the least recently used.
        _ = await cache.transcript(serverID: server, fingerprint: "print", sessionID: "one", directory: "/p", workspace: nil)
        try await Task.sleep(for: .milliseconds(20))
        cache.saveTranscript([message("three", role: "user")], serverID: server, fingerprint: "print", sessionID: "three", directory: "/p", workspace: nil)
        await cache.flush()
        func has(_ id: String, on serverID: UUID) async -> Bool {
            await cache.transcript(serverID: serverID, fingerprint: "print", sessionID: id, directory: "/p", workspace: nil) != nil
        }
        #expect(await has("one", on: server))
        #expect(await !has("two", on: server))
        #expect(await has("three", on: server))
        #expect(await has("x", on: other))
    }

    @Test("All servers' transcripts share one byte budget")
    func transcriptTotalEviction() async throws {
        let messages = [message("m", role: "user", text: String(repeating: "z", count: 2_000))]
        let size = try #require(OpenCodeOfflineCache.encodeTranscript(
            messages, limits: .init(), savedAt: Date(), fingerprint: "print", sessionID: "first")).count
        var limits = OpenCodeOfflineCache.Limits()
        limits.transcriptBytes = size * 2 + size / 2
        let cache = OpenCodeOfflineCache(root: root, limits: limits)
        defer { try? FileManager.default.removeItem(at: root) }
        let servers = [UUID(), UUID(), UUID()]
        for (index, serverID) in servers.enumerated() {
            cache.saveTranscript(messages, serverID: serverID, fingerprint: "print", sessionID: "s\(index)", directory: "/p", workspace: nil)
            await cache.flush()
            try await Task.sleep(for: .milliseconds(20))
        }
        func has(_ index: Int) async -> Bool {
            await cache.transcript(serverID: servers[index], fingerprint: "print", sessionID: "s\(index)", directory: "/p", workspace: nil) != nil
        }
        #expect(await !has(0))
        #expect(await has(1))
        #expect(await has(2))
    }

    @Test("Removing a server deletes everything saved for it, and only it")
    func removeServer() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let other = UUID()
        for serverID in [server, other] {
            cache.saveSessionList([.init(project: project("/p"), sessions: [session("a")])], serverID: serverID, fingerprint: "print")
            cache.saveTranscript([message("m", role: "user")], serverID: serverID, fingerprint: "print", sessionID: "a", directory: "/p", workspace: nil)
        }
        cache.removeServer(server)
        await cache.flush()
        #expect(cache.sessionList(serverID: server, fingerprint: "print") == nil)
        #expect(await cache.transcript(serverID: server, fingerprint: "print", sessionID: "a", directory: "/p", workspace: nil) == nil)
        #expect(cache.sessionList(serverID: other, fingerprint: "print") != nil)
        cache.retainServers([])
        await cache.flush()
        #expect(cache.sessionList(serverID: other, fingerprint: "print") == nil)
    }

    @Test("The fingerprint follows the address, user and directory, not the name")
    func fingerprint() {
        let base = OpenCodeServerProfile(id: server, name: "Mac", baseURL: "https://mac.example", directory: "/repo")
        var renamed = base
        renamed.name = "Studio"
        var slash = base
        slash.baseURL = "https://mac.example/"
        var moved = base
        moved.baseURL = "https://other.example"
        var user = base
        user.username = "someone"
        var directory = base
        directory.directory = "/elsewhere"
        let print = OpenCodeOfflineCache.fingerprint(of: base)
        #expect(OpenCodeOfflineCache.fingerprint(of: renamed) == print)
        #expect(OpenCodeOfflineCache.fingerprint(of: slash) == print)
        #expect(OpenCodeOfflineCache.fingerprint(of: moved) != print)
        #expect(OpenCodeOfflineCache.fingerprint(of: user) != print)
        #expect(OpenCodeOfflineCache.fingerprint(of: directory) != print)
    }

    // MARK: Session list

    @Test("The session list opens with saved sessions, then reconciles with the server")
    @MainActor
    func browserRestoresAndReconciles() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = OpenCodeOfflineCacheScope(cache: cache, profile: profile())
        let service = OfflineBrowserService()
        await service.set(["/one": [session("kept", directory: "/one"), session("gone", directory: "/one")]])
        let first = OpenCodeSessionBrowserStore(service: service, cache: scope)
        #expect(first.cachedAt == nil)
        await first.load(projects: [project("/one")])
        await cache.flush()

        await service.set(["/one": [session("kept", directory: "/one"), session("new", directory: "/one")]])
        let relaunched = OpenCodeSessionBrowserStore(service: service, cache: scope)
        #expect(relaunched.cachedAt != nil)
        #expect(Set(relaunched.sessions.map(\.id)) == ["kept", "gone"])
        #expect(relaunched.cachedProjects.map(\.worktree) == ["/one"])
        #expect(relaunched.groups.allSatisfy { $0.isLoaded && $0.statuses == nil && $0.error == nil })

        await relaunched.load(projects: [project("/one")])
        #expect(relaunched.cachedAt == nil)
        #expect(relaunched.cachedProjects.isEmpty)
        #expect(Set(relaunched.sessions.map(\.id)) == ["kept", "new"])
        await cache.flush()
        let saved = try #require(scope.sessionList())
        #expect(Set(saved.groups.flatMap(\.sessions).map(\.id)) == ["kept", "new"])
    }

    @Test("Saved sessions stay while the server can't list them")
    @MainActor
    func browserKeepsSavedSessionsOnFailure() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = OpenCodeOfflineCacheScope(cache: cache, profile: profile())
        scope.saveSessionList([.init(project: project("/one"), sessions: [session("saved", directory: "/one")])])
        await cache.flush()
        let service = OfflineBrowserService()
        await service.setFailing(true)
        let store = OpenCodeSessionBrowserStore(service: service, cache: scope)
        await store.load(projects: [project("/one")])
        #expect(store.sessions.map(\.id) == ["saved"])
        #expect(store.groups[0].error != nil)
        await cache.flush()
        #expect(scope.sessionList()?.groups.first?.sessions.map(\.id) == ["saved"])
    }

    @Test("A list saved for another address is not shown")
    @MainActor
    func browserIgnoresOtherAddress() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        OpenCodeOfflineCacheScope(cache: cache, profile: profile())
            .saveSessionList([.init(project: project("/one"), sessions: [session("saved")])])
        await cache.flush()
        var moved = profile()
        moved.baseURL = "https://moved.example"
        let store = OpenCodeSessionBrowserStore(service: OfflineBrowserService(),
                                                cache: OpenCodeOfflineCacheScope(cache: cache, profile: moved))
        #expect(store.groups.isEmpty)
        #expect(store.cachedAt == nil)
    }

    // MARK: Transcript

    @Test("A session shows its saved transcript until the server's arrives, then saves the new one")
    @MainActor
    func transcriptRestoresAndReconciles() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = OpenCodeOfflineCacheScope(cache: cache, profile: profile())
        let saved = [message("u1", role: "user", created: 1), message("a1", role: "assistant", created: 2)]
        scope.saveTranscript(saved, sessionID: "ses", directory: "/one", workspace: nil)
        await cache.flush()

        let service = OfflineTranscriptService(messages: saved + [message("u2", role: "user", created: 3)])
        await service.setFailing(true)
        let store = makeStore(service, cache: scope)
        await store.start()
        defer { store.stop() }
        for _ in 0..<100 where store.offlineTranscript == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.messages.map(\.id) == ["u1", "a1"])
        #expect(store.offlineTranscript != nil)
        #expect(store.errorMessage != nil)

        await service.setFailing(false)
        await store.refresh(showLoading: true)
        #expect(store.messages.map(\.id) == ["u1", "a1", "u2"])
        #expect(store.offlineTranscript == nil)
        store.saveOfflineTranscriptNow()
        await cache.flush()
        let refreshed = await scope.transcript(sessionID: "ses", directory: "/one", workspace: nil)
        #expect(refreshed?.messages.map(\.id) == ["u1", "a1", "u2"])
    }

    @Test("A saved transcript never replaces one the server already sent")
    @MainActor
    func transcriptServerWins() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = OpenCodeOfflineCacheScope(cache: cache, profile: profile())
        scope.saveTranscript([message("stale", role: "user")], sessionID: "ses", directory: "/one", workspace: nil)
        await cache.flush()
        let store = makeStore(OfflineTranscriptService(messages: [message("fresh", role: "user")]), cache: scope)
        await store.start()
        defer { store.stop() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.messages.map(\.id) == ["fresh"])
        #expect(store.offlineTranscript == nil)
    }

    @Test("Events streamed before the server's transcript update the saved one instead of hiding it")
    @MainActor
    func transcriptOverlaysStreamedEvents() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = OpenCodeOfflineCacheScope(cache: cache, profile: profile())
        let saved = [message("u1", role: "user", created: 1), message("a1", role: "assistant", created: 2)]
        scope.saveTranscript(saved, sessionID: "ses", directory: "/one", workspace: nil)
        await cache.flush()
        let service = OfflineTranscriptService(messages: [])
        await service.setFailing(true)
        let store = makeStore(service, cache: scope)
        await store.start()
        defer { store.stop() }
        for _ in 0..<100 where store.offlineTranscript == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.offlineTranscript != nil)

        let more = OpenCodePart(id: "a1-more", sessionID: "ses", messageID: "a1", type: "text", text: "More",
                                mime: nil, filename: nil, url: nil, callID: nil, tool: nil, state: nil,
                                files: nil, description: nil, agent: nil)
        store.handle(OpenCodeEvent(id: "e1", type: "message.part.updated", properties: ["part": try json(more)]))
        store.handle(OpenCodeEvent(id: "e2", type: "message.updated", properties: ["info": try json(saved[1].info)]))
        store.handle(OpenCodeEvent(id: "e3", type: "message.updated",
                                   properties: ["info": try json(message("u2", role: "user", created: 3).info)]))
        #expect(store.messages.map(\.id) == ["u1", "a1", "u2"])
        #expect(store.messages[1].parts.map(\.id) == ["a1-text", "a1-more"])
        #expect(store.offlineTranscript != nil)
    }

    @Test("An empty transcript from the server removes the saved copy")
    @MainActor
    func emptyServerTranscriptRemovesSavedCopy() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = OpenCodeOfflineCacheScope(cache: cache, profile: profile())
        scope.saveTranscript([message("stale", role: "user")], sessionID: "ses", directory: "/one", workspace: nil)
        await cache.flush()
        let store = makeStore(OfflineTranscriptService(messages: []), cache: scope)
        await store.start()
        store.stop()
        await cache.flush()
        #expect(await scope.transcript(sessionID: "ses", directory: "/one", workspace: nil) == nil)
    }

    @Test("A session with nothing saved and no server shows no transcript")
    @MainActor
    func transcriptMissWithoutServer() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = OfflineTranscriptService(messages: [])
        await service.setFailing(true)
        let store = makeStore(service, cache: OpenCodeOfflineCacheScope(cache: cache, profile: profile()))
        await store.start()
        defer { store.stop() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(store.messages.isEmpty)
        #expect(store.offlineTranscript == nil)
        store.saveOfflineTranscriptNow()
        await cache.flush()
        #expect(await cache.transcript(serverID: server, fingerprint: OpenCodeOfflineCache.fingerprint(of: profile()),
                                       sessionID: "ses", directory: "/one", workspace: nil) == nil)
    }

    // MARK: Profiles

    @Test("Opening the server list deletes what was saved for servers that no longer exist")
    @MainActor
    func profileStorePrunesRemovedServers() async throws {
        let cache = OpenCodeOfflineCache(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let removed = OpenCodeServerProfile(name: "Old", baseURL: "https://old.example")
        for profile in [profile(), removed] {
            OpenCodeOfflineCacheScope(cache: cache, profile: profile)
                .saveSessionList([.init(project: project("/one"), sessions: [session("a")])])
        }
        await cache.flush()
        let defaults = UserDefaults(suiteName: "offline-cache-\(UUID().uuidString)")!
        defaults.set(try JSONEncoder().encode([profile()]), forKey: "byot.opencode.profiles.v1")
        _ = OpenCodeProfileStore(defaults: defaults, offlineCache: cache)
        await cache.flush()
        #expect(OpenCodeOfflineCacheScope(cache: cache, profile: profile()).sessionList() != nil)
        #expect(OpenCodeOfflineCacheScope(cache: cache, profile: removed).sessionList() == nil)
    }

    // MARK: Fixtures

    private func profile() -> OpenCodeServerProfile {
        OpenCodeServerProfile(id: server, name: "Mac", baseURL: "https://mac.example")
    }

    private func project(_ directory: String) -> OpenCodeProject {
        OpenCodeProject(id: directory, worktree: directory, vcs: nil, name: nil,
                        time: OpenCodeProjectTime(created: 0, updated: 0), sandboxes: [])
    }

    private func session(_ id: String, directory: String = "/one", updated: Double = 1) -> OpenCodeSession {
        OpenCodeSession(id: id, slug: id, projectID: "project", workspaceID: nil, directory: directory, parentID: nil,
                        summary: nil, title: id, agent: nil, version: "1",
                        time: OpenCodeSessionTime(created: 0, updated: updated, compacting: nil, archived: nil))
    }

    private func message(_ id: String, role: String, text: String = "Hello", created: Double = 1) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessageInfo(id: id, sessionID: "ses", role: role,
                                      time: OpenCodeMessageTime(created: created, completed: nil), agent: nil,
                                      modelID: nil, providerID: nil, finish: nil, error: nil),
            parts: [OpenCodePart(id: "\(id)-text", sessionID: "ses", messageID: id, type: "text", text: text,
                                 mime: nil, filename: nil, url: nil, callID: nil, tool: nil, state: nil,
                                 files: nil, description: nil, agent: nil)])
    }

    private func json(_ value: some Encodable) throws -> OpenCodeJSONValue {
        try JSONDecoder().decode(OpenCodeJSONValue.self, from: JSONEncoder().encode(value))
    }

    @MainActor
    private func makeStore(_ service: OfflineTranscriptService, cache: OpenCodeOfflineCacheScope) -> OpenCodeSessionStore {
        OpenCodeSessionStore(service: service, serverID: server, session: session("ses"), directory: "/one",
                             defaults: UserDefaults(suiteName: UUID().uuidString)!, offlineCache: cache)
    }
}

private struct OfflineCacheTestError: LocalizedError {
    var errorDescription: String? { "The Internet connection appears to be offline." }
}

private actor OfflineBrowserService: OpenCodeSessionBrowsing {
    private var sessions: [String: [OpenCodeSession]] = [:]
    private var failing = false
    func set(_ value: [String: [OpenCodeSession]]) { sessions = value }
    func setFailing(_ value: Bool) { failing = value }
    func listSessions(directory: String) async throws -> [OpenCodeSession] {
        if failing { throw OfflineCacheTestError() }
        return sessions[directory] ?? []
    }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] {
        if failing { throw OfflineCacheTestError() }
        return [:]
    }
}

private actor OfflineTranscriptService: OpenCodeSessionServicing {
    private let transcript: [OpenCodeMessageEnvelope]
    private var failing = false
    init(messages: [OpenCodeMessageEnvelope]) { transcript = messages }
    func setFailing(_ value: Bool) { failing = value }
    private func check() throws { if failing { throw OfflineCacheTestError() } }
    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] { try check(); return [] }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] { try check(); return transcript }
    func sendMessage(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String,
                     attachments: [OpenCodePromptAttachment], promptID: UUID) async throws { try check() }
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool { try check(); return true }
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff] { try check(); return [] }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] { try check(); return [:] }
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest] { try check(); return [] }
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest] { try check(); return [] }
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] { [] }
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] { [] }
    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?, reply: OpenCodePermissionReply) async throws {}
    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws {}
    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?) async throws {}
    nonisolated func events(directory: String, workspace: String?) -> AsyncThrowingStream<OpenCodeEvent, Error> { AsyncThrowingStream { _ in } }
}
