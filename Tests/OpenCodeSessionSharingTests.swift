import Foundation
import Testing
@testable import byot

@Suite("Session sharing")
struct OpenCodeSessionSharingTests {
    @Test("V1 publishes and unpublishes through the scoped share route and keeps the server's link")
    func v1Requests() async throws {
        let transport = ShareTransport(v2: false)
        let service = shareService(transport: transport, v2: false)
        #expect(service.support.share)

        let published = try await service.share("ses_one", directory: "/project", workspace: "wrk_one")
        #expect(published.share?.link == URL(string: "https://opncd.ai/share/abc123"))
        let unpublished = try await service.unshare("ses_one", directory: "/project", workspace: "wrk_one")
        #expect(unpublished.share == nil)
        #expect(try await service.sharePolicy(directory: "/project", workspace: "wrk_one") == .disabled)

        let requests = await transport.requests
        #expect(requests.map(\.httpMethod) == ["POST", "DELETE", "GET"])
        #expect(requests.map { $0.url!.path } == ["/session/ses_one/share", "/session/ses_one/share", "/config"])
        #expect(requests.allSatisfy { $0.httpBody == nil })
        #expect(requests.allSatisfy {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems
                == [URLQueryItem(name: "directory", value: "/project"), URLQueryItem(name: "workspace", value: "wrk_one")]
        })
    }

    @Test("The v2 session API has no publish operation, so sharing is hidden without a request")
    func v2HidesSharing() async throws {
        let transport = ShareTransport(v2: true)
        let service = shareService(transport: transport, v2: true)
        #expect(!service.support.share)
        #expect(try await service.sharePolicy(directory: "/project", workspace: nil) == .disabled)
        await #expect(throws: OpenCodeSessionFeatureError.self) {
            _ = try await service.share("ses_one", directory: "/project", workspace: nil)
        }
        await #expect(throws: OpenCodeSessionFeatureError.self) {
            _ = try await service.unshare("ses_one", directory: "/project", workspace: nil)
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test("Share policy follows OpenCode's config, including the deprecated autoshare flag")
    func policyParsing() {
        #expect(OpenCodeSessionSharePolicy(config: .object([:])) == .manual)
        #expect(OpenCodeSessionSharePolicy(config: .object(["share": .string("manual")])) == .manual)
        #expect(OpenCodeSessionSharePolicy(config: .object(["share": .string("auto")])) == .auto)
        #expect(OpenCodeSessionSharePolicy(config: .object(["share": .string("disabled")])) == .disabled)
        #expect(OpenCodeSessionSharePolicy(config: .object(["autoshare": .bool(true)])) == .auto)
        #expect(OpenCodeSessionSharePolicy(config: .object(["share": .string("disabled"), "autoshare": .bool(true)])) == .disabled)
        #expect(OpenCodeSessionSharePolicy(config: .object(["share": .string("future")])) == .manual)
    }

    @Test("Only an absolute web link from the server counts as published")
    func linkValidation() {
        #expect(OpenCodeSessionShare(url: "https://opncd.ai/share/abc").link == URL(string: "https://opncd.ai/share/abc"))
        #expect(OpenCodeSessionShare(url: " http://share.internal/s/1 ").link == URL(string: "http://share.internal/s/1"))
        #expect(OpenCodeSessionShare(url: "").link == nil)
        #expect(OpenCodeSessionShare(url: "/share/abc").link == nil)
        #expect(OpenCodeSessionShare(url: "javascript:alert(1)").link == nil)
        #expect(OpenCodeSessionShare(url: "https://").link == nil)
    }

    @Test("Sessions decode share state from v1 JSON and v2 snapshots")
    func sessionDecoding() throws {
        let v1 = try JSONDecoder().decode(OpenCodeSession.self, from: Data(#"{"id":"ses_one","slug":"one","projectID":"p","directory":"/project","title":"One","version":"1.18.21","time":{"created":1,"updated":2},"share":{"url":"https://opncd.ai/share/one"}}"#.utf8))
        #expect(v1.share?.link == URL(string: "https://opncd.ai/share/one"))
        let privateV1 = try JSONDecoder().decode(OpenCodeSession.self, from: Data(#"{"id":"ses_two","slug":"two","projectID":"p","directory":"/project","title":"Two","version":"1.18.21","time":{"created":1,"updated":2}}"#.utf8))
        #expect(privateV1.share == nil)
        let v2 = OpenCodeV2Normalization.session(["id": .string("ses_three"), "share": .object(["url": .string("https://opncd.ai/share/three")])])
        #expect(v2?.share?.link == URL(string: "https://opncd.ai/share/three"))
    }

    @Test("Controls hide for unsupported or disabled servers but a published session can always go private")
    func presentation() {
        let link = URL(string: "https://opncd.ai/share/abc")
        let unknown = OpenCodeSessionSharePresentation(link: nil, isSupported: true, policy: nil, isUpdating: false)
        #expect(unknown.isAvailable && unknown.canPublish && !unknown.canUnpublish)
        #expect(unknown.menuTitle == "Publish on web")

        let disabled = OpenCodeSessionSharePresentation(link: nil, isSupported: true, policy: .disabled, isUpdating: false)
        #expect(!disabled.isAvailable && !disabled.canPublish)

        let publishedWhileDisabled = OpenCodeSessionSharePresentation(link: link, isSupported: true, policy: .disabled, isUpdating: false)
        #expect(publishedWhileDisabled.isAvailable && publishedWhileDisabled.canUnpublish && !publishedWhileDisabled.canPublish)
        #expect(publishedWhileDisabled.menuTitle == "Share link")

        let unsupported = OpenCodeSessionSharePresentation(link: link, isSupported: false, policy: .manual, isUpdating: false)
        #expect(unsupported.isPublished && !unsupported.isAvailable && !unsupported.canUnpublish)

        let updating = OpenCodeSessionSharePresentation(link: link, isSupported: true, policy: .manual, isUpdating: true)
        #expect(!updating.canUnpublish && !updating.canPublish)
    }

    @Test("Publishing and unpublishing update the session without blocking the composer")
    @MainActor
    func storePublishAndUnpublish() async throws {
        let service = ShareStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        await store.refreshSessionFeatures()
        #expect(store.sharePolicy == .manual)
        #expect(store.sharePresentation.canPublish)

        await service.pauseShare()
        let publish = Task { await store.publishShareLink() }
        for _ in 0..<100 {
            if await service.shareStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.isUpdatingShare)
        #expect(!store.isPerformingSessionAction)
        #expect(!store.sharePresentation.canPublish)
        #expect(await store.publishShareLink() == false)
        await service.resumeShare()
        #expect(await publish.value)
        #expect(store.sharePresentation.link == URL(string: "https://opncd.ai/share/abc123"))
        #expect(store.shareErrorMessage == nil)

        #expect(await store.unpublishShareLink())
        #expect(!store.sharePresentation.isPublished)
        #expect(await service.shareCalls == 1)
        #expect(await service.unshareCalls == 1)
    }

    @Test("A details snapshot started before publishing cannot hide the confirmed link")
    @MainActor
    func confirmedShareWinsOverConcurrentDetails() async throws {
        let service = ShareStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        await service.pauseDetails()
        let refresh = Task { await store.refreshSessionFeatures() }
        for _ in 0..<100 {
            if await service.detailsStarted { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await service.detailsStarted)
        #expect(await store.publishShareLink())
        await service.resumeDetails()
        await refresh.value
        #expect(store.sharePresentation.isPublished)
    }

    @Test("Failures and link-less responses leave the session private with an explanation")
    @MainActor
    func storeFailures() async throws {
        let service = ShareStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        await store.refreshSessionFeatures()

        await service.setShareFailure(OpenCodeSessionFeatureError(message: "Share service unreachable"))
        #expect(await store.publishShareLink() == false)
        #expect(store.shareErrorMessage == "Share service unreachable")
        #expect(!store.sharePresentation.isPublished)

        await service.setShareFailure(nil)
        await service.setReturnedURL("")
        #expect(await store.publishShareLink() == false)
        #expect(store.shareErrorMessage?.contains("didn’t return a link") == true)
        #expect(!store.sharePresentation.isPublished)

        store.clearShareError()
        #expect(store.shareErrorMessage == nil)
    }

    @Test("A disabled server hides publishing; a failed config read keeps it offered")
    @MainActor
    func storePolicy() async throws {
        let disabledService = ShareStoreService(policy: .disabled)
        let disabled = makeStore(disabledService)
        await disabled.start()
        defer { disabled.stop() }
        await disabled.refreshSessionFeatures()
        #expect(disabled.sharePolicy == .disabled)
        #expect(!disabled.sharePresentation.isAvailable)
        #expect(await disabled.publishShareLink() == false)
        #expect(await disabledService.shareCalls == 0)

        let failingService = ShareStoreService(policy: nil)
        let failing = makeStore(failingService)
        await failing.start()
        defer { failing.stop() }
        await failing.refreshSessionFeatures()
        #expect(failing.sharePolicy == nil)
        #expect(failing.sharePresentation.canPublish)
    }

    @Test("Share state published by another client updates the session live")
    @MainActor
    func liveSessionUpdate() async throws {
        let service = ShareStoreService()
        let store = makeStore(service)
        await store.start()
        defer { store.stop() }
        var shared = sharingSession()
        shared.share = OpenCodeSessionShare(url: "https://opncd.ai/share/live")
        let info = try JSONDecoder().decode(OpenCodeJSONValue.self, from: JSONEncoder().encode(shared))
        store.handle(OpenCodeEvent(id: "shared", type: "session.updated", properties: ["sessionID": .string("ses_one"), "info": info]))
        #expect(store.sharePresentation.link == URL(string: "https://opncd.ai/share/live"))

        let privateInfo = try JSONDecoder().decode(OpenCodeJSONValue.self, from: JSONEncoder().encode(sharingSession()))
        store.handle(OpenCodeEvent(id: "private", type: "session.updated", properties: ["sessionID": .string("ses_one"), "info": privateInfo]))
        #expect(!store.sharePresentation.isPublished)
    }

    @MainActor private func makeStore(_ service: ShareStoreService) -> OpenCodeSessionStore {
        OpenCodeSessionStore(service: service, serverID: UUID(), session: sharingSession(), directory: "/project", defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }
}

private func sharingSession(share: OpenCodeSessionShare? = nil) -> OpenCodeSession {
    OpenCodeSession(id: "ses_one", slug: "ses_one", projectID: "project", workspaceID: nil, directory: "/project", parentID: nil, summary: nil, title: "Session", agent: nil, version: "1", time: OpenCodeSessionTime(created: 1, updated: 2, compacting: nil, archived: nil), share: share)
}

private func shareService(transport: ShareTransport, v2: Bool) -> OpenCodeSessionFeatureService {
    // A v2 schema that lists every other session route still offers no share route.
    let routes = ["/api/session", "/api/session/{sessionID}", "/api/session/{sessionID}/fork"]
    let operations: OpenCodeJSONValue = .object(["get": .object([:]), "post": .object([:]), "delete": .object([:])])
    let schema: OpenCodeJSONValue = .object(["paths": .object(Dictionary(uniqueKeysWithValues: routes.map { ($0, operations) }))])
    return OpenCodeSessionFeatureService(context: OpenCodeFeatureContext(serverProtocol: v2 ? .v2 : .v1, schema: schema, transport: transport, profile: OpenCodeServerProfile(name: "Test", baseURL: "https://test.example", directory: "/project")))
}

private actor ShareTransport: OpenCodeHTTPTransport {
    let v2: Bool
    var requests: [URLRequest] = []
    init(v2: Bool) { self.v2 = v2 }
    nonisolated func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        var components = URLComponents(string: "https://share.test/" + path.joined(separator: "/"))!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        return request
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let result: OpenCodeJSONValue
        if request.url!.path == "/config" {
            result = .object(["share": .string("disabled"), "model": .string("provider/model")])
        } else {
            let share = request.httpMethod == "POST" ? OpenCodeSessionShare(url: "https://opncd.ai/share/abc123") : nil
            result = try JSONDecoder().decode(OpenCodeJSONValue.self, from: JSONEncoder().encode(sharingSession(share: share)))
        }
        return (try JSONEncoder().encode(result), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
    nonisolated func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> { AsyncThrowingStream { _ in } }
}

private actor ShareStoreService: OpenCodeSessionServicing, OpenCodeSessionFeatureServicing {
    private let policy: OpenCodeSessionSharePolicy?
    private var current = sharingSession()
    private var returnedURL = "https://opncd.ai/share/abc123"
    private var shareFailure: Error?
    private var sharePaused = false
    private var shareContinuation: CheckedContinuation<Void, Never>?
    private var detailsPaused = false
    private var detailsContinuation: CheckedContinuation<Void, Never>?
    var shareStarted = false
    var detailsStarted = false
    var shareCalls = 0
    var unshareCalls = 0

    init(policy: OpenCodeSessionSharePolicy? = .manual) { self.policy = policy }

    func pauseShare() { sharePaused = true }
    func resumeShare() { sharePaused = false; shareContinuation?.resume(); shareContinuation = nil }
    func pauseDetails() { detailsPaused = true }
    func resumeDetails() { detailsPaused = false; detailsContinuation?.resume(); detailsContinuation = nil }
    func setShareFailure(_ error: Error?) { shareFailure = error }
    func setReturnedURL(_ url: String) { returnedURL = url }

    func sessionFeatureSupport() async throws -> OpenCodeSessionFeatureSupport { OpenCodeSessionFeatureSupport(details: true, share: true) }
    func sessionDetails(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSessionDetails {
        let snapshot = OpenCodeSessionDetails(session: current, revertMessageID: nil)
        if detailsPaused {
            detailsStarted = true
            await withCheckedContinuation { detailsContinuation = $0 }
        }
        return snapshot
    }
    func sessionSharePolicy(directory: String, workspace: String?) async throws -> OpenCodeSessionSharePolicy {
        guard let policy else { throw OpenCodeSessionFeatureError(message: "Config unavailable") }
        return policy
    }
    func shareSession(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSession {
        shareStarted = true
        shareCalls += 1
        if sharePaused { await withCheckedContinuation { shareContinuation = $0 } }
        if let shareFailure { throw shareFailure }
        current = sharingSession(share: OpenCodeSessionShare(url: returnedURL))
        return current
    }
    func unshareSession(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSession {
        unshareCalls += 1
        current = sharingSession()
        return current
    }
    func renameSession(sessionID: String, directory: String, workspace: String?, title: String) async throws -> OpenCodeSessionDetails {
        OpenCodeSessionDetails(session: current, revertMessageID: nil)
    }
    func deleteSession(sessionID: String, directory: String, workspace: String?) async throws {}
    func archiveSession(sessionID: String, directory: String, workspace: String?) async throws {}
    func childSessions(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeSession] { [] }
    func sessionTodos(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeTodo]? { nil }
    func stageSessionRevert(sessionID: String, directory: String, workspace: String?, messageID: String) async throws {}
    func clearSessionRevert(sessionID: String, directory: String, workspace: String?) async throws {}
    func commitSessionRevert(sessionID: String, directory: String, workspace: String?) async throws -> Bool { false }
    func compactSession(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?) async throws {}
    func forkSession(sessionID: String, directory: String, workspace: String?, beforeMessageID: String?) async throws -> OpenCodeSession { current }
    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] { [] }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] { [] }
    func sendMessage(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String,
                     attachments: [OpenCodePromptAttachment], promptID: UUID) async throws {}
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool { true }
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff] { [] }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] { [:] }
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest] { [] }
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest] { [] }
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] { [] }
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] { [] }
    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?,
               reply: OpenCodePermissionReply) async throws {}
    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws {}
    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?) async throws {}
    nonisolated func events(directory: String, workspace: String?) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { _ in }
    }
}
