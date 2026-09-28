import Combine
import Foundation

/// One independently loaded part of the status screen. Sections the server doesn't
/// offer are `unsupported` and hidden rather than shown as errors.
enum OpenCodeContextSection<Value: Equatable & Sendable>: Equatable, Sendable {
    case loading
    case loaded(Value)
    case failed(String)
    case unsupported

    var value: Value? {
        if case .loaded(let value) = self { return value }
        return nil
    }

    var isVisible: Bool { self != .unsupported }
}

/// Status of one project location: paths, branch and working-tree changes, MCP servers
/// (with connect and disconnect), language servers, formatters and configuration, and
/// whether the server's global settings can be edited.
@MainActor
final class OpenCodeServerContextStore: ObservableObject {
    @Published private(set) var paths: OpenCodeContextSection<OpenCodeProjectPaths> = .loading
    @Published private(set) var branch: OpenCodeContextSection<OpenCodeVcsBranch> = .loading
    @Published private(set) var changes: OpenCodeContextSection<[OpenCodeProjectFileChange]> = .loading
    @Published private(set) var mcpServers: OpenCodeContextSection<[OpenCodeMCPServer]> = .loading
    @Published private(set) var languageServers: OpenCodeContextSection<[OpenCodeLSPServer]> = .loading
    @Published private(set) var formatters: OpenCodeContextSection<[OpenCodeFormatterStatus]> = .loading
    @Published private(set) var configuration: OpenCodeContextSection<OpenCodeServerConfiguration> = .loading
    @Published private(set) var canControlMCP = false
    /// The server lets BYOT change its global settings.
    @Published private(set) var canEditSettings = false
    /// MCP servers with a connect or disconnect in flight.
    @Published private(set) var switchingMCP: Set<String> = []
    @Published private(set) var mcpErrors: [String: String] = [:]
    /// Set when the server couldn't be reached before anything loaded.
    @Published private(set) var connectionError: String?
    /// Set when a refresh failed but earlier results are still on screen.
    @Published private(set) var refreshError: String?
    @Published private(set) var isRefreshing = false

    private let service: any OpenCodeServerContextServicing
    private var generation = 0
    private var hasLoaded = false

    init(service: any OpenCodeServerContextServicing) {
        self.service = service
    }

    /// True once every section has settled and none of them has anything to show.
    var hasNothingToShow: Bool {
        hasLoaded && connectionError == nil && !canEditSettings
            && ![paths.isVisible, branch.isVisible, changes.isVisible, mcpServers.isVisible,
                 languageServers.isVisible, formatters.isVisible, configuration.isVisible].contains(true)
    }

    /// Loads every section the server offers, concurrently, publishing each as it arrives.
    /// A refresh keeps earlier results on screen and reports failures in `refreshError`.
    func load() async {
        generation &+= 1
        let current = generation
        isRefreshing = true
        defer { if current == generation { isRefreshing = false } }

        let capabilities: OpenCodeServerContextCapabilities
        do {
            capabilities = try await service.capabilities()
        } catch {
            guard current == generation, !Self.isCancellation(error) else { return }
            if hasLoaded { refreshError = error.localizedDescription } else { connectionError = error.localizedDescription }
            return
        }
        guard current == generation else { return }
        connectionError = nil
        refreshError = nil
        canControlMCP = capabilities.mcp && capabilities.mcpControl
        canEditSettings = capabilities.settings
        if !capabilities.paths { paths = .unsupported }
        if !capabilities.branch { branch = .unsupported }
        if !capabilities.changes { changes = .unsupported }
        if !capabilities.mcp { mcpServers = .unsupported }
        if !capabilities.languageServers { languageServers = .unsupported }
        if !capabilities.formatters { formatters = .unsupported }
        if !capabilities.configuration { configuration = .unsupported }

        let service = service
        await withTaskGroup(of: Loaded.self) { group in
            if capabilities.paths { group.addTask { .paths(await Self.result { try await service.paths() }) } }
            if capabilities.branch { group.addTask { .branch(await Self.result { try await service.branch() }) } }
            if capabilities.changes { group.addTask { .changes(await Self.result { try await service.changes() }) } }
            if capabilities.mcp { group.addTask { .mcp(await Self.result { try await service.mcpServers() }) } }
            if capabilities.languageServers {
                group.addTask { .languageServers(await Self.result { try await service.languageServers() }) }
            }
            if capabilities.formatters { group.addTask { .formatters(await Self.result { try await service.formatters() }) } }
            if capabilities.configuration {
                group.addTask { .configuration(await Self.result { try await service.configuration() }) }
            }
            for await loaded in group {
                guard current == generation else { continue }
                apply(loaded)
            }
        }
        guard current == generation else { return }
        hasLoaded = true
    }

    /// Connects or disconnects one MCP server, then reloads the list: a connect that
    /// fails still succeeds as a request, and the server's status is the truth.
    func setMCPServer(_ server: OpenCodeMCPServer, connected: Bool) async {
        guard canControlMCP, server.canToggle, !switchingMCP.contains(server.name) else { return }
        switchingMCP.insert(server.name)
        mcpErrors[server.name] = nil
        defer { switchingMCP.remove(server.name) }
        do {
            try await service.setMCPServer(server.name, connected: connected)
        } catch {
            guard !Self.isCancellation(error) else { return }
            mcpErrors[server.name] = error.localizedDescription
        }
        await reloadMCP()
    }

    func mcpServer(named name: String) -> OpenCodeMCPServer? {
        mcpServers.value?.first { $0.name == name }
    }

    private func reloadMCP() async {
        let current = generation
        let service = service
        let result = await Self.result { try await service.mcpServers() }
        guard current == generation else { return }
        apply(.mcp(result), keepingOnFailure: true)
    }

    // MARK: Results

    private enum Loaded: Sendable {
        case paths(Result<OpenCodeProjectPaths, any Error>)
        case branch(Result<OpenCodeVcsBranch, any Error>)
        case changes(Result<[OpenCodeProjectFileChange], any Error>)
        case mcp(Result<[OpenCodeMCPServer], any Error>)
        case languageServers(Result<[OpenCodeLSPServer], any Error>)
        case formatters(Result<[OpenCodeFormatterStatus], any Error>)
        case configuration(Result<OpenCodeServerConfiguration, any Error>)
    }

    private nonisolated static func result<Value: Sendable>(
        _ body: @Sendable () async throws -> Value
    ) async -> Result<Value, any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    private func apply(_ loaded: Loaded, keepingOnFailure: Bool = false) {
        switch loaded {
        case .paths(let result): paths = merge(paths, result)
        case .branch(let result): branch = merge(branch, result)
        case .changes(let result): changes = merge(changes, result)
        case .mcp(let result):
            mcpServers = merge(mcpServers, result, keepingOnFailure: keepingOnFailure)
            // A server that disappeared can't carry an error any more.
            if let names = mcpServers.value.map({ Set($0.map(\.name)) }) {
                mcpErrors = mcpErrors.filter { names.contains($0.key) }
            }
        case .languageServers(let result): languageServers = merge(languageServers, result)
        case .formatters(let result): formatters = merge(formatters, result)
        case .configuration(let result): configuration = merge(configuration, result)
        }
    }

    /// A missing route hides the section; any other failure keeps an earlier value on
    /// screen (flagging the refresh) or shows the error in place of the section.
    private func merge<Value>(
        _ section: OpenCodeContextSection<Value>,
        _ result: Result<Value, any Error>,
        keepingOnFailure: Bool = false
    ) -> OpenCodeContextSection<Value> {
        switch result {
        case .success(let value):
            return .loaded(value)
        case .failure(let error):
            if (error as? OpenCodeServerContextError) == .unsupported { return .unsupported }
            if Self.isCancellation(error) { return section }
            if section.value != nil {
                if !keepingOnFailure { refreshError = error.localizedDescription }
                return section
            }
            return .failed(error.localizedDescription)
        }
    }

    private nonisolated static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }
}
