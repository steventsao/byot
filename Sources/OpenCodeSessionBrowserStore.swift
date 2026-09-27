import Combine
import Foundation

struct OpenCodeSessionGroup: Identifiable, Sendable {
    let project: OpenCodeProject
    var sessions: [OpenCodeSession] = []
    var statuses: [String: OpenCodeSessionStatus]?
    var error: String?
    var isLoaded = false
    var id: String { project.worktree }

    var updated: Double { sessions.map(\.time.updated).max() ?? project.time.updated }
    var priority: Int {
        if error != nil { return 0 }
        return sessions.map { OpenCodeSessionSort.priority(status(for: $0)) }.min() ?? 3
    }

    func status(for session: OpenCodeSession) -> OpenCodeSessionStatus? {
        statuses.map { $0[session.id] ?? .idle }
    }
}

enum OpenCodeSessionSort: String, CaseIterable, Identifiable {
    case recent, status, name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .recent: "Recent activity"
        case .status: "Session status"
        case .name: "Name"
        }
    }

    static func priority(_ status: OpenCodeSessionStatus?) -> Int {
        switch status {
        case .retry: 0
        case .busy: 1
        case nil: 2
        case .idle: 3
        }
    }

    func ordered(_ sessions: [OpenCodeSession], statuses: [String: OpenCodeSessionStatus],
                 attention: Set<String> = []) -> [OpenCodeSession] {
        sessions.sorted { lhs, rhs in
            if self == .status {
                let a = attention.contains(lhs.id) ? 0 : Self.priority(statuses[lhs.id])
                let b = attention.contains(rhs.id) ? 0 : Self.priority(statuses[rhs.id])
                if a != b { return a < b }
            }
            if self == .name {
                let comparison = lhs.title.localizedStandardCompare(rhs.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            if lhs.time.updated != rhs.time.updated { return lhs.time.updated > rhs.time.updated }
            return lhs.id < rhs.id
        }
    }
}

@MainActor
final class OpenCodeSessionBrowserStore: ObservableObject {
    @Published private(set) var groups: [OpenCodeSessionGroup] = []
    @Published private(set) var isLoading = false
    private let service: any OpenCodeSessionBrowsing
    private var generation = 0
    // Archived from this list. A load already in flight must not bring them back.
    private var archivedIDs: Set<String> = []

    init(service: any OpenCodeSessionBrowsing) { self.service = service }

    func markArchived(_ id: String) {
        archivedIDs.insert(id)
        for index in groups.indices { groups[index].sessions.removeAll { $0.id == id } }
    }

    func unmarkArchived(_ id: String) { archivedIDs.remove(id) }

    var sessions: [OpenCodeSession] {
        // A configured worktree can overlap a server project. Keep one row per session.
        var byID: [String: OpenCodeSession] = [:]
        for session in groups.flatMap(\.sessions) {
            if (byID[session.id]?.time.updated ?? -.infinity) < session.time.updated {
                byID[session.id] = session
            }
        }
        return Array(byID.values)
    }

    var statuses: [String: OpenCodeSessionStatus] {
        var result: [String: OpenCodeSessionStatus] = [:]
        for group in groups {
            for session in group.sessions {
                if let status = group.status(for: session) { result[session.id] = status }
            }
        }
        return result
    }

    func orderedGroups(by sort: OpenCodeSessionSort, attention: Set<String> = []) -> [OpenCodeSessionGroup] {
        uniqueGroups.sorted { lhs, rhs in
            let a = lhs.sessions.contains { attention.contains($0.id) } ? 0 : lhs.priority
            let b = rhs.sessions.contains { attention.contains($0.id) } ? 0 : rhs.priority
            if sort == .status, a != b { return a < b }
            if sort == .name {
                let comparison = lhs.project.displayName.localizedStandardCompare(rhs.project.displayName)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            if lhs.updated != rhs.updated { return lhs.updated > rhs.updated }
            return lhs.id < rhs.id
        }
    }

    private var uniqueGroups: [OpenCodeSessionGroup] {
        // V1's global project and an explicitly configured directory can return
        // the same sessions. Prefer the session's directory when both respond,
        // while retaining an overlapping response if that directory fails.
        var owners: [String: Int] = [:]
        var newest: [String: OpenCodeSession] = [:]
        for (index, group) in groups.enumerated() {
            for session in group.sessions {
                if let previous = owners[session.id] {
                    if group.project.worktree == session.directory,
                       groups[previous].project.worktree != session.directory {
                        owners[session.id] = index
                    }
                } else {
                    owners[session.id] = index
                }
                if (newest[session.id]?.time.updated ?? -.infinity) < session.time.updated {
                    newest[session.id] = session
                }
            }
        }
        var result = groups.map { group in
            var group = group
            group.sessions = []
            return group
        }
        for (id, session) in newest {
            if let owner = owners[id] { result[owner].sessions.append(session) }
        }
        return result.filter {
            !($0.project.id == "global" && $0.project.worktree == "/"
              && $0.sessions.isEmpty && $0.isLoaded && $0.error == nil)
        }
    }

    func load(projects: [OpenCodeProject]) async {
        generation &+= 1
        let requestGeneration = generation
        var seen = Set<String>()
        groups = projects.filter { seen.insert($0.worktree).inserted }.map { project in
            var group = OpenCodeSessionGroup(project: project)
            if let previous = groups.first(where: { $0.id == project.worktree }) {
                group.sessions = previous.sessions
                group.statuses = previous.statuses
                group.isLoaded = previous.isLoaded
                group.error = previous.error
            }
            return group
        }
        let targets = groups.map(\.project)
        let previousSessions = Dictionary(groups.map { ($0.id, $0.sessions) }, uniquingKeysWith: { first, _ in first })
        isLoading = true
        defer { if generation == requestGeneration { isLoading = false } }
        let service = service
        // Bound fan-out and publish each project as it arrives. A slow project
        // must not hide usable sessions from another project.
        await withTaskGroup(of: OpenCodeSessionGroup.self) { tasks in
            var next = 0
            func enqueue() {
                guard next < targets.count else { return }
                let project = targets[next]
                next += 1
                let previous = previousSessions[project.worktree] ?? []
                tasks.addTask { await Self.fetch(project: project, previous: previous, service: service) }
            }
            for _ in 0..<min(3, targets.count) { enqueue() }
            for await loaded in tasks {
                guard !Task.isCancelled, generation == requestGeneration else {
                    tasks.cancelAll()
                    break
                }
                if let index = groups.firstIndex(where: { $0.id == loaded.id }) {
                    var loaded = loaded
                    if !loaded.isLoaded { loaded.sessions = groups[index].sessions }
                    loaded.sessions.removeAll { archivedIDs.contains($0.id) }
                    groups[index] = loaded
                }
                enqueue()
            }
        }
    }

    nonisolated private static func fetch(
        project: OpenCodeProject, previous: [OpenCodeSession], service: any OpenCodeSessionBrowsing
    ) async -> OpenCodeSessionGroup {
        async let sessionsResult = capture { try await service.listSessions(directory: project.worktree) }
        async let statusesResult = capture { try await service.sessionStatuses(directory: project.worktree, workspace: nil) }
        // Sessions started in a worktree live under its own directory, not the project's.
        async let worktreesResult = fetchWorktrees(of: project, previous: previous, service: service)
        let (sessions, statuses, worktrees) = await (sessionsResult, statusesResult, worktreesResult)
        var group = OpenCodeSessionGroup(project: project)
        var errors: [String] = []
        switch sessions {
        case .success(let sessions):
            group.sessions = (sessions + worktrees.sessions).filter { $0.parentID == nil && $0.time.archived == nil }
            group.isLoaded = true
        case .failure(let error): errors.append(error.localizedDescription)
        }
        switch statuses {
        case .success(let statuses): group.statuses = statuses.merging(worktrees.statuses) { current, _ in current }
        case .failure(let error): errors.append("Status unavailable: \(error.localizedDescription)")
        }
        group.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return group
    }

    /// Lists each worktree (`sandboxes`) a few at a time. A worktree that can't be listed
    /// keeps the sessions it had, and never marks the whole project as failed.
    nonisolated private static func fetchWorktrees(
        of project: OpenCodeProject, previous: [OpenCodeSession], service: any OpenCodeSessionBrowsing
    ) async -> (sessions: [OpenCodeSession], statuses: [String: OpenCodeSessionStatus]) {
        var seen: Set<String> = [project.worktree]
        let directories = project.sandboxes.filter { seen.insert($0).inserted }
        guard !directories.isEmpty else { return ([], [:]) }
        var sessions: [OpenCodeSession] = []
        var statuses: [String: OpenCodeSessionStatus] = [:]
        await withTaskGroup(of: (String, Result<[OpenCodeSession], Error>, [String: OpenCodeSessionStatus]?).self) { tasks in
            var next = 0
            func enqueue() {
                guard next < directories.count else { return }
                let directory = directories[next]
                next += 1
                tasks.addTask {
                    async let listed = capture { try await service.listSessions(directory: directory) }
                    async let status = capture { try await service.sessionStatuses(directory: directory, workspace: nil) }
                    return (directory, await listed, try? await status.get())
                }
            }
            for _ in 0..<min(3, directories.count) { enqueue() }
            for await (directory, listed, status) in tasks {
                switch listed {
                case .success(let listed): sessions += listed
                case .failure: sessions += previous.filter { $0.directory == directory }
                }
                statuses.merge(status ?? [:]) { current, _ in current }
                enqueue()
            }
        }
        return (sessions, statuses)
    }

    nonisolated private static func capture<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}
