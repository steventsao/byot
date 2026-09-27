#if DEBUG
import Foundation
import SwiftUI

/// UI-test and screenshot harness: the terminal screen over an in-memory shell that
/// echoes input, shows control keys in caret notation, and exits on `exit`.
struct OpenCodeTerminalHarness: View {
    var body: some View {
        NavigationStack {
            OpenCodeTerminalScreen(
                service: OpenCodeTerminalFixtureService(),
                route: OpenCodeTerminalRoute(directory: "/Users/dev/byot", projectName: "byot")
            )
        }
    }
}

actor OpenCodeTerminalFixtureService: OpenCodeTerminalServicing {
    private var ptys = [
        OpenCodePty(id: "pty_fixture_1", title: "Terminal 1", command: "/bin/zsh", cwd: "/Users/dev/byot"),
    ]
    private var counter = 1
    private(set) var sizes: [String: OpenCodeTerminalSize] = [:]

    func availability() async throws -> OpenCodeTerminalAvailability { .available }

    func list() async throws -> [OpenCodePty] { ptys }

    func create(title: String) async throws -> OpenCodePty {
        counter += 1
        let pty = OpenCodePty(id: "pty_fixture_\(counter)", title: title, command: "/bin/zsh", cwd: "/Users/dev/byot")
        ptys.append(pty)
        return pty
    }

    func info(_ id: String) async throws -> OpenCodePty? {
        ptys.first { $0.id == id }
    }

    func update(_ id: String, title: String?, size: OpenCodeTerminalSize?) async throws {
        guard let index = ptys.firstIndex(where: { $0.id == id }) else { return }
        if let title { ptys[index].title = title }
        if let size { sizes[id] = size }
    }

    func remove(_ id: String) async throws {
        ptys.removeAll { $0.id == id }
    }

    func connect(_ id: String, cursor: Int?) async throws -> any OpenCodeTerminalSocket {
        let exit: @Sendable () async -> Void = { [weak self] in await self?.markExited(id) }
        return OpenCodeTerminalFixtureSocket(replay: cursor == nil, onExit: exit)
    }

    private func markExited(_ id: String) {
        guard let index = ptys.firstIndex(where: { $0.id == id }) else { return }
        ptys[index].status = .exited
        ptys[index].exitCode = 0
    }
}

final class OpenCodeTerminalFixtureSocket: OpenCodeTerminalSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<OpenCodeTerminalMessage>
    private let continuation: AsyncStream<OpenCodeTerminalMessage>.Continuation
    private var line = ""
    private let onExit: @Sendable () async -> Void

    private static let prompt = "\u{1b}[32m~/byot\u{1b}[0m \u{1b}[1m$\u{1b}[0m "

    init(replay: Bool, onExit: @escaping @Sendable () async -> Void) {
        (stream, continuation) = AsyncStream.makeStream()
        self.onExit = onExit
        if replay {
            continuation.yield(.text("Welcome to the \u{1b}[1mbyot\u{1b}[0m terminal fixture.\r\n"
                + "\u{1b}[31mred\u{1b}[0m \u{1b}[32mgreen\u{1b}[0m \u{1b}[33myellow\u{1b}[0m \u{1b}[34mblue\u{1b}[0m "
                + "\u{1b}[35mmagenta\u{1b}[0m \u{1b}[36mcyan\u{1b}[0m \u{1b}[37mwhite\u{1b}[0m\r\n" + Self.prompt))
        }
        var meta = Data([0])
        meta.append(Data(#"{"cursor":0}"#.utf8))
        continuation.yield(.data(meta))
    }

    func receive() async throws -> OpenCodeTerminalMessage {
        // One reader at a time; each call takes the next buffered message.
        for await message in stream { return message }
        throw OpenCodeTerminalSocketError(disconnect: .closed(code: 1000))
    }

    func send(_ text: String) async throws {
        var echo = ""
        var command: String?
        lock.withLock {
            for scalar in text.unicodeScalars {
                switch scalar.value {
                case 0x0D:
                    command = line
                    line = ""
                case 0x7F:
                    if !line.isEmpty { line.removeLast(); echo += "\u{8} \u{8}" }
                case 0x00..<0x20:
                    // Caret notation keeps control keys visible: esc is ^[, tab is ^I.
                    let caret = "^" + String(UnicodeScalar(UInt8(scalar.value) + 0x40))
                    line += caret
                    echo += caret
                default:
                    line.unicodeScalars.append(scalar)
                    echo.unicodeScalars.append(scalar)
                }
            }
        }
        if !echo.isEmpty { continuation.yield(.text(echo)) }
        guard let command else { return }
        if command == "exit" {
            continuation.yield(.text("\r\nlogout\r\n"))
            await onExit()
            continuation.finish()
            return
        }
        let output = command.isEmpty ? "" : "\r\nran: \(command)"
        continuation.yield(.text(output + "\r\n" + Self.prompt))
    }

    func close() {
        continuation.finish()
    }
}
#endif
