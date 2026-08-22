import Combine
import Foundation

@MainActor
final class OpenCodeProjectStore: ObservableObject {
    @Published private(set) var lifecycleState = OpenCodeSessionLifecycleState()
    @Published private(set) var protocolCapabilities: OpenCodeProtocolCapabilities?
    @Published private(set) var isLoading = false
    @Published private(set) var isCreating = false
    @Published private(set) var mutatingSessionIDs: Set<String> = []
    @Published var errorMessage: String?

    let client: OpenCodeClient
    let directory: String
    private var loadGeneration = 0

    init(client: OpenCodeClient, directory: String) {
        self.client = client
        self.directory = directory
    }

    var sessions: [OpenCodeSession] { lifecycleState.sessions }
    var statuses: [String: OpenCodeSessionStatus] { lifecycleState.statuses }

    var lifecyclePolicy: OpenCodeSessionLifecyclePolicy? {
        protocolCapabilities.map(OpenCodeSessionLifecyclePolicy.init)
    }

    func isMutating(sessionID: String) -> Bool {
        mutatingSessionIDs.contains(sessionID)
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let capabilities = try await client.protocolCapabilities()
            try Task.checkCancellation()
            guard generation == loadGeneration else { return }
            async let sessionsRequest = client.listSessions(directory: directory)
            async let statusesRequest = client.sessionStatuses(directory: directory)
            let (sessions, statuses) = try await (sessionsRequest, statusesRequest)
            guard generation == loadGeneration else { return }
            lifecycleState.replace(sessions: sessions, statuses: statuses)
            protocolCapabilities = capabilities
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func createSession(title: String?) async -> OpenCodeSession? {
        guard !isCreating else { return nil }
        loadGeneration &+= 1
        isLoading = false
        isCreating = true
        defer { isCreating = false }
        do {
            let session = try await client.createSession(directory: directory, title: title)
            lifecycleState.upsert(session)
            errorMessage = nil
            return session
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func renameSession(_ session: OpenCodeSession, title: String) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lifecyclePolicy?.canRename == true,
              !title.isEmpty,
              mutatingSessionIDs.insert(session.id).inserted
        else { return false }
        defer { mutatingSessionIDs.remove(session.id) }
        do {
            let updated = try await client.renameSession(
                sessionID: session.id,
                title: title,
                directory: session.directory,
                workspace: session.workspaceID
            )
            lifecycleState.upsert(updated)
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteSession(_ session: OpenCodeSession) async -> Bool {
        guard lifecyclePolicy?.canDelete == true,
              mutatingSessionIDs.insert(session.id).inserted
        else { return false }
        defer { mutatingSessionIDs.remove(session.id) }
        do {
            try await client.deleteSession(
                sessionID: session.id,
                directory: session.directory,
                workspace: session.workspaceID
            )
            lifecycleState.remove(sessionID: session.id)
            errorMessage = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
