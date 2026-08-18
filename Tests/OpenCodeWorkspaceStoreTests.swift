import Foundation
import Testing
@testable import byot

@MainActor
@Suite(.serialized)
struct OpenCodeWorkspaceStoreTests {
    @Test("Compatible servers probe before loading projects and publish the summary")
    func compatibleProbeOrder() async {
        let summary = makeSummary(version: "1.18.10", verdict: .compatible(isVerifiedBaseline: true))
        let service = MockWorkspaceService(probeResult: .success(summary))
        let store = makeStore(service: service)

        await store.load()

        #expect(service.steps == [.probe, .listProjects])
        #expect(store.compatibility == summary)
        #expect(store.projects.map(\.id) == ["proj_1"])
        #expect(store.errorMessage == nil)
    }

    @Test("Degraded servers still load projects after the probe")
    func degradedLoadsProjects() async {
        let summary = makeSummary(
            version: "1.18.5",
            verdict: .degraded(reason: "OpenCode 1.18.5 is older than the verified 1.18.10 baseline.")
        )
        let service = MockWorkspaceService(probeResult: .success(summary))
        let store = makeStore(service: service)

        await store.load()

        #expect(service.steps == [.probe, .listProjects])
        #expect(store.compatibility?.state == .degraded)
        #expect(store.projects.map(\.id) == ["proj_1"])
        #expect(store.errorMessage == nil)
    }

    @Test("Unsupported servers block project loading and publish the reason")
    func unsupportedBlocksProjects() async {
        let summary = makeSummary(
            version: "1.17.0",
            verdict: .unsupported(reason: "OpenCode 1.17.0 is older than the minimum supported 1.18.0.")
        )
        let service = MockWorkspaceService(probeResult: .success(summary))
        let store = makeStore(service: service)

        await store.load()

        #expect(service.steps == [.probe])
        #expect(store.compatibility?.state == .unsupported)
        #expect(store.projects.isEmpty)
        #expect(store.errorMessage == "OpenCode 1.17.0 is older than the minimum supported 1.18.0.")
    }

    @Test("Compatible servers surface an error when the core project route fails")
    func compatibleRequiresProjectRoute() async {
        let summary = makeSummary(version: "1.18.10", verdict: .compatible(isVerifiedBaseline: true))
        let service = MockWorkspaceService(
            probeResult: .success(summary),
            projectsResult: .failure(OpenCodeConnectionError.httpStatus(503, nil))
        )
        let store = makeStore(service: service)

        await store.load()

        #expect(service.steps == [.probe, .listProjects])
        #expect(store.compatibility == summary)
        #expect(store.projects.isEmpty)
        #expect(store.errorMessage == "OpenCode returned HTTP 503.")
    }

    @Test("Probe failures surface an error without loading projects")
    func probeFailureSkipsProjects() async {
        let service = MockWorkspaceService(
            probeResult: .failure(OpenCodeConnectionError.httpStatus(401, nil))
        )
        let store = makeStore(service: service)

        await store.load()

        #expect(service.steps == [.probe])
        #expect(store.compatibility == nil)
        #expect(store.projects.isEmpty)
        #expect(store.errorMessage == "OpenCode rejected the username or password.")
    }

    @Test("A failed re-probe clears the previously published summary")
    func failedReprobeclearsStaleSummary() async {
        let summary = makeSummary(version: "1.18.10", verdict: .compatible(isVerifiedBaseline: true))
        let service = MockWorkspaceService(probeResult: .success(summary))
        let store = makeStore(service: service)

        await store.load()
        #expect(store.compatibility == summary)
        #expect(store.errorMessage == nil)

        service.setProbeResult(.failure(OpenCodeConnectionError.httpStatus(503, nil)))
        await store.load()

        #expect(service.steps == [.probe, .listProjects, .probe])
        #expect(store.compatibility == nil)
        #expect(store.errorMessage == "OpenCode returned HTTP 503.")
    }

    private func makeStore(service: MockWorkspaceService) -> OpenCodeWorkspaceStore {
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://mac.example.test",
            username: "opencode"
        )
        return OpenCodeWorkspaceStore(
            client: OpenCodeClient(profile: profile, password: "store-secret"),
            service: service
        )
    }

    private func makeSummary(
        version: String,
        verdict: OpenCodeCompatibility
    ) -> OpenCodeCompatibilitySummary {
        OpenCodeCompatibilitySummary(
            verdict: verdict,
            health: OpenCodeHealth(healthy: true, version: version),
            capabilityProbe: .unavailable
        )
    }
}

private final class MockWorkspaceService: OpenCodeWorkspaceServicing, @unchecked Sendable {
    enum Step: Equatable {
        case probe
        case listProjects
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var recordedSteps: [Step] = []
    nonisolated(unsafe) private var probeResult: Result<OpenCodeCompatibilitySummary, Error>
    nonisolated(unsafe) private var projectsResult: Result<[OpenCodeProject], Error>

    init(
        probeResult: Result<OpenCodeCompatibilitySummary, Error>,
        projectsResult: Result<[OpenCodeProject], Error> = .success([
            OpenCodeProject(
                id: "proj_1",
                worktree: "/repo",
                vcs: "git",
                name: nil,
                time: OpenCodeProjectTime(created: 1, updated: 2),
                sandboxes: []
            ),
        ])
    ) {
        self.probeResult = probeResult
        self.projectsResult = projectsResult
    }

    var steps: [Step] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSteps
    }

    func setProbeResult(_ result: Result<OpenCodeCompatibilitySummary, Error>) {
        lock.lock()
        probeResult = result
        lock.unlock()
    }

    func probeCompatibility() async throws -> OpenCodeCompatibilitySummary {
        try recordAndRead(.probe) { probeResult }.get()
    }

    func listProjects() async throws -> [OpenCodeProject] {
        try recordAndRead(.listProjects) { projectsResult }.get()
    }

    private func recordAndRead<Value>(
        _ step: Step,
        _ read: () -> Value
    ) -> Value {
        lock.lock()
        recordedSteps.append(step)
        let value = read()
        lock.unlock()
        return value
    }
}
