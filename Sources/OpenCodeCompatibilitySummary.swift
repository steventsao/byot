import Foundation

enum OpenCodeCompatibilityState: String, Codable, Sendable {
    case compatible
    case degraded
    case unsupported
}

struct OpenCodeCompatibilitySummary: Codable, Equatable, Sendable {
    var state: OpenCodeCompatibilityState
    var serverVersion: String?
    var isVerifiedBaseline: Bool
    var capabilitiesAvailable: Bool
    var advertisedCapabilities: [String]
    var detail: String?

    init(
        verdict: OpenCodeCompatibility,
        health: OpenCodeHealth,
        capabilityProbe: OpenCodeCapabilityProbeResult
    ) {
        serverVersion = health.version
        switch verdict {
        case .compatible(let isVerifiedBaseline):
            state = .compatible
            self.isVerifiedBaseline = isVerifiedBaseline
            detail = isVerifiedBaseline
                ? nil
                : "OpenCode \(health.version) is newer than the verified \(OpenCodeCompatibilityEvaluator.verifiedBaseline) baseline."
        case .degraded(let reason):
            state = .degraded
            isVerifiedBaseline = false
            detail = reason
        case .unsupported(let reason):
            state = .unsupported
            isVerifiedBaseline = false
            detail = reason
        }
        switch capabilityProbe {
        case .available(let capabilities):
            capabilitiesAvailable = true
            advertisedCapabilities = capabilities.advertisedIdentifiers
        case .unavailable:
            capabilitiesAvailable = false
            advertisedCapabilities = []
        }
    }

    var stateTitle: String {
        switch state {
        case .compatible:
            isVerifiedBaseline ? "Compatible (verified baseline)" : "Compatible (newer, unverified)"
        case .degraded:
            "Degraded (usable with limits)"
        case .unsupported:
            "Unsupported"
        }
    }

    var redactedSummary: String {
        var parts = ["OpenCode \(serverVersion ?? "unknown version")", stateTitle]
        if let detail, !detail.isEmpty {
            parts.append(detail)
        }
        if capabilitiesAvailable {
            if advertisedCapabilities.isEmpty {
                parts.append("capabilities: advertised")
            } else {
                let shown = advertisedCapabilities.prefix(6).joined(separator: ", ")
                let remaining = advertisedCapabilities.count - 6
                parts.append(
                    remaining > 0
                        ? "capabilities: \(shown), +\(remaining) more"
                        : "capabilities: \(shown)"
                )
            }
        } else {
            parts.append("capabilities: unavailable")
        }
        return parts.joined(separator: " · ")
    }
}
