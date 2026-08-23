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

struct OpenCodeProtocolCapabilities: Equatable, Sendable {
    let sessionDiff: OpenCodeFeatureSupport
    let symbolSearch: OpenCodeFeatureSupport
    let providerConnectionState: OpenCodeFeatureSupport
    let modelReasoningMetadata: OpenCodeFeatureSupport
    let modelTemperatureMetadata: OpenCodeFeatureSupport
    let sessionDetails: OpenCodeFeatureSupport
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

    static let v1 = Self(
        sessionDiff: .supported,
        symbolSearch: .supported,
        providerConnectionState: .supported,
        modelReasoningMetadata: .supported,
        modelTemperatureMetadata: .supported,
        sessionDetails: .supported,
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
        fileSearch: .supported
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
        modelReasoningMetadata: .unavailable(
            reason: "OpenCode v2 does not report the model reasoning capability."
        ),
        modelTemperatureMetadata: .unavailable(
            reason: "OpenCode v2 does not report the model temperature capability."
        ),
        sessionDetails: .supported,
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
        fileSearch: .supported
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
