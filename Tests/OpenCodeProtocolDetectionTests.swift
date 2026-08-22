import Foundation
import Testing
@testable import byot

@Suite("OpenCode v1/v2 protocol detection (#12, #19)")
struct OpenCodeProtocolDetectionTests {
    @Test("v1 server: JSON /global/health detects v1 and never probes /api/health")
    func detectsV1FromGlobalHealth() async throws {
        let (client, stub) = makeStubbedClient(responses: [
            "/global/health": .json(#"{"healthy":true,"version":"1.18.18"}"#),
        ])

        let probe = try await OpenCodeProtocolDetector(client: client).probe()

        #expect(probe.protocol == .v1)
        #expect(probe.health == OpenCodeHealth(healthy: true, version: "1.18.18"))
        #expect(stub.recordedPaths() == ["/global/health"])
    }

    @Test("v1 server reporting unhealthy still detects v1 so the verdict can explain it")
    func detectsUnhealthyV1() async throws {
        let (client, _) = makeStubbedClient(responses: [
            "/global/health": .json(#"{"healthy":false,"version":"1.18.10"}"#),
        ])

        let probe = try await OpenCodeProtocolDetector(client: client).probe()

        #expect(probe.protocol == .v1)
        #expect(probe.health.healthy == false)
    }

    @Test("v2 server: HTML on /global/health falls through to JSON /api/health with pid")
    func detectsV2PastHTMLTrap() async throws {
        let (client, stub) = makeStubbedClient(responses: [
            "/global/health": .html("<!doctype html><html><title>OpenCode</title></html>"),
            "/api/health": .json(#"{"healthy":true,"version":"0.0.0-beta-17595","pid":69310}"#),
        ])

        let probe = try await OpenCodeProtocolDetector(client: client).probe()

        #expect(probe.protocol == .v2)
        #expect(probe.health.version == "0.0.0-beta-17595")
        #expect(stub.recordedPaths() == ["/global/health", "/api/health"])
    }

    @Test("v2 server: 404 on /global/health still detects v2 via /api/health")
    func detectsV2WhenGlobalHealthMissing() async throws {
        let (client, _) = makeStubbedClient(responses: [
            "/api/health": .json(#"{"healthy":true,"version":"0.0.0-beta-17595","pid":69310}"#),
        ])

        let probe = try await OpenCodeProtocolDetector(client: client).probe()

        #expect(probe.protocol == .v2)
    }

    @Test("current v2 health without pid or version detects v2 when legacy health is absent")
    func currentV2HealthWithoutPIDDetectsV2() async throws {
        let (client, _) = makeStubbedClient(responses: [
            "/global/health": .html("<!doctype html><html></html>"),
            "/api/health": .json(#"{"healthy":true}"#),
        ])

        let probe = try await OpenCodeProtocolDetector(client: client).probe()

        #expect(probe.protocol == .v2)
        #expect(probe.health == OpenCodeHealth(healthy: true, version: "v2"))
    }

    @Test("server returning HTML for both health routes is not a usable server")
    func htmlEverywhereThrows() async throws {
        let (client, _) = makeStubbedClient(responses: [
            "/global/health": .html("<!doctype html><html></html>"),
            "/api/health": .html("<!doctype html><html></html>"),
        ])

        await #expect(throws: OpenCodeConnectionError.self) {
            _ = try await OpenCodeProtocolDetector(client: client).probe()
        }
    }

    @Test("probes attach Basic auth credentials")
    func probesAttachCredentials() async throws {
        let (client, stub) = makeStubbedClient(responses: [
            "/global/health": .json(#"{"healthy":true,"version":"1.18.18"}"#),
        ])

        _ = try await OpenCodeProtocolDetector(client: client).probe()

        let authorization = try #require(stub.recordedAuthorization())
        #expect(
            authorization == "Basic \(Data("opencode:probe-secret".utf8).base64EncodedString())"
        )
    }

    @Test("200 text/html on a JSON route throws unexpectedContentType, not a decode error (#19)")
    func htmlOnJSONRouteThrowsContentTypeError() async throws {
        let (client, _) = makeStubbedClient(responses: [
            "/global/health": .html("<!doctype html><html><title>OpenCode</title></html>"),
        ])

        do {
            _ = try await client.health()
            Issue.record("Expected unexpectedContentType")
        } catch let error as OpenCodeConnectionError {
            guard case .unexpectedContentType(let path, _) = error else {
                Issue.record("Expected unexpectedContentType, got \(error)")
                return
            }
            #expect(path == "/global/health")
        }
    }

    @Test("HTML body without a JSON content-type still throws unexpectedContentType (#19)")
    func htmlBodyWithoutContentTypeHeaderThrowsContentTypeError() async throws {
        let (client, _) = makeStubbedClient(responses: [
            "/global/health": .init(
                statusCode: 200,
                body: Data("<!doctype html><html></html>".utf8),
                contentType: nil
            ),
        ])

        await #expect(throws: OpenCodeConnectionError.self) {
            _ = try await client.health()
        }
        do {
            _ = try await client.health()
            Issue.record("Expected unexpectedContentType")
        } catch let error as OpenCodeConnectionError {
            guard case .unexpectedContentType = error else {
                Issue.record("Expected unexpectedContentType, got \(error)")
                return
            }
        }
    }

    @Test("compatibility probe against a v2 server enables the implemented core without v1 capabilities")
    func compatibilityProbeAgainstV2Server() async throws {
        let (client, _) = makeStubbedClient(responses: [
            "/global/health": .html("<!doctype html><html></html>"),
            "/api/health": .json(#"{"healthy":true,"version":"0.0.0-beta-17595","pid":69310}"#),
        ])

        let summary = try await client.probeCompatibility()

        #expect(summary.state == .degraded)
        #expect(summary.serverVersion == "0.0.0-beta-17595")
        #expect(summary.capabilitiesAvailable == false)
        let detail = try #require(summary.detail)
        #expect(detail.contains("OpenCode 2"))
        #expect(detail.contains("core chat") == true)
    }

    @Test("evaluator treats 0.x beta versions as OpenCode 2, not as an outdated v1")
    func evaluatorExplainsOpenCode2Beta() {
        let verdict = OpenCodeCompatibilityEvaluator.evaluate(
            health: OpenCodeHealth(healthy: true, version: "0.0.0-beta-17595")
        )

        guard case .unsupported(let reason) = verdict else {
            Issue.record("Expected unsupported, got \(verdict)")
            return
        }
        #expect(reason.contains("OpenCode 2"))
        #expect(reason.contains("Upgrade the OpenCode CLI") == false)
    }

    @Test("compatibility probe against v1 keeps the existing flow untouched")
    func compatibilityProbeAgainstV1Unchanged() async throws {
        let (client, stub) = makeStubbedClient(responses: [
            "/global/health": .json(#"{"healthy":true,"version":"1.18.10"}"#),
            "/experimental/capabilities": .json(#"{"backgroundSubagents":true}"#),
        ])

        let summary = try await client.probeCompatibility()

        #expect(summary.state == .compatible)
        #expect(stub.recordedPaths().contains("/experimental/capabilities"))
    }

    private func makeStubbedClient(
        responses: [String: OpenCodeProtocolStub.StubbedResponse]
    ) -> (OpenCodeClient, OpenCodeProtocolStub.Type) {
        OpenCodeProtocolStub.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let profile = OpenCodeServerProfile(
            name: "Detection stub",
            baseURL: "https://detect.example.test",
            username: "opencode"
        )
        return (
            OpenCodeClient(profile: profile, password: "probe-secret", session: session),
            OpenCodeProtocolStub.self
        )
    }
}

final class OpenCodeProtocolStub: URLProtocol, @unchecked Sendable {
    struct StubbedResponse {
        let statusCode: Int
        let body: Data
        let contentType: String?

        init(statusCode: Int, body: Data, contentType: String?) {
            self.statusCode = statusCode
            self.body = body
            self.contentType = contentType
        }

        static func json(_ body: String, statusCode: Int = 200) -> StubbedResponse {
            StubbedResponse(
                statusCode: statusCode,
                body: Data(body.utf8),
                contentType: "application/json"
            )
        }

        static func html(_ body: String, statusCode: Int = 200) -> StubbedResponse {
            StubbedResponse(
                statusCode: statusCode,
                body: Data(body.utf8),
                contentType: "text/html; charset=utf-8"
            )
        }
    }

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var responses: [String: StubbedResponse] = [:]
    nonisolated(unsafe) private static var requestedPaths: [String] = []
    nonisolated(unsafe) private static var lastAuthorization: String?

    static func reset(_ responses: [String: StubbedResponse]) {
        stateLock.lock()
        self.responses = responses
        requestedPaths = []
        lastAuthorization = nil
        stateLock.unlock()
    }

    static func recordedPaths() -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return requestedPaths
    }

    static func recordedAuthorization() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastAuthorization
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "detect.example.test"
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
        Self.lastAuthorization = request.value(forHTTPHeaderField: "Authorization")
        Self.stateLock.unlock()

        let response = stubbed ?? .json(#"{"message":"not found"}"#, statusCode: 404)
        var headers: [String: String] = [:]
        if let contentType = response.contentType {
            headers["Content-Type"] = contentType
        }
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                  url: url,
                  statusCode: response.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: headers
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
