import Foundation

/// The project whose worktrees a screen manages: its primary checkout on one server.
/// Worktree routes resolve the project from this directory (`?directory=`).
struct OpenCodeWorktreeRoute: Hashable, Identifiable, Sendable {
    let directory: String
    var projectName: String

    var id: String { directory }

    init(directory: String, projectName: String? = nil) {
        self.directory = directory
        self.projectName = projectName ?? URL(fileURLWithPath: directory).lastPathComponent
    }
}

// MARK: - Models

/// `Worktree.Info` from `packages/opencode/src/worktree`. Creating one answers with its
/// name and branch; the list answers directories only, so those fall back to the folder
/// name and whatever the branch lookup finds.
struct OpenCodeWorktree: Decodable, Identifiable, Hashable, Sendable {
    let directory: String
    var name: String
    var branch: String?

    var id: String { directory }

    init(directory: String, name: String? = nil, branch: String? = nil) {
        self.directory = directory
        self.name = name?.trimmedNonEmpty ?? Self.name(of: directory)
        self.branch = branch?.trimmedNonEmpty
    }

    private enum CodingKeys: String, CodingKey { case directory, name, branch }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(directory: try container.decode(String.self, forKey: .directory),
                  name: try container.decodeIfPresent(String.self, forKey: .name),
                  branch: try container.decodeIfPresent(String.self, forKey: .branch))
    }

    /// The folder name, which is the name OpenCode gave the worktree.
    static func name(of directory: String) -> String {
        let trimmed = directory.hasSuffix("/") && directory.count > 1 ? String(directory.dropLast()) : directory
        return trimmed.split(separator: "/").last.map(String.init) ?? directory
    }

    /// Directories compare without a trailing slash, as the server canonicalises them.
    static func key(_ directory: String) -> String {
        var key = directory
        while key.count > 1 && key.hasSuffix("/") { key.removeLast() }
        return key
    }
}

/// What a worktree row shows beside its name. `nil` fields are unknown (still loading,
/// or the server can't say), which is different from zero.
struct OpenCodeWorktreeSummary: Equatable, Sendable {
    var branch: String?
    /// The project's default branch, which a reset returns the worktree to.
    var defaultBranch: String?
    var changes: Int?
    var sessions: Int?
}

/// Names the way the server does (`slugify` in `worktree/index.ts`), so the sheet can show
/// the branch a name will create. The server adds a suffix if that branch already exists.
enum OpenCodeWorktreeNaming {
    static func slug(_ input: String) -> String {
        var slug = ""
        var pendingDash = false
        for scalar in input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if pendingDash && !slug.isEmpty { slug.append("-") }
                pendingDash = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return slug
    }

    /// `opencode/<slug>`, or `nil` where the server will pick a random name instead.
    static func branch(for name: String) -> String? {
        let slug = slug(name)
        return slug.isEmpty ? nil : "opencode/\(slug)"
    }
}

/// Words for worktree rows and confirmations, kept apart from the views so they're testable.
enum OpenCodeWorktreeCopy {
    static func changes(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No uncommitted changes")
        case 1: String(localized: "1 uncommitted change")
        default: String(localized: "\(count) uncommitted changes")
        }
    }

    static func sessions(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No sessions")
        case 1: String(localized: "1 session")
        default: String(localized: "\(count) sessions")
        }
    }

    /// What a reset discards, as the web app's reset dialog explains it.
    static func resetMessage(_ worktree: OpenCodeWorktree, summary: OpenCodeWorktreeSummary?) -> String {
        let branch = summary?.branch ?? worktree.branch
        let target = summary?.defaultBranch ?? String(localized: "the default branch")
        var lines = [branch.map { String(localized: "Resets \($0) to match \(target).") }
            ?? String(localized: "Resets the worktree to match \(target).")]
        switch summary?.changes {
        case let count? where count > 0:
            lines.append(String(localized: "Commits on it and \(changes(count).lowercased()) will be discarded."))
        default:
            lines.append(String(localized: "Commits on it and any uncommitted changes will be discarded."))
        }
        lines.append(String(localized: "Its sessions are kept."))
        return lines.joined(separator: " ")
    }

    /// What a delete removes: the folder, the branch, and (from the list) its sessions.
    static func removalMessage(_ worktree: OpenCodeWorktree, summary: OpenCodeWorktreeSummary?) -> String {
        let branch = summary?.branch ?? worktree.branch
        var lines = [branch.map { String(localized: "Deletes the worktree’s folder on the server and its branch, \($0).") }
            ?? String(localized: "Deletes the worktree’s folder on the server and its branch.")]
        if let count = summary?.changes, count > 0 {
            lines.append(String(localized: "\(changes(count)) will be lost."))
        }
        if let count = summary?.sessions, count > 0 {
            lines.append(count == 1 ? String(localized: "Its session will no longer be listed.") : String(localized: "Its \(count) sessions will no longer be listed."))
        }
        return lines.joined(separator: " ")
    }
}

/// `worktree.ready` and `worktree.failed` from the global event stream. A new worktree is
/// checked out and booted after the create request returns; these report how that went.
enum OpenCodeWorktreeEvent: Equatable, Sendable {
    case connected
    case ready(directory: String)
    case failed(directory: String, message: String)

    init?(_ event: OpenCodeEvent) {
        switch event.type {
        case "server.connected":
            self = .connected
        case "worktree.ready":
            guard let directory = event.location?.directory else { return nil }
            self = .ready(directory: OpenCodeWorktree.key(directory))
        case "worktree.failed":
            guard let directory = event.location?.directory else { return nil }
            let message = event.properties["message"]?.stringValue?.trimmedNonEmpty
            self = .failed(directory: OpenCodeWorktree.key(directory),
                           message: message ?? String(localized: "OpenCode couldn’t check out the worktree."))
        default:
            return nil
        }
    }
}

enum OpenCodeWorktreeError: LocalizedError, Equatable {
    /// The server has no worktree routes: a 404, the web app's HTML, or a v2 schema without them.
    case unsupported
    /// The server's own explanation, such as "Worktrees are only supported for git projects".
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "This OpenCode server doesn’t manage worktrees.")
        case .server(let message): message
        }
    }
}

// MARK: - Service

protocol OpenCodeWorktreeServicing: Sendable {
    /// The project's worktrees, oldest first. Throws `unsupported` where the server has none.
    func list() async throws -> [OpenCodeWorktree]
    /// `name` is optional; the server picks one (and slugs whatever it is given).
    func create(name: String?) async throws -> OpenCodeWorktree
    /// Removes the worktree's folder and deletes its branch.
    func remove(_ directory: String) async throws
    /// Resets the worktree's branch to the project's default branch and cleans its folder.
    func reset(_ directory: String) async throws
    /// Readiness reports for new worktrees. Finishes at once where the server has no global stream.
    func events() -> AsyncThrowingStream<OpenCodeWorktreeEvent, Error>
    /// Branch, uncommitted changes and sessions of one worktree; unknown parts stay `nil`.
    func summary(of directory: String) async -> OpenCodeWorktreeSummary
    func createSession(in directory: String) async throws -> OpenCodeSession
}

/// Contract: OpenCode v1 1.18 `/experimental/worktree` (GET list, POST create, DELETE remove)
/// and `/experimental/worktree/reset`, scoped by `?directory=`, with readiness on `/global/event`.
/// A v2 server is used only when its schema publishes each of these routes; the v2 beta
/// doesn't, so the feature stays hidden there. Errors arrive as 400 `WorktreeError`s.
struct OpenCodeWorktreeService: OpenCodeWorktreeServicing {
    let directory: String
    let context: @Sendable () async throws -> OpenCodeFeatureContext
    let listSessions: @Sendable (String) async throws -> [OpenCodeSession]
    let startSession: @Sendable (String) async throws -> OpenCodeSession

    init(client: OpenCodeClient, route: OpenCodeWorktreeRoute) {
        self.init(directory: route.directory,
                  context: { try await client.featureContext() },
                  listSessions: { try await client.listSessions(directory: $0) },
                  startSession: { try await client.createSession(directory: $0, title: nil) })
    }

    init(directory: String,
         context: @escaping @Sendable () async throws -> OpenCodeFeatureContext,
         listSessions: @escaping @Sendable (String) async throws -> [OpenCodeSession] = { _ in [] },
         startSession: @escaping @Sendable (String) async throws -> OpenCodeSession = { _ in
             throw OpenCodeWorktreeError.unsupported
         }) {
        self.directory = directory
        self.context = context
        self.listSessions = listSessions
        self.startSession = startSession
    }

    /// Gates entry points: hidden unless the server is reachable and lists worktrees.
    func isAvailable() async -> Bool {
        (try? await list()) != nil
    }

    func list() async throws -> [OpenCodeWorktree] {
        let connection = try await context()
        try requireSupport(connection)
        let request = try connection.transport.makeRequest(
            path: Self.path, query: query, method: "GET", body: nil)
        let directories: [String] = try await perform(connection, request)
        var seen = Set<String>()
        return directories.filter { seen.insert(OpenCodeWorktree.key($0)).inserted }
            .map { OpenCodeWorktree(directory: $0) }
    }

    func create(name: String?) async throws -> OpenCodeWorktree {
        let connection = try await context()
        try requireSupport(connection)
        struct Body: Encodable { let name: String? }
        let body = try JSONEncoder().encode(Body(name: name?.trimmedNonEmpty))
        let request = try connection.transport.makeRequest(
            path: Self.path, query: query, method: "POST", body: body)
        return try await perform(connection, request)
    }

    func remove(_ worktree: String) async throws {
        try await change(Self.path, method: "DELETE", worktree: worktree)
    }

    func reset(_ worktree: String) async throws {
        try await change(Self.path + ["reset"], method: "POST", worktree: worktree)
    }

    func events() -> AsyncThrowingStream<OpenCodeWorktreeEvent, Error> {
        let context = context
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                do {
                    let connection = try await context()
                    guard connection.supports("/global/event") else {
                        continuation.finish()
                        return
                    }
                    for try await event in connection.transport.events(path: ["global", "event"], query: []) {
                        try Task.checkCancellation()
                        if let event = OpenCodeWorktreeEvent(event) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func summary(of worktree: String) async -> OpenCodeWorktreeSummary {
        let status = OpenCodeServerContextService(directory: worktree, workspace: nil, context: context)
        async let branch = try? status.branch()
        async let changes = try? status.changes()
        async let sessions = try? listSessions(worktree)
        let (vcs, files, listed) = await (branch, changes, sessions)
        return OpenCodeWorktreeSummary(
            branch: vcs?.current,
            defaultBranch: vcs?.defaultBranch,
            changes: files?.count,
            sessions: listed?.filter { $0.parentID == nil && $0.time.archived == nil }.count)
    }

    func createSession(in worktree: String) async throws -> OpenCodeSession {
        try await startSession(worktree)
    }

    // MARK: Requests

    private static let path = ["experimental", "worktree"]

    private var query: [URLQueryItem] { [URLQueryItem(name: "directory", value: directory)] }

    /// Remove and reset answer `true`; anything else that isn't an error is still success.
    private func change(_ path: [String], method: String, worktree: String) async throws {
        let connection = try await context()
        try requireSupport(connection)
        let body = try JSONEncoder().encode(["directory": worktree])
        let request = try connection.transport.makeRequest(path: path, query: query, method: method, body: body)
        let _: OpenCodeJSONValue = try await perform(connection, request)
    }

    private func perform<Value: Decodable>(_ connection: OpenCodeFeatureContext, _ request: URLRequest) async throws -> Value {
        do {
            return try await connection.transport.perform(request)
        } catch let error as OpenCodeConnectionError {
            switch error {
            case .httpStatus(let status, _) where status == 404 || status == 405:
                throw OpenCodeWorktreeError.unsupported
            case .unexpectedContentType:
                // Older servers answer the web app's HTML for routes they lack.
                throw OpenCodeWorktreeError.unsupported
            case .httpStatus(400, let message?) where !message.isEmpty:
                throw OpenCodeWorktreeError.server(message)
            default:
                throw error
            }
        }
    }

    /// Never guesses routes a v2 schema omits.
    private func requireSupport(_ connection: OpenCodeFeatureContext) throws {
        guard connection.serverProtocol == .v2 else { return }
        let path = "/experimental/worktree"
        guard connection.supports(path), connection.supports(path, method: "post"),
              connection.supports(path, method: "delete"), connection.supports(path + "/reset", method: "post")
        else { throw OpenCodeWorktreeError.unsupported }
    }
}
