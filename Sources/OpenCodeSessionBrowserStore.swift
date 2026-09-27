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
    @Published private(set) var liveState: OpenCodeSessionListLiveState = .off
    /// Pending permission/question request IDs by the session that asked.
    /// A subagent asks from its own session; `needsInputIDs` maps it to the listed conversation.
    @Published private(set) var pendingInput: [String: Set<String>] = [:]
    /// Advances on every live change so the list can animate it.
    @Published private(set) var liveRevision = 0
    /// When the sessions shown were saved, while they come from this device's cache
    /// and the server has not answered yet. `nil` once a load reaches the server.
    @Published private(set) var cachedAt: Date?
    private let service: any OpenCodeSessionBrowsing
    private let cache: OpenCodeOfflineCacheScope?
    private let timing: OpenCodeSessionListLiveTiming
    private var generation = 0
    // Archived from this list. A load already in flight must not bring them back.
    private var archivedIDs: Set<String> = []
    private var savedGroups: [OpenCodeCachedSessionList.Group]?
    // Subagent session → the session that started it.
    private var parents: [String: String] = [:]
    // Sessions whose parent was looked up once already (found or not).
    private var lookedUpParents: Set<String> = []
    // Live sessions outside every listed project. Each triggers at most one
    // reconciliation, so a busy unrelated directory cannot cause a reload storm.
    private var unplacedIDs: Set<String> = []
    // Live changes since the current load started. A snapshot fetched before
    // them must not undo them when it lands.
    private var sessionEdits: [String: SessionEdit] = [:]
    private var inputEdits: Set<String> = []
    // The project whose snapshot last reported each pending session, so the
    // next snapshot of that project can clear it even if it is not listed.
    private var inputSources: [String: String] = [:]
    private var follower: Task<OpenCodeSessionListLiveState, Never>?
    private var followerClaims = 0
    private var handlers: LiveHandlers?
    private var reconcileTask: Task<Void, Never>?
    private var reconcileRequest: ReconcileScope?
    private var statusTask: Task<Void, Never>?
    private var statusRefreshIDs: Set<String> = []

    /// How much of the list a live change invalidated.
    enum ReconcileScope: Comparable, Sendable {
        /// Sessions and statuses may have changed while the stream was down.
        case sessions
        /// A project appeared or an instance was disposed; refetch projects too.
        case projects
    }

    /// What the list does outside this store when a live event arrives.
    struct LiveHandlers {
        /// Refetch after the stream (re)connects or the server reports a
        /// change the event itself does not describe.
        var reconcile: @MainActor (ReconcileScope) async -> Void
        var failure: @MainActor (_ sessionID: String, _ message: String) -> Void = { _, _ in }
        /// A listed session went idle; a recorded failure may no longer apply.
        var settled: @MainActor (_ sessionID: String) -> Void = { _ in }
    }

    /// Consequences of one live change that need work beyond this store.
    struct LiveFollowUp: Equatable {
        var reconcile: ReconcileScope?
        /// A listed session whose status must be refetched (v2 streams activity, not status).
        var refreshStatus: String?
        var failure: Failure?
        var settled: String?
        /// A session outside the list asked for input; find the conversation it belongs to.
        var lookUpParent: String?

        struct Failure: Equatable {
            let sessionID: String
            let message: String
        }
    }

    private enum SessionEdit {
        case upserted(OpenCodeSession)
        case removed
    }

    init(
        service: any OpenCodeSessionBrowsing, cache: OpenCodeOfflineCacheScope? = nil,
        timing: OpenCodeSessionListLiveTiming = .standard
    ) {
        self.service = service
        self.cache = cache
        self.timing = timing
        // Restore synchronously, so the first frame already lists the last-known sessions.
        if let saved = cache?.sessionList() {
            groups = saved.groups.map { saved in
                // Statuses are live state. A saved "busy" would claim work that may have ended.
                var group = OpenCodeSessionGroup(project: saved.project, sessions: saved.sessions)
                group.isLoaded = true
                return group
            }
            savedGroups = saved.groups
            cachedAt = saved.savedAt
        }
    }

    /// The projects of the restored list, so the workspace can name them before it connects.
    var cachedProjects: [OpenCodeProject] { cachedAt == nil ? [] : groups.map(\.project) }

    /// Listed conversations waiting on a permission or question, their own or a subagent's.
    var needsInputIDs: Set<String> {
        Set(pendingInput.compactMap { id, requests in requests.isEmpty ? nil : root(of: id) })
    }

    func markArchived(_ id: String) {
        archivedIDs.insert(id)
        for index in groups.indices { groups[index].sessions.removeAll { $0.id == id } }
        saveToCache()
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

    /// - Parameter showsProgress: false for background reconciliation, which
    ///   should not flash a refreshing row every time the stream reconnects.
    func load(projects: [OpenCodeProject], showsProgress: Bool = true) async {
        generation &+= 1
        let requestGeneration = generation
        sessionEdits = [:]
        inputEdits = []
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
        if showsProgress { isLoading = true }
        defer { if generation == requestGeneration { isLoading = false } }
        let service = service
        var inputCovered = Set<String>()
        // Bound fan-out and publish each project as it arrives. A slow project
        // must not hide usable sessions from another project.
        await withTaskGroup(of: Loaded.self) { tasks in
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
                if let index = groups.firstIndex(where: { $0.id == loaded.group.id }) {
                    var group = loaded.group
                    if !group.isLoaded { group.sessions = groups[index].sessions }
                    group.sessions.removeAll { archivedIDs.contains($0.id) }
                    reapplySessionEdits(to: &group)
                    groups[index] = group
                    if let pending = loaded.pendingInput {
                        inputCovered.formUnion(applyInputSnapshot(pending, listed: loaded.sessionIDs, from: group.id))
                    }
                }
                enqueue()
            }
        }
        guard !Task.isCancelled, generation == requestGeneration else { return }
        // Reconciled: the list now reflects the server, including removed projects.
        cachedAt = nil
        saveToCache()
        await verifyPendingInput(excluding: inputCovered, generation: requestGeneration)
        guard !Task.isCancelled, generation == requestGeneration else { return }
        await lookUpParents(of: Array(pendingInput.keys))
    }

    private struct Loaded: Sendable {
        var group: OpenCodeSessionGroup
        var sessionIDs: Set<String> = []
        var pendingInput: [String: Set<String>]?
    }

    nonisolated private static func fetch(
        project: OpenCodeProject, previous: [OpenCodeSession], service: any OpenCodeSessionBrowsing
    ) async -> Loaded {
        async let sessionsResult = capture { try await service.listSessions(directory: project.worktree) }
        async let statusesResult = capture { try await service.sessionStatuses(directory: project.worktree, workspace: nil) }
        async let pendingResult = capture { try await service.pendingInputRequests(directory: project.worktree) }
        // Sessions started in a worktree live under its own directory, not the project's.
        async let worktreesResult = fetchWorktrees(of: project, previous: previous, service: service)
        let (sessions, statuses, pending, worktrees) = await (sessionsResult, statusesResult, pendingResult, worktreesResult)
        var loaded = Loaded(group: OpenCodeSessionGroup(project: project))
        var errors: [String] = []
        switch sessions {
        case .success(let sessions):
            loaded.group.sessions = (sessions + worktrees.sessions).filter { $0.parentID == nil && $0.time.archived == nil }
            loaded.group.isLoaded = true
            // The project's input snapshot answers only for its own directory;
            // worktree sessions are rechecked one by one when flagged.
            loaded.sessionIDs = Set(sessions.map(\.id))
        case .failure(let error): errors.append(error.localizedDescription)
        }
        switch statuses {
        case .success(let statuses): loaded.group.statuses = statuses.merging(worktrees.statuses) { current, _ in current }
        case .failure(let error): errors.append("Status unavailable: \(error.localizedDescription)")
        }
        // Pending input is an enhancement: without a snapshot the list keeps
        // what live events told it and cannot flag anything new.
        if loaded.group.isLoaded, case .success(let pending?) = pending { loaded.pendingInput = pending }
        loaded.group.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
        return loaded
    }

    /// Replaces pending input for a project's sessions and any subagent that
    /// asked in that project. Returns the sessions the snapshot answered for.
    private func applyInputSnapshot(
        _ snapshot: [String: Set<String>], listed: Set<String>, from project: String
    ) -> Set<String> {
        var covered = listed.union(snapshot.keys)
        // A subagent's request belongs to the project of its conversation.
        covered.formUnion(pendingInput.keys.filter { listed.contains(root(of: $0)) || inputSources[$0] == project })
        covered.subtract(inputEdits)
        var updated = pendingInput
        for id in covered {
            updated[id] = snapshot[id].flatMap { $0.isEmpty ? nil : $0 }
            inputSources[id] = updated[id] == nil ? nil : project
        }
        if updated != pendingInput {
            pendingInput = updated
            liveRevision &+= 1
        }
        return covered
    }

    /// Sessions no directory snapshot answered for (older v2 servers list
    /// requests per session only). Rechecks sessions already flagged, so a
    /// request answered while the stream was down is cleared, and running
    /// ones, since only a running session can be waiting; idle projects cost
    /// no extra request.
    private func verifyPendingInput(excluding covered: Set<String>, generation requestGeneration: Int) async {
        let running = groups.flatMap { group in
            group.sessions.lazy.filter { group.statuses?[$0.id]?.isActive == true }.map(\.id)
        }
        let targets = Set(pendingInput.keys).union(running).subtracting(covered).sorted()
        guard !targets.isEmpty else { return }
        let service = service
        await withTaskGroup(of: (String, Set<String>?).self) { tasks in
            var next = 0
            func enqueue() {
                guard next < targets.count else { return }
                let id = targets[next]
                next += 1
                tasks.addTask { (id, try? await service.pendingInputRequests(sessionID: id)) }
            }
            for _ in 0..<min(3, targets.count) { enqueue() }
            for await (id, requests) in tasks {
                guard !Task.isCancelled, generation == requestGeneration else {
                    tasks.cancelAll()
                    return
                }
                let pending = requests.flatMap { $0.isEmpty ? nil : $0 }
                if requests != nil, !inputEdits.contains(id), pendingInput[id] != pending {
                    pendingInput[id] = pending
                    liveRevision &+= 1
                }
                enqueue()
            }
        }
    }

    /// Saves the last-known list. A project that failed this time keeps the sessions
    /// it had, which is still the best offline answer. Unchanged lists are not rewritten.
    private func saveToCache() {
        guard let cache, cachedAt == nil else { return }
        let snapshot = groups.map { OpenCodeCachedSessionList.Group(project: $0.project, sessions: $0.sessions) }
        guard snapshot != savedGroups else { return }
        savedGroups = snapshot
        cache.saveSessionList(snapshot)
    }

    // MARK: Live updates

    /// Follows the server-wide event stream until the calling task is
    /// cancelled or live updates stop being available, and returns why it stopped:
    /// - `.polling`: the stream kept dropping; reconnects backed off
    ///   exponentially and gave up after `timing.maximumAttempts` short-lived
    ///   connections. Poll, then try again later.
    /// - `.unsupported`: the server has no usable server-wide stream. Poll.
    /// - `.off`: the caller was cancelled, or a newer caller took over.
    ///
    /// At most one stream runs per store: a new caller stops the previous one first.
    func followLiveUpdates(_ handlers: LiveHandlers) async -> OpenCodeSessionListLiveState {
        followerClaims &+= 1
        let claim = followerClaims
        if let previous = follower {
            previous.cancel()
            _ = await previous.value
        }
        // An even newer caller claimed the stream while the previous one wound down.
        guard claim == followerClaims, !Task.isCancelled else { return .off }
        let task = Task { await self.runLiveUpdates(handlers) }
        follower = task
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if follower == task { follower = nil }
        return outcome
    }

    private func runLiveUpdates(_ handlers: LiveHandlers) async -> OpenCodeSessionListLiveState {
        self.handlers = handlers
        liveState = .connecting
        defer {
            self.handlers = nil
            reconcileTask?.cancel()
            reconcileTask = nil
            reconcileRequest = nil
            statusTask?.cancel()
            statusTask = nil
            statusRefreshIDs = []
        }
        var failures = 0
        while !Task.isCancelled {
            let opened = ContinuousClock.now
            // The reader stays off the main actor and never waits on it, so a
            // busy UI cannot back up the stream; only list changes are relayed.
            let (changes, relay) = AsyncStream.makeStream(of: OpenCodeSessionListEvent.self)
            async let ended = Self.read(service.sessionListEvents(), into: relay)
            for await change in changes { receive(change) }
            let end = await ended
            guard !Task.isCancelled else { break }
            if end == .unsupported {
                liveState = .unsupported
                return .unsupported
            }
            // A connection that outlived heartbeats was healthy; start the budget over.
            if ContinuousClock.now - opened >= timing.healthyConnection { failures = 0 }
            failures += 1
            guard failures < timing.maximumAttempts else {
                liveState = .polling
                return .polling
            }
            liveState = .reconnecting
            do { try await Task.sleep(for: timing.delay(afterFailure: failures)) } catch { break }
        }
        liveState = .off
        return .off
    }

    private enum StreamEnd: Sendable { case ended, unsupported }

    nonisolated private static func read(
        _ stream: AsyncThrowingStream<OpenCodeEvent, Error>,
        into relay: AsyncStream<OpenCodeSessionListEvent>.Continuation
    ) async -> StreamEnd {
        defer { relay.finish() }
        var received = false
        do {
            for try await event in stream {
                received = true
                if let change = OpenCodeSessionListEvent(event) { relay.yield(change) }
            }
        } catch let error as OpenCodeConnectionError where !received && isUnsupported(error) {
            return .unsupported
        } catch {}
        return .ended
    }

    /// Older servers answer an unknown route with 404/405 or with the web
    /// app's HTML; neither will ever become an event stream.
    nonisolated static func isUnsupported(_ error: OpenCodeConnectionError) -> Bool {
        if error.isUnsupportedRoute { return true }
        if case .unexpectedEventContentType = error { return true }
        return false
    }

    private func receive(_ change: OpenCodeSessionListEvent) {
        guard let handlers else { return }
        if liveState != .live { liveState = .live }
        let followUp = apply(change)
        if let scope = followUp.reconcile { scheduleReconcile(scope) }
        if let id = followUp.refreshStatus { scheduleStatusRefresh(id) }
        if let failure = followUp.failure { handlers.failure(failure.sessionID, failure.message) }
        if let settled = followUp.settled { handlers.settled(settled) }
        if let id = followUp.lookUpParent { Task { await lookUpParents(of: [id]) } }
    }

    /// Applies one live change to the list. Exposed for tests; the stream
    /// loop is the only production caller.
    @discardableResult
    func apply(_ change: OpenCodeSessionListEvent) -> LiveFollowUp {
        var followUp = LiveFollowUp()
        switch change {
        case .connected:
            // Anything may have changed while no stream was open.
            followUp.reconcile = .sessions
        case .disposed:
            followUp.reconcile = .projects
        case .upserted(let session):
            if let parent = session.parentID {
                // A subagent that already asked for input now flags its conversation.
                if parents.updateValue(parent, forKey: session.id) != parent, pendingInput[session.id] != nil {
                    liveRevision &+= 1
                }
                break
            }
            if session.time.archived != nil || archivedIDs.contains(session.id) {
                sessionEdits[session.id] = .removed
                remove(sessionID: session.id)
            } else {
                sessionEdits[session.id] = .upserted(session)
                if !replace(session), insert(session) { followUp.reconcile = .projects }
            }
        case .removed(let id):
            sessionEdits[id] = .removed
            remove(sessionID: id)
            parents[id] = nil
            if pendingInput.removeValue(forKey: id) != nil { liveRevision &+= 1 }
        case .renamed(let id, let title):
            guard let session = sessions.first(where: { $0.id == id }) else { break }
            guard let title else {
                followUp.reconcile = .sessions
                break
            }
            let renamed = session.retitled(title)
            sessionEdits[id] = .upserted(renamed)
            replace(renamed)
        case .status(let id, let status):
            var previous: OpenCodeSessionStatus?
            var changed = false
            for index in groups.indices where groups[index].statuses != nil
                && groups[index].sessions.contains(where: { $0.id == id }) {
                previous = groups[index].statuses?[id] ?? .idle
                if previous != status {
                    groups[index].statuses?[id] = status == .idle ? nil : status
                    changed = true
                }
            }
            if changed { liveRevision &+= 1 }
            if status == .idle, previous?.isActive == true { followUp.settled = id }
        case .failed(let id, let message):
            // A subagent's failure does not fail the listed conversation.
            guard isListed(id) else { break }
            followUp.failure = .init(sessionID: id, message: message)
            // v2 has no status event; a failed turn may have ended.
            if statuses[id]?.isActive == true { followUp.refreshStatus = id }
        case .activity(let id, let mayHaveSettled):
            guard isListed(id), mayHaveSettled || statuses[id]?.isActive != true else { break }
            followUp.refreshStatus = id
        case .inputRequested(let id, let requestID):
            inputEdits.insert(id)
            if pendingInput[id]?.contains(requestID) != true {
                pendingInput[id, default: []].insert(requestID)
                liveRevision &+= 1
            }
            let conversation = root(of: id)
            if !isListed(conversation) { followUp.lookUpParent = conversation }
        case .inputResolved(let id, let requestID):
            inputEdits.insert(id)
            guard var requests = pendingInput[id] else { break }
            // Without a request ID, assume nothing is left to answer; opening
            // the session refetches its requests anyway.
            if let requestID { requests.remove(requestID) } else { requests.removeAll() }
            pendingInput[id] = requests.isEmpty ? nil : requests
            liveRevision &+= 1
        }
        return followUp
    }

    private func isListed(_ id: String) -> Bool {
        groups.contains { $0.sessions.contains { $0.id == id } }
    }

    @discardableResult
    private func replace(_ session: OpenCodeSession) -> Bool {
        var found = false
        for index in groups.indices {
            if let row = groups[index].sessions.firstIndex(where: { $0.id == session.id }) {
                groups[index].sessions[row] = session
                found = true
            }
        }
        if found { liveRevision &+= 1 }
        return found
    }

    /// Adds a session the list has not seen. Returns true when it belongs to
    /// no listed project, so projects need refetching.
    private func insert(_ session: OpenCodeSession) -> Bool {
        guard let index = groups.firstIndex(where: { owns($0.project, session) }) else {
            return unplacedIDs.insert(session.id).inserted
        }
        // An unloaded project picks the session up when its load lands.
        guard groups[index].isLoaded else { return false }
        groups[index].sessions.append(session)
        liveRevision &+= 1
        return false
    }

    private func owns(_ project: OpenCodeProject, _ session: OpenCodeSession) -> Bool {
        project.worktree == session.directory || (project.id == session.projectID && project.id != "global")
    }

    private func remove(sessionID id: String) {
        var removed = false
        for index in groups.indices {
            let count = groups[index].sessions.count
            groups[index].sessions.removeAll { $0.id == id }
            if groups[index].sessions.count != count {
                groups[index].statuses?[id] = nil
                removed = true
            }
        }
        if removed { liveRevision &+= 1 }
    }

    /// Re-applies live changes made while `group` was being fetched.
    private func reapplySessionEdits(to group: inout OpenCodeSessionGroup) {
        guard group.isLoaded else { return }
        for (id, edit) in sessionEdits {
            switch edit {
            case .removed:
                group.sessions.removeAll { $0.id == id }
            case .upserted(let session):
                if let row = group.sessions.firstIndex(where: { $0.id == id }) {
                    if group.sessions[row].time.updated <= session.time.updated { group.sessions[row] = session }
                } else if owns(group.project, session) {
                    group.sessions.append(session)
                }
            }
        }
    }

    private func root(of id: String) -> String {
        var current = id
        var depth = 0
        while let parent = parents[current], depth < 32 {
            current = parent
            depth += 1
        }
        return current
    }

    /// Finds the listed conversation behind sessions that asked for input
    /// but are not listed themselves: subagents started before the list
    /// opened. Each session is looked up at most once.
    private func lookUpParents(of ids: [String]) async {
        var queue = ids.map(root(of:)).filter { !isListed($0) }
        var lookups = 0
        while let id = queue.popLast(), lookups < 8 {
            guard parents[id] == nil, !isListed(id), lookedUpParents.insert(id).inserted else { continue }
            lookups += 1
            let parent: String?
            do { parent = try await service.parentSessionID(of: id, directory: nil) } catch {
                lookedUpParents.remove(id)
                continue
            }
            guard let parent else { continue }
            parents[id] = parent
            liveRevision &+= 1
            // Nested subagents: keep climbing until a listed conversation.
            if !isListed(root(of: parent)) { queue.append(root(of: parent)) }
        }
    }

    private func scheduleReconcile(_ scope: ReconcileScope) {
        reconcileRequest = max(reconcileRequest ?? scope, scope)
        guard reconcileTask == nil else { return }
        reconcileTask = Task { [weak self] in
            while let store = self, let scope = store.reconcileRequest, !Task.isCancelled {
                store.reconcileRequest = nil
                await store.handlers?.reconcile(scope)
            }
            self?.reconcileTask = nil
        }
    }

    /// v2 streams turn activity, not status. Coalesce bursts into one status
    /// refresh of the projects involved instead of refetching on every event.
    private func scheduleStatusRefresh(_ id: String) {
        statusRefreshIDs.insert(id)
        guard statusTask == nil else { return }
        statusTask = Task { [weak self, timing] in
            while let store = self, !store.statusRefreshIDs.isEmpty, !Task.isCancelled {
                do { try await Task.sleep(for: timing.statusDebounce) } catch { break }
                let ids = store.statusRefreshIDs
                store.statusRefreshIDs = []
                await store.refreshStatuses(of: ids)
            }
            self?.statusTask = nil
        }
    }

    /// Refetches statuses for the loaded projects that list `ids`, from the
    /// directory that reports each: the project's, or a worktree's.
    func refreshStatuses(of ids: Set<String>) async {
        let requestGeneration = generation
        let service = service
        var targets: [(group: String, directory: String)] = []
        for group in groups where group.isLoaded {
            for session in group.sessions where ids.contains(session.id) {
                let target = (group: group.id, directory: Self.statusDirectory(of: session, in: group.project))
                if !targets.contains(where: { $0 == target }) { targets.append(target) }
            }
        }
        let before = statuses
        await withTaskGroup(of: (String, String, [String: OpenCodeSessionStatus]?).self) { tasks in
            var next = 0
            func enqueue() {
                guard next < targets.count else { return }
                let (group, directory) = targets[next]
                next += 1
                tasks.addTask {
                    (group, directory, try? await service.sessionStatuses(directory: directory, workspace: nil))
                }
            }
            for _ in 0..<min(3, targets.count) { enqueue() }
            for await (groupID, directory, statuses) in tasks {
                guard !Task.isCancelled, generation == requestGeneration else {
                    tasks.cancelAll()
                    return
                }
                if let statuses, let index = groups.firstIndex(where: { $0.id == groupID }) {
                    let group = groups[index]
                    // Keep what the project's other directories reported.
                    var updated = (group.statuses ?? [:]).filter { id, _ in
                        group.sessions.first { $0.id == id }
                            .map { Self.statusDirectory(of: $0, in: group.project) != directory } ?? false
                    }
                    updated.merge(statuses) { _, new in new }
                    if group.statuses != updated {
                        groups[index].statuses = updated
                        liveRevision &+= 1
                    }
                }
                enqueue()
            }
        }
        guard !Task.isCancelled, generation == requestGeneration else { return }
        let after = statuses
        for (id, status) in before where status.isActive && after[id]?.isActive != true {
            handlers?.settled(id)
        }
    }

    /// The directory whose status route reports `session`: its worktree's, else the project's.
    nonisolated private static func statusDirectory(of session: OpenCodeSession, in project: OpenCodeProject) -> String {
        project.sandboxes.contains(session.directory) ? session.directory : project.worktree
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
