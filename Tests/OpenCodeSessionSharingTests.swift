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

    @Test("Reopening sharing clears a stale mutation failure")
    func presentationClearsMutationFailure() async {
        let store = OpenCodeSessionSharingStore(
            service: FailingMutationSessionSharingService(),
            session: makeSession(shareURL: nil)
        )
        await store.loadCapabilities()
        await store.publish()
        #expect(store.errorMessage != nil)

        await store.prepareForPresentation()

        #expect(store.support == .supported)
        #expect(store.errorMessage == nil)
        #expect(store.presentation.canPublish)
    }

    @Test("Cancelling capability discovery does not present an error")
    func cancelledCapabilityDiscovery() async {
        let store = OpenCodeSessionSharingStore(
            service: CancelledCapabilitySessionSharingService(),
            session: makeSession(shareURL: nil)
        )

        await store.loadCapabilities()

        #expect(store.support == nil)
        #expect(!store.isLoadingCapabilities)
        #expect(store.errorMessage == nil)
    }

    @Test("Sharing and history changes exclusively own the session mutation coordinator")
    func sessionMutationCoordinatorIsExclusive() {
        let coordinator = OpenCodeSessionMutationCoordinator()

        #expect(coordinator.acquire(.history(.revert)))
        #expect(!coordinator.acquire(.sharing))
        coordinator.release(.history(.revert))

        #expect(coordinator.acquire(.sharing))
        #expect(!coordinator.acquire(.history(.unrevert)))
        coordinator.release(.sharing)
        #expect(coordinator.owner == nil)
    }

    @Test("A history change blocks sharing before the service mutation")
    func historyMutationBlocksSharing() async {
        let coordinator = OpenCodeSessionMutationCoordinator()
        let service = MockSessionSharingService()
        let store = OpenCodeSessionSharingStore(
            service: service,
            session: makeSession(shareURL: nil),
            mutationCoordinator: coordinator
        )
        await store.loadCapabilities()
        #expect(coordinator.acquire(.history(.revert)))

        await store.publish()

        #expect(!store.presentation.canPublish)
        #expect(service.steps == [.capabilities])
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

    @Test("A sharing reconciliation invalidates an older session-list reload")
    func sharingInvalidatesStaleReload() {
        var state = OpenCodeSessionLifecycleState(
            sessions: [makeSession(shareURL: nil)]
        )
        var version = OpenCodeSessionLifecycleRequestVersion()
        let staleLoad = version.beginLoad()
        let sharedURL = URL(string: "https://share.example.test/ses_1")!

        OpenCodeSessionLifecycleReconciliation.apply(
            makeSession(shareURL: sharedURL),
            to: &state,
            requestVersion: &version
        )

        #expect(!version.accepts(load: staleLoad))
        #expect(state.sessions.first?.share?.url == sharedURL)
    }

    @Test("An open sharing presentation follows a newer server session")
    func sharingPresentationReconcilesServerSession() {
        let store = OpenCodeSessionSharingStore(
            service: MockSessionSharingService(),
            session: makeSession(shareURL: nil)
        )
        let sharedURL = URL(string: "https://share.example.test/ses_1")!

        store.reconcileSession(makeSession(shareURL: sharedURL))

        #expect(store.presentation.shareURL == sharedURL)
        #expect(store.presentation.canUnpublish == false)
    }

    @Test("A sharing change replaces the matching subagent session")
    func childSessionReconciliation() {
        let sharedURL = URL(string: "https://share.example.test/ses_1")!
        let original = makeSession(shareURL: nil)
        let unrelated = OpenCodeSession(
            id: "ses_2",
            slug: "second",
            projectID: "proj_1",
            workspaceID: "wrk_1",
            directory: "/repo",
            parentID: "ses_parent",
            share: nil,
            summary: nil,
            title: "Second",
            agent: nil,
            version: "1",
            time: OpenCodeSessionTime(
                created: 5,
                updated: 10,
                compacting: nil,
                archived: nil
            )
        )

        let reconciled = OpenCodeChildSessionReconciliation.replacing(
            makeSession(shareURL: sharedURL),
            in: [original, unrelated]
        )

        #expect(reconciled.count == 2)
        #expect(reconciled.first?.id == original.id)
        #expect(reconciled.first?.share?.url == sharedURL)
        #expect(reconciled.last?.id == unrelated.id)
    }

    @Test("Subagent changes are excluded from the root project session list")
    func childSessionIsNotAProjectRoot() {
        let root = makeSession(shareURL: nil)
        let child = OpenCodeSession(
            id: "ses_child",
            slug: "child",
            projectID: "proj_1",
            workspaceID: "wrk_1",
            directory: "/repo",
            parentID: root.id,
            share: nil,
            summary: nil,
            title: "Child",
            agent: "build",
            version: "1",
            time: OpenCodeSessionTime(
                created: 10,
                updated: 20,
                compacting: nil,
                archived: nil
            )
        )

        #expect(OpenCodeProjectSessionReconciliation.accepts(root))
        #expect(!OpenCodeProjectSessionReconciliation.accepts(child))
    }

    @Test("Only local share mutations propagate through the owner callback")
    func ownerChangeCallback() async {
        var ownerChanges: [OpenCodeSession] = []
        let store = OpenCodeSessionSharingStore(
            service: MockSessionSharingService(),
            session: makeSession(shareURL: nil),
            sessionDidChange: { ownerChanges.append($0) }
        )
        let refreshedURL = URL(string: "https://share.example.test/refreshed")!

        store.reconcileSession(makeSession(shareURL: refreshedURL))
        #expect(ownerChanges.isEmpty)

        await store.loadCapabilities()
        await store.unpublish()
        #expect(ownerChanges.count == 1)
        #expect(ownerChanges.first?.share == nil)
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

private final class CancelledCapabilitySessionSharingService: OpenCodeSessionSharingServicing,
    @unchecked Sendable
{
    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities {
        throw CancellationError()
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

private final class FailingMutationSessionSharingService: OpenCodeSessionSharingServicing,
    @unchecked Sendable
{
    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities {
        .v1
    }

    func shareSession(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeSession {
        throw OpenCodeConnectionError.server("Temporary sharing failure")
    }

    func unshareSession(
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeSession {
        throw OpenCodeConnectionError.server("Temporary sharing failure")
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
