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
        #expect(store.errorMessage == "OpenCode rejected the username or password. If you paired with a code, scan a new one.")
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

    @Test("Cancellation errors preserve the last workspace state", arguments: LoadPhase.allCases, [LoadFailure.swiftCancellation, .urlCancellation, .foundationCancellation])
    private func cancellationPreservesState(phase: LoadPhase, failure: LoadFailure) async {
        let (store, service) = await loadedWorkspace()
        let previousSummary = store.compatibility
        let previousProjects = store.projects
        service.fail(failure.error, at: phase)

        await store.load()

        #expect(store.compatibility == previousSummary)
        #expect(store.projects == previousProjects)
        #expect(store.errorMessage == "Previous error")
        #expect(store.isLoading == false)
    }

    @Test("Successful responses from canceled tasks cannot publish state", arguments: LoadPhase.allCases)
    private func canceledSuccessPreservesState(phase: LoadPhase) async {
        let (store, service) = await loadedWorkspace()
        let previousSummary = store.compatibility
        let previousProjects = store.projects
        // An unsupported probe would otherwise clear the saved projects immediately.
        if phase == .probe {
            service.probeResult = .success(makeSummary(version: "1.17.0", verdict: .unsupported(reason: "Unsupported")))
        }
        let gate = service.suspendNext(phase)
        let load = Task { await store.load() }
        await gate.waitUntilSuspended()
        #expect(store.isLoading)
        load.cancel()
        gate.resume()
        await load.value

        #expect(store.compatibility == previousSummary)
        #expect(store.projects == previousProjects)
        #expect(store.errorMessage == "Previous error")
        #expect(store.isLoading == false)
        #expect(service.projectRequestCount == (phase == .probe ? 1 : 2))
    }

    @Test("A task canceled during a supported probe does not request projects")
    func canceledProbeStopsBeforeProjects() async {
        let (store, service) = await loadedWorkspace()
        let previousSummary = store.compatibility
        let gate = service.suspendNext(.probe)
        let load = Task { await store.load() }
        await gate.waitUntilSuspended()
        load.cancel()
        gate.resume()
        await load.value

        #expect(service.projectRequestCount == 1)
        #expect(store.compatibility == previousSummary)
        #expect(store.projects.map(\.id) == ["saved"])
        #expect(store.errorMessage == "Previous error")
        #expect(store.isLoading == false)
    }

    @Test("An error arriving after task cancellation preserves state", arguments: LoadPhase.allCases)
    private func canceledTaskFailurePreservesState(phase: LoadPhase) async {
        let (store, service) = await loadedWorkspace()
        let previousSummary = store.compatibility
        let previousProjects = store.projects
        service.fail(URLError(.timedOut), at: phase)
        let gate = service.suspendNext(phase)
        let load = Task { await store.load() }
        await gate.waitUntilSuspended()
        load.cancel()
        gate.resume()
        await load.value

        #expect(store.compatibility == previousSummary)
        #expect(store.projects == previousProjects)
        #expect(store.errorMessage == "Previous error")
        #expect(store.isLoading == false)
    }

    @Test("Real failures still update the workspace error", arguments: LoadPhase.allCases, [LoadFailure.timeout, .unrelatedDomain])
    private func realFailuresAreShown(phase: LoadPhase, failure: LoadFailure) async {
        let (store, service) = await loadedWorkspace()
        let previousProjects = store.projects
        let newSummary = try? service.probeResult.get()
        service.fail(failure.error, at: phase)

        await store.load()

        #expect(store.compatibility == (phase == .probe ? nil : newSummary))
        #expect(store.projects == previousProjects)
        #expect(store.errorMessage == failure.error.localizedDescription)
        #expect(store.isLoading == false)
    }

    @Test("An older refresh cannot overwrite a completed newer refresh", arguments: LoadPhase.allCases, LateResponse.allCases)
    private func newerRefreshWins(phase: LoadPhase, response: LateResponse) async {
        let (store, service) = await loadedWorkspace()
        if let error = response.error { service.fail(error, at: phase) }
        let gate = service.suspendNext(phase)
        let olderLoad = Task { await store.load() }
        await gate.waitUntilSuspended()

        let newSummary = makeSummary(version: "1.18.12", verdict: .compatible(isVerifiedBaseline: false))
        service.probeResult = .success(newSummary)
        service.projectsResult = .success([makeProject(id: "newest")])
        await store.load()
        // Also preserve errors supplied by a newer operation while the old request finishes.
        store.errorMessage = "Newer error"
        gate.resume()
        await olderLoad.value

        #expect(store.compatibility == newSummary)
        #expect(store.projects.map(\.id) == ["newest"])
        #expect(store.errorMessage == "Newer error")
        #expect(store.isLoading == false)
    }

    @Test("A canceled older refresh cannot stop the newer loading indicator", arguments: LoadPhase.allCases)
    private func olderCancellationKeepsNewerLoading(phase: LoadPhase) async {
        let (store, service) = await loadedWorkspace()
        let olderGate = service.suspendNext(phase)
        let olderLoad = Task { await store.load() }
        await olderGate.waitUntilSuspended()
        let newerGate = service.suspendNext(.probe)
        let newerLoad = Task { await store.load() }
        await newerGate.waitUntilSuspended()

        olderLoad.cancel()
        olderGate.resume()
        await olderLoad.value
        #expect(store.isLoading)

        newerGate.resume()
        await newerLoad.value
        #expect(store.isLoading == false)
        #expect(store.projects.map(\.id) == ["replacement"])
        #expect(store.errorMessage == nil)
    }

    @Test("A task canceled before loading cannot supersede an active refresh")
    func alreadyCanceledLoadDoesNotSupersedeRefresh() async {
        let (store, service) = await loadedWorkspace()
        let previousSummary = store.compatibility
        let gate = service.suspendNext(.probe)
        let activeLoad = Task { await store.load() }
        await gate.waitUntilSuspended()

        let canceledLoad = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await store.load()
        }
        await canceledLoad.value
        #expect(store.isLoading)
        #expect(store.compatibility == previousSummary)
        #expect(store.projects.map(\.id) == ["saved"])
        #expect(store.errorMessage == "Previous error")
        #expect(service.projectRequestCount == 1)

        gate.resume()
        await activeLoad.value
        #expect(store.isLoading == false)
        #expect(store.projects.map(\.id) == ["replacement"])
        #expect(store.errorMessage == nil)
    }

    private func loadedWorkspace() async -> (OpenCodeWorkspaceStore, SuspendedWorkspaceService) {
        let service = SuspendedWorkspaceService(
            summary: makeSummary(version: "1.18.10", verdict: .compatible(isVerifiedBaseline: true)),
            projects: [makeProject(id: "saved")]
        )
        let store = makeStore(service: service)
        await store.load()
        store.errorMessage = "Previous error"
        service.probeResult = .success(makeSummary(version: "1.18.5", verdict: .degraded(reason: "Older version")))
        service.projectsResult = .success([makeProject(id: "replacement")])
        return (store, service)
    }

    private func makeProject(id: String) -> OpenCodeProject {
        OpenCodeProject(id: id, worktree: "/\(id)", vcs: "git", name: nil,
                        time: OpenCodeProjectTime(created: 1, updated: 2), sandboxes: [])
    }

    private func makeStore(service: any OpenCodeWorkspaceServicing) -> OpenCodeWorkspaceStore {
        OpenCodeWorkspaceStore(service: service)
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

private enum LoadPhase: CaseIterable, Sendable {
    case probe, projects
}

private enum LoadFailure: Sendable {
    case swiftCancellation, urlCancellation, foundationCancellation, timeout, unrelatedDomain

    var error: any Error {
        switch self {
        case .swiftCancellation: CancellationError()
        case .urlCancellation: URLError(.cancelled)
        case .foundationCancellation: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        case .timeout: URLError(.timedOut)
        case .unrelatedDomain: NSError(domain: "WorkspaceTestError", code: NSURLErrorCancelled)
        }
    }
}

private enum LateResponse: CaseIterable, Sendable {
    case success, cancellation, failure

    var error: (any Error)? {
        switch self {
        case .success: nil
        case .cancellation: URLError(.cancelled)
        case .failure: URLError(.notConnectedToInternet)
        }
    }
}

/// Deliberately ignores task cancellation so tests control exactly when requests finish.
@MainActor
private final class WorkspaceRequestGate {
    private var suspended: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation {
            suspended = $0
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        guard suspended == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        suspended?.resume()
        suspended = nil
    }
}

@MainActor
private final class SuspendedWorkspaceService: OpenCodeWorkspaceServicing {
    var probeResult: Result<OpenCodeCompatibilitySummary, Error>
    var projectsResult: Result<[OpenCodeProject], Error>
    private var probeGate: WorkspaceRequestGate?
    private var projectsGate: WorkspaceRequestGate?
    private(set) var projectRequestCount = 0

    init(summary: OpenCodeCompatibilitySummary, projects: [OpenCodeProject]) {
        probeResult = .success(summary)
        projectsResult = .success(projects)
    }

    func fail(_ error: any Error, at phase: LoadPhase) {
        switch phase {
        case .probe: probeResult = .failure(error)
        case .projects: projectsResult = .failure(error)
        }
    }

    func suspendNext(_ phase: LoadPhase) -> WorkspaceRequestGate {
        let gate = WorkspaceRequestGate()
        switch phase {
        case .probe: probeGate = gate
        case .projects: projectsGate = gate
        }
        return gate
    }

    func probeCompatibility() async throws -> OpenCodeCompatibilitySummary {
        let result = probeResult
        let gate = probeGate
        probeGate = nil
        await gate?.suspend()
        return try result.get()
    }

    func listProjects() async throws -> [OpenCodeProject] {
        projectRequestCount += 1
        let result = projectsResult
        let gate = projectsGate
        projectsGate = nil
        await gate?.suspend()
        return try result.get()
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
