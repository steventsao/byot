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
}

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
