import Foundation
import Testing
@testable import byot

@Suite("Terminal wire protocol and keys")
struct OpenCodeTerminalWireTests {
    @Test("Text frames are output; a 0x00 binary frame carries the resume cursor")
    func frames() {
        #expect(OpenCodeTerminalWire.frame(.text("ls\r\n")) == .output("ls\r\n"))
        #expect(OpenCodeTerminalWire.frame(.text("")) == .ignored)
        var meta = Data([0])
        meta.append(Data(#"{"cursor":1024}"#.utf8))
        #expect(OpenCodeTerminalWire.frame(.data(meta)) == .cursor(1024))
        var negative = Data([0])
        negative.append(Data(#"{"cursor":-1}"#.utf8))
        #expect(OpenCodeTerminalWire.frame(.data(negative)) == .ignored)
        #expect(OpenCodeTerminalWire.frame(.data(Data([0, 0x7B]))) == .ignored)
        #expect(OpenCodeTerminalWire.frame(.data(Data("hi".utf8))) == .output("hi"))
        #expect(OpenCodeTerminalWire.frame(.data(Data())) == .ignored)
    }

    @Test("The cursor advances in UTF-16 units, like the server's JavaScript string length")
    func cursorUnits() {
        #expect(OpenCodeTerminalWire.advance(10, by: "abc") == 13)
        // One emoji is two UTF-16 units but four UTF-8 bytes and one Character.
        #expect(OpenCodeTerminalWire.advance(0, by: "👋") == 2)
        #expect(OpenCodeTerminalWire.advance(0, by: "é\r\n") == 3)
        #expect(OpenCodeTerminalWire.input([0x1b, 0x5b, 0x41]) == "\u{1b}[A")
        #expect(OpenCodeTerminalWire.input(Array("héllo".utf8)) == "héllo")
    }

    @Test("Exits are confirmed with the server, auth failures stop, drops reconnect")
    func recovery() {
        #expect(OpenCodeTerminalDisconnect.closed(code: 1000).recovery == .checkStatus)
        #expect(OpenCodeTerminalDisconnect.closed(code: 4404).recovery == .checkStatus)
        #expect(OpenCodeTerminalDisconnect.closed(code: 1001).recovery == .reconnect)
        #expect(OpenCodeTerminalDisconnect.rejected(status: 404).recovery == .checkStatus)
        #expect(OpenCodeTerminalDisconnect.rejected(status: 502).recovery == .reconnect)
        #expect(OpenCodeTerminalDisconnect.lost("offline").recovery == .reconnect)
        if case .fail = OpenCodeTerminalDisconnect.rejected(status: 401).recovery {} else {
            Issue.record("A rejected password must not retry forever")
        }
        if case .fail = OpenCodeTerminalDisconnect.rejected(status: 403).recovery {} else {
            Issue.record("A refused origin must not retry forever")
        }
    }

    @Test("Backoff doubles from 250 ms to a 4 s ceiling")
    func backoff() {
        let delays = (1...7).map { OpenCodeTerminalBackoff.delay(afterAttempt: $0) }
        #expect(delays == [.milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2),
                           .seconds(4), .seconds(4), .seconds(4)])
        #expect(OpenCodeTerminalBackoff.maximumAttempts > 4)
    }

    @Test("Accessory keys send xterm sequences, honoring cursor mode and the control latch")
    func keys() {
        #expect(OpenCodeTerminalKey.escape.bytes(applicationCursor: false) == [0x1b])
        #expect(OpenCodeTerminalKey.tab.bytes(applicationCursor: false) == [0x09])
        #expect(OpenCodeTerminalKey.up.bytes(applicationCursor: false) == Array("\u{1b}[A".utf8))
        #expect(OpenCodeTerminalKey.left.bytes(applicationCursor: true) == Array("\u{1b}OD".utf8))
        #expect(OpenCodeTerminalKey.right.bytes(applicationCursor: true, control: true) == Array("\u{1b}[1;5C".utf8))
        #expect(OpenCodeTerminalKey.down.bytes(applicationCursor: false) == Array("\u{1b}[B".utf8))
        #expect(OpenCodeTerminalKey.pipe.bytes(applicationCursor: false) == Array("|".utf8))
        #expect(OpenCodeTerminalKey.control.bytes(applicationCursor: false).isEmpty)
        #expect(OpenCodeTerminalKey.allCases.allSatisfy { !$0.accessibilityLabel.isEmpty })
        #expect(OpenCodeTerminalKey.allCases.filter(\.repeats) == [.left, .up, .down, .right])
    }

    @Test("PTY info decodes v1 and v2 shapes, including exit codes")
    func ptyDecoding() throws {
        let v1 = try JSONDecoder().decode(OpenCodePty.self, from: Data("""
            {"id":"pty_a","title":"Terminal 1","command":"/bin/zsh","args":["-l"],"cwd":"/repo","status":"running","pid":52846}
            """.utf8))
        #expect(v1 == OpenCodePty(id: "pty_a", title: "Terminal 1", command: "/bin/zsh", cwd: "/repo"))
        #expect(v1.shellName == "zsh")
        let exited = try JSONDecoder().decode(OpenCodePty.self, from: Data("""
            {"id":"pty_b","title":"build","command":"/bin/bash","args":[],"cwd":"/repo","status":"exited","pid":1,"exitCode":2}
            """.utf8))
        #expect(exited.status == .exited && exited.exitCode == 2)
        let legacy = try JSONDecoder().decode(OpenCodePty.self, from: Data(#"{"id":"pty_c"}"#.utf8))
        #expect(legacy.status == .running && legacy.title.isEmpty && legacy.shellName == nil)
    }

    @Test("Shell choices use the short name unless two shells share it")
    func shellChoices() throws {
        let shells = [
            OpenCodeTerminalShell(path: "/bin/zsh", name: "zsh"),
            OpenCodeTerminalShell(path: "/bin/bash", name: "bash"),
            OpenCodeTerminalShell(path: "/opt/homebrew/bin/bash", name: "bash"),
            OpenCodeTerminalShell(path: "/bin/zsh", name: "zsh"),
        ]
        #expect(OpenCodeTerminalShell.choices(shells).map(\.label) == ["zsh", "/bin/bash", "/opt/homebrew/bin/bash"])
        #expect(OpenCodeTerminalShell.choices([]).isEmpty)
        let unnamed = try JSONDecoder().decode(OpenCodeTerminalShell.self, from: Data(#"{"path":"/usr/local/bin/fish"}"#.utf8))
        #expect(unnamed == OpenCodeTerminalShell(path: "/usr/local/bin/fish", name: "fish", acceptable: true))
    }

    @Test("New tabs take the lowest free Terminal number")
    func numbering() {
        #expect(OpenCodeTerminalStore.nextTitle(after: []) == "Terminal 1")
        #expect(OpenCodeTerminalStore.nextTitle(after: ["Terminal 1", "Terminal 3", "build"]) == "Terminal 2")
        #expect(OpenCodeTerminalStore.nextTitle(after: ["Terminal 2"]) == "Terminal 1")
    }

    @Test("Text size follows Dynamic Type within readable bounds")
    func fontSize() {
        let base = OpenCodeTerminalAppearance.fontSize(for: .large, adjustment: 0)
        #expect(base == OpenCodeTerminalAppearance.defaultFontSize)
        let huge = OpenCodeTerminalAppearance.fontSize(for: .accessibility5, adjustment: 0)
        #expect(huge > base && huge <= 20)
        #expect(OpenCodeTerminalAppearance.fontSize(for: .accessibility5, adjustment: 40) == 28)
        #expect(OpenCodeTerminalAppearance.fontSize(for: .xSmall, adjustment: -40) == 8)
    }
}

@Suite("Terminal service")
struct OpenCodeTerminalServiceTests {
    private let profile = OpenCodeServerProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000082")!, name: "Terminal",
        baseURL: "https://term.example.test/opencode")
    private static let pty = #"{"id":"pty_1","title":"Terminal 1","command":"/bin/zsh","args":["-l"],"cwd":"/repo/app","status":"running","pid":7}"#
    private static let exited = #"{"id":"pty_2","title":"build","command":"/bin/zsh","args":[],"cwd":"/repo/app","status":"exited","pid":8,"exitCode":3}"#

    @Test("v1 uses /pty with the directory, a ticket for the upgrade, and Basic auth on the socket")
    func v1Routes() async throws {
        let transport = TerminalTestTransport(profile: profile) { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/opencode/pty"): .raw("[\(Self.pty)]")
            case ("POST", "/opencode/pty"): .raw(Self.pty)
            case ("PUT", "/opencode/pty/pty_1"): .raw(Self.pty)
            case ("DELETE", "/opencode/pty/pty_1"): .raw("true")
            case ("POST", "/opencode/pty/pty_1/connect-token"): .json(["ticket": "tkt", "expires_in": 60])
            default: .init(data: Data(), mime: "application/json", status: 404)
            }
        }
        let sockets = SocketRecorder()
        let service = makeService(transport, protocol: .v1, sockets: sockets)
        #expect(try await service.availability() == .available)
        #expect(try await service.list().map(\.id) == ["pty_1"])
        #expect(try await service.create(title: "Terminal 2", command: nil).id == "pty_1")
        try await service.update("pty_1", title: nil, size: OpenCodeTerminalSize(cols: 80, rows: 24))
        try await service.remove("pty_1")
        _ = try await service.connect("pty_1", cursor: 42)

        let requests = transport.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "GET /opencode/pty", "GET /opencode/pty", "POST /opencode/pty", "PUT /opencode/pty/pty_1",
            "DELETE /opencode/pty/pty_1", "POST /opencode/pty/pty_1/connect-token",
        ])
        for request in requests {
            #expect(query(request, "directory") == "/repo/app")
            #expect(query(request, "workspace") == "wrk_term")
        }
        #expect(try body(requests[2])["title"] as? String == "Terminal 2")
        // The default shell is the server's choice, so no command is sent.
        #expect(try body(requests[2])["command"] == nil)
        let size = try body(requests[3])["size"] as? [String: Int]
        #expect(size == ["cols": 80, "rows": 24])
        #expect(requests[5].value(forHTTPHeaderField: "x-opencode-ticket") == "1")

        let socket = try #require(sockets.requests.first)
        #expect(socket.url?.scheme == "wss")
        #expect(socket.url?.path == "/opencode/pty/pty_1/connect")
        #expect(query(socket, "cursor") == "42")
        #expect(query(socket, "ticket") == "tkt")
        #expect(query(socket, "directory") == "/repo/app")
        #expect(socket.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true)
    }

    @Test("Servers without tickets still connect with Basic auth; the first connect replays everything")
    func v1WithoutTickets() async throws {
        let transport = TerminalTestTransport(profile: profile) { _ in .init(data: Data(), mime: "application/json", status: 404) }
        let sockets = SocketRecorder()
        _ = try await makeService(transport, protocol: .v1, sockets: sockets).connect("pty_1", cursor: nil)
        let socket = try #require(sockets.requests.first)
        #expect(query(socket, "ticket") == nil)
        #expect(query(socket, "cursor") == nil)
        #expect(socket.value(forHTTPHeaderField: "Authorization") != nil)
    }

    @Test("Older v1 servers without /pty hide the terminal; a gone PTY reads as nil")
    func v1Unavailable() async throws {
        let html = TerminalTestTransport(profile: profile) { _ in .init(data: Data("<!doctype html>".utf8), mime: "text/html") }
        #expect(try await makeService(html, protocol: .v1).availability().isAvailable == false)
        let missing = TerminalTestTransport(profile: profile) { _ in .init(data: Data(), mime: "application/json", status: 404) }
        let service = makeService(missing, protocol: .v1)
        #expect(try await service.availability().isAvailable == false)
        #expect(try await service.info("pty_gone") == nil)
        // Closing a PTY the server already forgot succeeds.
        try await service.remove("pty_gone")
    }

    @Test("An unreachable server is a retryable failure, not a missing feature")
    func unreachable() async {
        let service = OpenCodeTerminalService(directory: "/repo/app", workspace: nil) {
            throw OpenCodeConnectionError.httpStatus(502, nil)
        }
        await #expect(throws: OpenCodeConnectionError.self) { try await service.availability() }
        #expect(await service.isAvailable() == false)
    }

    @Test("v1 lists shells and starts the chosen one; servers without the list keep the default")
    func shells() async throws {
        let transport = TerminalTestTransport(profile: profile) { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/opencode/pty/shells"):
                .raw(#"[{"path":"/bin/zsh","name":"zsh","acceptable":true},{"path":"/usr/bin/nu","name":"nu","acceptable":false}]"#)
            default: .raw(Self.pty)
            }
        }
        let service = makeService(transport, protocol: .v1)
        let shells = try await service.shells()
        #expect(shells.map(\.path) == ["/bin/zsh", "/usr/bin/nu"])
        #expect(shells.map(\.acceptable) == [true, false])
        _ = try await service.create(title: "Terminal 2", command: "/usr/bin/nu")
        let requests = transport.requests
        #expect(query(requests[0], "directory") == "/repo/app")
        #expect(try body(requests[1])["command"] as? String == "/usr/bin/nu")

        let missing = TerminalTestTransport(profile: profile) { _ in .init(data: Data(), mime: "application/json", status: 404) }
        #expect(try await makeService(missing, protocol: .v1).shells().isEmpty)
        let html = TerminalTestTransport(profile: profile) { _ in .init(data: Data("<!doctype html>".utf8), mime: "text/html") }
        #expect(try await makeService(html, protocol: .v1).shells().isEmpty)
        // The v2 schema has no shell list; nothing is requested.
        let v2 = TerminalTestTransport(profile: profile) { _ in .json([]) }
        #expect(try await makeService(v2, protocol: .v2, schema: try schema()).shells().isEmpty)
        #expect(v2.requests.isEmpty)
    }

    @Test("v2 uses the location-scoped /api/pty routes from the pinned beta schema")
    func v2Routes() async throws {
        let transport = TerminalTestTransport(profile: profile) { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/opencode/api/pty"): Self.envelope("[\(Self.pty),\(Self.exited)]")
            case ("POST", "/opencode/api/pty/pty_1/connect-token"): Self.envelope(#"{"ticket":"v2tkt","expires_in":60}"#)
            case ("DELETE", _): .init(data: Data(), mime: "application/json", status: 204)
            default: Self.envelope(Self.pty)
            }
        }
        let sockets = SocketRecorder()
        let service = makeService(transport, protocol: .v2, schema: try schema(), sockets: sockets)
        #expect(try await service.availability() == .available)
        let listed = try await service.list()
        #expect(listed.map(\.status) == [.running, .exited])
        #expect(listed.last?.exitCode == 3)
        try await service.remove("pty_1")
        _ = try await service.connect("pty_1", cursor: 7)

        let requests = transport.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "GET /opencode/api/pty", "DELETE /opencode/api/pty/pty_1", "POST /opencode/api/pty/pty_1/connect-token",
        ])
        #expect(query(requests[0], "location[directory]") == "/repo/app")
        #expect(query(requests[0], "location[workspace]") == "wrk_term")
        let socket = try #require(sockets.requests.first)
        #expect(socket.url?.path == "/opencode/api/pty/pty_1/connect")
        #expect(query(socket, "ticket") == "v2tkt")
        #expect(query(socket, "location[directory]") == "/repo/app")
    }

    @Test("v2 rejects another project's PTYs and never guesses routes the schema omits")
    func v2Guards() async throws {
        let wrong = TerminalTestTransport(profile: profile) { _ in
            .json(["location": ["directory": "/elsewhere", "project": ["id": "pro"]], "data": []])
        }
        await #expect(throws: OpenCodeTerminalError.wrongLocation) {
            try await makeService(wrong, protocol: .v2, schema: try schema()).list()
        }
        let bare = TerminalTestTransport(profile: profile) { _ in .json([]) }
        let service = makeService(bare, protocol: .v2, schema: .object(["paths": .object([:])]))
        let availability = try await service.availability()
        #expect(!availability.isAvailable && availability.unavailableReason != nil)
        await #expect(throws: OpenCodeTerminalError.unsupported) { try await service.list() }
        #expect(bare.requests.isEmpty)
    }

    private func makeService(_ transport: TerminalTestTransport, protocol value: OpenCodeServerProtocol,
                             schema: OpenCodeJSONValue? = nil, sockets: SocketRecorder = SocketRecorder()) -> OpenCodeTerminalService {
        let context = OpenCodeFeatureContext(serverProtocol: value, schema: schema, transport: transport, profile: profile)
        return OpenCodeTerminalService(directory: "/repo/app", workspace: "wrk_term", context: { context },
                                       openSocket: { sockets.open($0) })
    }

    private static func envelope(_ data: String) -> TerminalTestTransport.Response {
        .raw(#"{"location":{"directory":"/repo/app","workspaceID":"wrk_term","project":{"id":"pro"}},"data":"# + data + "}")
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    private func schema() throws -> OpenCodeJSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/opencode2-beta-19242-openapi.json")
        return try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(contentsOf: url))
    }
}

@MainActor
@Suite("Terminal session")
struct OpenCodeTerminalSessionTests {
    private let info = OpenCodePty(id: "pty_1", title: "Terminal 1", command: "/bin/zsh")

    @Test("Replay and live output reach the emulator; the meta frame sets the resume cursor")
    func connectsAndStreams() async throws {
        let service = FakeTerminalService(info: info)
        let session = OpenCodeTerminalSession(pty: info, service: service, resizeDelay: .milliseconds(10))
        let output = RecordingOutput()
        session.resize(cols: 80, rows: 24)
        session.attach(output)
        let socket = try await service.nextSocket()
        socket.deliver(.text("replayed"))
        socket.deliver(.data(Data([0]) + Data(#"{"cursor":500}"#.utf8)))
        socket.deliver(.text("live 👋"))
        try await until { output.text == "replayedlive 👋" }
        #expect(session.state == .connected)
        #expect(session.cursor == 507)
        #expect(await service.connectCursors == [nil])
        // The viewport is sent once the socket opens.
        try await until { await service.sizes == [OpenCodeTerminalSize(cols: 80, rows: 24)] }
    }

    @Test("Keystrokes typed while connecting are sent in order once the socket opens")
    func pendingInput() async throws {
        let service = FakeTerminalService(info: info)
        let session = OpenCodeTerminalSession(pty: info, service: service)
        session.send(text: "l")
        session.send(Array("s\r".utf8))
        session.attach(RecordingOutput())
        let socket = try await service.nextSocket()
        #expect(socket.sent.isEmpty)
        socket.deliver(.data(Data([0]) + Data(#"{"cursor":0}"#.utf8)))
        try await until { socket.sent.joined() == "ls\r" }
        session.send(text: "x")
        try await until { socket.sent.joined() == "ls\rx" }
    }

    @Test("A dropped network reconnects from the last cursor without replaying old output")
    func reconnectsFromCursor() async throws {
        let service = FakeTerminalService(info: info)
        let session = OpenCodeTerminalSession(pty: info, service: service)
        let output = RecordingOutput()
        session.attach(output)
        let first = try await service.nextSocket()
        first.deliver(.data(Data([0]) + Data(#"{"cursor":10}"#.utf8)))
        first.deliver(.text("abc"))
        try await until { output.text == "abc" }
        first.fail(.lost("Wi-Fi dropped"))
        try await until { if case .reconnecting = session.state { true } else { false } }
        let second = try await service.nextSocket()
        #expect(await service.connectCursors == [nil, 13])
        second.deliver(.data(Data([0]) + Data(#"{"cursor":13}"#.utf8)))
        second.deliver(.text("def"))
        try await until { output.text == "abcdef" && session.state == .connected }
    }

    @Test("A normal close is confirmed with the server: exited shows the code, running reconnects")
    func exitAndServerRestartedSocket() async throws {
        let service = FakeTerminalService(info: info)
        let session = OpenCodeTerminalSession(pty: info, service: service)
        session.attach(RecordingOutput())
        let first = try await service.nextSocket()
        first.deliver(.text("$ "))
        first.fail(.closed(code: 1000))
        // Still running (another client closed its socket): reconnect.
        _ = try await service.nextSocket()
        await service.setInfo(OpenCodePty(id: "pty_1", title: "Terminal 1", status: .exited, exitCode: 3))
        let second = await service.sockets.last!
        second.fail(.closed(code: 4404))
        try await until { session.state == .exited(code: 3) }
        #expect(session.pty.status == .exited)
        session.send(text: "ignored")
        #expect(second.sent.isEmpty)
    }

    @Test("A PTY the server forgot ends the tab instead of retrying")
    func goneAfterRestart() async throws {
        let service = FakeTerminalService(info: nil, connectError: .rejected(status: 404))
        let session = OpenCodeTerminalSession(pty: info, service: service)
        session.attach(RecordingOutput())
        try await until { session.state == .exited(code: nil) }
        #expect(await service.connectCursors.count == 1)
    }

    @Test("Rejected credentials stop with a message; Reconnect tries again")
    func authFailure() async throws {
        let service = FakeTerminalService(info: info, connectError: .rejected(status: 401))
        let session = OpenCodeTerminalSession(pty: info, service: service)
        session.attach(RecordingOutput())
        try await until { if case .failed = session.state { true } else { false } }
        #expect(await service.connectCursors.count == 1)
        await service.setConnectError(nil)
        session.reconnectNow()
        let socket = try await service.nextSocket()
        socket.deliver(.text("ok"))
        try await until { session.state == .connected }
    }

    @Test("A suspended tab stays closed when its view re-attaches, and resumes from its cursor")
    func suspendAndResume() async throws {
        let service = FakeTerminalService(info: info)
        let session = OpenCodeTerminalSession(pty: info, service: service)
        let output = RecordingOutput()
        session.attach(output)
        let first = try await service.nextSocket()
        first.deliver(.text("12345"))
        try await until { session.state == .connected }
        session.suspend()
        #expect(session.state == .idle)
        session.attach(output)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await service.connectCursors == [nil])
        session.resume()
        session.attach(output)
        let second = try await service.nextSocket()
        #expect(await service.connectCursors == [nil, 5])
        second.deliver(.text("6"))
        try await until { output.text == "123456" }
    }

    @Test("Rotation and keyboard sizes settle into one resize request")
    func resizeDebounce() async throws {
        let service = FakeTerminalService(info: info)
        let session = OpenCodeTerminalSession(pty: info, service: service, resizeDelay: .milliseconds(40))
        session.attach(RecordingOutput())
        let socket = try await service.nextSocket()
        socket.deliver(.text("$ "))
        try await until { session.state == .connected }
        session.resize(cols: 0, rows: 0)
        session.resize(cols: 60, rows: 30)
        session.resize(cols: 100, rows: 20)
        session.resize(cols: 100, rows: 18)
        try await until { await service.sizes == [OpenCodeTerminalSize(cols: 100, rows: 18)] }
        try await Task.sleep(for: .milliseconds(80))
        #expect(await service.sizes.count == 1)
        session.stop()
    }
}

@MainActor
@Suite("Terminal store")
struct OpenCodeTerminalStoreTests {
    @Test("A first visit with no terminals opens one; unavailable servers explain why")
    func load() async {
        let service = FakeTerminalService(info: nil, listed: [])
        let store = OpenCodeTerminalStore(service: service)
        await store.load()
        #expect(store.phase == .ready)
        #expect(store.terminals.map(\.pty.title) == ["Terminal 1"])
        #expect(store.selectedID == store.terminals.first?.id)
        // Reloading never adds more on its own.
        await store.load()
        #expect(await service.created == ["Terminal 1"])

        let unavailable = OpenCodeTerminalStore(service: FakeTerminalService(info: nil, availability: .unavailable("No PTY")))
        await unavailable.load()
        #expect(unavailable.phase == .unavailable("No PTY"))
        #expect(unavailable.terminals.isEmpty)
    }

    @Test("Existing PTYs become tabs; exited v2 PTYs stay visible with their code")
    func adoptsServerTerminals() async {
        let service = FakeTerminalService(info: nil, listed: [
            OpenCodePty(id: "pty_a", title: "Terminal 1"),
            OpenCodePty(id: "pty_b", title: "build", status: .exited, exitCode: 1),
        ])
        let store = OpenCodeTerminalStore(service: service)
        await store.load()
        #expect(store.terminals.map(\.id) == ["pty_a", "pty_b"])
        #expect(store.terminals[1].state == .exited(code: 1))
        #expect(store.selectedID == "pty_a")
        #expect(await service.created.isEmpty)
        await store.newTerminal()
        #expect(store.terminals.last?.pty.title == "Terminal 2")
        #expect(store.selectedID == store.terminals.last?.id)
    }

    @Test("Shells load with the tabs; a chosen shell starts the new tab, and no list is not an error")
    func shells() async {
        let service = FakeTerminalService(info: nil, listed: [OpenCodePty(id: "pty_a", title: "Terminal 1")])
        let bash = OpenCodeTerminalShell(path: "/bin/bash", name: "bash")
        await service.setShells([bash])
        let store = OpenCodeTerminalStore(service: service)
        await store.load()
        #expect(store.shells == [bash])
        await store.newTerminal(shell: bash)
        await store.newTerminal()
        #expect(await service.commands == ["/bin/bash", nil])
        #expect(store.terminals.map(\.pty.shellName) == [nil, "bash", nil])

        let bare = FakeTerminalService(info: nil, listed: [OpenCodePty(id: "pty_a", title: "Terminal 1")])
        await bare.setShells([], error: .httpStatus(500, "boom"))
        let plain = OpenCodeTerminalStore(service: bare)
        await plain.load()
        #expect(plain.phase == .ready)
        #expect(plain.shells.isEmpty)
        #expect(plain.actionError == nil)
    }

    @Test("Closing selects the neighbor; a failed close restores the tab")
    func close() async {
        let service = FakeTerminalService(info: nil, listed: [
            OpenCodePty(id: "pty_a", title: "Terminal 1"), OpenCodePty(id: "pty_b", title: "Terminal 2"),
            OpenCodePty(id: "pty_c", title: "Terminal 3"),
        ])
        let store = OpenCodeTerminalStore(service: service)
        await store.load()
        store.select(store.terminals[1])
        await store.close(store.terminals[1])
        #expect(store.terminals.map(\.id) == ["pty_a", "pty_c"])
        #expect(store.selectedID == "pty_c")
        #expect(await service.removed == ["pty_b"])

        await service.setRemoveFails(true)
        await store.close(store.terminals[0])
        #expect(store.terminals.map(\.id) == ["pty_a", "pty_c"])
        #expect(store.actionError != nil)
    }

    @Test("Renaming is optimistic and reverts on failure; v1 drops exited PTYs from the list")
    func renameAndMerge() async {
        let service = FakeTerminalService(info: nil, listed: [OpenCodePty(id: "pty_a", title: "Terminal 1")])
        let store = OpenCodeTerminalStore(service: service)
        await store.load()
        let session = store.terminals[0]
        await store.rename(session, to: "  server  ")
        #expect(session.pty.title == "server")
        #expect(await service.titles == ["server"])
        await service.setUpdateFails(true)
        await store.rename(session, to: "logs")
        #expect(session.pty.title == "server")
        #expect(store.actionError != nil)

        await service.setListed([])
        await store.load()
        #expect(store.terminals.map(\.id) == ["pty_a"])
        #expect(store.terminals[0].state == .exited(code: nil))
    }

    @Test("A tab opened while the list refreshes is not mistaken for an ended one")
    func newTerminalDuringRefresh() async throws {
        let service = FakeTerminalService(info: nil, listed: [OpenCodePty(id: "pty_a", title: "Terminal 1")])
        let store = OpenCodeTerminalStore(service: service)
        await store.load()
        await service.setListDelay(.milliseconds(200))
        let refresh = Task { await store.load() }
        try await until { await service.listCount == 2 }
        await store.newTerminal()
        await refresh.value
        #expect(store.terminals.map(\.id) == ["pty_a", "pty_new_1"])
        #expect(!store.terminals.contains { $0.isExited })
        #expect(store.selectedID == "pty_new_1")
    }
}

// MARK: - Fakes

@MainActor
private final class RecordingOutput: OpenCodeTerminalOutput {
    private(set) var text = ""
    func write(_ text: String) { self.text += text }
}

private final class FakeTerminalSocket: OpenCodeTerminalSocket, @unchecked Sendable {
    private let lock = NSLock()
    private let stream: AsyncStream<Result<OpenCodeTerminalMessage, OpenCodeTerminalSocketError>>
    private let continuation: AsyncStream<Result<OpenCodeTerminalMessage, OpenCodeTerminalSocketError>>.Continuation
    private var recorded: [String] = []
    var sent: [String] { lock.withLock { recorded } }

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func deliver(_ message: OpenCodeTerminalMessage) { continuation.yield(.success(message)) }
    func fail(_ disconnect: OpenCodeTerminalDisconnect) {
        continuation.yield(.failure(OpenCodeTerminalSocketError(disconnect: disconnect)))
    }

    func receive() async throws -> OpenCodeTerminalMessage {
        for await result in stream { return try result.get() }
        throw OpenCodeTerminalSocketError(disconnect: .closed(code: 1000))
    }

    func send(_ text: String) async throws { lock.withLock { recorded.append(text) } }

    func close() { continuation.finish() }
}

private actor FakeTerminalService: OpenCodeTerminalServicing {
    private var infoValue: OpenCodePty?
    private var listedValue: [OpenCodePty]
    private let availabilityValue: OpenCodeTerminalAvailability
    private var connectError: OpenCodeTerminalDisconnect?
    private var removeFails = false
    private var updateFails = false
    private(set) var sockets: [FakeTerminalSocket] = []
    private(set) var connectCursors: [Int?] = []
    private(set) var sizes: [OpenCodeTerminalSize] = []
    private(set) var titles: [String] = []
    private(set) var created: [String] = []
    private(set) var commands: [String?] = []
    private var shellsValue: [OpenCodeTerminalShell] = []
    private var shellsError: OpenCodeConnectionError?
    private(set) var removed: [String] = []
    private(set) var listCount = 0
    private var listDelay: Duration?
    private var handedOut = 0

    init(info: OpenCodePty?, listed: [OpenCodePty] = [], availability: OpenCodeTerminalAvailability = .available,
         connectError: OpenCodeTerminalDisconnect? = nil) {
        infoValue = info
        listedValue = listed
        availabilityValue = availability
        self.connectError = connectError
    }

    func setInfo(_ value: OpenCodePty?) { infoValue = value }
    func setListed(_ value: [OpenCodePty]) { listedValue = value }
    func setConnectError(_ value: OpenCodeTerminalDisconnect?) { connectError = value }
    func setRemoveFails(_ value: Bool) { removeFails = value }
    func setUpdateFails(_ value: Bool) { updateFails = value }
    func setListDelay(_ value: Duration?) { listDelay = value }
    func setShells(_ value: [OpenCodeTerminalShell], error: OpenCodeConnectionError? = nil) {
        shellsValue = value
        shellsError = error
    }

    /// Waits for the session's next connection attempt.
    func nextSocket() async throws -> FakeTerminalSocket {
        let deadline = ContinuousClock.now + .seconds(5)
        while sockets.count <= handedOut {
            guard ContinuousClock.now < deadline else { throw FakeTimeout() }
            try await Task.sleep(for: .milliseconds(5))
        }
        handedOut += 1
        return sockets[handedOut - 1]
    }

    func availability() async throws -> OpenCodeTerminalAvailability { availabilityValue }
    /// Answers with the PTYs as they were when the request arrived, like a slow server.
    func list() async throws -> [OpenCodePty] {
        let snapshot = listedValue
        listCount += 1
        if let listDelay { try await Task.sleep(for: listDelay) }
        return snapshot
    }

    func shells() async throws -> [OpenCodeTerminalShell] {
        if let shellsError { throw shellsError }
        return shellsValue
    }

    func create(title: String, command: String?) async throws -> OpenCodePty {
        created.append(title)
        commands.append(command)
        let pty = OpenCodePty(id: "pty_new_\(created.count)", title: title, command: command ?? "")
        listedValue.append(pty)
        return pty
    }

    func info(_ id: String) async throws -> OpenCodePty? { infoValue }

    func update(_ id: String, title: String?, size: OpenCodeTerminalSize?) async throws {
        if updateFails { throw OpenCodeConnectionError.httpStatus(500, "nope") }
        if let size { sizes.append(size) }
        if let title { titles.append(title) }
    }

    func remove(_ id: String) async throws {
        if removeFails { throw OpenCodeConnectionError.httpStatus(500, "nope") }
        removed.append(id)
    }

    func connect(_ id: String, cursor: Int?) async throws -> any OpenCodeTerminalSocket {
        connectCursors.append(cursor)
        if let connectError { throw OpenCodeTerminalSocketError(disconnect: connectError) }
        let socket = FakeTerminalSocket()
        sockets.append(socket)
        return socket
    }
}

private struct FakeTimeout: Error {}

@MainActor
private func until(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting for condition")
            throw FakeTimeout()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private final class SocketRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }

    func open(_ request: URLRequest) -> any OpenCodeTerminalSocket {
        lock.withLock { recorded.append(request) }
        return FakeTerminalSocket()
    }
}

private final class TerminalTestTransport: OpenCodeHTTPTransport, @unchecked Sendable {
    struct Response {
        let data: Data
        let mime: String
        var status = 200
        static func json(_ value: Any) -> Self {
            .init(data: try! JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), mime: "application/json")
        }
        static func raw(_ json: String) -> Self { .init(data: Data(json.utf8), mime: "application/json") }
    }

    let base: OpenCodeTransport
    let respond: @Sendable (URLRequest) -> Response
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }

    init(profile: OpenCodeServerProfile, respond: @escaping @Sendable (URLRequest) -> Response) {
        base = .init(profile: profile, password: "test", session: .shared)
        self.respond = respond
    }

    func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        try base.makeRequest(path: path, query: query, method: method, body: body)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(request) }
        let response = respond(request)
        return (response.data, HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil,
                                               headerFields: ["Content-Type": response.mime])!)
    }

    func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> { .init { $0.finish() } }
}
