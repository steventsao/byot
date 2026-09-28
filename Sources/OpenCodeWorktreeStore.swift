import Combine
import Foundation

/// Collects worktree readiness reports from the moment it is created, so a report that
/// arrives before the create request returns is not missed.
@MainActor
final class OpenCodeWorktreeReadinessMonitor {
    enum Outcome: Equatable, Sendable {
        case ready
        case failed(String)
        /// Nothing was reported in time; the worktree exists and may still be checking out.
        case timedOut
        /// The server has no event stream, or it ended, so readiness can't be known.
        case unobserved
    }

    private var task: Task<Void, Never>?
    private var isConnected = false
    private var hasEnded = false
    private var ready: Set<String> = []
    private var failures: [String: String] = [:]

    init(events: AsyncThrowingStream<OpenCodeWorktreeEvent, Error>) {
        task = Task { [weak self] in
            do {
                for try await event in events {
                    guard let self else { return }
                    self.record(event)
                }
            } catch {}
            self?.hasEnded = true
        }
    }

    deinit { task?.cancel() }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Waits until the stream is live, so the create request can't outrun the subscription.
    func waitUntilConnected(timeout: Duration) async {
        await wait(timeout: timeout) { $0.isConnected || $0.hasEnded }
    }

    func outcome(for directory: String, timeout: Duration) async -> Outcome {
        let key = OpenCodeWorktree.key(directory)
        await wait(timeout: timeout) { $0.ready.contains(key) || $0.failures[key] != nil || $0.hasEnded }
        if ready.contains(key) { return .ready }
        if let message = failures[key] { return .failed(message) }
        return hasEnded ? .unobserved : .timedOut
    }

    private func record(_ event: OpenCodeWorktreeEvent) {
        switch event {
        case .connected: isConnected = true
        case .ready(let directory): ready.insert(directory)
        case .failed(let directory, let message): failures[directory] = message
        }
    }

    /// Readiness takes seconds; a short poll keeps this simple and bounded.
    private func wait(timeout: Duration, until satisfied: (OpenCodeWorktreeReadinessMonitor) -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !satisfied(self), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// One project's worktrees: list with branch, change and session counts, create (waiting
/// until the server has checked the new one out), start a session in one, reset and delete.
@MainActor
final class OpenCodeWorktreeStore: ObservableObject {
    enum Availability: Equatable {
        case unknown
        case available
        /// The server has no worktree routes, or the project can't have worktrees here.
        case unsupported
    }

    enum Creation: Equatable {
        case creating(name: String?)
        /// Created; the server is checking out files and running the project's start command.
        case preparing(OpenCodeWorktree)
    }

    enum Operation: Equatable {
        case resetting
        case removing
        case startingSession
    }

    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var worktrees: [OpenCodeWorktree] = []
    @Published private(set) var summaries: [String: OpenCodeWorktreeSummary] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    /// Set when the list couldn't be loaded and nothing is on screen.
    @Published private(set) var loadError: String?
    /// Set when a refresh failed but the earlier list is still on screen.
    @Published private(set) var refreshError: String?
    /// The last create, start, reset or delete that failed.
    @Published var actionError: String?
    @Published private(set) var creation: Creation?
    @Published private(set) var operations: [String: Operation] = [:]

    private var service: (any OpenCodeWorktreeServicing)?
    private var generation = 0
    private let connectTimeout: Duration
    private let readinessTimeout: Duration

    init(service: (any OpenCodeWorktreeServicing)? = nil,
         connectTimeout: Duration = .seconds(3), readinessTimeout: Duration = .seconds(90)) {
        self.service = service
        self.connectTimeout = connectTimeout
        self.readinessTimeout = readinessTimeout
    }

    /// Points the store at another project (or none, which reads as unsupported).
    func use(_ service: (any OpenCodeWorktreeServicing)?) {
        generation &+= 1
        self.service = service
        availability = service == nil ? .unsupported : .unknown
        worktrees = []
        summaries = [:]
        isLoading = false
        hasLoaded = false
        loadError = nil
        refreshError = nil
        actionError = nil
        operations = [:]
    }

    var isBusy: Bool { creation != nil || !operations.isEmpty }

    func load() async {
        guard let service else {
            availability = .unsupported
            return
        }
        generation &+= 1
        let current = generation
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            let listed = try await service.list()
            guard current == generation else { return }
            // Keep names and branches a create answered with; the list only has folders.
            let known = Dictionary(worktrees.map { (OpenCodeWorktree.key($0.directory), $0) },
                                   uniquingKeysWith: { first, _ in first })
            worktrees = listed.map { known[OpenCodeWorktree.key($0.directory)] ?? $0 }
            let keys = Set(worktrees.map(\.directory))
            summaries = summaries.filter { keys.contains($0.key) }
            availability = .available
            hasLoaded = true
            loadError = nil
            refreshError = nil
        } catch OpenCodeWorktreeError.unsupported {
            guard current == generation else { return }
            availability = .unsupported
            worktrees = []
            hasLoaded = true
            return
        } catch {
            guard current == generation, !Self.isCancellation(error) else { return }
            if hasLoaded { refreshError = error.localizedDescription } else { loadError = error.localizedDescription }
            return
        }
        await loadSummaries(worktrees, generation: current)
    }

    /// Creates a worktree and waits until the server reports it checked out, so a session
    /// started in it sees the project's files. Returns `nil` (with `actionError`) on failure.
    func create(name: String?) async -> OpenCodeWorktree? {
        guard let service, creation == nil else { return nil }
        let name = name?.trimmedNonEmpty
        creation = .creating(name: name)
        actionError = nil
        defer { creation = nil }
        let monitor = OpenCodeWorktreeReadinessMonitor(events: service.events())
        defer { monitor.cancel() }
        await monitor.waitUntilConnected(timeout: connectTimeout)
        let worktree: OpenCodeWorktree
        do {
            worktree = try await service.create(name: name)
        } catch {
            if !Self.isCancellation(error) { actionError = Self.message(error, doing: String(localized: "create the worktree")) }
            return nil
        }
        availability = .available
        worktrees.removeAll { OpenCodeWorktree.key($0.directory) == OpenCodeWorktree.key(worktree.directory) }
        worktrees.append(worktree)
        creation = .preparing(worktree)
        let outcome = await monitor.outcome(for: worktree.directory, timeout: readinessTimeout)
        await refreshSummary(of: worktree)
        if case .failed(let message) = outcome {
            actionError = String(localized: "“\(worktree.name)” was created, but OpenCode couldn’t prepare it: \(message)")
            return nil
        }
        return worktree
    }

    func createSession(in worktree: OpenCodeWorktree) async -> OpenCodeSession? {
        guard let service, operations[worktree.directory] == nil else { return nil }
        operations[worktree.directory] = .startingSession
        actionError = nil
        defer { operations[worktree.directory] = nil }
        do {
            return try await service.createSession(in: worktree.directory)
        } catch {
            if !Self.isCancellation(error) { actionError = Self.message(error, doing: String(localized: "start a session in “\(worktree.name)”")) }
            return nil
        }
    }

    @discardableResult
    func reset(_ worktree: OpenCodeWorktree) async -> Bool {
        guard let service, operations[worktree.directory] == nil else { return false }
        operations[worktree.directory] = .resetting
        actionError = nil
        defer { operations[worktree.directory] = nil }
        do {
            try await service.reset(worktree.directory)
        } catch {
            if !Self.isCancellation(error) { actionError = Self.message(error, doing: String(localized: "reset “\(worktree.name)”")) }
            await refreshSummary(of: worktree)
            return false
        }
        await refreshSummary(of: worktree)
        return true
    }

    @discardableResult
    func remove(_ worktree: OpenCodeWorktree) async -> Bool {
        guard let service, operations[worktree.directory] == nil else { return false }
        operations[worktree.directory] = .removing
        actionError = nil
        defer { operations[worktree.directory] = nil }
        do {
            try await service.remove(worktree.directory)
        } catch {
            if !Self.isCancellation(error) { actionError = Self.message(error, doing: String(localized: "delete “\(worktree.name)”")) }
            return false
        }
        worktrees.removeAll { $0.directory == worktree.directory }
        summaries[worktree.directory] = nil
        return true
    }

    /// The branch the row shows: the one the server reported, else the one it created.
    func branch(of worktree: OpenCodeWorktree) -> String? {
        summaries[worktree.directory]?.branch ?? worktree.branch
    }

    // MARK: Summaries

    private func loadSummaries(_ worktrees: [OpenCodeWorktree], generation current: Int) async {
        guard let service else { return }
        await withTaskGroup(of: (String, OpenCodeWorktreeSummary).self) { group in
            for worktree in worktrees {
                group.addTask { (worktree.directory, await service.summary(of: worktree.directory)) }
            }
            for await (directory, summary) in group where current == generation {
                summaries[directory] = merged(summaries[directory], summary)
            }
        }
    }

    private func refreshSummary(of worktree: OpenCodeWorktree) async {
        guard let service else { return }
        let current = generation
        let summary = await service.summary(of: worktree.directory)
        guard current == generation, worktrees.contains(where: { $0.directory == worktree.directory }) else { return }
        summaries[worktree.directory] = merged(summaries[worktree.directory], summary)
    }

    /// A lookup that failed this time keeps what an earlier one found.
    private func merged(_ old: OpenCodeWorktreeSummary?, _ new: OpenCodeWorktreeSummary) -> OpenCodeWorktreeSummary {
        OpenCodeWorktreeSummary(branch: new.branch ?? old?.branch,
                                defaultBranch: new.defaultBranch ?? old?.defaultBranch,
                                changes: new.changes ?? old?.changes,
                                sessions: new.sessions ?? old?.sessions)
    }

    private static func message(_ error: any Error, doing action: String) -> String {
        if let error = error as? OpenCodeWorktreeError, case .server(let message) = error {
            return String(localized: "Couldn’t \(action): \(message)")
        }
        return String(localized: "Couldn’t \(action). \(error.localizedDescription)")
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}
