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

    @Test("Registered commands override the picker with their configured agent")
    func commandAgentResolution() {
        let commands = [
            OpenCodeCommandOption(
                name: "review",
                description: nil,
                template: "Review",
                source: nil,
                agent: "reviewer",
                subtask: false,
                hints: []
            ),
        ]

        #expect(
            OpenCodeSessionInputAgentResolver.agentID(
                for: .command(name: "review", arguments: "staged"),
                selectedAgentID: "build",
                commands: commands
            ) == "reviewer"
        )
        #expect(
            OpenCodeSessionInputAgentResolver.agentID(
                for: .prompt("hello"),
                selectedAgentID: "build",
                commands: commands
            ) == "build"
        )
    }

    @Test("Attachments finishing after shell mode starts are rejected")
    func lateShellAttachments() {
        let attachment = OpenCodePromptAttachment(
            filename: "late.txt",
            mimeType: "text/plain",
            data: Data("late".utf8)
        )

        do {
            _ = try OpenCodeSessionAttachmentPolicy.appending(
                [attachment],
                to: [],
                mode: .shell
            )
            Issue.record("Expected shell mode to reject the late attachment")
        } catch let error as OpenCodeSessionInputError {
            #expect(error == .shellAttachmentsUnavailable)
        } catch {
            Issue.record("Expected an input policy error, got \(error)")
        }
    }
}

@MainActor
@Suite(.serialized)
struct OpenCodeSessionInputStoreTests {
    @Test("Shell validation rejects submission after its selected agent disappears")
    func shellValidationRequiresCurrentAgent() async {
        let service = MockSessionInputService(
            capabilities: .v1,
            commands: [],
            agents: []
        )
        let store = OpenCodeSessionInputStore(
            service: service,
            directory: "/repo",
            workspace: nil,
            initialAgentID: nil
        )
        await store.load()

        #expect(!store.validate(.shell("git status")))
        #expect(
            store.errorMessage
                == OpenCodeSessionInputError.shellAgentRequired.localizedDescription
        )
    }

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

    @Test("Slash text cannot bypass a command catalog that has not loaded")
    func slashTextWaitsForCatalog() async {
        let command = OpenCodeCommandOption(
            name: "review",
            description: nil,
            template: "Review",
            source: nil,
            agent: nil,
            subtask: nil,
            hints: []
        )
        let service = MockSessionInputService(
            capabilities: .v1,
            commands: [command],
            agents: []
        )
        let store = OpenCodeSessionInputStore(
            service: service,
            directory: "/repo",
            workspace: nil,
            initialAgentID: nil
        )

        #expect(!store.validate(.prompt("/review staged"), sourceText: "/review staged"))
        #expect(!store.hasLoadedCommandCatalog)

        await store.load()

        #expect(store.hasLoadedCommandCatalog)
        #expect(store.validate(.command(name: "review", arguments: "staged"), sourceText: "/review staged"))
        #expect(store.validate(.prompt("/unknown literal"), sourceText: "/unknown literal"))
    }

    @Test("Pull-to-refresh retries a failed command catalog")
    func refreshRetriesCommandCatalog() async {
        let service = MockSessionInputService(
            capabilities: .v1,
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
            agents: [],
            commandFailuresRemaining: 1
        )
        let store = OpenCodeSessionInputStore(
            service: service,
            directory: "/repo",
            workspace: nil,
            initialAgentID: nil
        )

        await store.load()
        #expect(!store.hasLoadedCommandCatalog)

        await store.refresh()

        #expect(store.hasLoadedCommandCatalog)
        #expect(store.validate(.command(name: "review", arguments: ""), sourceText: "/review"))
    }

    @Test("A hidden or subagent session agent is never replaced implicitly")
    func preservesSubagentSessionSelection() async {
        let service = MockSessionInputService(
            capabilities: .v2,
            commands: [],
            agents: [
                OpenCodeAgentOption(id: "build", description: nil, mode: "primary", hidden: false),
                OpenCodeAgentOption(id: "helper", description: nil, mode: "subagent", hidden: false),
            ]
        )
        let store = OpenCodeSessionInputStore(
            service: service,
            directory: "/repo",
            workspace: nil,
            initialAgentID: "helper"
        )

        await store.load()

        #expect(store.selectedAgentID == "helper")
        #expect(store.selectedAgent == nil)
    }

    @Test("A preserved subagent remains the submission and shell agent")
    func preservedSubagentRemainsSubmittable() async {
        let service = MockSessionInputService(
            capabilities: .v1,
            commands: [],
            agents: [
                OpenCodeAgentOption(id: "build", description: nil, mode: "primary", hidden: false),
                OpenCodeAgentOption(id: "helper", description: nil, mode: "subagent", hidden: false),
            ]
        )
        let store = OpenCodeSessionInputStore(
            service: service,
            directory: "/repo",
            workspace: nil,
            initialAgentID: "helper"
        )

        await store.load()

        #expect(store.selectedAgent == nil)
        #expect(store.submissionAgentID == "helper")
        #expect(store.agentPresentationValue == "helper")
        #expect(store.validate(.prompt("continue")))
        #expect(store.validate(.shell("git status")))
        #expect(store.prepareShellMode())
    }

    @Test("A failed catalog refresh preserves the last trusted commands and agents")
    func failedRefreshPreservesCatalogs() async {
        let command = OpenCodeCommandOption(
            name: "review",
            description: nil,
            template: "Review",
            source: nil,
            agent: nil,
            subtask: nil,
            hints: []
        )
        let agent = OpenCodeAgentOption(
            id: "build",
            description: nil,
            mode: "primary",
            hidden: false
        )
        let service = MockSessionInputService(
            capabilities: .v1,
            commands: [command],
            agents: [agent]
        )
        let store = OpenCodeSessionInputStore(
            service: service,
            directory: "/repo",
            workspace: nil,
            initialAgentID: "build"
        )
        await store.load()
        service.failNextCatalogRefresh()

        await store.refresh()

        #expect(store.hasLoadedCommandCatalog)
        #expect(store.commands == [command])
        #expect(store.agents == [agent])
        #expect(store.selectedAgent?.id == "build")
        #expect(store.errorMessage != nil)
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
    nonisolated(unsafe) private var commandFailuresRemaining: Int
    nonisolated(unsafe) private var agentFailuresRemaining = 0

    init(
        capabilities: OpenCodeProtocolCapabilities,
        commands: [OpenCodeCommandOption],
        agents: [OpenCodeAgentOption],
        commandFailuresRemaining: Int = 0
    ) {
        self.capabilities = capabilities
        self.commands = commands
        self.agents = agents
        self.commandFailuresRemaining = commandFailuresRemaining
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
        if takeCommandFailure() { throw MockSessionInputError.commandCatalogUnavailable }
        return commands
    }

    func agents(directory: String, workspace: String?) async throws -> [OpenCodeAgentOption] {
        record(.agents)
        if takeAgentFailure() { throw MockSessionInputError.agentCatalogUnavailable }
        return agents
    }

    func failNextCatalogRefresh() {
        lock.lock()
        commandFailuresRemaining += 1
        agentFailuresRemaining += 1
        lock.unlock()
    }

    private func record(_ step: Step) {
        lock.lock()
        recordedSteps.append(step)
        lock.unlock()
    }

    private func takeCommandFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard commandFailuresRemaining > 0 else { return false }
        commandFailuresRemaining -= 1
        return true
    }

    private func takeAgentFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard agentFailuresRemaining > 0 else { return false }
        agentFailuresRemaining -= 1
        return true
    }
}

private enum MockSessionInputError: Error {
    case commandCatalogUnavailable
    case agentCatalogUnavailable
}
