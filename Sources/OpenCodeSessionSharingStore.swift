import Combine
import Foundation

struct OpenCodeSessionSharingPresentation: Equatable, Sendable {
    let shareURL: URL?
    let support: OpenCodeFeatureSupport?
    let isMutating: Bool

    var canPublish: Bool {
        support?.isSupported == true && shareURL == nil && !isMutating
    }

    var canUnpublish: Bool {
        support?.isSupported == true && shareURL != nil && !isMutating
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

enum OpenCodeSessionOwnerChangePropagation {
    enum Source: Equatable, Sendable {
        case sessionRefresh
        case sharingMutation
    }

    static func shouldNotifyOwner(source: Source) -> Bool {
        source == .sharingMutation
    }
}

@MainActor
final class OpenCodeSessionSharingStore: ObservableObject {
    @Published private(set) var session: OpenCodeSession
    @Published private(set) var support: OpenCodeFeatureSupport?
    @Published private(set) var isLoadingCapabilities = false
    @Published private(set) var isMutating = false
    @Published private(set) var ownerMutationRevision = 0
    @Published var errorMessage: String?

    private let service: OpenCodeSessionSharingServicing
    private let sessionDidChange: @MainActor (OpenCodeSession) -> Void

    init(
        service: OpenCodeSessionSharingServicing,
        session: OpenCodeSession,
        sessionDidChange: @escaping @MainActor (OpenCodeSession) -> Void = { _ in }
    ) {
        self.service = service
        self.session = session
        self.sessionDidChange = sessionDidChange
    }

    func prepareForPresentation() async {
        await loadCapabilities()
    }

    var presentation: OpenCodeSessionSharingPresentation {
        OpenCodeSessionSharingPresentation(
            shareURL: session.share?.url,
            support: support,
            isMutating: isMutating
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
        guard !isMutating else { return }
        isMutating = true
        errorMessage = nil
        let current = session
        defer { isMutating = false }
        do {
            session = try await request(service, current)
            ownerMutationRevision &+= 1
            sessionDidChange(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
