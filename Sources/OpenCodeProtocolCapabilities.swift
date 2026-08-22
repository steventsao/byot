import Foundation

enum OpenCodeFeatureSupport: Equatable, Sendable {
    case supported
    case unavailable(reason: String)

    var isSupported: Bool {
        self == .supported
    }

    var unavailableReason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

struct OpenCodeServerContextCapabilities: Equatable, Sendable {
    let configurationRead: OpenCodeFeatureSupport
    let configurationWrite: OpenCodeFeatureSupport
    let vcs: OpenCodeFeatureSupport
    let paths: OpenCodeFeatureSupport
    let mcp: OpenCodeFeatureSupport
    let lsp: OpenCodeFeatureSupport
    let formatter: OpenCodeFeatureSupport
}

struct OpenCodeProtocolCapabilities: Equatable, Sendable {
    let sessionDiff: OpenCodeFeatureSupport
    let symbolSearch: OpenCodeFeatureSupport
    let providerConnectionState: OpenCodeFeatureSupport
    let providerConnectionCatalog: OpenCodeFeatureSupport
    let providerKeyAuthentication: OpenCodeFeatureSupport
    let providerOAuthAuthentication: OpenCodeFeatureSupport
    let providerOAuthCancellation: OpenCodeFeatureSupport
    let modelReasoningMetadata: OpenCodeFeatureSupport
    let modelTemperatureMetadata: OpenCodeFeatureSupport
    let sessionDetails: OpenCodeFeatureSupport
    let sessionSharing: OpenCodeFeatureSupport
    let serverContext: OpenCodeServerContextCapabilities
    let sessionRename: OpenCodeFeatureSupport
    let sessionDelete: OpenCodeFeatureSupport
    let sessionChildren: OpenCodeFeatureSupport
    let sessionAbort: OpenCodeFeatureSupport
    let sessionTodos: OpenCodeFeatureSupport
    let sessionRevert: OpenCodeFeatureSupport
    let sessionUnrevert: OpenCodeFeatureSupport
    let sessionSummarize: OpenCodeFeatureSupport
    let sessionFork: OpenCodeFeatureSupport
    let sessionSummarizeRequiresModel: Bool
    let fileTree: OpenCodeFeatureSupport
    let fileRead: OpenCodeFeatureSupport
    let fileStatus: OpenCodeFeatureSupport
    let fileSearch: OpenCodeFeatureSupport
    let commandCatalog: OpenCodeFeatureSupport
    let commandExecution: OpenCodeFeatureSupport
    let shellExecution: OpenCodeFeatureSupport
    let agentCatalog: OpenCodeFeatureSupport
    let agentSelection: OpenCodeFeatureSupport

    static let v1 = Self(
        sessionDiff: .supported,
        symbolSearch: .supported,
        providerConnectionState: .supported,
        providerConnectionCatalog: .supported,
        providerKeyAuthentication: .supported,
        providerOAuthAuthentication: .supported,
        providerOAuthCancellation: .unavailable(
            reason: "OpenCode v1 does not expose an OAuth cancellation route."
        ),
        modelReasoningMetadata: .supported,
        modelTemperatureMetadata: .supported,
        sessionDetails: .supported,
        sessionSharing: .supported,
        serverContext: OpenCodeServerContextCapabilities(
            configurationRead: .supported,
            configurationWrite: .supported,
            vcs: .supported,
            paths: .supported,
            mcp: .supported,
            lsp: .supported,
            formatter: .supported
        ),
        sessionRename: .supported,
        sessionDelete: .supported,
        sessionChildren: .supported,
        sessionAbort: .supported,
        sessionTodos: .supported,
        sessionRevert: .supported,
        sessionUnrevert: .supported,
        sessionSummarize: .supported,
        sessionFork: .supported,
        sessionSummarizeRequiresModel: true,
        fileTree: .supported,
        fileRead: .supported,
        fileStatus: .supported,
        fileSearch: .supported,
        commandCatalog: .supported,
        commandExecution: .supported,
        shellExecution: .supported,
        agentCatalog: .supported,
        agentSelection: .supported
    )

    static let v2 = Self(
        sessionDiff: .unavailable(
            reason: "OpenCode v2 does not expose a per-session diff route yet."
        ),
        symbolSearch: .unavailable(
            reason: "OpenCode v2 file search does not expose workspace symbols yet."
        ),
        providerConnectionState: .unavailable(
            reason: "OpenCode v2 does not report whether a provider is connected."
        ),
        providerConnectionCatalog: .supported,
        providerKeyAuthentication: .supported,
        providerOAuthAuthentication: .supported,
        providerOAuthCancellation: .supported,
        modelReasoningMetadata: .unavailable(
            reason: "OpenCode v2 does not report the model reasoning capability."
        ),
        modelTemperatureMetadata: .unavailable(
            reason: "OpenCode v2 does not report the model temperature capability."
        ),
        sessionDetails: .supported,
        sessionSharing: .unavailable(
            reason: "OpenCode v2 does not expose session share or unshare routes yet."
        ),
        serverContext: OpenCodeServerContextCapabilities(
            configurationRead: .unavailable(
                reason: "OpenCode v2 does not expose a configuration read route yet."
            ),
            configurationWrite: .unavailable(
                reason: "OpenCode v2 does not expose a configuration update route yet."
            ),
            vcs: .unavailable(
                reason: "OpenCode v2 does not expose VCS status yet."
            ),
            paths: .supported,
            mcp: .unavailable(
                reason: "OpenCode v2 does not expose MCP status yet."
            ),
            lsp: .unavailable(
                reason: "OpenCode v2 does not expose LSP status yet."
            ),
            formatter: .unavailable(
                reason: "OpenCode v2 does not expose formatter status yet."
            )
        ),
        sessionRename: .unavailable(
            reason: "OpenCode v2 does not expose a session rename route yet."
        ),
        sessionDelete: .unavailable(
            reason: "OpenCode v2 does not expose a session delete route yet."
        ),
        sessionChildren: .unavailable(
            reason: "OpenCode v2 does not expose a child-session route yet."
        ),
        sessionAbort: .supported,
        sessionTodos: .unavailable(
            reason: "OpenCode v2 does not expose a session todo route yet."
        ),
        sessionRevert: .supported,
        sessionUnrevert: .supported,
        sessionSummarize: .supported,
        sessionFork: .unavailable(
            reason: "OpenCode v2 does not expose a session fork route yet."
        ),
        sessionSummarizeRequiresModel: false,
        fileTree: .unavailable(
            reason: "OpenCode v2 does not expose a directory listing route yet."
        ),
        fileRead: .unavailable(
            reason: "OpenCode v2 does not expose a file content route yet."
        ),
        fileStatus: .unavailable(
            reason: "OpenCode v2 does not expose a changed-file status route yet."
        ),
        fileSearch: .supported,
        commandCatalog: .supported,
        commandExecution: .unavailable(
            reason: "OpenCode v2 does not expose a command execution route yet."
        ),
        shellExecution: .unavailable(
            reason: "OpenCode v2 does not expose a session shell route yet."
        ),
        agentCatalog: .supported,
        agentSelection: .supported
    )
}

struct OpenCodeFeatureUnavailableError: LocalizedError, Equatable, Sendable {
    let feature: String
    let reason: String

    var errorDescription: String? {
        "\(feature) is unavailable: \(reason)"
    }
}

struct OpenCodeSessionDiffPresentation: Equatable, Sendable {
    let diffs: [OpenCodeDiff]
    private let support: OpenCodeFeatureSupport?

    init(diffs: [OpenCodeDiff], support: OpenCodeFeatureSupport?) {
        self.diffs = diffs
        self.support = support
    }

    var canPresent: Bool {
        !diffs.isEmpty || unavailableReason != nil
    }

    var unavailableReason: String? {
        guard diffs.isEmpty else { return nil }
        return support?.unavailableReason
    }
}

enum OpenCodeSessionDiffReconciliation {
    static func shouldApplyFetchedSnapshot(
        support: OpenCodeFeatureSupport?,
        mutationBaseline: Int,
        currentMutation: Int
    ) -> Bool {
        support?.isSupported == true && mutationBaseline == currentMutation
    }
}
