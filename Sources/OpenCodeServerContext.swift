import Foundation

/// One project location on one server, as the status screen shows it. Everything on the
/// screen is scoped to it: v1 with `?directory=&workspace=`, v2 with `?location[...]`.
struct OpenCodeProjectStatusRoute: Hashable, Identifiable, Sendable {
    let directory: String
    var workspace: String?
    var projectName: String

    var id: String { "\(directory)|\(workspace ?? "")" }

    init(directory: String, workspace: String? = nil, projectName: String? = nil) {
        self.directory = directory
        self.workspace = workspace
        self.projectName = projectName ?? URL(fileURLWithPath: directory).lastPathComponent
    }
}

// MARK: - Models

/// v1 `GET /path` and v2 `GET /api/location`. v2 knows only the location and its project.
struct OpenCodeProjectPaths: Equatable, Sendable {
    var directory: String
    var worktree: String?
    var projectID: String?
    var workspaceID: String?
    var home: String?
    var config: String?
    var state: String?

    /// `~/…` for paths under the server user's home, which is how the TUI prints them.
    func abbreviated(_ path: String) -> String {
        guard let home = home?.trimmedNonEmpty, home != "/" else { return path }
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }
}

/// A branch switch from the `vcs.branch.updated` event. `name` is `nil` for a detached
/// HEAD, so the wrapper tells "no report yet" apart from "reported no branch".
struct OpenCodeReportedBranch: Equatable, Sendable {
    let name: String?
}

/// `Vcs.FileStatus`: one changed file in the working tree, without its patch.
struct OpenCodeProjectFileChange: Decodable, Identifiable, Equatable, Sendable {
    let path: String
    let status: OpenCodeDiffFileStatus
    let additions: Int
    let deletions: Int

    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var folder: String? {
        let parts = path.split(separator: "/")
        return parts.count > 1 ? parts.dropLast().joined(separator: "/") : nil
    }

    init(path: String, status: OpenCodeDiffFileStatus, additions: Int = 0, deletions: Int = 0) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
    }

    private enum CodingKeys: String, CodingKey { case file, status, additions, deletions }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .file)
        status = (try? container.decodeIfPresent(String.self, forKey: .status))
            .flatMap(OpenCodeDiffFileStatus.init(rawValue:)) ?? .modified
        additions = Int((try? container.decodeIfPresent(Double.self, forKey: .additions)) ?? 0)
        deletions = Int((try? container.decodeIfPresent(Double.self, forKey: .deletions)) ?? 0)
    }
}

/// `MCP.Status` on v1 (a name-keyed map) and `Mcp.Server` on v2 (a list). v2 adds
/// `pending` while a server starts; v1 adds `needs_client_registration`.
struct OpenCodeMCPServer: Identifiable, Equatable, Sendable {
    enum State: Equatable, Sendable {
        case connected
        case pending
        case disabled
        case failed
        case needsAuthentication
        case needsClientRegistration
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "connected": self = .connected
            case "pending": self = .pending
            case "disabled": self = .disabled
            case "failed": self = .failed
            case "needs_auth": self = .needsAuthentication
            case "needs_client_registration": self = .needsClientRegistration
            default: self = .other(raw)
            }
        }

        var title: String {
            switch self {
            case .connected: "Connected"
            case .pending: "Connecting…"
            case .disabled: "Disabled"
            case .failed: "Failed"
            case .needsAuthentication: "Needs sign-in"
            case .needsClientRegistration: "Needs client registration"
            case .other(let raw): raw.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }
    }

    let name: String
    var state: State
    var error: String?

    var id: String { name }
    var isConnected: Bool { state == .connected }

    /// What the switch does from this state, following the web app's toggle: connected
    /// servers disconnect, and anything stopped or failed retries a connection. Sign-in
    /// opens a browser on the server's machine, so the phone can't complete it.
    var canToggle: Bool {
        switch self.state {
        case .pending, .needsAuthentication: false
        default: true
        }
    }

    init(name: String, state: State, error: String? = nil) {
        self.name = name
        self.state = state
        self.error = error
    }

    /// Accepts `{status, error?}` objects from either protocol.
    init?(name: String, status value: OpenCodeJSONValue?) {
        guard let object = value?.objectValue, let status = object["status"]?.stringValue else { return nil }
        self.init(name: name, state: State(status), error: object["error"]?.stringValue?.trimmedNonEmpty)
    }

    static func sorted(_ servers: [Self]) -> [Self] {
        servers.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// `LSP.Status`: one running language server client.
struct OpenCodeLSPServer: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let root: String
    let isConnected: Bool

    init(id: String, name: String, root: String, isConnected: Bool = true) {
        self.id = id
        self.name = name
        self.root = root
        self.isConnected = isConnected
    }

    private enum CodingKeys: String, CodingKey { case id, name, root, status }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)?.trimmedNonEmpty ?? id
        root = try container.decodeIfPresent(String.self, forKey: .root) ?? ""
        isConnected = (try? container.decodeIfPresent(String.self, forKey: .status)) == "connected"
    }

    /// The root relative to the project, since most servers run at the project root.
    func displayRoot(relativeTo directory: String) -> String {
        let root = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        let base = directory.hasSuffix("/") && directory.count > 1 ? String(directory.dropLast()) : directory
        if root.isEmpty || root == base { return "Project root" }
        if root.hasPrefix(base + "/") { return String(root.dropFirst(base.count + 1)) }
        return root
    }
}

/// `Format.Status`: every formatter OpenCode knows, and whether it runs in this project.
struct OpenCodeFormatterStatus: Decodable, Identifiable, Equatable, Sendable {
    let name: String
    let extensions: [String]
    let enabled: Bool

    var id: String { name }

    init(name: String, extensions: [String], enabled: Bool) {
        self.name = name
        self.extensions = extensions
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case name, extensions, enabled }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        extensions = (try? container.decodeIfPresent([String].self, forKey: .extensions)) ?? []
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
    }

    /// Enabled formatters first, each group by name.
    static func sorted(_ formatters: [Self]) -> [Self] {
        formatters.sorted {
            if $0.enabled != $1.enabled { return $0.enabled }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

// MARK: - Configuration

/// The configuration a project runs with, read-only. v1 `GET /config` returns the merged
/// document; v2 `GET /api/config` returns each source from lowest to highest priority.
///
/// Editing is deliberately absent: v1 `PATCH /config` deep-merges its body into a
/// `config.json` in the project directory, which project loading doesn't read, so a
/// full-document round trip would copy global secrets into the project without effect.
struct OpenCodeServerConfiguration: Equatable, Sendable {
    struct Plugin: Identifiable, Equatable, Sendable {
        let name: String
        var version: String?
        var id: String { version.map { "\(name)@\($0)" } ?? name }
    }

    struct Provider: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
    }

    /// Where a v2 configuration came from.
    struct Source: Identifiable, Equatable, Sendable {
        enum Kind: String, Sendable {
            case document, directory, agents, claude

            var title: String {
                switch self {
                case .document: "Config file"
                case .directory: "Config directory"
                case .agents: "Agents directory"
                case .claude: "Claude directory"
                }
            }
        }

        let kind: Kind
        let path: String?
        let index: Int
        var id: Int { index }
    }

    /// One JSON document for the viewer, with secrets already removed.
    struct Document: Identifiable, Equatable, Sendable {
        let title: String
        let path: String?
        let json: OpenCodeJSONValue
        let index: Int
        var id: Int { index }
    }

    var model: String?
    var smallModel: String?
    var defaultAgent: String?
    var username: String?
    var share: String?
    var updates: String?
    var shell: String?
    var plugins: [Plugin] = []
    var providers: [Provider] = []
    var instructions: [String] = []
    var sources: [Source] = []
    var documents: [Document] = []

    /// v1: the merged configuration object.
    static func v1(_ object: [String: OpenCodeJSONValue]) -> Self {
        var configuration = Self()
        configuration.apply(object, v2: false)
        configuration.documents = [Document(title: "Effective configuration", path: nil,
                                            json: redacted(.object(object)), index: 0)]
        return configuration
    }

    /// v2: `Config.Entry` values, lowest priority first, so later documents win.
    static func v2(_ entries: [OpenCodeJSONValue]) -> Self {
        var configuration = Self()
        for (index, entry) in entries.enumerated() {
            guard let object = entry.objectValue,
                  let kind = object["type"]?.stringValue.flatMap(Source.Kind.init(rawValue:)) else { continue }
            let path = object["path"]?.stringValue?.trimmedNonEmpty
            configuration.sources.append(Source(kind: kind, path: path, index: index))
            guard kind == .document, let info = object["info"]?.objectValue else { continue }
            configuration.apply(info, v2: true)
            configuration.documents.append(Document(
                title: path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Configuration",
                path: path, json: redacted(.object(info)), index: index))
        }
        return configuration
    }

    private mutating func apply(_ object: [String: OpenCodeJSONValue], v2: Bool) {
        if let model = Self.model(object["model"]) { self.model = model }
        if let model = Self.model(object["small_model"]) { smallModel = model }
        if let agent = object["default_agent"]?.stringValue?.trimmedNonEmpty { defaultAgent = agent }
        if let name = object["username"]?.stringValue?.trimmedNonEmpty { username = name }
        if let shell = object["shell"]?.stringValue?.trimmedNonEmpty { self.shell = shell }
        if let share = object["share"]?.stringValue { self.share = Self.shareTitle(share) }
        if let updates = Self.updatesTitle(object[v2 ? "update" : "autoupdate"]) { self.updates = updates }

        let plugins = (object[v2 ? "plugins" : "plugin"]?.arrayValue ?? []).compactMap(Self.plugin)
        for plugin in plugins where !self.plugins.contains(plugin) { self.plugins.append(plugin) }
        self.plugins.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for (id, value) in object[v2 ? "providers" : "provider"]?.objectValue ?? [:] {
            let name = value.objectValue?["name"]?.stringValue?.trimmedNonEmpty ?? id
            providers.removeAll { $0.id == id }
            providers.append(Provider(id: id, name: name))
        }
        providers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for instruction in object["instructions"]?.arrayValue?.compactMap(\.stringValue) ?? []
        where !instructions.contains(instruction) {
            instructions.append(instruction)
        }
    }

    /// `provider/model` strings, or v2's `{providerID, model, variant}` object.
    static func model(_ value: OpenCodeJSONValue?) -> String? {
        if let string = value?.stringValue?.trimmedNonEmpty { return string }
        guard let object = value?.objectValue,
              let provider = object["providerID"]?.stringValue?.trimmedNonEmpty,
              let model = object["model"]?.stringValue?.trimmedNonEmpty else { return nil }
        let variant = object["variant"]?.stringValue?.trimmedNonEmpty.map { " (\($0))" } ?? ""
        return "\(provider)/\(model)\(variant)"
    }

    static func shareTitle(_ raw: String) -> String {
        switch raw {
        case "manual": "Manual"
        case "auto": "Automatic"
        case "disabled": "Off"
        default: raw.capitalized
        }
    }

    /// v1 `autoupdate` is a boolean or `"notify"`; v2 `update` is `disable|notify|auto`.
    static func updatesTitle(_ value: OpenCodeJSONValue?) -> String? {
        switch value {
        case .bool(true), .string("auto"): "Automatic"
        case .bool(false), .string("disable"): "Off"
        case .string("notify"): "Notify only"
        case .string(let raw): raw.trimmedNonEmpty?.capitalized
        default: nil
        }
    }

    /// Plugin specs as the TUI's status dialog names them: npm specs split at the
    /// version `@`, and `file://` plugins by file name (or folder, for `index.*`).
    static func plugin(_ value: OpenCodeJSONValue) -> Plugin? {
        let spec: String?
        switch value {
        case .string(let string): spec = string
        case .array(let tuple): spec = tuple.first?.stringValue
        case .object(let object): spec = object["package"]?.stringValue
        default: spec = nil
        }
        guard let spec = spec?.trimmedNonEmpty else { return nil }
        if spec.hasPrefix("file://") {
            let path = URL(string: spec)?.path ?? String(spec.dropFirst("file://".count))
            var parts = path.split(separator: "/").map(String.init)
            let filename = parts.popLast() ?? path
            guard let dot = filename.firstIndex(of: ".") else { return Plugin(name: filename) }
            let basename = String(filename[..<dot])
            if basename == "index" { return Plugin(name: parts.last ?? basename) }
            return Plugin(name: basename)
        }
        guard let at = spec.lastIndex(of: "@"), at > spec.startIndex else { return Plugin(name: spec, version: "latest") }
        return Plugin(name: String(spec[..<at]), version: String(spec[spec.index(after: at)...]).trimmedNonEmpty)
    }

    // MARK: Redaction

    static let redactionMark = "••••••"

    /// Removes credentials before anything reaches the screen or the pasteboard: values
    /// under key-, token-, secret- and password-like names, and every value in `headers`
    /// and `env` maps, which commonly carry `Authorization` headers and API keys.
    static func redacted(_ value: OpenCodeJSONValue, hideAll: Bool = false) -> OpenCodeJSONValue {
        switch value {
        case .object(let object):
            var result: [String: OpenCodeJSONValue] = [:]
            for (key, child) in object {
                if hideAll || isSecretKey(key) {
                    result[key] = hidden(child)
                } else {
                    result[key] = redacted(child, hideAll: isSecretMap(key))
                }
            }
            return .object(result)
        case .array(let array):
            return .array(array.map { redacted($0, hideAll: hideAll) })
        case .string, .number, .bool:
            return hideAll ? hidden(value) : value
        case .null:
            return value
        }
    }

    static func isSecretKey(_ key: String) -> Bool {
        let key = key.lowercased().replacingOccurrences(of: "-", with: "_")
        if ["key", "authorization", "bearer", "credentials", "cookie"].contains(key) { return true }
        return ["apikey", "api_key", "_key", "token", "secret", "password", "passphrase"].contains { key.hasSuffix($0) }
    }

    private static func isSecretMap(_ key: String) -> Bool {
        ["headers", "env", "environment"].contains(key.lowercased())
    }

    private static func hidden(_ value: OpenCodeJSONValue) -> OpenCodeJSONValue {
        switch value {
        case .null, .bool: value
        case .object(let object): object.isEmpty ? value : .object(object.mapValues { hidden($0) })
        case .array(let array): .array(array.map { hidden($0) })
        case .string, .number: .string(redactionMark)
        }
    }

    /// Pretty, key-sorted JSON for the viewer and the pasteboard.
    static func text(_ value: OpenCodeJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return value.compactDescription }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Capabilities

/// Which sections this server can answer. v1 has every route; v2 is read from the
/// OpenAPI schema so the app never guesses an `/api` path the server doesn't publish.
struct OpenCodeServerContextCapabilities: Equatable, Sendable {
    var paths = false
    var branch = false
    var changes = false
    var mcp = false
    var mcpControl = false
    var languageServers = false
    var formatters = false
    var configuration = false

    static let v1 = Self(paths: true, branch: true, changes: true, mcp: true, mcpControl: true,
                         languageServers: true, formatters: true, configuration: true)

    /// Current v2 has no language-server or formatter routes; those sections stay hidden.
    static func v2(_ connection: OpenCodeFeatureContext) -> Self {
        Self(
            paths: connection.supports("/api/location"),
            branch: connection.supports("/api/vcs"),
            changes: connection.supports("/api/vcs/status"),
            mcp: connection.supports("/api/mcp"),
            mcpControl: connection.supports("/api/mcp/{server}/connect", method: "post")
                && connection.supports("/api/mcp/{server}/disconnect", method: "post"),
            configuration: connection.supports("/api/config")
        )
    }

    var any: Bool { paths || branch || changes || mcp || languageServers || formatters || configuration }
}

// MARK: - Service

protocol OpenCodeServerContextServicing: Sendable {
    /// Throws only when the server can't be reached.
    func capabilities() async throws -> OpenCodeServerContextCapabilities
    func paths() async throws -> OpenCodeProjectPaths
    func branch() async throws -> OpenCodeVcsBranch
    func changes() async throws -> [OpenCodeProjectFileChange]
    func mcpServers() async throws -> [OpenCodeMCPServer]
    func setMCPServer(_ name: String, connected: Bool) async throws
    func languageServers() async throws -> [OpenCodeLSPServer]
    func formatters() async throws -> [OpenCodeFormatterStatus]
    func configuration() async throws -> OpenCodeServerConfiguration
}

enum OpenCodeServerContextError: LocalizedError, Equatable {
    /// The route is missing on this server: a 404, or the web app's HTML fallback.
    case unsupported
    case wrongLocation

    var errorDescription: String? {
        switch self {
        case .unsupported: "This OpenCode server doesn’t provide this information."
        case .wrongLocation: "The server answered for a different project. Refresh and try again."
        }
    }
}

/// Contract: OpenCode v1 1.18 (`/path`, `/vcs`, `/vcs/status`, `/mcp`, `/mcp/{name}/connect|disconnect`,
/// `/lsp`, `/formatter`, `/config`) and the v2 beta schema (`/api/location`, `/api/vcs`,
/// `/api/vcs/status`, `/api/mcp`, `/api/mcp/{server}/connect|disconnect`, `/api/config`).
/// v2 answers wrapped in `{location, data}` are checked against the requested location.
struct OpenCodeServerContextService: OpenCodeServerContextServicing {
    let directory: String
    let workspace: String?
    let context: @Sendable () async throws -> OpenCodeFeatureContext

    init(client: OpenCodeClient, route: OpenCodeProjectStatusRoute) {
        self.init(directory: route.directory, workspace: route.workspace,
                  context: { try await client.featureContext() })
    }

    init(directory: String, workspace: String?,
         context: @escaping @Sendable () async throws -> OpenCodeFeatureContext) {
        self.directory = directory
        self.workspace = workspace
        self.context = context
    }

    func capabilities() async throws -> OpenCodeServerContextCapabilities {
        let connection = try await context()
        return connection.serverProtocol == .v2 ? .v2(connection) : .v1
    }

    /// Gates entry points: hidden unless the server is reachable and has something to show.
    func isAvailable() async -> Bool {
        (try? await capabilities())?.any ?? false
    }

    /// The current branch for the session header; `nil` outside a repository or where
    /// the server can't say.
    func currentBranch() async -> String? {
        guard (try? await capabilities())?.branch == true else { return nil }
        return try? await branch().current
    }

    func paths() async throws -> OpenCodeProjectPaths {
        let connection = try await context()
        if connection.serverProtocol == .v2 {
            try require(connection.supports("/api/location"))
            struct Location: Decodable {
                struct Project: Decodable { let id: String; let directory: String }
                let directory: String
                let workspaceID: String?
                let project: Project?
            }
            // `/api/location` resolves the location itself, so it answers unwrapped.
            let location: Location = try await get(connection, ["api", "location"])
            guard location.directory == directory, location.workspaceID == workspace else {
                throw OpenCodeServerContextError.wrongLocation
            }
            return OpenCodeProjectPaths(directory: location.directory, worktree: location.project?.directory,
                                        projectID: location.project?.id, workspaceID: location.workspaceID)
        }
        struct Path: Decodable {
            let home: String?
            let state: String?
            let config: String?
            let worktree: String?
            let directory: String?
        }
        let path: Path = try await get(connection, ["path"])
        return OpenCodeProjectPaths(directory: path.directory?.trimmedNonEmpty ?? directory,
                                    worktree: path.worktree?.trimmedNonEmpty, workspaceID: workspace,
                                    home: path.home?.trimmedNonEmpty, config: path.config?.trimmedNonEmpty,
                                    state: path.state?.trimmedNonEmpty)
    }

    func branch() async throws -> OpenCodeVcsBranch {
        let connection = try await context()
        if connection.serverProtocol == .v2 {
            try require(connection.supports("/api/vcs"))
            struct Info: Decodable {
                struct Branch: Decodable { let current: String?; let `default`: String? }
                let branch: Branch?
            }
            let info: Info = try await located(connection, ["api", "vcs"])
            return OpenCodeVcsBranch(current: info.branch?.current?.trimmedNonEmpty,
                                     defaultBranch: info.branch?.default?.trimmedNonEmpty)
        }
        struct Info: Decodable { let branch: String?; let default_branch: String? }
        let info: Info = try await get(connection, ["vcs"])
        return OpenCodeVcsBranch(current: info.branch?.trimmedNonEmpty, defaultBranch: info.default_branch?.trimmedNonEmpty)
    }

    func changes() async throws -> [OpenCodeProjectFileChange] {
        let connection = try await context()
        if connection.serverProtocol == .v2 {
            try require(connection.supports("/api/vcs/status"))
            return try await located(connection, ["api", "vcs", "status"])
        }
        return try await get(connection, ["vcs", "status"])
    }

    func mcpServers() async throws -> [OpenCodeMCPServer] {
        let connection = try await context()
        if connection.serverProtocol == .v2 {
            try require(connection.supports("/api/mcp"))
            let servers: [OpenCodeJSONValue] = try await located(connection, ["api", "mcp"])
            return OpenCodeMCPServer.sorted(servers.compactMap { value in
                guard let object = value.objectValue, let name = object["name"]?.stringValue else { return nil }
                return OpenCodeMCPServer(name: name, status: object["status"])
            })
        }
        let statuses: [String: OpenCodeJSONValue] = try await get(connection, ["mcp"])
        return OpenCodeMCPServer.sorted(statuses.compactMap { OpenCodeMCPServer(name: $0.key, status: $0.value) })
    }

    /// v1 answers `true`; v2 answers 204. Either way the list is reloaded afterwards,
    /// since a connect that fails still succeeds as a request.
    func setMCPServer(_ name: String, connected: Bool) async throws {
        let connection = try await context()
        let action = connected ? "connect" : "disconnect"
        let v2 = connection.serverProtocol == .v2
        if v2 { try require(connection.supports("/api/mcp/{server}/\(action)", method: "post")) }
        let request = try connection.transport.makeRequest(
            path: (v2 ? ["api", "mcp"] : ["mcp"]) + [name, action], query: locationQuery(v2: v2),
            method: "POST", body: nil)
        let (data, response) = try await connection.transport.data(for: request)
        try connection.transport.validateEmptyResponse(data: data, response: response)
    }

    func languageServers() async throws -> [OpenCodeLSPServer] {
        let connection = try await context()
        // No v2 schema publishes language-server status yet.
        try require(connection.serverProtocol == .v1)
        return try await get(connection, ["lsp"])
    }

    func formatters() async throws -> [OpenCodeFormatterStatus] {
        let connection = try await context()
        try require(connection.serverProtocol == .v1)
        return OpenCodeFormatterStatus.sorted(try await get(connection, ["formatter"]))
    }

    func configuration() async throws -> OpenCodeServerConfiguration {
        let connection = try await context()
        if connection.serverProtocol == .v2 {
            try require(connection.supports("/api/config"))
            return .v2(try await get(connection, ["api", "config"]))
        }
        return .v1(try await get(connection, ["config"]))
    }

    // MARK: Requests

    private func get<Value: Decodable>(_ connection: OpenCodeFeatureContext, _ path: [String]) async throws -> Value {
        let v2 = connection.serverProtocol == .v2
        do {
            return try await connection.transport.get(path, query: locationQuery(v2: v2))
        } catch let error as OpenCodeConnectionError where error.isUnsupportedRoute || error.isUnexpectedContent {
            // Older v1 servers answer 404 or the web app's HTML for routes they lack.
            throw OpenCodeServerContextError.unsupported
        }
    }

    private func located<Value: Decodable>(_ connection: OpenCodeFeatureContext, _ path: [String]) async throws -> Value {
        let response: Located<Value> = try await get(connection, path)
        guard response.location.directory == directory, response.location.workspaceID == workspace else {
            throw OpenCodeServerContextError.wrongLocation
        }
        return response.data
    }

    private func require(_ supported: Bool) throws {
        guard supported else { throw OpenCodeServerContextError.unsupported }
    }

    private func locationQuery(v2: Bool) -> [URLQueryItem] {
        var query = [URLQueryItem(name: v2 ? "location[directory]" : "directory", value: directory)]
        if let workspace { query.append(URLQueryItem(name: v2 ? "location[workspace]" : "workspace", value: workspace)) }
        return query
    }

    private struct Located<Value: Decodable>: Decodable {
        struct Location: Decodable {
            let directory: String
            let workspaceID: String?
        }
        let location: Location
        let data: Value
    }
}
