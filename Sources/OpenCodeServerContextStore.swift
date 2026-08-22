import Combine
import Foundation

@MainActor
final class OpenCodeServerContextStore: ObservableObject {
    @Published private(set) var configuration = OpenCodeServerContextSection<OpenCodeConfiguration>.idle
    @Published private(set) var vcs = OpenCodeServerContextSection<OpenCodeVCSInfo>.idle
    @Published private(set) var paths = OpenCodeServerContextSection<OpenCodeServerPaths>.idle
    @Published private(set) var mcp = OpenCodeServerContextSection<[String: OpenCodeMCPStatus]>.idle
    @Published private(set) var lsp = OpenCodeServerContextSection<[OpenCodeLSPStatus]>.idle
    @Published private(set) var formatters = OpenCodeServerContextSection<[OpenCodeFormatterStatus]>.idle
    @Published private(set) var isLoading = false
    @Published private(set) var isSavingConfiguration = false
    @Published var configurationText = ""
    @Published var configurationErrorMessage: String?

    private let service: any OpenCodeServerContextServicing
    private let directory: String
    private let workspace: String?
    private var capabilities: OpenCodeServerContextCapabilities?
    private var loadGeneration = 0

    init(
        service: any OpenCodeServerContextServicing,
        directory: String,
        workspace: String? = nil
    ) {
        self.service = service
        self.directory = directory
        self.workspace = workspace
    }

    var canSaveConfiguration: Bool {
        capabilities?.configurationWrite.isSupported == true
            && configuration.value != nil
            && !isSavingConfiguration
    }

    var configurationWriteUnavailableReason: String? {
        capabilities?.configurationWrite.unavailableReason
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        configurationErrorMessage = nil
        defer {
            if generation == loadGeneration { isLoading = false }
        }

        let contextCapabilities: OpenCodeServerContextCapabilities
        do {
            contextCapabilities = try await service.protocolCapabilities().serverContext
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            setAllFailed(error.localizedDescription)
            return
        }
        guard generation == loadGeneration else { return }
        capabilities = contextCapabilities

        await loadConfiguration(
            support: contextCapabilities.configurationRead,
            generation: generation
        )
        await loadVCS(support: contextCapabilities.vcs, generation: generation)
        await loadPaths(support: contextCapabilities.paths, generation: generation)
        await loadMCP(support: contextCapabilities.mcp, generation: generation)
        await loadLSP(support: contextCapabilities.lsp, generation: generation)
        await loadFormatters(support: contextCapabilities.formatter, generation: generation)
    }

    func saveConfiguration() async {
        guard canSaveConfiguration else { return }
        let candidate: OpenCodeConfiguration
        do {
            candidate = try OpenCodeConfigurationDocument.configuration(from: configurationText)
        } catch {
            configurationErrorMessage = "Configuration must be a valid JSON object: \(error.localizedDescription)"
            return
        }

        isSavingConfiguration = true
        configurationErrorMessage = nil
        defer { isSavingConfiguration = false }
        do {
            let saved = try await service.updateServerConfiguration(
                candidate,
                directory: directory,
                workspace: workspace
            )
            configuration = .available(saved)
            configurationText = try OpenCodeConfigurationDocument.string(from: saved)
        } catch is CancellationError {
            return
        } catch {
            configurationErrorMessage = error.localizedDescription
        }
    }

    private func loadConfiguration(
        support: OpenCodeFeatureSupport,
        generation: Int
    ) async {
        guard support.isSupported else {
            configuration = .unavailable(reason: support.unavailableReason ?? "Configuration is unavailable.")
            return
        }
        configuration = .loading
        do {
            let value = try await service.serverConfiguration(
                directory: directory,
                workspace: workspace
            )
            guard generation == loadGeneration else { return }
            configuration = .available(value)
            configurationText = try OpenCodeConfigurationDocument.string(from: value)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            configuration = .failed(message: error.localizedDescription)
        }
    }

    private func loadVCS(support: OpenCodeFeatureSupport, generation: Int) async {
        guard support.isSupported else {
            vcs = .unavailable(reason: support.unavailableReason ?? "VCS status is unavailable.")
            return
        }
        vcs = .loading
        do {
            let value = try await service.vcsInfo(directory: directory, workspace: workspace)
            guard generation == loadGeneration else { return }
            vcs = .available(value)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            vcs = .failed(message: error.localizedDescription)
        }
    }

    private func loadPaths(support: OpenCodeFeatureSupport, generation: Int) async {
        guard support.isSupported else {
            paths = .unavailable(reason: support.unavailableReason ?? "Path context is unavailable.")
            return
        }
        paths = .loading
        do {
            let value = try await service.pathInfo(directory: directory, workspace: workspace)
            guard generation == loadGeneration else { return }
            paths = .available(value)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            paths = .failed(message: error.localizedDescription)
        }
    }

    private func loadMCP(support: OpenCodeFeatureSupport, generation: Int) async {
        guard support.isSupported else {
            mcp = .unavailable(reason: support.unavailableReason ?? "MCP status is unavailable.")
            return
        }
        mcp = .loading
        do {
            let value = try await service.mcpStatuses(directory: directory, workspace: workspace)
            guard generation == loadGeneration else { return }
            mcp = .available(value)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            mcp = .failed(message: error.localizedDescription)
        }
    }

    private func loadLSP(support: OpenCodeFeatureSupport, generation: Int) async {
        guard support.isSupported else {
            lsp = .unavailable(reason: support.unavailableReason ?? "LSP status is unavailable.")
            return
        }
        lsp = .loading
        do {
            let value = try await service.lspStatuses(directory: directory, workspace: workspace)
            guard generation == loadGeneration else { return }
            lsp = .available(value)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            lsp = .failed(message: error.localizedDescription)
        }
    }

    private func loadFormatters(support: OpenCodeFeatureSupport, generation: Int) async {
        guard support.isSupported else {
            formatters = .unavailable(reason: support.unavailableReason ?? "Formatter status is unavailable.")
            return
        }
        formatters = .loading
        do {
            let value = try await service.formatterStatuses(directory: directory, workspace: workspace)
            guard generation == loadGeneration else { return }
            formatters = .available(value)
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            formatters = .failed(message: error.localizedDescription)
        }
    }

    private func setAllFailed(_ message: String) {
        configuration = .failed(message: message)
        vcs = .failed(message: message)
        paths = .failed(message: message)
        mcp = .failed(message: message)
        lsp = .failed(message: message)
        formatters = .failed(message: message)
    }
}
