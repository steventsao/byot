import Foundation
import Testing
@testable import byot

@Suite("Server context models")
struct OpenCodeServerContextModelTests {
    @Test("MCP status decodes from v1 maps and v2 lists, sorted by name, with switchable states")
    func mcpStatus() throws {
        let failed = try #require(OpenCodeMCPServer(name: "broken", status: .object([
            "status": .string("failed"), "error": .string("MCP error -32000: Connection closed"),
        ])))
        #expect(failed.state == .failed && failed.error == "MCP error -32000: Connection closed")
        #expect(OpenCodeMCPServer(name: "x", status: .string("connected")) == nil)
        #expect(OpenCodeMCPServer(name: "x", status: .object(["status": .string("needs_auth")]))?.state == .needsAuthentication)
        #expect(OpenCodeMCPServer.State("needs_client_registration") == .needsClientRegistration)
        #expect(OpenCodeMCPServer.State("pending") == .pending)
        #expect(OpenCodeMCPServer.State("warming_up") == .other("warming_up"))
        #expect(OpenCodeMCPServer.State("warming_up").title == "Warming Up")

        let sorted = OpenCodeMCPServer.sorted([
            OpenCodeMCPServer(name: "zeta", state: .connected),
            OpenCodeMCPServer(name: "Alpha", state: .disabled),
            OpenCodeMCPServer(name: "mid10", state: .failed),
            OpenCodeMCPServer(name: "mid9", state: .failed),
        ])
        #expect(sorted.map(\.name) == ["Alpha", "mid9", "mid10", "zeta"])

        // Sign-in opens a browser on the server's machine, and pending servers are mid-start.
        #expect(OpenCodeMCPServer(name: "a", state: .needsAuthentication).canToggle == false)
        #expect(OpenCodeMCPServer(name: "a", state: .pending).canToggle == false)
        for state in [OpenCodeMCPServer.State.connected, .disabled, .failed, .needsClientRegistration] {
            #expect(OpenCodeMCPServer(name: "a", state: state).canToggle, "\(state)")
        }
    }

    @Test("Language servers, formatters and file changes decode the server's shapes")
    func statusDecoding() throws {
        let lsp = try JSONDecoder().decode([OpenCodeLSPServer].self, from: Data("""
            [{"id":"typescript","name":"TypeScript","root":"/repo/app","status":"connected"},
             {"id":"gopls","name":"","root":"/repo/app/tools/","status":"error"},
             {"id":"pyright","name":"Pyright","root":"/elsewhere","status":"connected"}]
            """.utf8))
        #expect(lsp.map(\.name) == ["TypeScript", "gopls", "Pyright"])
        #expect(lsp.map(\.isConnected) == [true, false, true])
        #expect(lsp.map { $0.displayRoot(relativeTo: "/repo/app") } == ["Project root", "tools", "/elsewhere"])
        #expect(lsp[0].displayRoot(relativeTo: "/repo/app/") == "Project root")

        let formatters = try JSONDecoder().decode([OpenCodeFormatterStatus].self, from: Data("""
            [{"name":"zig","extensions":[".zig"],"enabled":false},{"name":"ruff","extensions":[".py"],"enabled":true},
             {"name":"biome","extensions":[".ts",".js"],"enabled":true},{"name":"air","enabled":false}]
            """.utf8))
        #expect(OpenCodeFormatterStatus.sorted(formatters).map(\.name) == ["biome", "ruff", "air", "zig"])
        #expect(formatters[3].extensions.isEmpty)

        let changes = try JSONDecoder().decode([OpenCodeProjectFileChange].self, from: Data("""
            [{"file":"Sources/App/Main.swift","additions":12,"deletions":3,"status":"modified"},
             {"file":"README.md","additions":4,"deletions":0,"status":"added"},
             {"file":"old.txt","additions":0,"deletions":9,"status":"deleted"}]
            """.utf8))
        #expect(changes[0] == OpenCodeProjectFileChange(path: "Sources/App/Main.swift", status: .modified, additions: 12, deletions: 3))
        #expect(changes[0].name == "Main.swift" && changes[0].folder == "Sources/App")
        #expect(changes[1].status == .added && changes[1].folder == nil)
        #expect(changes[2].status == .deleted)
    }

    @Test("Paths under the server's home read as ~/…, like the TUI")
    func paths() {
        let paths = OpenCodeProjectPaths(directory: "/Users/dev/repo", home: "/Users/dev")
        #expect(paths.abbreviated("/Users/dev/.config/opencode") == "~/.config/opencode")
        #expect(paths.abbreviated("/Users/dev") == "~")
        #expect(paths.abbreviated("/Users/devtools/x") == "/Users/devtools/x")
        #expect(OpenCodeProjectPaths(directory: "/r").abbreviated("/Users/dev/x") == "/Users/dev/x")
        #expect(OpenCodeProjectPaths(directory: "/r", home: "/").abbreviated("/etc") == "/etc")
    }

    @Test("v1 configuration: summary values, TUI-style plugin names, provider names, and a redacted document")
    func v1Configuration() throws {
        let object = try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: Data("""
            {"$schema":"https://opencode.ai/config.json","model":"anthropic/claude-sonnet-4","small_model":"openai/gpt-5-mini",
             "default_agent":"plan","username":"dev","share":"disabled","autoupdate":"notify","shell":"/bin/zsh",
             "plugin":["file:///Users/dev/.config/opencode/plugins/herdr-agent-state.js","opencode-wakatime@1.2.0",
                       "@scope/tool","file:///srv/plugins/notify/index.ts",["opencode-foo@2.0.0",{"x":1}]],
             "instructions":["AGENTS.md","docs/*.md"],
             "provider":{"nvidia":{"name":"NVIDIA Build","options":{"apiKey":"nvapi-SECRET","baseURL":"https://integrate.api.nvidia.com/v1"}},
                         "local":{"options":{"headers":{"Authorization":"Bearer SECRET"}}}},
             "mcp":{"gh":{"type":"remote","url":"https://mcp.example.com","headers":{"X-Token":"SECRET"}},
                    "db":{"type":"local","command":["db-mcp"],"environment":{"DB_PASSWORD":"SECRET","PORT":5432}}},
             "keybinds":{"leader":"ctrl+x"}}
            """.utf8))
        let configuration = OpenCodeServerConfiguration.v1(object)
        #expect(configuration.model == "anthropic/claude-sonnet-4")
        #expect(configuration.smallModel == "openai/gpt-5-mini")
        #expect(configuration.defaultAgent == "plan")
        #expect(configuration.username == "dev")
        #expect(configuration.share == "Off")
        #expect(configuration.updates == "Notify only")
        #expect(configuration.shell == "/bin/zsh")
        #expect(configuration.instructions == ["AGENTS.md", "docs/*.md"])
        #expect(configuration.providers.map(\.name) == ["local", "NVIDIA Build"])
        #expect(Set(configuration.plugins.map(\.id)) == [
            "@scope/tool@latest", "herdr-agent-state", "notify", "opencode-foo@2.0.0", "opencode-wakatime@1.2.0",
        ])
        #expect(configuration.plugins.map(\.name).suffix(3) == ["notify", "opencode-foo", "opencode-wakatime"])
        #expect(configuration.sources.isEmpty)

        let document = try #require(configuration.documents.first)
        let text = OpenCodeServerConfiguration.text(document.json)
        #expect(!text.contains("SECRET"))
        #expect(text.contains("\"baseURL\" : \"https://integrate.api.nvidia.com/v1\""))
        #expect(text.contains("\"leader\" : \"ctrl+x\""))
        #expect(text.contains("\"$schema\" : \"https://opencode.ai/config.json\""))
        let mcp = document.json.objectValue?["mcp"]?.objectValue
        #expect(mcp?["db"]?.objectValue?["environment"]?.objectValue?["PORT"] == .string(OpenCodeServerConfiguration.redactionMark))
        #expect(mcp?["db"]?.objectValue?["command"] == .array([.string("db-mcp")]))
        #expect(mcp?["gh"]?.objectValue?["url"] == .string("https://mcp.example.com"))
    }

    @Test("Secret-looking names are hidden wherever they appear; ordinary keys are kept")
    func redaction() {
        for key in ["apiKey", "api_key", "API-KEY", "key", "token", "accessToken", "refresh_token", "clientSecret",
                    "password", "passphrase", "Authorization", "private_key"] {
            #expect(OpenCodeServerConfiguration.isSecretKey(key), "\(key)")
        }
        for key in ["keybinds", "max_tokens", "model", "baseURL", "url", "enabled", "tokenizer"] {
            #expect(!OpenCodeServerConfiguration.isSecretKey(key), "\(key)")
        }
        let redacted = OpenCodeServerConfiguration.redacted(.object([
            "list": .array([.object(["token": .string("t"), "name": .string("n")])]),
            "env": .object(["A": .string("1"), "nested": .object(["B": .number(2)]), "flag": .bool(true)]),
            "secret": .null,
        ]))
        let mark = OpenCodeJSONValue.string(OpenCodeServerConfiguration.redactionMark)
        #expect(redacted == .object([
            "list": .array([.object(["token": mark, "name": .string("n")])]),
            "env": .object(["A": mark, "nested": .object(["B": mark]), "flag": .bool(true)]),
            "secret": .null,
        ]))
    }

    @Test("v2 configuration merges documents lowest priority first and lists every source")
    func v2Configuration() throws {
        let entries = try JSONDecoder().decode([OpenCodeJSONValue].self, from: Data("""
            [{"type":"document","path":"/Users/dev/.config/opencode/opencode.json",
              "info":{"model":"anthropic/claude-sonnet-4","update":"auto","plugins":["opencode-a@1.0.0"],
                      "providers":{"anthropic":{"name":"Anthropic","options":{"apiKey":"SECRET"}}}}},
             {"type":"directory","path":"/repo/.opencode"},
             {"type":"claude","path":"/repo/.claude"},
             {"type":"document","path":"/repo/opencode.json",
              "info":{"model":{"providerID":"openai","model":"gpt-5","variant":"high"},"share":"auto","default_agent":"build",
                      "plugins":[{"package":"opencode-b"},"opencode-a@1.0.0"],"instructions":["AGENTS.md"]}},
             {"type":"unknown","path":"/ignored"}]
            """.utf8))
        let configuration = OpenCodeServerConfiguration.v2(entries)
        #expect(configuration.model == "openai/gpt-5 (high)")
        #expect(configuration.updates == "Automatic")
        #expect(configuration.share == "Automatic")
        #expect(configuration.defaultAgent == "build")
        #expect(configuration.providers == [.init(id: "anthropic", name: "Anthropic")])
        #expect(configuration.plugins.map(\.id) == ["opencode-a@1.0.0", "opencode-b@latest"])
        #expect(configuration.instructions == ["AGENTS.md"])
        #expect(configuration.sources.map(\.kind) == [.document, .directory, .claude, .document])
        #expect(configuration.sources.map(\.path) == [
            "/Users/dev/.config/opencode/opencode.json", "/repo/.opencode", "/repo/.claude", "/repo/opencode.json",
        ])
        #expect(configuration.documents.map(\.title) == ["opencode.json", "opencode.json"])
        #expect(configuration.documents.map(\.path) == ["/Users/dev/.config/opencode/opencode.json", "/repo/opencode.json"])
        #expect(!OpenCodeServerConfiguration.text(configuration.documents[0].json).contains("SECRET"))
        #expect(OpenCodeServerConfiguration.v2([]) == OpenCodeServerConfiguration())
    }

    @Test("Update and share settings read as words, not raw values")
    func settingTitles() {
        #expect(OpenCodeServerConfiguration.updatesTitle(.bool(true)) == "Automatic")
        #expect(OpenCodeServerConfiguration.updatesTitle(.bool(false)) == "Off")
        #expect(OpenCodeServerConfiguration.updatesTitle(.string("disable")) == "Off")
        #expect(OpenCodeServerConfiguration.updatesTitle(nil) == nil)
        #expect(OpenCodeServerConfiguration.shareTitle("manual") == "Manual")
        #expect(OpenCodeServerConfiguration.model(.object(["providerID": .string("p")])) == nil)
    }
}

@Suite("Server context service")
struct OpenCodeServerContextServiceTests {
    private let profile = OpenCodeServerProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!, name: "Context",
        baseURL: "https://ctx.example.test/opencode")

    @Test("v1 reads every section from location-scoped routes and switches MCP servers")
    func v1Routes() async throws {
        let transport = ContextTestTransport(profile: profile) { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/opencode/path"):
                .raw(#"{"home":"/Users/dev","state":"/Users/dev/.local/state/opencode","config":"/Users/dev/.config/opencode","worktree":"/repo","directory":"/repo/app"}"#)
            case ("GET", "/opencode/vcs"): .raw(#"{"branch":"feature","default_branch":null}"#)
            case ("GET", "/opencode/vcs/status"): .raw(#"[{"file":"a.swift","additions":1,"deletions":2,"status":"modified"}]"#)
            case ("GET", "/opencode/mcp"):
                .raw(#"{"zed":{"status":"connected"},"broken":{"status":"failed","error":"Connection closed"},"off":{"status":"disabled"}}"#)
            case ("POST", "/opencode/mcp/off/connect"), ("POST", "/opencode/mcp/zed/disconnect"): .raw("true")
            case ("GET", "/opencode/lsp"): .raw(#"[{"id":"ts","name":"TypeScript","root":"/repo/app","status":"connected"}]"#)
            case ("GET", "/opencode/formatter"): .raw(#"[{"name":"zig","extensions":[".zig"],"enabled":false},{"name":"ruff","extensions":[".py"],"enabled":true}]"#)
            case ("GET", "/opencode/config"): .raw(#"{"model":"anthropic/claude","plugin":["opencode-x@1"]}"#)
            default: .init(data: Data(), mime: "application/json", status: 404)
            }
        }
        let service = makeService(transport, protocol: .v1)
        #expect(try await service.capabilities() == .v1)
        #expect(await service.isAvailable())
        #expect(try await service.paths() == OpenCodeProjectPaths(
            directory: "/repo/app", worktree: "/repo", workspaceID: "wrk_ctx", home: "/Users/dev",
            config: "/Users/dev/.config/opencode", state: "/Users/dev/.local/state/opencode"))
        #expect(try await service.branch() == OpenCodeVcsBranch(current: "feature", defaultBranch: nil))
        #expect(await service.currentBranch() == "feature")
        #expect(try await service.changes() == [OpenCodeProjectFileChange(path: "a.swift", status: .modified, additions: 1, deletions: 2)])
        let servers = try await service.mcpServers()
        #expect(servers.map(\.name) == ["broken", "off", "zed"])
        #expect(servers.map(\.state) == [.failed, .disabled, .connected])
        #expect(servers[0].error == "Connection closed")
        try await service.setMCPServer("off", connected: true)
        try await service.setMCPServer("zed", connected: false)
        #expect(try await service.languageServers().map(\.id) == ["ts"])
        #expect(try await service.formatters().map(\.name) == ["ruff", "zig"])
        let configuration = try await service.configuration()
        #expect(configuration.model == "anthropic/claude")
        #expect(configuration.plugins == [.init(name: "opencode-x", version: "1")])

        let requests = transport.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "GET /opencode/path", "GET /opencode/vcs", "GET /opencode/vcs", "GET /opencode/vcs/status",
            "GET /opencode/mcp", "POST /opencode/mcp/off/connect", "POST /opencode/mcp/zed/disconnect",
            "GET /opencode/lsp", "GET /opencode/formatter", "GET /opencode/config",
        ])
        for request in requests {
            #expect(query(request, "directory") == "/repo/app")
            #expect(query(request, "workspace") == "wrk_ctx")
            #expect(request.httpBody == nil)
        }
    }

    @Test("Older v1 servers without a route read as unsupported; other failures stay errors")
    func v1Unsupported() async throws {
        let html = ContextTestTransport(profile: profile) { _ in .init(data: Data("<!doctype html>".utf8), mime: "text/html") }
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await makeService(html, protocol: .v1).formatters() }
        let missing = ContextTestTransport(profile: profile) { _ in .init(data: Data(), mime: "application/json", status: 404) }
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await makeService(missing, protocol: .v1).changes() }
        let broken = ContextTestTransport(profile: profile) { _ in .init(data: Data(#"{"message":"boom"}"#.utf8), mime: "application/json", status: 500) }
        await #expect(throws: OpenCodeConnectionError.self) { try await makeService(broken, protocol: .v1).mcpServers() }
        // An unknown MCP server is a real failure, not a missing feature.
        let unknown = ContextTestTransport(profile: profile) { _ in
            .init(data: Data(#"{"name":"nope","message":"MCP server not found: nope"}"#.utf8), mime: "application/json", status: 404)
        }
        await #expect(throws: OpenCodeConnectionError.self) {
            try await makeService(unknown, protocol: .v1).setMCPServer("nope", connected: true)
        }
    }

    @Test("v2 follows the beta schema: location, branch, status, MCP and config; no guessed LSP or formatter routes")
    func v2Routes() async throws {
        let located = #"{"directory":"/repo/app","workspaceID":"wrk_ctx","project":{"id":"prj_1","directory":"/repo","canonical":"/repo"}}"#
        let transport = ContextTestTransport(profile: profile) { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/opencode/api/location"): .raw(located)
            case ("GET", "/opencode/api/vcs"): .raw(#"{"location":\#(located),"data":{"branch":{"current":"main","default":"main"}}}"#)
            case ("GET", "/opencode/api/vcs/status"):
                .raw(#"{"location":\#(located),"data":[{"file":"b.ts","additions":3,"deletions":0,"status":"added"}]}"#)
            case ("GET", "/opencode/api/mcp"):
                .raw(#"{"location":\#(located),"data":[{"name":"docs","status":{"status":"pending"}},{"name":"auth","status":{"status":"needs_auth"},"integrationID":"int_1"}]}"#)
            case ("POST", "/opencode/api/mcp/docs/connect"): .init(data: Data(), mime: "application/json", status: 204)
            case ("GET", "/opencode/api/config"):
                .raw(#"[{"type":"document","path":"/repo/opencode.json","info":{"model":"openai/gpt-5"}},{"type":"agents","path":"/repo/.agents"}]"#)
            default: .init(data: Data(), mime: "application/json", status: 404)
            }
        }
        let service = makeService(transport, protocol: .v2, schema: try schema())
        let capabilities = try await service.capabilities()
        #expect(capabilities == OpenCodeServerContextCapabilities(
            paths: true, branch: true, changes: true, mcp: true, mcpControl: true, configuration: true))
        #expect(try await service.paths() == OpenCodeProjectPaths(
            directory: "/repo/app", worktree: "/repo", projectID: "prj_1", workspaceID: "wrk_ctx"))
        #expect(try await service.branch() == OpenCodeVcsBranch(current: "main", defaultBranch: "main"))
        #expect(try await service.changes().map(\.status) == [.added])
        #expect(try await service.mcpServers().map(\.state) == [.needsAuthentication, .pending])
        try await service.setMCPServer("docs", connected: true)
        let configuration = try await service.configuration()
        #expect(configuration.model == "openai/gpt-5")
        #expect(configuration.sources.map(\.kind) == [.document, .agents])
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await service.languageServers() }
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await service.formatters() }

        let requests = transport.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "GET /opencode/api/location", "GET /opencode/api/vcs", "GET /opencode/api/vcs/status",
            "GET /opencode/api/mcp", "POST /opencode/api/mcp/docs/connect", "GET /opencode/api/config",
        ])
        for request in requests {
            #expect(query(request, "location[directory]") == "/repo/app")
            #expect(query(request, "location[workspace]") == "wrk_ctx")
            #expect(query(request, "directory") == nil)
        }
    }

    @Test("v2 answers for another location are rejected")
    func v2WrongLocation() async throws {
        let other = #"{"directory":"/other","project":{"id":"prj_2","directory":"/other","canonical":"/other"}}"#
        let transport = ContextTestTransport(profile: profile) { request in
            switch request.url!.path {
            case "/opencode/api/location": .raw(other)
            default: .raw(#"{"location":\#(other),"data":[]}"#)
            }
        }
        let service = makeService(transport, protocol: .v2, schema: try schema())
        await #expect(throws: OpenCodeServerContextError.wrongLocation) { try await service.paths() }
        await #expect(throws: OpenCodeServerContextError.wrongLocation) { try await service.changes() }
        await #expect(throws: OpenCodeServerContextError.wrongLocation) { try await service.mcpServers() }
    }

    @Test("A v2 schema without these routes hides every section and sends nothing")
    func v2WithoutRoutes() async throws {
        let transport = ContextTestTransport(profile: profile) { _ in .raw("{}") }
        let service = makeService(transport, protocol: .v2, schema: .object(["paths": .object([:])]))
        #expect(try await service.capabilities() == OpenCodeServerContextCapabilities())
        #expect(await service.isAvailable() == false)
        #expect(await service.currentBranch() == nil)
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await service.paths() }
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await service.branch() }
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await service.mcpServers() }
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await service.setMCPServer("a", connected: true) }
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await service.configuration() }
        #expect(transport.requests.isEmpty)
    }

    @Test("An unreachable server is a retryable failure and hides entry points")
    func unreachable() async {
        let service = OpenCodeServerContextService(directory: "/repo/app", workspace: nil) {
            throw OpenCodeConnectionError.httpStatus(502, nil)
        }
        await #expect(throws: OpenCodeConnectionError.self) { try await service.capabilities() }
        #expect(await service.isAvailable() == false)
        #expect(await service.currentBranch() == nil)
    }

    private func makeService(_ transport: ContextTestTransport, protocol serverProtocol: OpenCodeServerProtocol,
                             schema: OpenCodeJSONValue? = nil) -> OpenCodeServerContextService {
        let context = OpenCodeFeatureContext(serverProtocol: serverProtocol, schema: schema, transport: transport, profile: profile)
        return OpenCodeServerContextService(directory: "/repo/app", workspace: "wrk_ctx") { context }
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private func schema() throws -> OpenCodeJSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/opencode2-beta-19242-openapi.json")
        return try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(contentsOf: url))
    }
}

@MainActor
@Suite("Server context store")
struct OpenCodeServerContextStoreTests {
    @Test("Sections load independently; missing ones hide and failures stay in place")
    func sections() async {
        let service = FakeContextService()
        await service.set(capabilities: OpenCodeServerContextCapabilities(
            paths: true, branch: true, changes: true, mcp: true, mcpControl: false, languageServers: true, formatters: true))
        await service.fail(.formatters, with: OpenCodeConnectionError.httpStatus(500, "boom"))
        await service.fail(.languageServers, with: OpenCodeServerContextError.unsupported)
        let store = OpenCodeServerContextStore(service: service)
        #expect(store.paths == .loading)
        await store.load()
        #expect(store.paths.value?.directory == "/repo")
        #expect(store.branch.value == OpenCodeVcsBranch(current: "main", defaultBranch: "main"))
        #expect(store.changes.value?.count == 1)
        #expect(store.mcpServers.value?.map(\.name) == ["docs", "github"])
        #expect(store.languageServers == .unsupported)
        #expect(store.configuration == .unsupported)
        if case .failed(let message) = store.formatters { #expect(message.contains("boom")) } else {
            Issue.record("Expected the formatter failure in place, got \(store.formatters)")
        }
        #expect(!store.canControlMCP)
        #expect(!store.hasNothingToShow)
        #expect(store.connectionError == nil && store.refreshError == nil && !store.isRefreshing)
    }

    @Test("A refresh that fails keeps earlier results and says so; a later success clears it")
    func refreshFailure() async {
        let service = FakeContextService()
        let store = OpenCodeServerContextStore(service: service)
        await store.load()
        #expect(store.formatters.value?.count == 1)
        await service.fail(.formatters, with: OpenCodeConnectionError.httpStatus(502, nil))
        await store.load()
        #expect(store.formatters.value?.count == 1)
        #expect(store.refreshError != nil)
        await service.fail(.formatters, with: nil)
        await store.load()
        #expect(store.refreshError == nil)
    }

    @Test("An unreachable server shows a connection error first, and a refresh error once loaded")
    func connectionFailure() async {
        let service = FakeContextService()
        await service.failCapabilities(OpenCodeConnectionError.httpStatus(502, nil))
        let store = OpenCodeServerContextStore(service: service)
        await store.load()
        #expect(store.connectionError != nil)
        #expect(!store.hasNothingToShow)
        await service.failCapabilities(nil)
        await store.load()
        #expect(store.connectionError == nil && store.paths.value != nil)
        await service.failCapabilities(OpenCodeConnectionError.httpStatus(502, nil))
        await store.load()
        #expect(store.connectionError == nil && store.refreshError != nil && store.paths.value != nil)
    }

    @Test("A server with nothing to report says so instead of showing an empty list")
    func nothingToShow() async {
        let service = FakeContextService()
        await service.set(capabilities: OpenCodeServerContextCapabilities())
        let store = OpenCodeServerContextStore(service: service)
        #expect(!store.hasNothingToShow)
        await store.load()
        #expect(store.hasNothingToShow)
        #expect(await service.calls.isEmpty)
    }

    @Test("Switching an MCP server calls the server, then reloads the list for its real status")
    func mcpSwitching() async throws {
        let service = FakeContextService()
        let store = OpenCodeServerContextStore(service: service)
        await store.load()
        #expect(store.canControlMCP)
        let docs = try #require(store.mcpServer(named: "docs"))
        await service.setMCPResult(for: "docs", state: .connected)
        await store.setMCPServer(docs, connected: true)
        #expect(store.mcpServer(named: "docs")?.state == .connected)
        #expect(store.switchingMCP.isEmpty && store.mcpErrors.isEmpty)
        #expect(await service.calls.suffix(2) == ["setMCP docs true", "mcp"])

        // A rejected switch reports the error on the row and still reloads the truth.
        let github = try #require(store.mcpServer(named: "github"))
        await service.fail(.setMCP, with: OpenCodeConnectionError.httpStatus(404, "MCP server not found: github"))
        await store.setMCPServer(github, connected: false)
        #expect(store.mcpErrors["github"]?.contains("not found") == true)
        #expect(store.mcpServer(named: "github")?.state == .connected)

        // Servers awaiting sign-in on the server's machine can't be switched from here.
        let calls = await service.calls.count
        await store.setMCPServer(OpenCodeMCPServer(name: "docs", state: .needsAuthentication), connected: true)
        #expect(await service.calls.count == calls)

        // A reload that drops a server also drops its error.
        await service.removeMCP("github")
        await store.load()
        #expect(store.mcpErrors.isEmpty)
    }

    @Test("Without MCP control the store never sends a switch")
    func mcpWithoutControl() async throws {
        let service = FakeContextService()
        await service.set(capabilities: OpenCodeServerContextCapabilities(mcp: true))
        let store = OpenCodeServerContextStore(service: service)
        await store.load()
        await store.setMCPServer(try #require(store.mcpServer(named: "docs")), connected: true)
        #expect(!(await service.calls.contains { $0.hasPrefix("setMCP") }))
    }
}

private actor FakeContextService: OpenCodeServerContextServicing {
    enum Section: Hashable { case formatters, languageServers, setMCP }

    private var capabilitiesValue = OpenCodeServerContextCapabilities.v1
    private var capabilitiesError: (any Error)?
    private var failures: [Section: any Error] = [:]
    private var mcp = [
        OpenCodeMCPServer(name: "docs", state: .disabled),
        OpenCodeMCPServer(name: "github", state: .connected),
    ]
    private var mcpResults: [String: OpenCodeMCPServer.State] = [:]
    private(set) var calls: [String] = []

    func set(capabilities: OpenCodeServerContextCapabilities) { capabilitiesValue = capabilities }
    func failCapabilities(_ error: (any Error)?) { capabilitiesError = error }
    func fail(_ section: Section, with error: (any Error)?) { failures[section] = error }
    func setMCPResult(for name: String, state: OpenCodeMCPServer.State) { mcpResults[name] = state }
    func removeMCP(_ name: String) { mcp.removeAll { $0.name == name } }

    func capabilities() async throws -> OpenCodeServerContextCapabilities {
        if let capabilitiesError { throw capabilitiesError }
        return capabilitiesValue
    }

    func paths() async throws -> OpenCodeProjectPaths {
        calls.append("paths")
        return OpenCodeProjectPaths(directory: "/repo", home: "/Users/dev")
    }

    func branch() async throws -> OpenCodeVcsBranch {
        calls.append("branch")
        return OpenCodeVcsBranch(current: "main", defaultBranch: "main")
    }

    func changes() async throws -> [OpenCodeProjectFileChange] {
        calls.append("changes")
        return [OpenCodeProjectFileChange(path: "a.swift", status: .modified, additions: 1, deletions: 1)]
    }

    func mcpServers() async throws -> [OpenCodeMCPServer] {
        calls.append("mcp")
        return mcp
    }

    func setMCPServer(_ name: String, connected: Bool) async throws {
        calls.append("setMCP \(name) \(connected)")
        if let error = failures[.setMCP] { throw error }
        if let state = mcpResults[name], let index = mcp.firstIndex(where: { $0.name == name }) {
            mcp[index].state = state
        }
    }

    func languageServers() async throws -> [OpenCodeLSPServer] {
        calls.append("lsp")
        if let error = failures[.languageServers] { throw error }
        return [OpenCodeLSPServer(id: "ts", name: "TypeScript", root: "/repo")]
    }

    func formatters() async throws -> [OpenCodeFormatterStatus] {
        calls.append("formatters")
        if let error = failures[.formatters] { throw error }
        return [OpenCodeFormatterStatus(name: "ruff", extensions: [".py"], enabled: true)]
    }

    func configuration() async throws -> OpenCodeServerConfiguration {
        calls.append("configuration")
        return OpenCodeServerConfiguration(model: "anthropic/claude")
    }
}

private final class ContextTestTransport: OpenCodeHTTPTransport, @unchecked Sendable {
    struct Response {
        let data: Data
        let mime: String
        var status = 200
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
