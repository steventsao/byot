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
                : String(localized: "OpenCode \(health.version) is newer than the verified \(OpenCodeCompatibilityEvaluator.verifiedBaseline.description) baseline.")
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
            isVerifiedBaseline ? String(localized: "Compatible (verified baseline)") : String(localized: "Compatible (newer, unverified)")
        case .degraded:
            String(localized: "Degraded (usable with limits)")
        case .unsupported:
            String(localized: "Unsupported")
        }
    }

    var redactedSummary: String {
        var parts = ["OpenCode \(serverVersion ?? String(localized: "unknown version"))", stateTitle]
        if let detail, !detail.isEmpty {
            parts.append(detail)
        }
        if capabilitiesAvailable {
            if advertisedCapabilities.isEmpty {
                parts.append(String(localized: "capabilities: advertised"))
            } else {
                let shown = advertisedCapabilities.prefix(6).joined(separator: ", ")
                let remaining = advertisedCapabilities.count - 6
                parts.append(
                    remaining > 0
                        ? String(localized: "capabilities: \(shown), +\(remaining) more")
                        : String(localized: "capabilities: \(shown)")
                )
            }
        } else {
            parts.append(String(localized: "capabilities: unavailable"))
        }
        return parts.joined(separator: " · ")
    }
}
