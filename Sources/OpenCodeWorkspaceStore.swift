import Combine
import Foundation

@MainActor
final class OpenCodeWorkspaceStore: ObservableObject {
    @Published private(set) var projects: [OpenCodeProject] = []
    @Published private(set) var isLoading = false
    @Published private(set) var compatibility: OpenCodeCompatibilitySummary?
    @Published var errorMessage: String?

    let client: OpenCodeClient
    private let service: any OpenCodeWorkspaceServicing
    private var loadGeneration = 0

    init(client: OpenCodeClient) {
        self.client = client
        service = client
    }

    init(client: OpenCodeClient, service: any OpenCodeWorkspaceServicing) {
        self.client = client
        self.service = service
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        let summary: OpenCodeCompatibilitySummary
        do {
            summary = try await service.probeCompatibility()
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            compatibility = nil
            errorMessage = error.localizedDescription
            return
        }
        guard generation == loadGeneration else { return }
        compatibility = summary
        guard summary.state != .unsupported else {
            projects = []
            errorMessage = summary.detail
                ?? "This OpenCode server version is not supported."
            return
        }
        do {
            let projects = try await service.listProjects().sorted {
                $0.time.updated > $1.time.updated
            }
            guard generation == loadGeneration else { return }
            self.projects = projects
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }
}
