import Foundation

/// Where a terminal screen opens: one project directory (and workspace) on one server.
/// PTYs are scoped to that location on both v1 (`?directory=`) and v2 (`?location[...]`).
struct OpenCodeTerminalRoute: Hashable, Identifiable, Sendable {
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

/// `Pty.Info` from `packages/schema/src/pty.ts`. v1 lists only running sessions;
/// v2 keeps exited ones, with their exit code, until they are removed.
struct OpenCodePty: Decodable, Identifiable, Equatable, Sendable {
    enum Status: String, Sendable {
        case running
        case exited
    }

    let id: String
    var title: String
    var command: String
    var cwd: String
    var status: Status
    var exitCode: Int?

    init(id: String, title: String, command: String = "", cwd: String = "",
         status: Status = .running, exitCode: Int? = nil) {
        self.id = id
        self.title = title
        self.command = command
        self.cwd = cwd
        self.status = status
        self.exitCode = exitCode
    }

    private enum CodingKeys: String, CodingKey { case id, title, command, cwd, status, exitCode }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        command = try container.decodeIfPresent(String.self, forKey: .command) ?? ""
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? ""
        // Older servers omit status; anything they list is running.
        status = (try? container.decodeIfPresent(String.self, forKey: .status)).flatMap(Status.init(rawValue:)) ?? .running
        exitCode = try? container.decodeIfPresent(Int.self, forKey: .exitCode)
    }

    /// The shell's name for tab subtitles, e.g. `zsh` for `/bin/zsh`.
    var shellName: String? {
        command.split(separator: "/").last.map(String.init)?.trimmedNonEmpty
    }
}

struct OpenCodeTerminalSize: Equatable, Sendable {
    let cols: Int
    let rows: Int

    /// The server rejects non-positive sizes; a view that is not laid out yet reports zero.
    var isValid: Bool { cols > 1 && rows > 0 }
}

struct OpenCodeTerminalAvailability: Equatable, Sendable {
    var unavailableReason: String?

    var isAvailable: Bool { unavailableReason == nil }

    static let available = Self(unavailableReason: nil)
    static func unavailable(_ reason: String) -> Self { Self(unavailableReason: reason) }
}

// MARK: - Wire protocol

/// One WebSocket message as received from, or sent to, the server.
enum OpenCodeTerminalMessage: Equatable, Sendable {
    case text(String)
    case data(Data)
}

/// `packages/core/src/pty/protocol.ts`: output arrives as UTF-8 text frames; one binary
/// control frame (0x00 followed by JSON) carries the absolute output cursor after replay.
enum OpenCodeTerminalFrame: Equatable, Sendable {
    case output(String)
    case cursor(Int)
    case ignored
}

enum OpenCodeTerminalWire {
    static func frame(_ message: OpenCodeTerminalMessage) -> OpenCodeTerminalFrame {
        switch message {
        case .text(let text):
            return text.isEmpty ? .ignored : .output(text)
        case .data(let data):
            guard let first = data.first else { return .ignored }
            guard first == 0 else {
                // Current servers only send text output; accept UTF-8 binary output too.
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return .ignored }
                return .output(text)
            }
            struct Meta: Decodable { let cursor: Int? }
            guard let meta = try? JSONDecoder().decode(Meta.self, from: data.dropFirst()),
                  let cursor = meta.cursor, cursor >= 0 else { return .ignored }
            return .cursor(cursor)
        }
    }

    /// The server counts output in JavaScript string length, which is UTF-16 code units.
    static func advance(_ cursor: Int, by text: String) -> Int {
        cursor + text.utf16.count
    }

    /// Terminal input is UTF-8; the server drops frames that are not valid UTF-8.
    static func input(_ bytes: some Sequence<UInt8>) -> String {
        String(decoding: Array(bytes), as: UTF8.self)
    }
}

/// How a dropped connection should be handled. Kept pure so the policy is testable.
enum OpenCodeTerminalDisconnect: Equatable, Sendable {
    /// The server sent a close frame.
    case closed(code: Int)
    /// The WebSocket upgrade was answered with an HTTP status instead of 101.
    case rejected(status: Int)
    /// The network dropped without a close frame.
    case lost(String)

    enum Recovery: Equatable, Sendable {
        /// Reconnect after the backoff delay.
        case reconnect
        /// Ask the server whether the process is still running before reconnecting.
        case checkStatus
        /// Stop and show the message; the user can retry.
        case fail(String)
    }

    var recovery: Recovery {
        switch self {
        // 1000 follows a process exit; 4404 means the session is gone or exited (v2).
        case .closed(let code) where code == 1000 || code == 4404: .checkStatus
        case .closed: .reconnect
        case .rejected(404): .checkStatus
        case .rejected(401):
            .fail("The server rejected the terminal credentials. Check the password for this server.")
        case .rejected(403):
            .fail("The server refused the terminal connection. Check its CORS and authentication settings.")
        case .rejected, .lost: .reconnect
        }
    }
}

/// The web app's schedule: 250 ms doubling to a 4 s ceiling. After `maximumAttempts`
/// consecutive failures the terminal stops and offers a manual retry instead of spinning.
enum OpenCodeTerminalBackoff {
    static let maximumAttempts = 8

    static func delay(afterAttempt attempt: Int) -> Duration {
        let exponent = min(max(attempt - 1, 0), 4)
        return .milliseconds(min(250 * (1 << exponent), 4_000))
    }
}

// MARK: - Accessory keys

/// Keys an iPhone keyboard lacks. Bytes follow xterm, which is what the PTY advertises.
enum OpenCodeTerminalKey: String, CaseIterable, Identifiable, Sendable {
    case escape, tab, control, left, up, down, right, tilde, pipe, slash, dash

    var id: String { rawValue }

    var title: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .control: "ctrl"
        case .left, .up, .down, .right: ""
        case .tilde: "~"
        case .pipe: "|"
        case .slash: "/"
        case .dash: "-"
        }
    }

    var symbol: String? {
        switch self {
        case .left: "arrow.left"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .right: "arrow.right"
        default: nil
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .control: "Control"
        case .left: "Left arrow"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .right: "Right arrow"
        case .tilde: "Tilde"
        case .pipe: "Vertical bar"
        case .slash: "Slash"
        case .dash: "Hyphen"
        }
    }

    /// Arrows repeat while held, like hardware keys.
    var repeats: Bool {
        switch self {
        case .left, .up, .down, .right: true
        default: false
        }
    }

    /// `control` is a latch applied to the next key and has no bytes of its own.
    /// With control latched, arrows send xterm's Ctrl-modified form (word motion in
    /// most shells); `applicationCursor` is DECCKM, set by full-screen programs.
    func bytes(applicationCursor: Bool, control: Bool = false) -> [UInt8] {
        let arrow: UInt8? = switch self {
        case .up: 0x41
        case .down: 0x42
        case .right: 0x43
        case .left: 0x44
        default: nil
        }
        if let arrow {
            if control { return Array("\u{1b}[1;5".utf8) + [arrow] }
            return [0x1b, applicationCursor ? 0x4f : 0x5b, arrow]
        }
        switch self {
        case .escape: return [0x1b]
        case .tab: return [0x09]
        case .control: return []
        default: return Array(title.utf8)
        }
    }
}

// MARK: - Service

/// A connected PTY WebSocket. Implementations must be safe to call from any task.
protocol OpenCodeTerminalSocket: AnyObject, Sendable {
    /// Throws `OpenCodeTerminalSocketError` when the connection ends.
    func receive() async throws -> OpenCodeTerminalMessage
    func send(_ text: String) async throws
    func close()
}

struct OpenCodeTerminalSocketError: Error, Equatable {
    let disconnect: OpenCodeTerminalDisconnect
}

protocol OpenCodeTerminalServicing: Sendable {
    /// Throws only when the server can't be reached; a missing route resolves to unavailable.
    func availability() async throws -> OpenCodeTerminalAvailability
    func list() async throws -> [OpenCodePty]
    func create(title: String) async throws -> OpenCodePty
    /// `nil` when the server no longer knows the PTY.
    func info(_ id: String) async throws -> OpenCodePty?
    func update(_ id: String, title: String?, size: OpenCodeTerminalSize?) async throws
    func remove(_ id: String) async throws
    /// `cursor` resumes after output the client already has; `nil` replays everything retained.
    func connect(_ id: String, cursor: Int?) async throws -> any OpenCodeTerminalSocket
}

enum OpenCodeTerminalError: LocalizedError, Equatable {
    case unsupported
    case wrongLocation

    var errorDescription: String? {
        switch self {
        case .unsupported: "This OpenCode server doesn’t provide terminals."
        case .wrongLocation: "The server opened the terminal in a different project. Close it and try again."
        }
    }
}

/// Contract: OpenCode v1 1.18 (`/pty`, `/pty/{id}`, `/pty/{id}/connect-token`, `/pty/{id}/connect`)
/// and the v2 beta schema (`/api/pty…`, location-scoped and wrapped in `{location, data}`).
/// Both accept Basic auth on the upgrade; a single-use ticket is preferred when offered.
struct OpenCodeTerminalService: OpenCodeTerminalServicing {
    typealias SocketFactory = @Sendable (URLRequest) -> any OpenCodeTerminalSocket

    let directory: String
    let workspace: String?
    let context: @Sendable () async throws -> OpenCodeFeatureContext
    let openSocket: SocketFactory

    init(client: OpenCodeClient, route: OpenCodeTerminalRoute) {
        self.init(directory: route.directory, workspace: route.workspace,
                  context: { try await client.featureContext() })
    }

    init(directory: String, workspace: String?,
         context: @escaping @Sendable () async throws -> OpenCodeFeatureContext,
         openSocket: @escaping SocketFactory = { OpenCodeWebSocket(request: $0) }) {
        self.directory = directory
        self.workspace = workspace
        self.context = context
        self.openSocket = openSocket
    }

    func availability() async throws -> OpenCodeTerminalAvailability {
        // A connection failure is retryable, not a missing feature.
        let connection = try await context()
        if connection.serverProtocol == .v2 {
            let supported = connection.supports("/api/pty") && connection.supports("/api/pty", method: "post")
                && connection.supports("/api/pty/{ptyID}/connect")
            return supported ? .available
                : .unavailable("This OpenCode 2 server doesn’t provide terminals yet.")
        }
        // v1 has no schema; older servers answer 404 or the web app's HTML.
        do {
            let _: [OpenCodeJSONValue] = try await connection.transport.get(["pty"], query: locationQuery(v2: false))
            return .available
        } catch let error as OpenCodeConnectionError where error.isUnsupportedRoute || error.isUnexpectedContent {
            return .unavailable(OpenCodeTerminalError.unsupported.localizedDescription)
        }
    }

    /// Gates entry points: hidden unless the server is reachable and offers PTYs.
    func isAvailable() async -> Bool {
        (try? await availability())?.isAvailable ?? false
    }

    func list() async throws -> [OpenCodePty] {
        let connection = try await context()
        return try await get(connection, [])
    }

    func create(title: String) async throws -> OpenCodePty {
        let connection = try await context()
        struct Body: Encodable { let title: String }
        let v2 = try requireSupport(connection)
        let body = try JSONEncoder().encode(Body(title: title))
        let request = try connection.transport.makeRequest(
            path: path(v2: v2, []), query: locationQuery(v2: v2), method: "POST", body: body)
        return try await decode(connection, request)
    }

    func info(_ id: String) async throws -> OpenCodePty? {
        let connection = try await context()
        do {
            return try await get(connection, [id])
        } catch let error as OpenCodeConnectionError {
            if case .httpStatus(404, _) = error { return nil }
            throw error
        }
    }

    func update(_ id: String, title: String?, size: OpenCodeTerminalSize?) async throws {
        let connection = try await context()
        struct Size: Encodable { let rows: Int; let cols: Int }
        struct Body: Encodable { let title: String?; let size: Size? }
        let v2 = try requireSupport(connection)
        let body = try JSONEncoder().encode(Body(title: title, size: size.map { Size(rows: $0.rows, cols: $0.cols) }))
        let request = try connection.transport.makeRequest(
            path: path(v2: v2, [id]), query: locationQuery(v2: v2), method: "PUT", body: body)
        try await connection.transport.performExpectingEmptyResponse(request)
    }

    func remove(_ id: String) async throws {
        let connection = try await context()
        let v2 = try requireSupport(connection)
        let request = try connection.transport.makeRequest(
            path: path(v2: v2, [id]), query: locationQuery(v2: v2), method: "DELETE", body: nil)
        do {
            try await connection.transport.performExpectingEmptyResponse(request)
        } catch let error as OpenCodeConnectionError {
            // Already gone is what the user asked for.
            if case .httpStatus(404, _) = error { return }
            throw error
        }
    }

    func connect(_ id: String, cursor: Int?) async throws -> any OpenCodeTerminalSocket {
        let connection = try await context()
        let v2 = try requireSupport(connection)
        var query = locationQuery(v2: v2)
        if let cursor { query.append(URLQueryItem(name: "cursor", value: String(cursor))) }
        if let ticket = try await ticket(connection, id: id, v2: v2) {
            query.append(URLQueryItem(name: "ticket", value: ticket))
        }
        var request = try connection.transport.makeRequest(
            path: path(v2: v2, [id, "connect"]), query: query, method: "GET", body: nil)
        request.setValue(nil, forHTTPHeaderField: "Accept")
        request.url = request.url.flatMap(Self.webSocketURL)
        return openSocket(request)
    }

    static func webSocketURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased() == "http" ? "ws" : "wss"
        return components.url
    }

    /// Servers that predate tickets (404/405) or refuse one (403) still accept the
    /// Authorization header on the upgrade itself, so a missing ticket is not fatal.
    private func ticket(_ connection: OpenCodeFeatureContext, id: String, v2: Bool) async throws -> String? {
        if v2 && !connection.supports("/api/pty/{ptyID}/connect-token", method: "post") { return nil }
        struct Ticket: Decodable { let ticket: String }
        var request = try connection.transport.makeRequest(
            path: path(v2: v2, [id, "connect-token"]), query: locationQuery(v2: v2), method: "POST", body: nil)
        request.setValue("1", forHTTPHeaderField: "x-opencode-ticket")
        do {
            let ticket: Ticket = try await decode(connection, request)
            return ticket.ticket.trimmedNonEmpty
        } catch let error as OpenCodeConnectionError {
            switch error {
            case .httpStatus(let status, _) where [403, 404, 405].contains(status): return nil
            case .unexpectedContentType: return nil
            default: throw error
            }
        }
    }

    private func get<Value: Decodable>(_ connection: OpenCodeFeatureContext, _ components: [String]) async throws -> Value {
        let v2 = try requireSupport(connection)
        let request = try connection.transport.makeRequest(
            path: path(v2: v2, components), query: locationQuery(v2: v2), method: "GET", body: nil)
        return try await decode(connection, request)
    }

    private func decode<Value: Decodable>(_ connection: OpenCodeFeatureContext, _ request: URLRequest) async throws -> Value {
        guard connection.serverProtocol == .v2 else { return try await connection.transport.perform(request) }
        let response: Located<Value> = try await connection.transport.perform(request)
        guard response.location.directory == directory, response.location.workspaceID == workspace else {
            throw OpenCodeTerminalError.wrongLocation
        }
        return response.data
    }

    /// Returns whether the v2 surface is in use; never guesses routes a v2 schema omits.
    private func requireSupport(_ connection: OpenCodeFeatureContext) throws -> Bool {
        guard connection.serverProtocol == .v2 else { return false }
        guard connection.supports("/api/pty") else { throw OpenCodeTerminalError.unsupported }
        return true
    }

    private func path(v2: Bool, _ components: [String]) -> [String] {
        (v2 ? ["api", "pty"] : ["pty"]) + components
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

extension OpenCodeConnectionError {
    /// A route answered with the web app's HTML or another non-JSON body.
    var isUnexpectedContent: Bool {
        if case .unexpectedContentType = self { return true }
        return false
    }
}

// MARK: - URLSession WebSocket

/// `URLSessionWebSocketTask` adapter. The close code and the upgrade's HTTP status are
/// read after `receive` fails so the terminal can tell an exited shell from a dropped network.
final class OpenCodeWebSocket: OpenCodeTerminalSocket, @unchecked Sendable {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    private let task: URLSessionWebSocketTask

    init(request: URLRequest) {
        task = Self.session.webSocketTask(with: request)
        // Replay arrives in 64 KiB frames, but live output from a busy process can be larger.
        task.maximumMessageSize = 8 * 1024 * 1024
        task.resume()
    }

    deinit { task.cancel(with: .goingAway, reason: nil) }

    func receive() async throws -> OpenCodeTerminalMessage {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .data(data)
            @unknown default: return .data(Data())
            }
        } catch {
            throw OpenCodeTerminalSocketError(disconnect: disconnect(after: error))
        }
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw OpenCodeTerminalSocketError(disconnect: disconnect(after: error))
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func disconnect(after error: any Error) -> OpenCodeTerminalDisconnect {
        if task.closeCode != .invalid { return .closed(code: task.closeCode.rawValue) }
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            return .rejected(status: http.statusCode)
        }
        return .lost(error.localizedDescription)
    }
}
