#if DEBUG
import Foundation
import SwiftUI

/// UI-test and screenshot harness: the project status screen over an in-memory server
/// with a branch, uncommitted changes, MCP servers in every state, a language server,
/// formatters, plugins, a configuration carrying secrets that must stay hidden, and
/// editable server settings.
struct OpenCodeProjectStatusHarness: View {
    var body: some View {
        NavigationStack {
            OpenCodeProjectStatusScreen(
                service: OpenCodeProjectStatusFixtureService(),
                route: OpenCodeProjectStatusRoute(directory: "/Users/dev/byot", projectName: "byot")
            )
        }
    }
}

actor OpenCodeProjectStatusFixtureService: OpenCodeServerContextServicing {
    private var mcp = [
        OpenCodeMCPServer(name: "github", state: .connected),
        OpenCodeMCPServer(name: "linear", state: .needsAuthentication),
        OpenCodeMCPServer(name: "postgres", state: .failed, error: "MCP error -32000: Connection closed"),
        OpenCodeMCPServer(name: "sentry", state: .disabled),
    ]

    /// The global config as stored, so saved settings read back the way a server merges them.
    private var globalConfig: [String: OpenCodeJSONValue] = [
        "$schema": .string("https://opencode.ai/config.json"),
        "model": .string("anthropic/claude-sonnet-4-5"),
        "share": .string("manual"),
        "provider": .object(["anthropic": .object(["options": .object(["apiKey": .string("sk-ant-fixture-secret")])])]),
    ]

    func capabilities() async throws -> OpenCodeServerContextCapabilities { .v1 }

    func serverSettings() async throws -> OpenCodeServerSettings { OpenCodeServerSettings(globalConfig) }

    func updateServerSettings(_ patch: [String: OpenCodeJSONValue]) async throws -> OpenCodeServerSettings {
        try await Task.sleep(for: .milliseconds(400))
        for (key, value) in patch {
            globalConfig[key] = value == .null || (key == "shell" && value == .string("")) ? nil : value
        }
        return OpenCodeServerSettings(globalConfig)
    }

    func serverSettingsOptions() async throws -> OpenCodeServerSettingsOptions {
        func model(_ provider: String, _ providerName: String, _ id: String, _ name: String) -> OpenCodeModelOption {
            OpenCodeModelOption(providerID: provider, providerName: providerName, modelID: id, modelName: name, status: nil)
        }
        return OpenCodeServerSettingsOptions(
            providers: [
                OpenCodeProviderModels(providerID: "anthropic", providerName: "Anthropic", models: [
                    model("anthropic", "Anthropic", "claude-haiku-4-5", "Claude Haiku 4.5"),
                    model("anthropic", "Anthropic", "claude-opus-4-1", "Claude Opus 4.1"),
                    model("anthropic", "Anthropic", "claude-sonnet-4-5", "Claude Sonnet 4.5"),
                ]),
                OpenCodeProviderModels(providerID: "openai", providerName: "OpenAI", models: [
                    model("openai", "OpenAI", "gpt-5", "GPT-5"),
                    model("openai", "OpenAI", "gpt-5-mini", "GPT-5 mini"),
                ]),
            ],
            agents: [
                OpenCodeAgentOption(id: "build", name: "build", description: "Default agent with every tool"),
                OpenCodeAgentOption(id: "plan", name: "plan", description: "Plans without editing files"),
            ])
    }

    func paths() async throws -> OpenCodeProjectPaths {
        OpenCodeProjectPaths(directory: "/Users/dev/byot", worktree: "/Users/dev/byot", home: "/Users/dev",
                             config: "/Users/dev/.config/opencode", state: "/Users/dev/.local/state/opencode")
    }

    func branch() async throws -> OpenCodeVcsBranch {
        OpenCodeVcsBranch(current: "feature/project-status", defaultBranch: "main")
    }

    func changes() async throws -> [OpenCodeProjectFileChange] {
        [
            OpenCodeProjectFileChange(path: "Sources/OpenCodeServerContext.swift", status: .added, additions: 412),
            OpenCodeProjectFileChange(path: "Sources/OpenCodeSessionView.swift", status: .modified, additions: 38, deletions: 6),
            OpenCodeProjectFileChange(path: "docs/old-notes.md", status: .deleted, deletions: 21),
        ]
    }

    func mcpServers() async throws -> [OpenCodeMCPServer] { mcp }

    func setMCPServer(_ name: String, connected: Bool) async throws {
        try await Task.sleep(for: .milliseconds(400))
        guard let index = mcp.firstIndex(where: { $0.name == name }) else { return }
        // postgres keeps failing, as a server whose process can't start would.
        if name == "postgres" && connected { return }
        mcp[index].state = connected ? .connected : .disabled
        mcp[index].error = nil
    }

    func languageServers() async throws -> [OpenCodeLSPServer] {
        [
            OpenCodeLSPServer(id: "sourcekit-lsp", name: "SourceKit-LSP", root: "/Users/dev/byot"),
            OpenCodeLSPServer(id: "typescript", name: "TypeScript", root: "/Users/dev/byot/web", isConnected: false),
        ]
    }

    func formatters() async throws -> [OpenCodeFormatterStatus] {
        OpenCodeFormatterStatus.sorted([
            OpenCodeFormatterStatus(name: "prettier", extensions: [".ts", ".tsx", ".json", ".md"], enabled: true),
            OpenCodeFormatterStatus(name: "swift-format", extensions: [".swift"], enabled: true),
            OpenCodeFormatterStatus(name: "ruff", extensions: [".py", ".pyi"], enabled: false),
            OpenCodeFormatterStatus(name: "rustfmt", extensions: [".rs"], enabled: false),
        ])
    }

    func configuration() async throws -> OpenCodeServerConfiguration {
        .v1([
            "$schema": .string("https://opencode.ai/config.json"),
            "model": .string("anthropic/claude-sonnet-4-5"),
            "small_model": .string("anthropic/claude-haiku-4-5"),
            "default_agent": .string("build"),
            "share": .string("manual"),
            "autoupdate": .bool(true),
            "plugin": .array([.string("opencode-wakatime@1.2.0"), .string("file:///Users/dev/.config/opencode/plugins/notify.js")]),
            "provider": .object(["anthropic": .object([
                "name": .string("Anthropic"),
                "options": .object(["apiKey": .string("sk-ant-fixture-secret")]),
            ])]),
            "mcp": .object(["github": .object([
                "type": .string("remote"), "url": .string("https://api.githubcopilot.com/mcp/"),
                "headers": .object(["Authorization": .string("Bearer fixture-secret")]),
            ])]),
        ])
    }
}
#endif
