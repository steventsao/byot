import Foundation

/// The slice of the OpenCode API that Siri and Shortcuts use. `OpenCodeClient`
/// provides it for both protocol generations; tests substitute a fake.
protocol BYOTIntentServing: OpenCodeSessionBrowsing {
    func probeCompatibility() async throws -> OpenCodeCompatibilitySummary
    func listProjects() async throws -> [OpenCodeProject]
    func createSession(directory: String, title: String?) async throws -> OpenCodeSession
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels]
    func composerCatalog(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeComposerCatalog
    func sendPrompt(sessionID: String, directory: String, workspace: String?, prompt: OpenCodeQueuedPrompt) async throws
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope]
    func sessionDetails(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSessionDetails
}

extension OpenCodeClient: BYOTIntentServing {}

enum BYOTIntentError: LocalizedError, Equatable, Sendable {
    case noServers
    case serverRemoved
    case emptyPrompt
    case promptTooLong
    /// The server has several projects and none was chosen or configured.
    case needsProject
    case noProjects(server: String)
    case projectOnOtherServer
    case unsupported(server: String, detail: String)
    case unreachable(server: String)
    case notSent(server: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .noServers: "Add an OpenCode server in byot first."
        case .serverRemoved: "That server was removed from byot. Add it again, then try again."
        case .emptyPrompt: "Tell OpenCode what to do."
        case .promptTooLong: "That prompt is too long to send from Siri. Open byot to send it."
        case .needsProject: "Choose a project for OpenCode to work in."
        case .noProjects(let server): "\(server) has no projects yet. Open byot to start a session in a directory."
        case .projectOnOtherServer: "That project is on a different server. Choose the server again."
        case .unsupported(let server, let detail): "byot can’t start sessions on \(server). \(detail)"
        case .unreachable(let server): "Couldn’t reach \(server). Check that it’s running and connected, then try again."
        case .notSent(let server, let detail): "\(server) didn’t accept the prompt. \(detail)"
        }
    }
}

/// A session as Siri and Shortcuts show it. `state` is nil for an idle session.
struct BYOTIntentSession: Hashable, Identifiable, Sendable {
    var serverID: UUID
    var serverName: String
    var sessionID: String
    var title: String
    var projectName: String
    var directory: String
    var workspace: String?
    var state: BYOTWidgetSessionState?
    var updatedAt: Date

    var link: BYOTWidgetLink {
        BYOTWidgetLink(serverID: serverID, sessionID: sessionID, directory: directory, workspace: workspace)
    }

    var id: String { link.url.absoluteString }

    init(serverID: UUID, serverName: String, sessionID: String, title: String, projectName: String,
         directory: String, workspace: String?, state: BYOTWidgetSessionState?, updatedAt: Date) {
        self.serverID = serverID
        self.serverName = serverName
        self.sessionID = sessionID
        self.title = title
        self.projectName = projectName
        self.directory = directory
        self.workspace = workspace
        self.state = state
        self.updatedAt = updatedAt
    }

    init(_ row: BYOTWidgetSession) {
        self.init(serverID: row.serverID, serverName: row.serverName, sessionID: row.sessionID, title: row.title,
                  projectName: row.projectName, directory: row.directory, workspace: row.workspace,
                  state: row.state, updatedAt: row.updatedAt)
    }

    init(profile: OpenCodeServerProfile, session: OpenCodeSession, projectName: String? = nil,
         state: BYOTWidgetSessionState? = nil) {
        var row = BYOTIntentSession(BYOTWidgetSync.row(profile: profile, session: session, state: state ?? .running))
        row.state = state
        if let projectName { row.projectName = projectName }
        self = row
    }
}

/// A project on one server. Its identifier survives relaunches, so a saved
/// shortcut keeps pointing at the same directory.
struct BYOTIntentProject: Hashable, Identifiable, Sendable {
    var serverID: UUID
    var directory: String
    var name: String

    var id: String { Self.id(serverID: serverID, directory: directory) }

    static func id(serverID: UUID, directory: String) -> String {
        "\(serverID.uuidString)|\(directory)"
    }

    /// Server identifiers never contain "|", so the first one ends it.
    static func parse(_ id: String) -> (serverID: UUID, directory: String)? {
        guard let separator = id.firstIndex(of: "|"),
              let serverID = UUID(uuidString: String(id[..<separator])) else { return nil }
        let directory = String(id[id.index(after: separator)...])
        guard !directory.isEmpty else { return nil }
        return (serverID, directory)
    }
}

struct BYOTAskResult: Equatable, Sendable {
    var session: BYOTIntentSession

    var dialog: String {
        "Sent. OpenCode is working in \(session.projectName) on \(session.serverName)."
    }
}

/// What "Check sessions needing attention" found across the servers it asked.
struct BYOTAttentionReport: Equatable, Sendable {
    /// Sessions waiting on you or stopped with an error, most urgent first.
    var sessions: [BYOTIntentSession] = []
    var runningCount = 0
    /// Servers that didn't answer, or answered for only some projects.
    var unreachable: [String] = []
    var checkedServers = 0

    static let spokenLimit = 3

    var dialog: String {
        var sentences: [String] = []
        if checkedServers == 0, !unreachable.isEmpty {
            return "Couldn’t reach \(Self.list(unreachable)). Check that byot’s servers are running, then try again."
        }
        if sessions.isEmpty {
            sentences.append("Nothing needs you right now.")
        } else {
            let count = sessions.count
            let lead = count == 1 ? "1 session needs you" : "\(count) sessions need you"
            let named = sessions.prefix(Self.spokenLimit).map { session in
                "“\(session.title)” \(session.state == .failed ? "failed" : "is waiting for you")"
            }
            let rest = count - named.count
            let items = rest > 0 ? named + ["\(rest) more"] : named
            sentences.append("\(lead): \(Self.list(items)).")
        }
        if runningCount > 0 {
            sentences.append(runningCount == 1 ? "1 session is running." : "\(runningCount) sessions are running.")
        }
        if !unreachable.isEmpty {
            sentences.append("Couldn’t fully check \(Self.list(unreachable)).")
        }
        return sentences.joined(separator: " ")
    }

    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", and " + items[items.count - 1]
        }
    }
}

/// The work behind byot's App Intents. It reads saved servers the same way the
/// app does and reuses the session list's loading so both report the same
/// sessions. Every server call is bounded: Siri gives an intent about 30
/// seconds, and a server that is asleep must not use all of it.
struct BYOTIntentService: Sendable {
    static let maximumPromptLength = 20_000

    var profiles: @Sendable () -> [OpenCodeServerProfile]
    var activeProfileID: @Sendable () -> UUID?
    var makeService: @Sendable (OpenCodeServerProfile) -> any BYOTIntentServing
    /// Where byot keeps model choices and recorded failures; nil is `.standard`.
    var defaultsSuiteName: String?
    var timeout: Duration
    /// Shares a refresh with the home-screen widget.
    var publish: @MainActor @Sendable (BYOTWidgetServer) -> Void
    /// Shows a session started from Siri as running in the widget right away.
    var started: @MainActor @Sendable (OpenCodeServerProfile, OpenCodeSession) -> Void

    static let live = BYOTIntentService(
        profiles: { OpenCodeProfileStore.savedProfiles() },
        activeProfileID: { OpenCodeProfileStore.savedActiveProfileID() },
        makeService: { OpenCodeClient(profile: $0, password: OpenCodeProfileStore.savedPassword(for: $0.id)) },
        defaultsSuiteName: nil,
        timeout: .seconds(8),
        publish: { BYOTWidgetSync.shared.publish($0) },
        started: { profile, session in
            BYOTWidgetSync.shared.update(BYOTWidgetSync.row(profile: profile, session: session, state: .running),
                                         serverID: profile.id, sessionID: session.id, serverName: profile.name)
        })

    var defaults: UserDefaults { defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard }

    func profile(_ id: UUID?) throws -> OpenCodeServerProfile {
        let profiles = profiles()
        guard !profiles.isEmpty else { throw BYOTIntentError.noServers }
        guard let id = id ?? activeProfileID() else { return profiles[0] }
        guard let profile = profiles.first(where: { $0.id == id }) else { throw BYOTIntentError.serverRemoved }
        return profile
    }

    // MARK: Projects

    /// The server's projects, most recently used first, plus the directory
    /// configured on its profile when the server doesn't list it.
    func projects(serverID: UUID?) async throws -> [BYOTIntentProject] {
        let profile = try profile(serverID)
        let service = makeService(profile)
        let listed: [OpenCodeProject]
        do { listed = try await bounded { try await service.listProjects() } }
        catch { throw BYOTIntentError.unreachable(server: profile.name) }
        return Self.projects(listed, profile: profile)
    }

    static func projects(_ listed: [OpenCodeProject], profile: OpenCodeServerProfile) -> [BYOTIntentProject] {
        browsable(listed, profile: profile).map {
            BYOTIntentProject(serverID: profile.id, directory: $0.worktree, name: $0.displayName)
        }
    }

    /// Unique projects, most recently updated first, with the profile's
    /// configured directory added (first) when the server doesn't list it,
    /// as the session list does.
    static func browsable(_ listed: [OpenCodeProject], profile: OpenCodeServerProfile) -> [OpenCodeProject] {
        var seen = Set<String>()
        var result = listed.sorted { $0.time.updated > $1.time.updated }.filter { seen.insert($0.worktree).inserted }
        if let configured = profile.normalizedDirectory, !seen.contains(configured) {
            result.insert(OpenCodeProject(id: configured, worktree: configured, vcs: nil, name: nil,
                                          time: OpenCodeProjectTime(created: 0, updated: 0), sandboxes: []), at: 0)
        }
        return result
    }

    // MARK: Ask OpenCode

    /// Starts a session and sends the prompt with the model, agent and variant
    /// last picked on this server. Without a directory it uses the profile's
    /// configured one, or the server's only project.
    func ask(prompt: String, serverID: UUID?, directory: String?) async throws -> BYOTAskResult {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BYOTIntentError.emptyPrompt }
        guard text.count <= Self.maximumPromptLength else { throw BYOTIntentError.promptTooLong }
        let profile = try profile(serverID)
        let service = makeService(profile)

        let compatibility: OpenCodeCompatibilitySummary
        do { compatibility = try await bounded { try await service.probeCompatibility() } }
        catch { throw BYOTIntentError.unreachable(server: profile.name) }
        guard compatibility.state != .unsupported else {
            throw BYOTIntentError.unsupported(server: profile.name,
                                              detail: compatibility.detail ?? "This OpenCode version isn’t supported.")
        }

        var projectName: String?
        let target: String
        if let directory = directory?.trimmingCharacters(in: .whitespacesAndNewlines), !directory.isEmpty {
            target = directory
        } else if let configured = profile.normalizedDirectory {
            target = configured
        } else {
            let listed: [OpenCodeProject]
            do { listed = try await bounded { try await service.listProjects() } }
            catch { throw BYOTIntentError.unreachable(server: profile.name) }
            let projects = Self.projects(listed, profile: profile)
            guard !projects.isEmpty else { throw BYOTIntentError.noProjects(server: profile.name) }
            guard projects.count == 1 else { throw BYOTIntentError.needsProject }
            target = projects[0].directory
            projectName = projects[0].name
        }

        let session: OpenCodeSession
        do { session = try await bounded { try await service.createSession(directory: target, title: nil) } }
        catch { throw Self.failure(error, profile: profile) }
        let preferences = await preferences(for: profile, session: session, service: service)
        let queued = OpenCodeQueuedPrompt(text: text, model: preferences.model, agent: preferences.agent,
                                          variant: preferences.variant)
        do {
            try await bounded {
                try await service.sendPrompt(sessionID: session.id, directory: session.directory,
                                             workspace: session.workspaceID, prompt: queued)
            }
        } catch { throw Self.failure(error, profile: profile) }
        await started(profile, session)
        return BYOTAskResult(session: BYOTIntentSession(profile: profile, session: session,
                                                        projectName: projectName, state: .running))
    }

    struct Preferences: Equatable, Sendable {
        var model: OpenCodeModelOption?
        var agent: String?
        var variant: String?
    }

    /// Only choices the server still offers are sent; anything it no longer
    /// lists falls back to the server's own default rather than failing.
    func preferences(for profile: OpenCodeServerProfile, session: OpenCodeSession,
                     service: any BYOTIntentServing) async -> Preferences {
        let modelID = defaults.string(forKey: OpenCodeSessionStore.serverDefaultModelKey(profile.id))?.trimmedNonEmpty
        let agentID = defaults.string(forKey: OpenCodeSessionStore.serverDefaultAgentKey(profile.id))?.trimmedNonEmpty
        guard modelID != nil || agentID != nil else { return Preferences() }
        async let providers: [OpenCodeProviderModels]? = modelID == nil ? nil : try? bounded {
            try await service.connectedProviderModels(directory: session.directory, workspace: session.workspaceID)
        }
        async let catalog: OpenCodeComposerCatalog? = try? bounded {
            try await service.composerCatalog(sessionID: session.id, directory: session.directory,
                                              workspace: session.workspaceID)
        }
        let (models, composer) = await (providers?.flatMap(\.models), catalog)
        var result = Preferences()
        result.model = modelID.flatMap { id in models?.first { $0.qualifiedID == id } }
        if let agentID, composer?.unavailableReason == nil, composer?.agents.contains(where: { $0.id == agentID }) == true {
            result.agent = agentID
        }
        if let model = result.model, composer?.supportsVariants == true,
           let variant = defaults.string(forKey: OpenCodeSessionStore.serverDefaultVariantKey(profile.id, model: model))?
            .trimmedNonEmpty, model.variants.contains(variant) {
            result.variant = variant
        }
        return result
    }

    private static func failure(_ error: any Error, profile: OpenCodeServerProfile) -> BYOTIntentError {
        if error is CancellationError || (error as? URLError) != nil {
            return .unreachable(server: profile.name)
        }
        return .notSent(server: profile.name, detail: error.localizedDescription)
    }

    // MARK: Sessions needing attention

    /// Checks every saved server, or one, the way the session list does, and
    /// shares the result with the widget.
    @MainActor
    func attention(serverID: UUID?) async throws -> BYOTAttentionReport {
        let targets = serverID == nil ? profiles() : [try profile(serverID)]
        guard !targets.isEmpty else { throw BYOTIntentError.noServers }
        let checks = await withTaskGroup(of: (Int, ServerCheck).self) { group in
            for (index, profile) in targets.enumerated() {
                group.addTask { (index, await self.check(profile)) }
            }
            var results: [(Int, ServerCheck)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return Self.report(checks)
    }

    enum ServerCheck: Equatable, Sendable {
        case checked(BYOTWidgetServer, complete: Bool)
        case unreachable(String)
    }

    static func report(_ checks: [ServerCheck]) -> BYOTAttentionReport {
        var report = BYOTAttentionReport()
        var snapshot = BYOTWidgetSnapshot()
        for check in checks {
            switch check {
            case .checked(let server, let complete):
                report.checkedServers += 1
                snapshot.servers.append(server)
                if !complete { report.unreachable.append(server.name) }
            case .unreachable(let name):
                report.unreachable.append(name)
            }
        }
        let sessions = snapshot.sessions
        report.sessions = sessions.filter(\.state.needsAttention).map(BYOTIntentSession.init)
        report.runningCount = sessions.filter { $0.state == .running || $0.state == .retrying }.count
        return report
    }

    @MainActor
    private func check(_ profile: OpenCodeServerProfile) async -> ServerCheck {
        let service = makeService(profile)
        guard let listed = try? await bounded({ try await service.listProjects() }) else {
            return .unreachable(profile.name)
        }
        let projects = Self.browsable(listed, profile: profile)
        let browser = OpenCodeSessionBrowserStore(service: service)
        let finished = await boundedLoad { await browser.load(projects: projects) }
        guard browser.groups.contains(where: { $0.statuses != nil }) else { return .unreachable(profile.name) }
        let attention = OpenCodeSessionAttentionStore(serverID: profile.id, defaults: defaults)
        await reconcile(attention, sessions: browser.sessions, statuses: browser.statuses, service: service)
        let server = BYOTWidgetSync.server(profile: profile, sessions: browser.sessions, statuses: browser.statuses,
                                           pendingSessionIDs: browser.pendingSessionIDs, failures: attention.failures)
        publish(server)
        let complete = finished && browser.groups.allSatisfy { $0.error == nil && $0.statuses != nil }
        return .checked(server, complete: complete)
    }

    /// A failure recorded in byot may since have been retried from another
    /// client. Re-read only those idle sessions, a few at a time.
    @MainActor
    private func reconcile(_ attention: OpenCodeSessionAttentionStore, sessions: [OpenCodeSession],
                           statuses: [String: OpenCodeSessionStatus], service: any BYOTIntentServing) async {
        let targets = sessions.filter { attention.failures[$0.id] != nil && statuses[$0.id]?.isActive != true }
        guard !targets.isEmpty else { return }
        let settled = await withTaskGroup(of: (String, String??).self) { group in
            for session in targets.prefix(6) {
                group.addTask {
                    let messages = try? await bounded {
                        try await service.messages(sessionID: session.id, directory: session.directory,
                                                   workspace: session.workspaceID)
                    }
                    return (session.id, messages.map(OpenCodeSessionAttentionStore.message(in:)))
                }
            }
            var result: [(String, String??)] = []
            for await item in group { result.append(item) }
            return result
        }
        for case (let id, .some(let message)) in settled { attention.record(sessionID: id, message: message) }
    }

    // MARK: Recent sessions

    /// Recently updated sessions for the "Open Session" picker: the few most
    /// recent projects on each server, so the list stays quick to load.
    @MainActor
    func recentSessions(limit: Int = 20, projectsPerServer: Int = 5) async throws -> [BYOTIntentSession] {
        let targets = profiles()
        guard !targets.isEmpty else { throw BYOTIntentError.noServers }
        let lists = await withTaskGroup(of: [BYOTIntentSession].self) { group in
            for profile in targets {
                group.addTask { await self.recentSessions(on: profile, projectsPerServer: projectsPerServer) }
            }
            var result: [[BYOTIntentSession]] = []
            for await list in group { result.append(list) }
            return result
        }
        return Array(lists.joined().sorted { lhs, rhs in
            lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.id < rhs.id
        }.prefix(limit))
    }

    @MainActor
    private func recentSessions(on profile: OpenCodeServerProfile, projectsPerServer: Int) async -> [BYOTIntentSession] {
        let service = makeService(profile)
        guard let listed = try? await bounded({ try await service.listProjects() }) else { return [] }
        let projects = Array(Self.browsable(listed, profile: profile).prefix(projectsPerServer))
        let names = Dictionary(projects.map { ($0.worktree, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let browser = OpenCodeSessionBrowserStore(service: service)
        _ = await boundedLoad { await browser.load(projects: projects) }
        let failures = OpenCodeSessionAttentionStore(serverID: profile.id, defaults: defaults).failures
        let statuses = browser.statuses
        let pending = browser.pendingSessionIDs
        return browser.sessions.map { session in
            BYOTIntentSession(profile: profile, session: session, projectName: names[session.directory],
                              state: BYOTWidgetSync.state(status: statuses[session.id],
                                                          isPending: pending.contains(session.id),
                                                          hasFailure: failures[session.id] != nil))
        }
    }

    /// Looks up one session for a saved shortcut whose title isn't cached.
    func session(_ link: BYOTWidgetLink) async -> BYOTIntentSession? {
        guard let profile = profiles().first(where: { $0.id == link.serverID }) else { return nil }
        let service = makeService(profile)
        guard let details = try? await bounded({
            try await service.sessionDetails(sessionID: link.sessionID, directory: link.directory,
                                             workspace: link.workspace)
        }), details.session.id == link.sessionID else { return nil }
        return BYOTIntentSession(profile: profile, session: details.session)
    }

    // MARK: Deadlines

    /// Runs one request, cancelling it once `timeout` passes.
    func bounded<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let timeout = timeout
        let work = Task { try await operation() }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            work.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Runs a session-list load, cancelling it once `timeout` passes. Returns
    /// false when the deadline cut it short; what loaded before then is kept.
    @MainActor
    func boundedLoad(_ load: @escaping @MainActor () async -> Void) async -> Bool {
        let timeout = timeout
        let work = Task { @MainActor in await load() }
        let deadline = Task {
            try? await Task.sleep(for: timeout)
            work.cancel()
        }
        await work.value
        deadline.cancel()
        return !work.isCancelled
    }
}
