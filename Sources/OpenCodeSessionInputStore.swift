import Combine
import Foundation

@MainActor
final class OpenCodeSessionInputStore: ObservableObject {
    @Published private(set) var capabilities: OpenCodeProtocolCapabilities?
    @Published private(set) var commands: [OpenCodeCommandOption] = []
    @Published private(set) var agents: [OpenCodeAgentOption] = []
    @Published private(set) var selectedAgentID: String?
    @Published private(set) var hasLoadedCommandCatalog = false
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private let service: any OpenCodeSessionInputServicing
    private let directory: String
    private let workspace: String?
    private var loadGeneration = 0

    init(
        client: OpenCodeClient,
        directory: String,
        workspace: String?,
        initialAgentID: String?
    ) {
        service = client
        self.directory = directory
        self.workspace = workspace
        selectedAgentID = initialAgentID
    }

    init(
        service: any OpenCodeSessionInputServicing,
        directory: String,
        workspace: String?,
        initialAgentID: String?
    ) {
        self.service = service
        self.directory = directory
        self.workspace = workspace
        selectedAgentID = initialAgentID
    }

    var policy: OpenCodeSessionInputPolicy? {
        capabilities.map(OpenCodeSessionInputPolicy.init)
    }

    var selectableAgents: [OpenCodeAgentOption] {
        agents.filter { !$0.hidden && $0.mode != "subagent" }
    }

    var selectedAgent: OpenCodeAgentOption? {
        selectableAgents.first { $0.id == selectedAgentID }
    }

    func load() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        isLoading = true
        defer {
            if generation == loadGeneration { isLoading = false }
        }
        do {
            let capabilities = try await service.protocolCapabilities()
            guard generation == loadGeneration else { return }
            self.capabilities = capabilities
            let policy = OpenCodeSessionInputPolicy(capabilities: capabilities)
            var catalogErrors: [Error] = []
            if policy.canListCommands {
                do {
                    let loadedCommands = try await service.commands(
                        directory: directory,
                        workspace: workspace
                    )
                    guard generation == loadGeneration else { return }
                    commands = loadedCommands
                    hasLoadedCommandCatalog = true
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == loadGeneration else { return }
                    catalogErrors.append(error)
                }
            } else {
                commands = []
                hasLoadedCommandCatalog = true
            }
            guard generation == loadGeneration else { return }
            if policy.canListAgents {
                do {
                    let loadedAgents = try await service.agents(
                        directory: directory,
                        workspace: workspace
                    )
                    guard generation == loadGeneration else { return }
                    agents = loadedAgents
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == loadGeneration else { return }
                    catalogErrors.append(error)
                }
            } else {
                agents = []
            }
            guard generation == loadGeneration else { return }
            if selectedAgentID == nil {
                selectedAgentID = selectableAgents.first?.id
            }
            errorMessage = catalogErrors.first?.localizedDescription
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        await load()
    }

    func selectAgent(_ agent: OpenCodeAgentOption) {
        guard selectableAgents.contains(where: { $0.id == agent.id }) else { return }
        selectedAgentID = agent.id
    }

    func validate(
        _ intent: OpenCodeSessionInputIntent,
        sourceText: String? = nil
    ) -> Bool {
        if case .prompt = intent {
            let looksLikeSlashCommand = sourceText?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .hasPrefix("/") == true
            if looksLikeSlashCommand,
               policy?.canListCommands != false,
               !hasLoadedCommandCatalog {
                errorMessage = isLoading
                    ? "OpenCode commands are still loading."
                    : "OpenCode commands could not be loaded. Refresh before sending slash text."
                return false
            }
            errorMessage = nil
            return true
        }
        guard let policy else {
            errorMessage = "OpenCode input capabilities are still loading."
            return false
        }
        guard policy.supports(intent) else {
            switch intent {
            case .command:
                errorMessage = policy.commandUnavailableReason
            case .shell:
                errorMessage = policy.shellUnavailableReason
            case .prompt:
                break
            }
            return false
        }
        if case .shell = intent, selectedAgent == nil {
            errorMessage = OpenCodeSessionInputError.shellAgentRequired.localizedDescription
            return false
        }
        errorMessage = nil
        return true
    }

    func prepareShellMode() -> Bool {
        guard let policy else {
            errorMessage = "OpenCode input capabilities are still loading."
            return false
        }
        guard policy.canRunShell else {
            errorMessage = policy.shellUnavailableReason
            return false
        }
        guard selectedAgent != nil else {
            errorMessage = OpenCodeSessionInputError.shellAgentRequired.localizedDescription
            return false
        }
        errorMessage = nil
        return true
    }
}
