import Foundation
import Testing
@testable import byot

@Suite("Server settings model")
struct OpenCodeServerSettingsModelTests {
    @Test("Global config reads as settings, with OpenCode's defaults for unset keys")
    func parsing() throws {
        let object = try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: Data("""
            {"$schema":"https://opencode.ai/config.json","model":"anthropic/claude-sonnet-4-5","small_model":" ",
             "default_agent":"plan","share":"disabled","autoupdate":"notify","snapshot":false,"shell":"/bin/zsh",
             "provider":{"anthropic":{"options":{"apiKey":"sk-secret"}}}}
            """.utf8))
        #expect(OpenCodeServerSettings(object) == OpenCodeServerSettings(
            model: "anthropic/claude-sonnet-4-5", smallModel: nil, defaultAgent: "plan", sharing: .disabled,
            updates: .notify, snapshots: false, shell: "/bin/zsh"))

        let defaults = OpenCodeServerSettings(["$schema": .string("https://opencode.ai/config.json")])
        #expect(defaults == OpenCodeServerSettings())
        #expect(defaults.sharing == .manual && defaults.updates == .automatic && defaults.snapshots && defaults.shell.isEmpty)

        // The legacy `autoshare` flag means automatic sharing unless `share` says otherwise.
        #expect(OpenCodeServerSettings(["autoshare": .bool(true)]).sharing == .auto)
        #expect(OpenCodeServerSettings(["autoshare": .bool(true), "share": .string("manual")]).sharing == .manual)
        #expect(OpenCodeServerSettings(["autoupdate": .bool(false)]).updates == .off)
        #expect(OpenCodeServerSettings(["autoupdate": .bool(true)]).updates == .automatic)
        // A `null` echoed back for a removed key reads as unset.
        #expect(OpenCodeServerSettings(["model": .null]).model == nil)
    }

    @Test("A patch carries only changed keys, in the shapes the server's schema accepts")
    func patch() {
        let saved = OpenCodeServerSettings(model: "anthropic/claude", defaultAgent: "plan", shell: "/bin/zsh")
        #expect(saved.patch(from: saved).isEmpty)

        var draft = saved
        draft.smallModel = "openai/gpt-5-mini"
        draft.sharing = .disabled
        draft.updates = .notify
        draft.snapshots = false
        #expect(draft.patch(from: saved) == [
            "small_model": .string("openai/gpt-5-mini"), "share": .string("disabled"),
            "autoupdate": .string("notify"), "snapshot": .bool(false),
        ])
        draft = saved
        draft.updates = .off
        #expect(draft.patch(from: saved) == ["autoupdate": .bool(false)])
        draft.updates = .automatic
        #expect(draft.patch(from: saved).isEmpty)

        // Automatic removes the key with null; an emptied shell is sent as "", which the
        // server turns into removal rather than writing a blank shell.
        draft.model = nil
        draft.defaultAgent = nil
        draft.shell = "   "
        #expect(draft.patch(from: saved) == ["model": .null, "default_agent": .null, "shell": .string("")])

        // Whitespace-only edits aren't changes.
        draft = saved
        draft.shell = " /bin/zsh\n"
        draft.model = " anthropic/claude "
        #expect(draft.patch(from: saved).isEmpty)
    }

    @Test("Typed model IDs need a provider and a model")
    func customModel() {
        #expect(OpenCodeServerSettingsModelPicker.customModel(" openrouter/qwen/qwen3-coder ") == "openrouter/qwen/qwen3-coder")
        #expect(OpenCodeServerSettingsModelPicker.customModel("anthropic/claude-sonnet-4-5") == "anthropic/claude-sonnet-4-5")
        for text in ["claude", "/claude", "anthropic/", "anthropic/claude sonnet", ""] {
            #expect(OpenCodeServerSettingsModelPicker.customModel(text) == nil, "\(text)")
        }
    }

    @Test("Options find models by qualified ID and agents by ID or name")
    func options() {
        let options = OpenCodeServerSettingsOptions(
            providers: [OpenCodeProviderModels(providerID: "openai", providerName: "OpenAI", models: [
                OpenCodeModelOption(providerID: "openai", providerName: "OpenAI", modelID: "gpt-5", modelName: "GPT-5", status: nil),
            ])],
            agents: [OpenCodeAgentOption(id: "agt_1", name: "review", description: nil)])
        #expect(options.model("openai/gpt-5")?.modelName == "GPT-5")
        #expect(options.model("gpt-5") == nil && options.model(nil) == nil)
        #expect(options.agent("review")?.id == "agt_1" && options.agent("agt_1")?.name == "review")
        #expect(options.agent("build") == nil)
    }
}

@Suite("Server settings service")
struct OpenCodeServerSettingsServiceTests {
    private let profile = OpenCodeServerProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!, name: "Settings",
        baseURL: "https://settings.example.test/opencode")

    @Test("v1 reads and patches /global/config with only the changed keys, unscoped to a project")
    func v1Routes() async throws {
        let transport = ContextTestTransport(profile: profile) { request in
            switch (request.httpMethod!, request.url!.path) {
            case ("GET", "/opencode/global/config"):
                .raw(#"{"$schema":"https://opencode.ai/config.json","model":"anthropic/claude","provider":{"x":{"options":{"apiKey":"k"}}}}"#)
            case ("PATCH", "/opencode/global/config"):
                .raw(#"{"$schema":"https://opencode.ai/config.json","model":null,"share":"disabled","provider":{"x":{"options":{"apiKey":"k"}}}}"#)
            case ("GET", "/opencode/agent"):
                .raw(#"[{"name":"build","mode":"primary"},{"name":"general","mode":"subagent"},{"name":"plan","mode":"primary"},{"name":"hidden","mode":"primary","hidden":true}]"#)
            default: .init(data: Data(), mime: "application/json", status: 404)
            }
        }
        let models = [OpenCodeProviderModels(providerID: "anthropic", providerName: "Anthropic", models: [])]
        let context = OpenCodeFeatureContext(serverProtocol: .v1, schema: nil, transport: transport, profile: profile)
        let service = OpenCodeServerContextService(directory: "/repo/app", workspace: "wrk_ctx",
                                                   context: { context }, providerModels: { models })
        #expect(try await service.capabilities().settings)
        #expect(try await service.serverSettings() == OpenCodeServerSettings(model: "anthropic/claude"))

        let updated = try await service.updateServerSettings(["model": .null, "share": .string("disabled")])
        #expect(updated == OpenCodeServerSettings(sharing: .disabled))

        let options = try await service.serverSettingsOptions()
        #expect(options.providers == models)
        #expect(options.agents.map(\.id) == ["build", "plan"])

        let requests = transport.requests
        #expect(requests.map { "\($0.httpMethod!) \($0.url!.path)" } == [
            "GET /opencode/global/config", "PATCH /opencode/global/config", "GET /opencode/agent",
        ])
        #expect(query(requests[0], "directory") == nil && query(requests[1], "directory") == nil)
        #expect(query(requests[2], "directory") == "/repo/app")
        let body = try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: try #require(requests[1].httpBody))
        #expect(body == ["model": .null, "share": .string("disabled")])
    }

    @Test("Servers without /global/config, or that reject a patch, report it plainly")
    func failures() async throws {
        let missing = ContextTestTransport(profile: profile) { _ in .init(data: Data("<!doctype html>".utf8), mime: "text/html") }
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await service(missing).serverSettings() }

        let rejecting = ContextTestTransport(profile: profile) { _ in
            .init(data: Data(#"{"name":"BadRequest","data":{"message":"Expected \"manual\" | \"auto\" | \"disabled\""}}"#.utf8),
                  mime: "application/json", status: 400)
        }
        do {
            _ = try await service(rejecting).updateServerSettings(["share": .string("bogus")])
            Issue.record("Expected the server's rejection")
        } catch {
            #expect(error.localizedDescription.contains("Expected"))
        }

        // Models and agents fail independently; only a double failure is reported.
        let noAgents = ContextTestTransport(profile: profile) { _ in .init(data: Data(), mime: "application/json", status: 500) }
        let options = try await service(noAgents, models: { [] }).serverSettingsOptions()
        #expect(options == OpenCodeServerSettingsOptions())
        await #expect(throws: OpenCodeConnectionError.self) {
            try await service(noAgents, models: { throw OpenCodeConnectionError.httpStatus(502, nil) }).serverSettingsOptions()
        }
    }

    @Test("v2 schemas without a global config write hide the editor and send nothing")
    func v2WithoutSettings() async throws {
        let transport = ContextTestTransport(profile: profile) { _ in .raw("{}") }
        let schema = try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appending(path: "Fixtures/opencode2-beta-19242-openapi.json")))
        let context = OpenCodeFeatureContext(serverProtocol: .v2, schema: schema, transport: transport, profile: profile)
        let service = OpenCodeServerContextService(directory: "/repo/app", workspace: nil) { context }
        #expect(try await service.capabilities().settings == false)
        await #expect(throws: OpenCodeServerContextError.unsupported) { try await service.serverSettings() }
        await #expect(throws: OpenCodeServerContextError.unsupported) {
            try await service.updateServerSettings(["share": .string("manual")])
        }
        #expect(transport.requests.isEmpty)

        // A schema that publishes both methods is followed.
        let published = OpenCodeFeatureContext(serverProtocol: .v2, schema: .object(["paths": .object([
            "/global/config": .object(["get": .object([:]), "patch": .object([:])]),
        ])]), transport: transport, profile: profile)
        #expect(OpenCodeServerContextCapabilities.v2(published).settings)
        #expect(OpenCodeServerContextCapabilities.v2(published).any)
    }

    private func service(_ transport: ContextTestTransport,
                         models: @escaping @Sendable () async throws -> [OpenCodeProviderModels] = { [] })
        -> OpenCodeServerContextService {
        let context = OpenCodeFeatureContext(serverProtocol: .v1, schema: nil, transport: transport, profile: profile)
        return OpenCodeServerContextService(directory: "/repo/app", workspace: nil, context: { context }, providerModels: models)
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

@MainActor
@Suite("Server settings store")
struct OpenCodeServerSettingsStoreTests {
    @Test("Loads settings and options, saves only the changes, and takes the server's answer as saved")
    func saving() async {
        let service = FakeSettingsService()
        let store = OpenCodeServerSettingsStore(service: service)
        #expect(store.phase == .loading && !store.hasChanges)
        await store.loadIfNeeded()
        #expect(store.phase == .loaded)
        // Coming back from a pushed picker must not reload over the draft.
        store.draft.snapshots = false
        await store.loadIfNeeded()
        #expect(store.draft.snapshots == false)
        store.discardChanges()
        #expect(store.saved.model == "anthropic/claude" && store.draft == store.saved)
        #expect(store.options.agents.map(\.id) == ["build"])
        #expect(await store.save() == false)

        store.draft.sharing = .disabled
        store.draft.model = nil
        #expect(store.hasChanges)
        #expect(await store.save())
        #expect(await service.patches == [["model": .null, "share": .string("disabled")]])
        #expect(store.saved == OpenCodeServerSettings(sharing: .disabled))
        #expect(store.draft == store.saved && !store.hasChanges && store.saveError == nil && !store.isSaving)
    }

    @Test("A rejected save keeps the draft and reports the error; discarding restores the saved settings")
    func rejected() async {
        let service = FakeSettingsService()
        await service.failSaves(with: OpenCodeConnectionError.httpStatus(400, "Expected \"manual\""))
        let store = OpenCodeServerSettingsStore(service: service)
        await store.load()
        store.draft.shell = "/bin/fish"
        #expect(await store.save() == false)
        #expect(store.draft.shell == "/bin/fish" && store.hasChanges)
        #expect(store.saveError?.contains("Expected") == true)
        store.discardChanges()
        #expect(store.draft == store.saved && store.saveError == nil)
    }

    @Test("Missing settings read as unsupported; unreachable ones as a retryable failure; option errors don't block")
    func loadFailures() async {
        let unsupported = OpenCodeServerSettingsStore(service: FakeSettingsService(settingsError: OpenCodeServerContextError.unsupported))
        await unsupported.load()
        #expect(unsupported.phase == .unsupported && !unsupported.hasChanges)

        let down = FakeSettingsService(settingsError: OpenCodeConnectionError.httpStatus(502, nil))
        let failing = OpenCodeServerSettingsStore(service: down)
        await failing.load()
        guard case .failed = failing.phase else { Issue.record("Expected a failure, got \(failing.phase)"); return }

        let noOptions = OpenCodeServerSettingsStore(service: FakeSettingsService(optionsError: OpenCodeConnectionError.httpStatus(500, "boom")))
        await noOptions.load()
        #expect(noOptions.phase == .loaded)
        #expect(noOptions.optionsError?.contains("boom") == true)
        #expect(noOptions.options == OpenCodeServerSettingsOptions())
    }

    @Test("The status screen offers settings only where the server supports them")
    func contextGating() async {
        let store = OpenCodeServerContextStore(service: FakeSettingsService())
        await store.load()
        #expect(store.canEditSettings)
        // Settings alone are something to show.
        #expect(!store.hasNothingToShow)
    }
}

private actor FakeSettingsService: OpenCodeServerContextServicing {
    private var stored: [String: OpenCodeJSONValue] = ["model": .string("anthropic/claude")]
    private var saveError: (any Error)?
    private let settingsError: (any Error)?
    private let optionsError: (any Error)?
    private(set) var patches: [[String: OpenCodeJSONValue]] = []

    init(settingsError: (any Error)? = nil, optionsError: (any Error)? = nil) {
        self.settingsError = settingsError
        self.optionsError = optionsError
    }

    func failSaves(with error: (any Error)?) { saveError = error }

    func capabilities() async throws -> OpenCodeServerContextCapabilities { OpenCodeServerContextCapabilities(settings: true) }
    func paths() async throws -> OpenCodeProjectPaths { throw OpenCodeServerContextError.unsupported }
    func branch() async throws -> OpenCodeVcsBranch { throw OpenCodeServerContextError.unsupported }
    func changes() async throws -> [OpenCodeProjectFileChange] { throw OpenCodeServerContextError.unsupported }
    func mcpServers() async throws -> [OpenCodeMCPServer] { throw OpenCodeServerContextError.unsupported }
    func setMCPServer(_ name: String, connected: Bool) async throws { throw OpenCodeServerContextError.unsupported }
    func languageServers() async throws -> [OpenCodeLSPServer] { throw OpenCodeServerContextError.unsupported }
    func formatters() async throws -> [OpenCodeFormatterStatus] { throw OpenCodeServerContextError.unsupported }
    func configuration() async throws -> OpenCodeServerConfiguration { throw OpenCodeServerContextError.unsupported }

    func serverSettings() async throws -> OpenCodeServerSettings {
        if let settingsError { throw settingsError }
        return OpenCodeServerSettings(stored)
    }

    func updateServerSettings(_ patch: [String: OpenCodeJSONValue]) async throws -> OpenCodeServerSettings {
        patches.append(patch)
        if let saveError { throw saveError }
        for (key, value) in patch { stored[key] = value == .null ? nil : value }
        return OpenCodeServerSettings(stored)
    }

    func serverSettingsOptions() async throws -> OpenCodeServerSettingsOptions {
        if let optionsError { throw optionsError }
        return OpenCodeServerSettingsOptions(agents: [OpenCodeAgentOption(id: "build", name: "build", description: nil)])
    }
}
