import Combine
import Foundation

/// Receives terminal output. The emulator view implements it; tests record into it.
@MainActor
protocol OpenCodeTerminalOutput: AnyObject {
    func write(_ text: String)
}

/// One PTY tab: owns its WebSocket, resumes from the last output cursor after a drop,
/// and forwards keyboard input and viewport size to the server.
@MainActor
final class OpenCodeTerminalSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case reconnecting(attempt: Int)
        case exited(code: Int?)
        case failed(String)

        var isLive: Bool {
            switch self {
            case .exited, .failed: false
            default: true
            }
        }
    }

    @Published private(set) var pty: OpenCodePty
    @Published private(set) var state: State = .idle
    /// The running program's title from OSC 0/2, e.g. `user@host: ~/project`.
    @Published var processTitle: String?

    nonisolated let id: String
    /// Absolute output position already shown; `nil` until the first connection reports it.
    private(set) var cursor: Int?
    private(set) var lastSentSize: OpenCodeTerminalSize?

    private let service: any OpenCodeTerminalServicing
    private weak var output: (any OpenCodeTerminalOutput)?
    private var pendingOutput: [String] = []
    private var pendingOutputLength = 0
    private var pendingInput = ""
    private var desiredSize: OpenCodeTerminalSize?
    private var socket: (any OpenCodeTerminalSocket)?
    private var connection: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var sendChain: Task<Void, Never>?
    private var generation = 0
    private var isSuspended = false
    private let resizeDelay: Duration

    /// Output that arrives before a view attaches is kept up to this many UTF-16 units.
    static let pendingOutputLimit = 512 * 1024
    /// Keystrokes typed while (re)connecting are delivered once the socket opens.
    static let pendingInputLimit = 4 * 1024

    init(pty: OpenCodePty, service: any OpenCodeTerminalServicing, resizeDelay: Duration = .milliseconds(120)) {
        self.pty = pty
        id = pty.id
        self.service = service
        self.resizeDelay = resizeDelay
        if pty.status == .exited { state = .exited(code: pty.exitCode) }
    }

    /// Attaches the emulator and connects on first use, so hidden tabs cost nothing.
    func attach(_ output: any OpenCodeTerminalOutput) {
        self.output = output
        if !pendingOutput.isEmpty {
            let buffered = pendingOutput.joined()
            pendingOutput = []
            pendingOutputLength = 0
            output.write(buffered)
        }
        if state == .idle && !isSuspended { start() }
    }

    func start() {
        guard connection == nil, state.isLive else { return }
        isSuspended = false
        generation &+= 1
        let current = generation
        connection = Task { [weak self] in
            await self?.run(generation: current)
        }
    }

    /// Retry after a failure, or reconnect at once when the app returns to the foreground.
    func reconnectNow() {
        guard state != .connected, !isExited else { return }
        stop()
        if case .failed = state { state = .idle }
        start()
    }

    /// Leaves the screen or the foreground: close the socket and stay closed, even if the
    /// emulator re-attaches, until `resume` or `reconnectNow`.
    func suspend() {
        stop()
        isSuspended = true
    }

    /// Allows a suspended tab to reconnect the next time it is shown.
    func resume() {
        isSuspended = false
    }

    /// Closes the socket; the PTY keeps running on the server.
    func stop() {
        generation &+= 1
        connection?.cancel()
        connection = nil
        resizeTask?.cancel()
        resizeTask = nil
        socket?.close()
        socket = nil
        if state.isLive { state = .idle }
    }

    func send(_ bytes: some Sequence<UInt8>) {
        send(text: OpenCodeTerminalWire.input(bytes))
    }

    func send(text: String) {
        guard !text.isEmpty, state.isLive else { return }
        guard let socket, state == .connected else {
            if pendingInput.utf8.count + text.utf8.count <= Self.pendingInputLimit { pendingInput += text }
            return
        }
        enqueue(text, on: socket)
    }

    func resize(cols: Int, rows: Int) {
        let size = OpenCodeTerminalSize(cols: cols, rows: rows)
        guard size.isValid else { return }
        desiredSize = size
        guard state == .connected else { return }
        scheduleResize()
    }

    func rename(to title: String) {
        pty.title = title
    }

    func markExited(code: Int?) {
        stop()
        pty.status = .exited
        pty.exitCode = code
        state = .exited(code: code)
        pendingInput = ""
    }

    var isExited: Bool {
        if case .exited = state { return true }
        return false
    }

    // MARK: Connection loop

    private func run(generation current: Int) async {
        var attempt = 0
        while !Task.isCancelled, current == generation {
            state = attempt == 0 && cursor == nil ? .connecting : .reconnecting(attempt: max(attempt, 1))
            let disconnect: OpenCodeTerminalDisconnect
            do {
                let socket = try await service.connect(id, cursor: cursor)
                guard !Task.isCancelled, current == generation else { socket.close(); return }
                self.socket = socket
                disconnect = await pump(socket, generation: current) { attempt = 0 }
                if self.socket === socket { self.socket = nil }
                socket.close()
            } catch is CancellationError {
                return
            } catch let error as OpenCodeTerminalSocketError {
                disconnect = error.disconnect
            } catch let error as OpenCodeConnectionError {
                if case .httpStatus(let status, _) = error { disconnect = .rejected(status: status) }
                else { disconnect = .lost(error.localizedDescription) }
            } catch {
                disconnect = .lost(error.localizedDescription)
            }
            guard !Task.isCancelled, current == generation else { return }

            switch disconnect.recovery {
            case .fail(let message):
                finish(.failed(message))
                return
            case .checkStatus:
                // The process may have exited, or a server restart forgot it.
                // An unreachable server falls through to an ordinary reconnect.
                do {
                    let info = try await service.info(id)
                    guard current == generation else { return }
                    if info == nil || info?.status == .exited {
                        finishExited(code: info?.exitCode)
                        return
                    }
                } catch {}
            case .reconnect:
                break
            }
            guard !Task.isCancelled, current == generation else { return }
            attempt += 1
            if attempt > OpenCodeTerminalBackoff.maximumAttempts {
                finish(.failed(String(localized: "Lost the connection to the terminal.")))
                return
            }
            state = .reconnecting(attempt: attempt)
            do { try await Task.sleep(for: OpenCodeTerminalBackoff.delay(afterAttempt: attempt)) }
            catch { return }
        }
    }

    /// Reads until the socket ends. The first frame proves the upgrade succeeded.
    private func pump(_ socket: any OpenCodeTerminalSocket, generation current: Int,
                      onOpen: () -> Void) async -> OpenCodeTerminalDisconnect {
        var opened = false
        while !Task.isCancelled, current == generation {
            let message: OpenCodeTerminalMessage
            do {
                message = try await socket.receive()
            } catch let error as OpenCodeTerminalSocketError {
                return error.disconnect
            } catch {
                return .lost(error.localizedDescription)
            }
            guard current == generation else { break }
            if !opened {
                opened = true
                onOpen()
                didOpen(socket)
            }
            switch OpenCodeTerminalWire.frame(message) {
            case .output(let text):
                cursor = OpenCodeTerminalWire.advance(cursor ?? 0, by: text)
                deliver(text)
            case .cursor(let value):
                cursor = value
            case .ignored:
                break
            }
        }
        return .closed(code: 1001)
    }

    private func didOpen(_ socket: any OpenCodeTerminalSocket) {
        state = .connected
        if !pendingInput.isEmpty {
            enqueue(pendingInput, on: socket)
            pendingInput = ""
        }
        // Another client may have resized the PTY while this one was away.
        lastSentSize = nil
        scheduleResize(immediately: true)
    }

    private func deliver(_ text: String) {
        if let output {
            output.write(text)
            return
        }
        pendingOutput.append(text)
        pendingOutputLength += text.utf16.count
        while pendingOutputLength > Self.pendingOutputLimit, pendingOutput.count > 1 {
            pendingOutputLength -= pendingOutput.removeFirst().utf16.count
        }
    }

    /// Frames go out strictly in keystroke order.
    private func enqueue(_ text: String, on socket: any OpenCodeTerminalSocket) {
        let previous = sendChain
        sendChain = Task {
            await previous?.value
            try? await socket.send(text)
        }
    }

    private func scheduleResize(immediately: Bool = false) {
        guard let desiredSize, desiredSize != lastSentSize else { return }
        resizeTask?.cancel()
        let delay = immediately ? Duration.zero : resizeDelay
        resizeTask = Task { [weak self, service, id] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let self, !Task.isCancelled, self.state == .connected else { return }
            // Rotation and the keyboard settle through several sizes; send only the last.
            guard let size = self.desiredSize, size != self.lastSentSize else { return }
            self.lastSentSize = size
            do {
                try await service.update(id, title: nil, size: size)
            } catch {
                if self.lastSentSize == size { self.lastSentSize = nil }
            }
        }
    }

    private func finish(_ state: State) {
        connection = nil
        socket?.close()
        socket = nil
        self.state = state
        if case .failed = state { pendingInput = "" }
    }

    private func finishExited(code: Int?) {
        finish(.exited(code: code))
        pty.status = .exited
        pty.exitCode = code
        pendingInput = ""
    }
}

/// The terminal screen for one project: lists the server's PTYs there, opens new ones,
/// and keeps each tab's connection alive while the screen is visible.
@MainActor
final class OpenCodeTerminalStore: ObservableObject {
    enum Phase: Equatable {
        case loading
        case ready
        case unavailable(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var terminals: [OpenCodeTerminalSession] = []
    @Published var selectedID: String?
    @Published private(set) var isCreating = false
    @Published var actionError: String?
    /// Shells a new terminal can start; empty keeps the server's default only.
    @Published private(set) var shells: [OpenCodeTerminalShell] = []

    let service: any OpenCodeTerminalServicing
    private var didOfferFirstTerminal = false
    private var isVisible = false

    init(service: any OpenCodeTerminalServicing) {
        self.service = service
    }

    var selected: OpenCodeTerminalSession? {
        terminals.first { $0.id == selectedID } ?? terminals.first
    }

    /// Negotiates support, then adopts the server's PTYs. Existing tabs keep their
    /// connections; a first visit with no terminals opens one so the screen is useful at once.
    func load() async {
        if terminals.isEmpty { phase = .loading }
        do {
            let availability = try await service.availability()
            guard availability.isAvailable else {
                phase = .unavailable(availability.unavailableReason ?? OpenCodeTerminalError.unsupported.localizedDescription)
                return
            }
            // The shell list is optional; a server without it still opens its default shell.
            async let shells = try? service.shells()
            // A tab opened while the list was in flight is not in it, and has not ended.
            let known = Set(terminals.map(\.id))
            let listed = try await service.list()
            merge(listed, known: known)
            self.shells = await shells ?? self.shells
            phase = .ready
            if terminals.isEmpty && !didOfferFirstTerminal {
                didOfferFirstTerminal = true
                await newTerminal()
            }
            didOfferFirstTerminal = true
        } catch is CancellationError {
        } catch {
            if terminals.isEmpty { phase = .failed(error.localizedDescription) }
            else { actionError = error.localizedDescription }
        }
    }

    /// Opens a tab running `shell`, or the server's default shell when `nil`.
    func newTerminal(shell: OpenCodeTerminalShell? = nil) async {
        guard !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let pty = try await service.create(title: Self.nextTitle(after: terminals.map(\.pty.title)),
                                               command: shell?.path)
            let session = OpenCodeTerminalSession(pty: pty, service: service)
            terminals.append(session)
            selectedID = session.id
            phase = .ready
        } catch is CancellationError {
        } catch {
            actionError = String(localized: "Couldn’t open a terminal: \(error.localizedDescription)")
        }
    }

    /// Closing a tab ends its process on the server, like closing a web terminal.
    func close(_ session: OpenCodeTerminalSession) async {
        guard let index = terminals.firstIndex(where: { $0.id == session.id }) else { return }
        session.stop()
        terminals.remove(at: index)
        if selectedID == session.id {
            selectedID = terminals.indices.contains(index) ? terminals[index].id : terminals.last?.id
        }
        do {
            try await service.remove(session.id)
        } catch {
            actionError = String(localized: "Couldn’t close “\(session.pty.title)”: \(error.localizedDescription)")
            terminals.insert(session, at: min(index, terminals.count))
            if isVisible { session.start() }
        }
    }

    func rename(_ session: OpenCodeTerminalSession, to title: String) async {
        guard let title = title.trimmedNonEmpty, title != session.pty.title else { return }
        let previous = session.pty.title
        session.rename(to: title)
        do {
            try await service.update(session.id, title: title, size: nil)
        } catch {
            session.rename(to: previous)
            actionError = String(localized: "Couldn’t rename the terminal: \(error.localizedDescription)")
        }
    }

    func select(_ session: OpenCodeTerminalSession) {
        selectedID = session.id
    }

    /// The screen appeared or the app returned to the foreground: reconnect the visible tab
    /// now; the others catch up from their cursors when they are shown.
    func resume() {
        isVisible = true
        terminals.forEach { $0.resume() }
        selected?.reconnectNow()
    }

    /// The screen went away: drop sockets but leave the processes running.
    func suspend() {
        isVisible = false
        terminals.forEach { $0.suspend() }
    }

    private func merge(_ listed: [OpenCodePty], known: Set<String>) {
        var merged: [OpenCodeTerminalSession] = []
        for pty in listed {
            if let existing = terminals.first(where: { $0.id == pty.id }) {
                existing.rename(to: pty.title)
                if pty.status == .exited && !existing.isExited { existing.markExited(code: pty.exitCode) }
                merged.append(existing)
            } else {
                merged.append(OpenCodeTerminalSession(pty: pty, service: service))
            }
        }
        // v1 hides exited sessions; keep an ended tab visible until the user closes it.
        for session in terminals where !listed.contains(where: { $0.id == session.id }) {
            if known.contains(session.id) && !session.isExited { session.markExited(code: nil) }
            merged.append(session)
        }
        terminals = merged
        if selectedID == nil || !terminals.contains(where: { $0.id == selectedID }) {
            selectedID = (terminals.first { !$0.isExited } ?? terminals.first)?.id
        }
    }

    /// "Terminal N" with the lowest free N, matching the web app's numbering.
    nonisolated static func nextTitle(after titles: [String]) -> String {
        let used = Set(titles.compactMap { title -> Int? in
            let parts = title.split(separator: " ")
            guard parts.count == 2, parts[0] == "Terminal" else { return nil }
            return Int(parts[1])
        })
        let number = (1...).first { !used.contains($0) } ?? 1
        return "Terminal \(number)"
    }
}
