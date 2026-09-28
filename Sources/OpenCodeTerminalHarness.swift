#if DEBUG
import Foundation
import SwiftUI

/// UI-test and screenshot harness: the terminal screen over an in-memory shell that
/// echoes input, shows control keys in caret notation, and exits on `exit`.
/// With `--app-store-screenshots` it replays a short test run in the App Store
/// fixture's project instead of the key-test banner.
struct OpenCodeTerminalHarness: View {
    var body: some View {
        NavigationStack {
            OpenCodeTerminalScreen(
                service: OpenCodeTerminalFixtureService(),
                route: OpenCodeTerminalFixtureSocket.isAppStore
                    ? OpenCodeTerminalRoute(directory: "/srv/acme-api", projectName: "acme-api")
                    : OpenCodeTerminalRoute(directory: "/Users/dev/byot", projectName: "byot")
            )
        }
    }
}

actor OpenCodeTerminalFixtureService: OpenCodeTerminalServicing {
    private var ptys = OpenCodeTerminalFixtureSocket.isAppStore ? [
        OpenCodePty(id: "pty_fixture_1", title: "Terminal 1", command: "/bin/zsh", cwd: "/srv/acme-api"),
        OpenCodePty(id: "pty_fixture_2", title: "Dev server", command: "/bin/zsh", cwd: "/srv/acme-api"),
    ] : [
        OpenCodePty(id: "pty_fixture_1", title: "Terminal 1", command: "/bin/zsh", cwd: "/Users/dev/byot"),
    ]
    private var counter = OpenCodeTerminalFixtureSocket.isAppStore ? 2 : 1
    private(set) var sizes: [String: OpenCodeTerminalSize] = [:]

    func availability() async throws -> OpenCodeTerminalAvailability { .available }

    func list() async throws -> [OpenCodePty] { ptys }

    func shells() async throws -> [OpenCodeTerminalShell] {
        [
            OpenCodeTerminalShell(path: "/bin/zsh", name: "zsh"),
            OpenCodeTerminalShell(path: "/bin/bash", name: "bash"),
            OpenCodeTerminalShell(path: "/opt/homebrew/bin/bash", name: "bash"),
        ]
    }

    func create(title: String, command: String?) async throws -> OpenCodePty {
        counter += 1
        let pty = OpenCodePty(id: "pty_fixture_\(counter)", title: title, command: command ?? "/bin/zsh", cwd: "/Users/dev/byot")
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

    static let isAppStore = ProcessInfo.processInfo.arguments.contains("--app-store-screenshots")

    private static let prompt = isAppStore
        ? "\u{1b}[32m~/acme-api\u{1b}[0m \u{1b}[36mrate-limit-uploads\u{1b}[0m \u{1b}[1m$\u{1b}[0m "
        : "\u{1b}[32m~/byot\u{1b}[0m \u{1b}[1m$\u{1b}[0m "

    /// The App Store frame: recent commits, then the upload tests passing.
    private static let appStoreReplay = [
        "\u{1b}]0;~/acme-api\u{7}",
        prompt + "git log --oneline -4",
        "\u{1b}[33m7c41e2a\u{1b}[0m (\u{1b}[1;36mHEAD -> rate-limit-uploads\u{1b}[0m) Limit uploads",
        "\u{1b}[33m3d9b0f6\u{1b}[0m Split the upload handler",
        "\u{1b}[33me2a7c19\u{1b}[0m (\u{1b}[1;31morigin/main\u{1b}[0m) Node 22 in CI",
        "\u{1b}[33m91f4d3b\u{1b}[0m Document webhooks",
        prompt + "npm test -- upload",
        "",
        "> acme-api@2.4.0 test",
        "> jest upload",
        "",
        "\u{1b}[1;30;42m PASS \u{1b}[0m tests/\u{1b}[1mupload.test.ts\u{1b}[0m",
        "  \u{1b}[32m✓\u{1b}[0m accepts uploads under the limit",
        "  \u{1b}[32m✓\u{1b}[0m returns 429 after 10 a minute",
        "  \u{1b}[32m✓\u{1b}[0m sets Retry-After",
        "  \u{1b}[32m✓\u{1b}[0m tracks clients separately",
        "",
        "\u{1b}[1mTests:\u{1b}[0m       \u{1b}[1;32m4 passed\u{1b}[0m, 4 total",
        "\u{1b}[1mTime:\u{1b}[0m        0.61 s",
        "",
    ].joined(separator: "\r\n") + prompt

    init(replay: Bool, onExit: @escaping @Sendable () async -> Void) {
        (stream, continuation) = AsyncStream.makeStream()
        self.onExit = onExit
        if replay && Self.isAppStore {
            continuation.yield(.text(Self.appStoreReplay))
        } else if replay {
            // The shell titles its window (OSC 0) like zsh and bash do.
            continuation.yield(.text("\u{1b}]0;dev@byot: ~/byot\u{7}"
                + "Welcome to the \u{1b}[1mbyot\u{1b}[0m terminal fixture.\r\n"
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
