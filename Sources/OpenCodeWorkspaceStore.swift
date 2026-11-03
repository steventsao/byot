import Combine
import Foundation

@MainActor
final class OpenCodeWorkspaceStore: ObservableObject {
    @Published private(set) var projects: [OpenCodeProject] = []
    @Published private(set) var isLoading = false
    @Published private(set) var compatibility: OpenCodeCompatibilitySummary?
    @Published var errorMessage: String?

    private let service: any OpenCodeWorkspaceServicing
    private var loadGeneration = 0

    init(service: any OpenCodeWorkspaceServicing) {
        self.service = service
    }

    func load() async {
        guard !Task.isCancelled else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        let summary: OpenCodeCompatibilitySummary
        do {
            summary = try await service.probeCompatibility()
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !Self.isCancellation(error) else { return }
            compatibility = nil
            errorMessage = error.localizedDescription
            return
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        guard summary.state != .unsupported else {
            compatibility = summary
            projects = []
            errorMessage = summary.detail
                ?? String(localized: "This OpenCode server version is not supported.")
            return
        }
        // Keep the previous summary until project loading finishes, so cancellation
        // at either request leaves the last known workspace state intact.
        do {
            let projects = try await service.listProjects().sorted {
                $0.time.updated > $1.time.updated
            }
            guard generation == loadGeneration, !Task.isCancelled else { return }
            compatibility = summary
            self.projects = projects
            errorMessage = nil
        } catch {
            guard generation == loadGeneration, !Task.isCancelled, !Self.isCancellation(error) else { return }
            compatibility = summary
            errorMessage = error.localizedDescription
        }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
