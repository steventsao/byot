import Foundation

enum OpenCodeCompatibility: Equatable, Sendable {
    case compatible(isVerifiedBaseline: Bool)
    case degraded(reason: String)
    case unsupported(reason: String)
}

enum OpenCodeCompatibilityEvaluator {
    // Contract baseline pinned by issue #71: this client was verified end to end
    // against the installed OpenCode CLI and @opencode-ai/sdk 1.18.10.
    static let verifiedBaseline = OpenCodeServerVersion(major: 1, minor: 18, patch: 10)

    // Conservative floor: this client's contract (legacy project/session/event
    // routes with selective v2 fallbacks, plus /global/health and
    // /experimental/capabilities negotiation) is only proven across the 1.18.x
    // line, so 1.18.0 is the minimum. 1.18.0–1.18.9 are degraded but usable
    // after the core project route succeeds; 1.17.x and older are rejected
    // instead of probed per feature with 404s.
    static let minimumSupported = OpenCodeServerVersion(major: 1, minor: 18, patch: 0)

    static func evaluate(health: OpenCodeHealth) -> OpenCodeCompatibility {
        guard health.healthy else {
            return .unsupported(
                reason: "OpenCode reported an unhealthy status. Restart the OpenCode server on your Mac and try again."
            )
        }
        guard let version = OpenCodeServerVersion(parsing: health.version) else {
            return .degraded(
                reason: "OpenCode reported an unrecognized version “\(health.version)”, so compatibility cannot be verified. Core chat remains available."
            )
        }
        guard version >= minimumSupported else {
            return .unsupported(
                reason: "OpenCode \(version) is older than the minimum supported \(minimumSupported). Upgrade the OpenCode CLI on your Mac to \(verifiedBaseline) or later."
            )
        }
        if version == verifiedBaseline {
            return .compatible(isVerifiedBaseline: true)
        }
        if version > verifiedBaseline {
            return .compatible(isVerifiedBaseline: false)
        }
        return .degraded(
            reason: "OpenCode \(version) is older than the verified \(verifiedBaseline) baseline. Core chat remains available, but some behaviors may differ."
        )
    }
}
