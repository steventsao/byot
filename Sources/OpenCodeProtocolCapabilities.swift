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

    static let v1 = Self(
        sessionDiff: .supported,
        symbolSearch: .supported,
        providerConnectionState: .supported,
        modelReasoningMetadata: .supported,
        modelTemperatureMetadata: .supported
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
        )
    )
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
