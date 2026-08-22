import Foundation
import Testing
@testable import byot

@MainActor
struct OpenCodeSessionSharingTests {
    @Test("Sharing state follows the server-returned session through publish and unpublish")
    func publishAndUnpublish() async {
        let service = MockSessionSharingService()
        let store = OpenCodeSessionSharingStore(
            service: service,
            session: makeSession(shareURL: nil)
        )

        await store.loadCapabilities()
        #expect(store.presentation.canPublish)
        #expect(!store.presentation.canUnpublish)

        await store.publish()
        #expect(service.steps == [.capabilities, .publish])
        #expect(store.presentation.shareURL?.absoluteString == "https://share.example.test/ses_1")
        #expect(!store.presentation.canPublish)
        #expect(store.presentation.canUnpublish)

        await store.unpublish()
        #expect(service.steps == [.capabilities, .publish, .unpublish])
        #expect(store.presentation.shareURL == nil)
        #expect(store.presentation.canPublish)
        #expect(!store.presentation.canUnpublish)
    }

    @Test("Unavailable sharing is explained and never reaches the service mutation")
    func unavailable() async {
        let service = MockSessionSharingService(
            capabilities: .v2
        )
        let store = OpenCodeSessionSharingStore(
            service: service,
            session: makeSession(shareURL: nil)
        )

        await store.loadCapabilities()
        await store.publish()

        #expect(!store.presentation.canPublish)
        #expect(store.presentation.unavailableReason == OpenCodeProtocolCapabilities.v2.sessionSharing.unavailableReason)
        #expect(service.steps == [.capabilities])
    }

    @Test("Presenting sharing retries capabilities after a transient failure")
    func retriesCapabilitiesOnPresentation() async {
        let service = FlakySessionSharingService()
        let store = OpenCodeSessionSharingStore(
            service: service,
            session: makeSession(shareURL: nil)
        )

        await store.prepareForPresentation()
        #expect(store.support == nil)
        #expect(store.errorMessage != nil)

        await store.prepareForPresentation()
        #expect(store.support == .supported)
        #expect(store.errorMessage == nil)
        #expect(service.capabilityRequestCount == 2)
    }

    @Test("Server-returned sharing changes propagate to the owning session list")
    func propagatesSessionChanges() async {
        let service = MockSessionSharingService()
        var updates: [OpenCodeSession] = []
        let store = OpenCodeSessionSharingStore(
            service: service,
            session: makeSession(shareURL: nil),
            sessionDidChange: { updates.append($0) }
        )

        await store.loadCapabilities()
        await store.publish()
        await store.unpublish()

        #expect(updates.map { $0.share?.url.absoluteString } == [
            "https://share.example.test/ses_1",
            nil,
        ])
    }

    private func makeSession(shareURL: URL?) -> OpenCodeSession {
        OpenCodeSession(
            id: "ses_1",
            slug: "first",
            projectID: "proj_1",
            workspaceID: "wrk_1",
            directory: "/repo",
            parentID: nil,
            share: shareURL.map(OpenCodeSessionShare.init(url:)),
            summary: nil,
            title: "First",
            agent: nil,
            version: "1",
            time: OpenCodeSessionTime(
                created: 10,
                updated: 20,
                compacting: nil,
                archived: nil
            )
        )
    }
}

private final class FlakySessionSharingService: OpenCodeSessionSharingServicing, @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var requestCount = 0

    var capabilityRequestCount: Int {
        lock.withLock { requestCount }
    }

    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities {
        let attempt = lock.withLock {
            requestCount += 1
            return requestCount
        }
        if attempt == 1 {
            throw OpenCodeConnectionError.server("Temporary capability failure")
        }
        return .v1
    }

    func shareSession(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeSession {
        throw OpenCodeConnectionError.invalidResponse
    }

    func unshareSession(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeSession {
        throw OpenCodeConnectionError.invalidResponse
    }
}

private final class MockSessionSharingService: OpenCodeSessionSharingServicing, @unchecked Sendable {
    enum Step: Equatable {
        case capabilities
        case publish
        case unpublish
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var recordedSteps: [Step] = []
    private let capabilities: OpenCodeProtocolCapabilities

    init(capabilities: OpenCodeProtocolCapabilities = .v1) {
        self.capabilities = capabilities
    }

    var steps: [Step] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSteps
    }

    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities {
        record(.capabilities)
        return capabilities
    }

    func shareSession(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeSession {
        record(.publish)
        return makeResponse(shareURL: URL(string: "https://share.example.test/ses_1")!)
    }

    func unshareSession(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeSession {
        record(.unpublish)
        return makeResponse(shareURL: nil)
    }

    private func makeResponse(shareURL: URL?) -> OpenCodeSession {
        OpenCodeSession(
            id: "ses_1",
            slug: "first",
            projectID: "proj_1",
            workspaceID: "wrk_1",
            directory: "/repo",
            parentID: nil,
            share: shareURL.map(OpenCodeSessionShare.init(url:)),
            summary: nil,
            title: "First",
            agent: nil,
            version: "1",
            time: OpenCodeSessionTime(
                created: 10,
                updated: 30,
                compacting: nil,
                archived: nil
            )
        )
    }

    private func record(_ step: Step) {
        lock.lock()
        recordedSteps.append(step)
        lock.unlock()
    }
}
