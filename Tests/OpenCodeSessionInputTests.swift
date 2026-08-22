import Foundation
import Testing
@testable import byot

struct OpenCodeSessionInputTests {
    @Test("Input policy exposes the exact detected protocol surface")
    func policy() {
        let v1 = OpenCodeSessionInputPolicy(capabilities: .v1)
        let v2 = OpenCodeSessionInputPolicy(capabilities: .v2)

        #expect(v1.canListCommands)
        #expect(v1.canExecuteCommands)
        #expect(v1.canRunShell)
        #expect(v1.canListAgents)
        #expect(v1.canSelectAgent)
        #expect(v2.canListCommands)
        #expect(!v2.canExecuteCommands)
        #expect(!v2.canRunShell)
        #expect(v2.canListAgents)
        #expect(v2.canSelectAgent)
        #expect(v2.commandUnavailableReason != nil)
        #expect(v2.shellUnavailableReason != nil)
    }

    @Test("Input parser recognizes only registered slash commands and explicit shell mode")
    func parser() {
        let commands = [
            OpenCodeCommandOption(
                name: "review",
                description: "Review changes",
                template: "Review $ARGUMENTS",
                source: "command",
                agent: nil,
                subtask: false,
                hints: ["scope"]
            ),
        ]

        #expect(
            OpenCodeSessionInputParser.intent(
                text: "/review staged changes",
                mode: .normal,
                commands: commands
            ) == .command(name: "review", arguments: "staged changes")
        )
        #expect(
            OpenCodeSessionInputParser.intent(
                text: "/unknown keep literal",
                mode: .normal,
                commands: commands
            ) == .prompt("/unknown keep literal")
        )
        #expect(
            OpenCodeSessionInputParser.intent(
                text: "git status",
                mode: .shell,
                commands: commands
            ) == .shell("git status")
        )
    }
}

@MainActor
@Suite(.serialized)
struct OpenCodeSessionInputStoreTests {
    @Test("Catalog store filters picker agents and keeps the session agent selected")
    func loadsCatalogs() async {
        let service = MockSessionInputService(
            capabilities: .v2,
            commands: [
                OpenCodeCommandOption(
                    name: "review",
                    description: nil,
                    template: "Review",
                    source: nil,
                    agent: nil,
                    subtask: nil,
                    hints: []
                ),
            ],
            agents: [
                OpenCodeAgentOption(id: "build", description: nil, mode: "primary", hidden: false),
                OpenCodeAgentOption(id: "plan", description: nil, mode: "all", hidden: false),
                OpenCodeAgentOption(id: "helper", description: nil, mode: "subagent", hidden: false),
                OpenCodeAgentOption(id: "secret", description: nil, mode: "primary", hidden: true),
            ]
        )
        let store = OpenCodeSessionInputStore(
            service: service,
            directory: "/repo",
            workspace: "wrk_1",
            initialAgentID: "plan"
        )

        await store.load()

        #expect(service.steps == [.capabilities, .commands, .agents])
        #expect(store.commands.map(\.name) == ["review"])
        #expect(store.selectableAgents.map(\.id) == ["build", "plan"])
        #expect(store.selectedAgent?.id == "plan")
        #expect(store.policy?.canExecuteCommands == false)
        #expect(store.errorMessage == nil)
    }
}

private final class MockSessionInputService: OpenCodeSessionInputServicing, @unchecked Sendable {
    enum Step: Equatable {
        case capabilities
        case commands
        case agents
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var recordedSteps: [Step] = []
    private let capabilities: OpenCodeProtocolCapabilities
    private let commands: [OpenCodeCommandOption]
    private let agents: [OpenCodeAgentOption]

    init(
        capabilities: OpenCodeProtocolCapabilities,
        commands: [OpenCodeCommandOption],
        agents: [OpenCodeAgentOption]
    ) {
        self.capabilities = capabilities
        self.commands = commands
        self.agents = agents
    }

    var steps: [Step] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSteps
    }

    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities {
        record(.capabilities)
        return capabilities
    }

    func commands(directory: String, workspace: String?) async throws -> [OpenCodeCommandOption] {
        record(.commands)
        return commands
    }

    func agents(directory: String, workspace: String?) async throws -> [OpenCodeAgentOption] {
        record(.agents)
        return agents
    }

    private func record(_ step: Step) {
        lock.lock()
        recordedSteps.append(step)
        lock.unlock()
    }
}
