import Foundation

struct OpenCodeCapabilities: Decodable, Equatable, Sendable {
    let backgroundSubagents: Bool

    var advertisedIdentifiers: [String] {
        backgroundSubagents ? ["backgroundSubagents"] : []
    }
}

enum OpenCodeCapabilityProbeResult: Equatable, Sendable {
    case available(OpenCodeCapabilities)
    case unavailable
}
