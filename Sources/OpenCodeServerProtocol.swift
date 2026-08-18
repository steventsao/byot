import Foundation

enum OpenCodeServerProtocol: String, Equatable, Sendable {
    case v1
    case v2
}

struct OpenCodeServerProbe: Equatable, Sendable {
    let `protocol`: OpenCodeServerProtocol
    let health: OpenCodeHealth
}

// Mirrors the desktop app's detectServerProtocol (packages/app/src/utils/
// server-protocol.ts): probe /global/health first, then /api/health, and only
// trust responses that are actually JSON. OpenCode 2 serves its web UI with a
// 200 text/html fallback on every legacy v1 route, so a status code alone
// proves nothing (#12, #19).
struct OpenCodeProtocolDetector: Sendable {
    let client: OpenCodeClient

    func probe() async throws -> OpenCodeServerProbe {
        if let legacy = try await client.probeJSON(["global", "health"]),
           let version = legacy["version"] as? String {
            return OpenCodeServerProbe(
                protocol: .v1,
                health: OpenCodeHealth(
                    healthy: legacy["healthy"] as? Bool ?? false,
                    version: version
                )
            )
        }
        if let current = try await client.probeJSON(["api", "health"]) {
            let healthy = current["healthy"] as? Bool ?? false
            let version = current["version"] as? String ?? "unknown"
            // A numeric pid is the v2 discriminator; a bare healthy:true
            // without pid matches the legacy health shape.
            if current["pid"] is NSNumber {
                return OpenCodeServerProbe(
                    protocol: .v2,
                    health: OpenCodeHealth(healthy: healthy, version: version)
                )
            }
            if healthy {
                return OpenCodeServerProbe(
                    protocol: .v1,
                    health: OpenCodeHealth(healthy: true, version: version)
                )
            }
            return OpenCodeServerProbe(
                protocol: .v2,
                health: OpenCodeHealth(healthy: healthy, version: version)
            )
        }
        throw OpenCodeConnectionError.invalidResponse
    }
}
