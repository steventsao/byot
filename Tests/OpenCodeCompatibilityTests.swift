import Foundation
import Testing
@testable import byot

@Suite(.serialized)
struct OpenCodeCompatibilityTests {
    @Test("Health payload decodes the /global/health contract shape")
    func healthDecoding() throws {
        let health = try JSONDecoder().decode(
            OpenCodeHealth.self,
            from: Data(#"{"healthy":true,"version":"1.18.10"}"#.utf8)
        )

        #expect(health.healthy)
        #expect(health.version == "1.18.10")
    }

    @Test("Pinned 1.18.10 baseline is compatible and verified")
    func verifiedBaseline() {
        let verdict = OpenCodeCompatibilityEvaluator.evaluate(
            health: OpenCodeHealth(healthy: true, version: "1.18.10")
        )

        #expect(verdict == .compatible(isVerifiedBaseline: true))
        #expect(OpenCodeServerVersion(parsing: "v1.18.10") == OpenCodeCompatibilityEvaluator.verifiedBaseline)
    }

    @Test("Build metadata does not affect precedence; 1.18.10+build.1 is the verified baseline")
    func buildMetadataIgnored() {
        let withBuild = OpenCodeServerVersion(parsing: "1.18.10+build.1")
        #expect(withBuild == OpenCodeCompatibilityEvaluator.verifiedBaseline)
        #expect(withBuild?.description == "1.18.10")

        let verdict = OpenCodeCompatibilityEvaluator.evaluate(
            health: OpenCodeHealth(healthy: true, version: "1.18.10+build.1")
        )
        #expect(verdict == .compatible(isVerifiedBaseline: true))
    }

    @Test("A prerelease of the baseline is lower than stable and degrades")
    func prereleaseBelowStableDegrades() throws {
        let beta = try #require(OpenCodeServerVersion(parsing: "1.18.10-beta.3"))
        #expect(beta != OpenCodeCompatibilityEvaluator.verifiedBaseline)
        #expect(beta < OpenCodeCompatibilityEvaluator.verifiedBaseline)
        #expect(beta.description == "1.18.10-beta.3")

        let verdict = OpenCodeCompatibilityEvaluator.evaluate(
            health: OpenCodeHealth(healthy: true, version: "1.18.10-beta.3")
        )
        guard case .degraded(let reason) = verdict else {
            Issue.record("Expected degraded for 1.18.10-beta.3, got \(verdict)")
            return
        }
        #expect(reason.contains("1.18.10-beta.3"))
    }

    @Test("Prerelease identifiers compare per SemVer")
    func prereleaseOrdering() throws {
        let ordered = [
            "1.18.10-alpha",
            "1.18.10-alpha.1",
            "1.18.10-alpha.beta",
            "1.18.10-beta",
            "1.18.10-beta.2",
            "1.18.10-beta.11",
            "1.18.10-rc.1",
            "1.18.10",
        ]
        let versions = try ordered.map { raw in
            try #require(OpenCodeServerVersion(parsing: raw))
        }
        for (lower, higher) in zip(versions, versions.dropFirst()) {
            #expect(lower < higher)
            #expect(higher > lower)
        }

        let numeric = try #require(OpenCodeServerVersion(parsing: "1.18.10-1"))
        let alphabetic = try #require(OpenCodeServerVersion(parsing: "1.18.10-alpha"))
        #expect(numeric < alphabetic)
        #expect(OpenCodeServerVersion(parsing: "1.18.10+b1") == OpenCodeServerVersion(parsing: "1.18.10+b2"))
        #expect(OpenCodeServerVersion(parsing: "1.18.10-") == nil)
    }

    @Test("Parser rejects malformed SemVer forms conservatively")
    func malformedParsingRejected() throws {
        for raw in [
            "01.18.10",
            "1.01.10",
            "1.18.01",
            "1.18.10-beta.01",
            "1.18.10-01",
            "1.18.10-a..b",
            "1.18.10+",
            "1.18.10+bad meta",
            "1.18.10+b1+b2",
            "1.18.10+a..b",
            "1.18.10+é",
        ] {
            #expect(OpenCodeServerVersion(parsing: raw) == nil, "expected \(raw.debugDescription) to be rejected")
        }

        #expect(try #require(OpenCodeServerVersion(parsing: "1.18.10-0")).prerelease == ["0"])
        #expect(try #require(OpenCodeServerVersion(parsing: "0.0.0")).major == 0)
        #expect(try #require(OpenCodeServerVersion(parsing: "1.18.10+001")).description == "1.18.10")
    }

    @Test("Newer versions stay compatible but are flagged unverified")
    func newerVersionsCompatibleUnverified() {
        for raw in ["1.19.0", "2.0.0"] {
            let verdict = OpenCodeCompatibilityEvaluator.evaluate(
                health: OpenCodeHealth(healthy: true, version: raw)
            )
            #expect(verdict == .compatible(isVerifiedBaseline: false))

            let summary = OpenCodeCompatibilitySummary(
                verdict: verdict,
                health: OpenCodeHealth(healthy: true, version: raw),
                capabilityProbe: .unavailable
            )
            #expect(summary.state == .compatible)
            #expect(summary.isVerifiedBaseline == false)
            #expect(summary.detail?.contains("newer") == true)
        }
    }

    @Test("1.18.0 through 1.18.9 degrade instead of blocking")
    func olderSupportedVersionsDegrade() {
        for raw in ["1.18.0", "1.18.9"] {
            let verdict = OpenCodeCompatibilityEvaluator.evaluate(
                health: OpenCodeHealth(healthy: true, version: raw)
            )
            guard case .degraded(let reason) = verdict else {
                Issue.record("Expected degraded for \(raw), got \(verdict)")
                continue
            }
            #expect(reason.contains(raw))
            #expect(reason.contains("1.18.10"))
        }
    }

    @Test("1.17.x and older are unsupported below the conservative minimum")
    func belowMinimumUnsupported() {
        for raw in ["1.17.9", "1.0.0", "0.9.9"] {
            let verdict = OpenCodeCompatibilityEvaluator.evaluate(
                health: OpenCodeHealth(healthy: true, version: raw)
            )
            guard case .unsupported(let reason) = verdict else {
                Issue.record("Expected unsupported for \(raw), got \(verdict)")
                continue
            }
            #expect(reason.contains(raw))
            #expect(reason.contains("1.18.0"))
        }
    }

    @Test("Unhealthy servers are unsupported")
    func unhealthyUnsupported() {
        let verdict = OpenCodeCompatibilityEvaluator.evaluate(
            health: OpenCodeHealth(healthy: false, version: "1.18.10")
        )

        guard case .unsupported = verdict else {
            Issue.record("Expected unsupported, got \(verdict)")
            return
        }
    }

    @Test("Malformed versions degrade with an explanation instead of failing hard")
    func malformedVersionDegrades() {
        for raw in ["latest", "1.x.0", "1.18", ""] {
            let verdict = OpenCodeCompatibilityEvaluator.evaluate(
                health: OpenCodeHealth(healthy: true, version: raw)
            )
            guard case .degraded(let reason) = verdict else {
                Issue.record("Expected degraded for \(raw.debugDescription), got \(verdict)")
                continue
            }
            #expect(reason.contains("unrecognized version"))
        }
    }

    @Test("A downgrade from the verified baseline re-evaluates to degraded or unsupported")
    func downgradeBehavior() {
        let baseline = OpenCodeCompatibilityEvaluator.evaluate(
            health: OpenCodeHealth(healthy: true, version: "1.18.10")
        )
        #expect(baseline == .compatible(isVerifiedBaseline: true))

        let patchDowngrade = OpenCodeCompatibilityEvaluator.evaluate(
            health: OpenCodeHealth(healthy: true, version: "1.18.9")
        )
        guard case .degraded(let degradedReason) = patchDowngrade else {
            Issue.record("Expected degraded after patch downgrade, got \(patchDowngrade)")
            return
        }
        #expect(degradedReason.contains("1.18.9"))

        let minorDowngrade = OpenCodeCompatibilityEvaluator.evaluate(
            health: OpenCodeHealth(healthy: true, version: "1.17.0")
        )
        guard case .unsupported = minorDowngrade else {
            Issue.record("Expected unsupported after minor downgrade, got \(minorDowngrade)")
            return
        }
    }

    @Test("Capabilities decode the typed 1.18.10 contract and expose only the allowlist")
    func capabilitiesDecoding() throws {
        let enabled = try JSONDecoder().decode(
            OpenCodeCapabilities.self,
            from: Data(#"{"backgroundSubagents":true}"#.utf8)
        )
        #expect(enabled.backgroundSubagents)
        #expect(enabled.advertisedIdentifiers == ["backgroundSubagents"])

        let disabled = try JSONDecoder().decode(
            OpenCodeCapabilities.self,
            from: Data(#"{"backgroundSubagents":false}"#.utf8)
        )
        #expect(disabled.backgroundSubagents == false)
        #expect(disabled.advertisedIdentifiers == [])

        let withServerExtras = try JSONDecoder().decode(
            OpenCodeCapabilities.self,
            from: Data(
                #"{"backgroundSubagents":false,"routes":["/api/session"],"surprise":"sentinel-value"}"#
                    .utf8
            )
        )
        #expect(withServerExtras.advertisedIdentifiers == [])
    }

    @Test("Capability route absence (404/405) is capability-unavailable, not a failed connection")
    func capabilityAbsenceStaysCompatible() async throws {
        for statusCode in [404, 405] {
            let (client, session) = makeProbeClient(responses: [
                "/global/health": .init(
                    statusCode: 200,
                    body: Data(#"{"healthy":true,"version":"1.18.10"}"#.utf8)
                ),
                "/experimental/capabilities": .init(
                    statusCode: statusCode,
                    body: Data(#"{"message":"unsupported"}"#.utf8)
                ),
            ])
            let summary = try await client.probeCompatibility()
            session.invalidateAndCancel()

            #expect(summary.state == .compatible)
            #expect(summary.isVerifiedBaseline)
            #expect(summary.capabilitiesAvailable == false)
            #expect(summary.advertisedCapabilities.isEmpty)
        }
    }

    @Test("Capability authentication and server errors fail the probe")
    func capabilityErrorsPropagate() async throws {
        for statusCode in [401, 500] {
            let (client, session) = makeProbeClient(responses: [
                "/global/health": .init(
                    statusCode: 200,
                    body: Data(#"{"healthy":true,"version":"1.18.10"}"#.utf8)
                ),
                "/experimental/capabilities": .init(
                    statusCode: statusCode,
                    body: Data(#"{"message":"capability failure"}"#.utf8)
                ),
            ])
            do {
                _ = try await client.probeCompatibility()
                Issue.record("Expected HTTP \(statusCode) capability response to fail the probe")
            } catch let error as OpenCodeConnectionError {
                guard case .httpStatus(statusCode, _) = error else {
                    Issue.record("Expected httpStatus \(statusCode), got \(error)")
                    continue
                }
            }
            session.invalidateAndCancel()
        }
    }

    @Test("Capability decoding errors fail the probe")
    func capabilityDecodingErrorsPropagate() async throws {
        let (client, session) = makeProbeClient(responses: [
            "/global/health": .init(
                statusCode: 200,
                body: Data(#"{"healthy":true,"version":"1.18.10"}"#.utf8)
            ),
            "/experimental/capabilities": .init(
                statusCode: 200,
                body: Data(#"{"backgroundSubagents":"not-a-bool"}"#.utf8)
            ),
        ])
        defer { session.invalidateAndCancel() }

        await #expect(throws: OpenCodeConnectionError.self) {
            try await client.probeCompatibility()
        }
    }

    @Test("Advertised capabilities are recorded in the summary from the fixed allowlist")
    func advertisedCapabilitiesRecorded() async throws {
        let (client, session) = makeProbeClient(responses: [
            "/global/health": .init(
                statusCode: 200,
                body: Data(#"{"healthy":true,"version":"1.18.10"}"#.utf8)
            ),
            "/experimental/capabilities": .init(
                statusCode: 200,
                body: Data(#"{"backgroundSubagents":true,"routes":["/do/not/echo"]}"#.utf8)
            ),
        ])
        defer { session.invalidateAndCancel() }

        let summary = try await client.probeCompatibility()

        #expect(summary.capabilitiesAvailable)
        #expect(summary.advertisedCapabilities == ["backgroundSubagents"])
        #expect(summary.redactedSummary.contains("/do/not/echo") == false)
    }

    @Test("Unsupported health verdict skips the capability route entirely")
    func unsupportedSkipsCapabilityProbe() async throws {
        let (client, session) = makeProbeClient(responses: [
            "/global/health": .init(
                statusCode: 200,
                body: Data(#"{"healthy":true,"version":"1.17.0"}"#.utf8)
            ),
            "/experimental/capabilities": .init(
                statusCode: 500,
                body: Data(#"{"message":"must not mask unsupported"}"#.utf8)
            ),
        ])
        defer { session.invalidateAndCancel() }

        let summary = try await client.probeCompatibility()

        #expect(summary.state == .unsupported)
        #expect(summary.capabilitiesAvailable == false)
        #expect(OpenCodeProbeStub.recordedPaths() == ["/global/health"])
    }

    @Test("Health probe failure still fails the core connection")
    func healthFailureFailsProbe() async throws {
        let (client, session) = makeProbeClient(responses: [
            "/global/health": .init(
                statusCode: 401,
                body: Data(#"{"message":"unauthorized"}"#.utf8)
            ),
        ])
        defer { session.invalidateAndCancel() }

        await #expect(throws: OpenCodeConnectionError.self) {
            try await client.probeCompatibility()
        }
    }

    @Test("Redacted summary never contains credentials, URL, or query strings")
    func redactionExcludesSecrets() {
        let password = "hunter2-sentinel"
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://mac-sentinel.example.test",
            username: "opencode-sentinel"
        )
        let summary = OpenCodeCompatibilitySummary(
            verdict: .degraded(reason: "OpenCode 1.18.5 is older than the verified 1.18.10 baseline."),
            health: OpenCodeHealth(healthy: true, version: "1.18.5"),
            capabilityProbe: .available(
                OpenCodeCapabilities(backgroundSubagents: true)
            )
        )

        let redacted = summary.redactedSummary
        for sentinel in [
            password,
            profile.baseURL,
            "mac-sentinel.example.test",
            profile.username,
            "Authorization",
            "Basic",
            "token=query-sentinel",
        ] {
            #expect(redacted.contains(sentinel) == false)
        }
        #expect(redacted.contains("1.18.5"))
        #expect(redacted.contains("backgroundSubagents"))
    }

    @Test("Persisted profile round-trips non-secret compatibility facts only")
    func profileCompatibilityPersistence() throws {
        let summary = OpenCodeCompatibilitySummary(
            verdict: .compatible(isVerifiedBaseline: true),
            health: OpenCodeHealth(healthy: true, version: "1.18.10"),
            capabilityProbe: .available(
                OpenCodeCapabilities(backgroundSubagents: true)
            )
        )
        var profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://mac.example.test"
        )
        profile.compatibility = summary

        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(OpenCodeServerProfile.self, from: data)
        #expect(decoded.compatibility == summary)

        let legacy = try JSONDecoder().decode(
            OpenCodeServerProfile.self,
            from: Data(
                #"{"id":"\#(profile.id.uuidString)","name":"Mac mini","baseURL":"https://mac.example.test","username":"opencode","directory":""}"#
                    .utf8
            )
        )
        #expect(legacy.compatibility == nil)
    }

    private func makeProbeClient(
        responses: [String: OpenCodeProbeStub.StubbedResponse]
    ) -> (OpenCodeClient, URLSession) {
        OpenCodeProbeStub.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeProbeStub.self]
        let session = URLSession(configuration: configuration)
        let profile = OpenCodeServerProfile(
            name: "Mac mini",
            baseURL: "https://probe.example.test",
            username: "opencode"
        )
        return (
            OpenCodeClient(
                profile: profile,
                password: "probe-secret",
                session: session
            ),
            session
        )
    }
}

private final class OpenCodeProbeStub: URLProtocol, @unchecked Sendable {
    struct StubbedResponse {
        let statusCode: Int
        let body: Data
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var responses: [String: StubbedResponse] = [:]
    nonisolated(unsafe) private static var requestedPaths: [String] = []

    static func reset(_ responses: [String: StubbedResponse]) {
        stateLock.lock()
        self.responses = responses
        requestedPaths = []
        stateLock.unlock()
    }

    static func recordedPaths() -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requestedPaths
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "probe.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.stateLock.lock()
        let stubbed = (request.url?.path).flatMap { Self.responses[$0] }
        if let path = request.url?.path {
            Self.requestedPaths.append(path)
        }
        Self.stateLock.unlock()

        let response = stubbed ?? StubbedResponse(
            statusCode: 404,
            body: Data(#"{"message":"not found"}"#.utf8)
        )
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                  url: url,
                  statusCode: response.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: nil
              )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: OpenCodeConnectionError.invalidResponse
            )
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty {
            client?.urlProtocol(self, didLoad: response.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
