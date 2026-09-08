import Combine
import Foundation

@MainActor
final class OpenCodeProjectStore: ObservableObject {
    @Published private(set) var sessions: [OpenCodeSession] = []
    @Published private(set) var statuses: [String: OpenCodeSessionStatus] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isCreating = false
    @Published var errorMessage: String?

    private let service: any OpenCodeProjectServicing
    let directory: String
    private var loadGeneration = 0

    init(service: any OpenCodeProjectServicing, directory: String) {
        self.service = service
        self.directory = directory
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            async let sessionsRequest = service.listSessions(directory: directory)
            async let statusesRequest = service.sessionStatuses(directory: directory, workspace: nil)
            let (sessions, statuses) = try await (sessionsRequest, statusesRequest)
            guard generation == loadGeneration else { return }
            self.sessions = sessions.sorted { $0.time.updated > $1.time.updated }
            self.statuses = statuses
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
            let session = try await service.createSession(directory: directory, title: title)
            sessions.removeAll { $0.id == session.id }
            sessions.insert(session, at: 0)
            statuses[session.id] = .idle
            errorMessage = nil
            return session
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}
