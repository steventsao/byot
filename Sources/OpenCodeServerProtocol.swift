import Foundation

enum OpenCodeServerProtocol: String, Equatable, Sendable {
    case v1
    case v2
}

struct OpenCodeServerProbe: Equatable, Sendable {
    let `protocol`: OpenCodeServerProtocol
    let health: OpenCodeHealth
}

// One health-route probe attempt. Non-2xx statuses and non-JSON bodies are
// distinct outcomes (not collapsed to nil) so a failing server produces an
// actionable error — a 401 from the server's basic auth or a fronting proxy
// must read as a credentials problem, not "invalid response".
enum OpenCodeProbeOutcome {
    case object([String: Any])
    case httpError(status: Int)
    case nonJSON(path: String, contentType: String?)
    case undecodable(path: String, contentType: String?)

    var object: [String: Any]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

// Mirrors the desktop app's detectServerProtocol (packages/app/src/utils/
// server-protocol.ts): probe /global/health first, then /api/health, and only
// trust responses that are actually JSON. OpenCode 2 serves its web UI with a
// 200 text/html fallback on every legacy v1 route, so a status code alone
// proves nothing (#12, #19).
struct OpenCodeProtocolDetector: Sendable {
    let client: OpenCodeClient

    func probe() async throws -> OpenCodeServerProbe {
        let legacyOutcome = try await client.probeJSON(["global", "health"])
        if let legacy = legacyOutcome.object,
           let version = legacy["version"] as? String {
            return OpenCodeServerProbe(
                protocol: .v1,
                health: OpenCodeHealth(
                    healthy: legacy["healthy"] as? Bool ?? false,
                    version: version
                )
            )
        }
        let currentOutcome = try await client.probeJSON(["api", "health"])
        if let current = currentOutcome.object.map(Self.unwrapDataEnvelope) {
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
        throw Self.probeFailure(legacy: legacyOutcome, current: currentOutcome)
    }

    // Newer OpenCode 2 builds wrap /api/health in the standard {data: ...}
    // response envelope; accept both the bare and wrapped shapes.
    static func unwrapDataEnvelope(_ object: [String: Any]) -> [String: Any] {
        if let data = object["data"] as? [String: Any],
           data["healthy"] != nil || data["version"] != nil || data["pid"] != nil {
            return data
        }
        return object
    }

    // Prefer the most actionable failure across the two probes: an auth
    // failure beats any other signal, then remaining HTTP errors, then a
    // declared non-JSON content type, then an undecodable body.
    static func probeFailure(
        legacy: OpenCodeProbeOutcome,
        current: OpenCodeProbeOutcome
    ) -> OpenCodeConnectionError {
        let outcomes = [current, legacy]
        for outcome in outcomes {
            if case .httpError(401) = outcome {
                return .httpStatus(401, nil)
            }
        }
        for outcome in outcomes {
            // 404/405 just mean "wrong protocol generation for this route";
            // only surface statuses that fail both routes for other reasons.
            if case .httpError(let status) = outcome, status != 404, status != 405 {
                return .httpStatus(status, nil)
            }
        }
        for outcome in outcomes {
            if case .nonJSON(let path, let contentType) = outcome {
                return .unexpectedContentType(path: path, contentType: contentType)
            }
        }
        for outcome in outcomes {
            if case .undecodable(let path, let contentType) = outcome,
               contentType != nil {
                return .unexpectedContentType(path: path, contentType: contentType)
            }
        }
        return .invalidResponse
    }
}
