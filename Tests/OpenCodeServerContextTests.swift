import Foundation
import Testing
@testable import byot

@MainActor
struct OpenCodeServerContextTests {
    @Test("Configuration JSON round-trips arbitrary nested fields without loss")
    func configurationDocumentRoundTrip() throws {
        let original: OpenCodeConfiguration = [
            "model": .string("openai/gpt-5"),
            "provider": .object([
                "openai": .object([
                    "options": .object([
                        "timeout": .number(90),
                        "headers": .object(["x-team": .string("mobile")]),
                    ]),
                ]),
            ]),
            "permission": .object([
                "bash": .array([.string("allow"), .bool(true), .null]),
            ]),
        ]

        let text = try OpenCodeConfigurationDocument.string(from: original)
        let decoded = try OpenCodeConfigurationDocument.configuration(from: text)

        #expect(decoded == original)
        #expect(text.contains("\"x-team\""))
    }

    @Test("Partial v2 availability loads paths and explains every absent section")
    func partialAvailability() async {
        let service = MockServerContextService(capabilities: .v2)
        let store = OpenCodeServerContextStore(
            service: service,
            directory: "/repo",
            workspace: "wrk_1"
        )

        await store.load()

        #expect(store.paths == .available(service.paths))
        #expect(store.configuration.unavailableReason == OpenCodeProtocolCapabilities.v2.serverContext.configurationRead.unavailableReason)
        #expect(store.vcs.unavailableReason == OpenCodeProtocolCapabilities.v2.serverContext.vcs.unavailableReason)
        #expect(store.mcp.unavailableReason == OpenCodeProtocolCapabilities.v2.serverContext.mcp.unavailableReason)
        #expect(store.lsp.unavailableReason == OpenCodeProtocolCapabilities.v2.serverContext.lsp.unavailableReason)
        #expect(store.formatters.unavailableReason == OpenCodeProtocolCapabilities.v2.serverContext.formatter.unavailableReason)
        #expect(service.steps == [.capabilities, .paths])
    }

    @Test("Validated configuration text is saved as the complete object returned by the server")
    func saveConfiguration() async throws {
        let service = MockServerContextService(capabilities: .v1)
        let store = OpenCodeServerContextStore(
            service: service,
            directory: "/repo",
            workspace: "wrk_1"
        )
        await store.load()
        store.configurationText = #"{"model":"anthropic/claude","custom":{"nested":[1,true,null]}}"#

        await store.saveConfiguration()

        let expected: OpenCodeConfiguration = [
            "model": .string("anthropic/claude"),
            "custom": .object([
                "nested": .array([.number(1), .bool(true), .null]),
            ]),
        ]
        #expect(service.updatedConfiguration == expected)
        #expect(store.configuration == .available(expected))
        #expect(store.configurationErrorMessage == nil)
    }

    @Test("An older load cannot leave a finished newer section stuck loading")
    func staleLoadCannotOverwriteNewerLoad() async {
        let service = StaleServerContextService()
        let store = OpenCodeServerContextStore(
            service: service,
            directory: "/repo"
        )

        let older = Task { await store.load() }
        await service.waitForFirstConfigurationRequest()
        await store.load()
        await service.releaseFirstConfigurationRequest()
        await older.value

        #expect(store.vcs == .available(OpenCodeVCSInfo(branch: "new", defaultBranch: "main")))
        #expect(store.paths.value?.directory == "/repo")
        #expect(!store.isLoading)
    }

    @Test("Refresh is ignored while a configuration save owns the store")
    func refreshDoesNotRaceSave() async {
        let service = SaveRaceServerContextService()
        let store = OpenCodeServerContextStore(
            service: service,
            directory: "/repo"
        )
        await store.load()
        store.configurationText = #"{"model":"saved"}"#

        let save = Task { await store.saveConfiguration() }
        await service.waitForUpdateRequest()
        await store.load()

        let configurationRequestCount = await service.configurationRequestCount
        #expect(configurationRequestCount == 1)
        await service.releaseUpdateRequest()
        await save.value
        #expect(store.configuration == .available(["model": .string("saved")]))
    }

    @Test("A completed save never overwrites edits made while the request was in flight")
    func savePreservesNewerEditorText() async {
        let service = SaveRaceServerContextService()
        let store = OpenCodeServerContextStore(
            service: service,
            directory: "/repo"
        )
        await store.load()
        store.configurationText = #"{"model":"submitted"}"#

        let save = Task { await store.saveConfiguration() }
        await service.waitForUpdateRequest()
        store.configurationText = #"{"model":"newer-draft"}"#
        await service.releaseUpdateRequest()
        await save.value

        #expect(store.configurationText == #"{"model":"newer-draft"}"#)
        #expect(store.configuration == .available(["model": .string("submitted")]))
    }

    @Test("Cancelling a context load restores every section and stops later requests")
    func cancellationRestoresSectionsAndStopsSequence() async {
        let service = CancellingServerContextService()
        let store = OpenCodeServerContextStore(
            service: service,
            directory: "/repo"
        )

        let load = Task { await store.load() }
        await service.waitForConfigurationRequest()
        load.cancel()
        await load.value

        #expect(store.configuration == .idle)
        #expect(store.vcs == .idle)
        #expect(store.paths == .idle)
        #expect(store.mcp == .idle)
        #expect(store.lsp == .idle)
        #expect(store.formatters == .idle)
        #expect(!store.isLoading)
        #expect(await service.laterRequestCount == 0)
    }

    @Test("A failed configuration refresh preserves the loaded value and unsaved editor text")
    func failedConfigurationRefreshPreservesLoadedDraft() async {
        let service = FailingConfigurationRefreshService()
        let store = OpenCodeServerContextStore(
            service: service,
            directory: "/repo"
        )
        await store.load()
        let loaded = store.configuration
        store.configurationText = #"{"model":"unsaved-draft"}"#

        await store.load()

        #expect(store.configuration == loaded)
        #expect(store.configurationText == #"{"model":"unsaved-draft"}"#)
        #expect(store.configurationErrorMessage == "configuration refresh failed")
        #expect(store.canSaveConfiguration)
    }
}

private actor FailingConfigurationRefreshService: OpenCodeServerContextServicing {
    private var configurationRequestCount = 0

    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }

    func serverConfiguration(
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeConfiguration {
        configurationRequestCount += 1
        if configurationRequestCount > 1 {
            throw FailingConfigurationRefreshError()
        }
        return ["model": .string("server-loaded")]
    }

    func updateServerConfiguration(
        _ configuration: OpenCodeConfiguration,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeConfiguration { configuration }

    func vcsInfo(directory: String, workspace: String?) async throws -> OpenCodeVCSInfo {
        OpenCodeVCSInfo(branch: "main", defaultBranch: "main")
    }

    func pathInfo(directory: String, workspace: String?) async throws -> OpenCodeServerPaths {
        racePaths
    }

    func mcpStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeMCPStatus] { [:] }
    func lspStatuses(directory: String, workspace: String?) async throws -> [OpenCodeLSPStatus] { [] }
    func formatterStatuses(directory: String, workspace: String?) async throws -> [OpenCodeFormatterStatus] { [] }
}

private struct FailingConfigurationRefreshError: LocalizedError {
    var errorDescription: String? { "configuration refresh failed" }
}

private actor CancellingServerContextService: OpenCodeServerContextServicing {
    private var configurationStarted = false
    private var configurationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var laterRequestCount = 0

    func waitForConfigurationRequest() async {
        if configurationStarted { return }
        await withCheckedContinuation { configurationWaiters.append($0) }
    }

    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }

    func serverConfiguration(
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeConfiguration {
        configurationStarted = true
        configurationWaiters.forEach { $0.resume() }
        configurationWaiters.removeAll()
        try await Task.sleep(for: .seconds(30))
        return [:]
    }

    func updateServerConfiguration(
        _ configuration: OpenCodeConfiguration,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeConfiguration { configuration }

    func vcsInfo(directory: String, workspace: String?) async throws -> OpenCodeVCSInfo {
        laterRequestCount += 1
        return OpenCodeVCSInfo(branch: nil, defaultBranch: nil)
    }

    func pathInfo(directory: String, workspace: String?) async throws -> OpenCodeServerPaths {
        laterRequestCount += 1
        return racePaths
    }

    func mcpStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeMCPStatus] {
        laterRequestCount += 1
        return [:]
    }

    func lspStatuses(directory: String, workspace: String?) async throws -> [OpenCodeLSPStatus] {
        laterRequestCount += 1
        return []
    }

    func formatterStatuses(directory: String, workspace: String?) async throws -> [OpenCodeFormatterStatus] {
        laterRequestCount += 1
        return []
    }
}

private actor StaleServerContextService: OpenCodeServerContextServicing {
    private var configurationRequests = 0
    private var firstConfigurationContinuation: CheckedContinuation<OpenCodeConfiguration, Never>?
    private var firstConfigurationWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForFirstConfigurationRequest() async {
        if configurationRequests > 0 { return }
        await withCheckedContinuation { firstConfigurationWaiters.append($0) }
    }

    func releaseFirstConfigurationRequest() {
        firstConfigurationContinuation?.resume(returning: ["model": .string("old")])
        firstConfigurationContinuation = nil
    }

    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }

    func serverConfiguration(directory: String, workspace: String?) async throws -> OpenCodeConfiguration {
        configurationRequests += 1
        if configurationRequests == 1 {
            firstConfigurationWaiters.forEach { $0.resume() }
            firstConfigurationWaiters.removeAll()
            return await withCheckedContinuation { firstConfigurationContinuation = $0 }
        }
        return ["model": .string("new")]
    }

    func updateServerConfiguration(
        _ configuration: OpenCodeConfiguration,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeConfiguration { configuration }

    func vcsInfo(directory: String, workspace: String?) async throws -> OpenCodeVCSInfo {
        OpenCodeVCSInfo(branch: "new", defaultBranch: "main")
    }

    func pathInfo(directory: String, workspace: String?) async throws -> OpenCodeServerPaths {
        racePaths
    }

    func mcpStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeMCPStatus] { [:] }
    func lspStatuses(directory: String, workspace: String?) async throws -> [OpenCodeLSPStatus] { [] }
    func formatterStatuses(directory: String, workspace: String?) async throws -> [OpenCodeFormatterStatus] { [] }
}

private actor SaveRaceServerContextService: OpenCodeServerContextServicing {
    private(set) var configurationRequestCount = 0
    private var updateContinuation: CheckedContinuation<Void, Never>?
    private var updateWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForUpdateRequest() async {
        if updateContinuation != nil { return }
        await withCheckedContinuation { updateWaiters.append($0) }
    }

    func releaseUpdateRequest() {
        updateContinuation?.resume()
        updateContinuation = nil
    }

    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }

    func serverConfiguration(directory: String, workspace: String?) async throws -> OpenCodeConfiguration {
        configurationRequestCount += 1
        return ["model": .string("server-old")]
    }

    func updateServerConfiguration(
        _ configuration: OpenCodeConfiguration,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeConfiguration {
        await withCheckedContinuation { continuation in
            updateContinuation = continuation
            updateWaiters.forEach { $0.resume() }
            updateWaiters.removeAll()
        }
        return configuration
    }

    func vcsInfo(directory: String, workspace: String?) async throws -> OpenCodeVCSInfo {
        OpenCodeVCSInfo(branch: "main", defaultBranch: "main")
    }

    func pathInfo(directory: String, workspace: String?) async throws -> OpenCodeServerPaths {
        racePaths
    }

    func mcpStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeMCPStatus] { [:] }
    func lspStatuses(directory: String, workspace: String?) async throws -> [OpenCodeLSPStatus] { [] }
    func formatterStatuses(directory: String, workspace: String?) async throws -> [OpenCodeFormatterStatus] { [] }
}

private let racePaths = OpenCodeServerPaths(
    home: nil,
    state: nil,
    config: nil,
    worktree: "/repo",
    directory: "/repo",
    workspaceID: nil,
    projectID: "proj_1"
)

private final class MockServerContextService: OpenCodeServerContextServicing, @unchecked Sendable {
    enum Step: Equatable, Sendable {
        case capabilities
        case configuration
        case updateConfiguration
        case vcs
        case paths
        case mcp
        case lsp
        case formatters
    }

    let paths = OpenCodeServerPaths(
        home: nil,
        state: nil,
        config: nil,
        worktree: "/repo",
        directory: "/repo",
        workspaceID: "wrk_1",
        projectID: "proj_1"
    )

    private let capabilities: OpenCodeProtocolCapabilities
    private let lock = NSLock()
    nonisolated(unsafe) private var recordedSteps: [Step] = []
    nonisolated(unsafe) private var savedConfiguration: OpenCodeConfiguration?

    init(capabilities: OpenCodeProtocolCapabilities) {
        self.capabilities = capabilities
    }

    var steps: [Step] {
        lock.withLock { recordedSteps }
    }

    var updatedConfiguration: OpenCodeConfiguration? {
        lock.withLock { savedConfiguration }
    }

    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities {
        record(.capabilities)
        return capabilities
    }

    func serverConfiguration(directory: String, workspace: String?) async throws -> OpenCodeConfiguration {
        record(.configuration)
        return ["model": .string("openai/gpt-5")]
    }

    func updateServerConfiguration(
        _ configuration: OpenCodeConfiguration,
        directory: String,
        workspace: String?
    ) async throws -> OpenCodeConfiguration {
        lock.withLock {
            recordedSteps.append(.updateConfiguration)
            savedConfiguration = configuration
        }
        return configuration
    }

    func vcsInfo(directory: String, workspace: String?) async throws -> OpenCodeVCSInfo {
        record(.vcs)
        return OpenCodeVCSInfo(branch: "feature", defaultBranch: "main")
    }

    func pathInfo(directory: String, workspace: String?) async throws -> OpenCodeServerPaths {
        record(.paths)
        return paths
    }

    func mcpStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeMCPStatus] {
        record(.mcp)
        return ["docs": OpenCodeMCPStatus(status: .connected, error: nil)]
    }

    func lspStatuses(directory: String, workspace: String?) async throws -> [OpenCodeLSPStatus] {
        record(.lsp)
        return [OpenCodeLSPStatus(id: "sourcekit", name: "SourceKit LSP", root: "/repo", status: .connected)]
    }

    func formatterStatuses(directory: String, workspace: String?) async throws -> [OpenCodeFormatterStatus] {
        record(.formatters)
        return [OpenCodeFormatterStatus(name: "swiftformat", extensions: [".swift"], enabled: true)]
    }

    private func record(_ step: Step) {
        lock.withLock { recordedSteps.append(step) }
    }
}
