import Foundation

enum OpenCodeServerProtocol: String, Equatable, Sendable {
    case v1
    case v2
}

struct OpenCodeServerProbe: Equatable, Sendable {
    let `protocol`: OpenCodeServerProtocol
    let health: OpenCodeHealth
}

// Probe /global/health first, then /api/health, and only trust responses that
// are actually JSON. The current v2 protocol contract returns only
// {healthy:true}; older betas also included pid/version and briefly wrapped the
// payload in {data:...}. A valid /api/health response is therefore v2 whenever
// the legacy health route is absent (#12, #13, #19).
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
            let payload = current["data"] as? [String: Any] ?? current
            guard let healthy = payload["healthy"] as? Bool else {
                throw OpenCodeConnectionError.invalidResponse
            }
            let version = payload["version"] as? String ?? "v2"
            return OpenCodeServerProbe(
                protocol: .v2,
                health: OpenCodeHealth(healthy: healthy, version: version)
            )
        }
        throw OpenCodeConnectionError.invalidResponse
    }
}
