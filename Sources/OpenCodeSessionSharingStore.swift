import Combine
import Foundation

struct OpenCodeSessionSharingPresentation: Equatable, Sendable {
    let shareURL: URL?
    let support: OpenCodeFeatureSupport?
    let isMutating: Bool
    let isMutationAvailable: Bool

    var canPublish: Bool {
        support?.isSupported == true
            && shareURL == nil
            && !isMutating
            && isMutationAvailable
    }

    var canUnpublish: Bool {
        support?.isSupported == true
            && shareURL != nil
            && !isMutating
            && isMutationAvailable
    }

    var unavailableReason: String? {
        support?.unavailableReason
    }
}

enum OpenCodeChildSessionReconciliation {
    static func replacing(
        _ updatedSession: OpenCodeSession,
        in sessions: [OpenCodeSession]
    ) -> [OpenCodeSession] {
        guard sessions.contains(where: { $0.id == updatedSession.id }) else {
            return sessions
        }
        return sessions
            .map { $0.id == updatedSession.id ? updatedSession : $0 }
            .sorted { $0.time.updated > $1.time.updated }
    }
}

@MainActor
final class OpenCodeSessionSharingStore: ObservableObject {
    @Published private(set) var session: OpenCodeSession
    @Published private(set) var support: OpenCodeFeatureSupport?
    @Published private(set) var isLoadingCapabilities = false
    @Published private(set) var isMutating = false
    @Published var errorMessage: String?

    private let service: OpenCodeSessionSharingServicing
    private let sessionDidChange: @MainActor (OpenCodeSession) -> Void
    private let mutationCoordinator: OpenCodeSessionMutationCoordinator

    init(
        service: OpenCodeSessionSharingServicing,
        session: OpenCodeSession,
        mutationCoordinator: OpenCodeSessionMutationCoordinator? = nil,
        sessionDidChange: @escaping @MainActor (OpenCodeSession) -> Void = { _ in }
    ) {
        self.service = service
        self.session = session
        self.mutationCoordinator = mutationCoordinator ?? OpenCodeSessionMutationCoordinator()
        self.sessionDidChange = sessionDidChange
    }

    func prepareForPresentation() async {
        errorMessage = nil
        await loadCapabilities()
    }

    var presentation: OpenCodeSessionSharingPresentation {
        OpenCodeSessionSharingPresentation(
            shareURL: session.share?.url,
            support: support,
            isMutating: isMutating,
            isMutationAvailable: mutationCoordinator.isAvailable
        )
    }

    func reconcileSession(_ updatedSession: OpenCodeSession) {
        guard !isMutating,
              updatedSession.id == session.id,
              updatedSession != session
        else { return }
        session = updatedSession
    }

    func loadCapabilities() async {
        guard support == nil, !isLoadingCapabilities else { return }
        isLoadingCapabilities = true
        errorMessage = nil
        defer { isLoadingCapabilities = false }
        do {
            support = try await service.protocolCapabilities().sessionSharing
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func publish() async {
        guard presentation.canPublish else { return }
        await mutate { service, session in
            try await service.shareSession(
                sessionID: session.id,
                directory: session.directory,
                workspace: session.workspaceID
            )
        }
    }

    func unpublish() async {
        guard presentation.canUnpublish else { return }
        await mutate { service, session in
            try await service.unshareSession(
                sessionID: session.id,
                directory: session.directory,
                workspace: session.workspaceID
            )
        }
    }

    private func mutate(
        _ request: @escaping @Sendable (
            OpenCodeSessionSharingServicing,
            OpenCodeSession
        ) async throws -> OpenCodeSession
    ) async {
        let owner = OpenCodeSessionMutationOwner.sharing
        guard !isMutating, mutationCoordinator.acquire(owner) else { return }
        isMutating = true
        errorMessage = nil
        let current = session
        defer {
            isMutating = false
            mutationCoordinator.release(owner)
        }
        do {
            session = try await request(service, current)
            sessionDidChange(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
