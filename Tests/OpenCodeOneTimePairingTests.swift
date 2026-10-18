import Foundation
import Testing
@testable import byot

@Suite("OpenCode 2 one-time pairing codes")
struct OpenCodeOneTimePairingParsingTests {
    @Test("The QR code from `opencode pair --remote` parses")
    func remoteQRCode() throws {
        let pairing = try #require(try OpenCodeOneTimePairing.parse(
            #"{"code":"iO4BxZhXrI8XP7howxftew","urls":["https://4f1c0b2e9a7d3c55.k3x9.opentunnel.xyz"]}"#
        ))
        #expect(pairing.code == "iO4BxZhXrI8XP7howxftew")
        #expect(pairing.urls == [URL(string: "https://4f1c0b2e9a7d3c55.k3x9.opentunnel.xyz")!])
    }

    @Test("A printed /auth/connect link parses to its origin")
    func connectLink() throws {
        let pairing = try #require(try OpenCodeOneTimePairing.parse(
            "  https://mac-mini.tail1234.ts.net/auth/connect/abc_DEF-123\n"
        ))
        #expect(pairing.code == "abc_DEF-123")
        #expect(pairing.urls == [URL(string: "https://mac-mini.tail1234.ts.net")!])
    }

    @Test("A local-network HTTP link with a port parses")
    func localHTTPLink() throws {
        let pairing = try #require(try OpenCodeOneTimePairing.parse("http://192.168.1.20:4096/auth/connect/code1"))
        #expect(pairing.urls == [URL(string: "http://192.168.1.20:4096")!])
    }

    @Test("byot codes and plain server addresses are left to byot's own parser")
    func otherFormatsReturnNil() throws {
        #expect(try OpenCodeOneTimePairing.parse("byot://pair?v=1&url=https%3A%2F%2Fmac.example.ts.net") == nil)
        #expect(try OpenCodeOneTimePairing.parse("https://mac.example.ts.net") == nil)
        #expect(try OpenCodeOneTimePairing.parse("https://mac.example.ts.net/auth/connect") == nil)
        #expect(try OpenCodeOneTimePairing.parse("https://mac.example.ts.net/auth/connect/x?y=1") == nil)
        #expect(try OpenCodeOneTimePairing.parse(#"{"url":"https://mac.example.ts.net"}"#) == nil)
    }

    @Test("Addresses the phone can't use are dropped; duplicates collapse")
    func unusableAddressesDropped() throws {
        let pairing = try #require(try OpenCodeOneTimePairing.parse(
            #"{"code":"c","urls":["http://mac.example.com:4096","https://mac.example.ts.net/","https://mac.example.ts.net","http://10.0.0.8:4096"]}"#
        ))
        #expect(pairing.urls == [
            URL(string: "https://mac.example.ts.net")!,
            URL(string: "http://10.0.0.8:4096")!,
        ])
    }

    @Test("A code with only public plain-HTTP addresses explains why")
    func onlyInsecureAddresses() {
        #expect(throws: OpenCodePairingError.insecureServerURL) {
            try OpenCodeOneTimePairing.parse(#"{"code":"c","urls":["http://mac.example.com:4096"]}"#)
        }
    }

    @Test("On a phone, 127.0.0.1 and localhost are dropped in favour of the other addresses")
    func loopbackDroppedOnPhone() throws {
        let pairing = try #require(try OpenCodeOneTimePairing.parse(
            #"{"code":"c","urls":["http://127.0.0.1:49374","http://localhost:49374","http://[::1]:49374","http://192.168.1.20:49374"]}"#,
            allowsLoopback: false
        ))
        #expect(pairing.urls == [URL(string: "http://192.168.1.20:49374")!])
    }

    @Test("A code that lists only the computer's own address says how to reach it", .bug(id: "anomalyco/opencode#54871"),
          arguments: [
              #"{"code":"c","urls":["http://127.0.0.1:49374"]}"#,
              "http://127.0.0.1:49374/auth/connect/abc",
              "http://localhost:49374/auth/connect/abc",
              "http://[::1]:49374/auth/connect/abc",
          ])
    func onlyLoopbackAddresses(code: String) {
        #expect(throws: OpenCodePairingError.loopbackServerURL) {
            try OpenCodeOneTimePairing.parse(code, allowsLoopback: false)
        }
        #expect(OpenCodePairingError.loopbackServerURL.errorDescription?.contains("opencode pair --remote") == true)
    }

    @Test("The simulator shares the computer's loopback, so 127.0.0.1 is kept there")
    func loopbackKeptWhereItReachesTheComputer() throws {
        let pairing = try #require(try OpenCodeOneTimePairing.parse(
            "http://127.0.0.1:4196/auth/connect/abc", allowsLoopback: true
        ))
        #expect(pairing.urls == [URL(string: "http://127.0.0.1:4196")!])
    }

    @Test("Hosts that only look like loopback are kept")
    func loopbackLookalikesKept() throws {
        let pairing = try #require(try OpenCodeOneTimePairing.parse(
            #"{"code":"c","urls":["https://localhost.example.ts.net","http://128.0.0.1:4096","https://127.example.ts.net"]}"#,
            allowsLoopback: false
        ))
        #expect(pairing.urls == [
            URL(string: "https://localhost.example.ts.net")!,
            URL(string: "https://127.example.ts.net")!,
        ])
    }

    @Test("A relay-only code that can't be reached points at the relay, not the computer",
          .bug(id: "anomalyco/opencode#54627"))
    func unreachableRelayMessage() {
        let relay = OpenCodePairingScannerView.unreachableMessage(
            for: [URL(string: "https://route.tunnel.opentunnel.xyz")!]
        )
        #expect(relay.contains("opencode service restart"))
        #expect(!relay.contains("route.tunnel"))
        let lan = OpenCodePairingScannerView.unreachableMessage(
            for: [URL(string: "http://192.168.1.20:4096")!, URL(string: "https://route.tunnel.opentunnel.xyz")!]
        )
        #expect(lan.contains("192.168.1.20"))
        #expect(!lan.contains("opencode service restart"))
    }

    @Test("A malformed code is refused")
    func malformedCode() {
        #expect(throws: OpenCodePairingError.notPairingCode) {
            try OpenCodeOneTimePairing.parse(#"{"code":"a b","urls":["https://mac.example.ts.net"]}"#)
        }
    }

    @Test("The scanner recognizes both OpenCode and byot codes")
    func scannerRecognizesCodes() {
        #expect(OpenCodePairingScannerView.isPairingCode("https://mac.example.ts.net/auth/connect/abc"))
        #expect(OpenCodePairingScannerView.isPairingCode("byot://pair?url=https%3A%2F%2Fmac.example.ts.net"))
        #expect(!OpenCodePairingScannerView.isPairingCode("hello"))
    }

    @Test("A redeemed code fills the form with the token as the opencode password")
    func payloadFromRedemption() {
        let payload = OpenCodePairingRedemption.paired(url: URL(string: "http://192.168.1.20:4096")!, token: "tok")
            .payload
        #expect(payload?.username == "opencode")
        #expect(payload?.password == "tok")
        #expect(payload?.allowsLocalHTTP == true)
        #expect(payload?.name == nil)
        #expect(OpenCodePairingRedemption.expired.payload == nil)
        let remote = OpenCodePairingRedemption.paired(url: URL(string: "https://r.t.opentunnel.xyz")!, token: "tok")
        #expect(remote.payload?.name == "OpenCode remote")
    }
}

@Suite("Redeeming OpenCode pairing codes", .serialized)
struct OpenCodePairingRedeemerTests {
    private let remote = URL(string: "https://route.tunnel.opentunnel.xyz")!
    private let lan = URL(string: "http://192.168.1.20:4096")!

    @Test("A code redeems for a token with a JSON request")
    func redeemsToken() async {
        PairingStub.reset([
            "https://route.tunnel.opentunnel.xyz/auth/connect/abc": .json(200, #"{"token":"1794817359.secret"}"#),
        ])
        let result = await redeemer().redeem(OpenCodeOneTimePairing(urls: [remote], code: "abc"))
        #expect(result == .paired(url: remote, token: "1794817359.secret"))
        #expect(PairingStub.acceptHeaders() == ["application/json"])
    }

    @Test("A spent or expired code reads as expired")
    func expiredCode() async {
        PairingStub.reset([
            "https://route.tunnel.opentunnel.xyz/auth/connect/abc":
                .json(401, #"{"_tag":"UnauthorizedError","message":"Pairing link expired or already used"}"#),
        ])
        let result = await redeemer().redeem(OpenCodeOneTimePairing(urls: [remote], code: "abc"))
        #expect(result == .expired)
    }

    @Test("No answer from any address reads as unreachable")
    func unreachable() async {
        PairingStub.reset([:])
        let result = await redeemer().redeem(OpenCodeOneTimePairing(urls: [lan, remote], code: "abc"))
        #expect(result == .unreachable)
    }

    @Test("An address that can't be reached gives way to one that redeems")
    func fallsBackToReachableAddress() async {
        PairingStub.reset([
            "https://route.tunnel.opentunnel.xyz/auth/connect/abc": .json(200, #"{"token":"t"}"#),
        ])
        let result = await redeemer().redeem(OpenCodeOneTimePairing(urls: [lan, remote], code: "abc"))
        #expect(result == .paired(url: remote, token: "t"))
    }

    @Test("The first-listed address is kept when it answered and accepts the token")
    func prefersFirstAddress() async {
        PairingStub.reset([
            "https://route.tunnel.opentunnel.xyz/auth/connect/abc": .json(401, #"{"_tag":"UnauthorizedError"}"#),
            "http://192.168.1.20:4096/auth/connect/abc": .json(200, #"{"token":"t"}"#),
            "https://route.tunnel.opentunnel.xyz/api/info": .json(200, #"{"version":"2.0.32","pid":1}"#),
        ])
        let result = await redeemer().redeem(OpenCodeOneTimePairing(urls: [remote, lan], code: "abc"))
        #expect(result == .paired(url: remote, token: "t"))
        #expect(PairingStub.authorization(for: "https://route.tunnel.opentunnel.xyz/api/info")
            == "Basic " + Data("opencode:t".utf8).base64EncodedString())
    }

    @Test("The first-listed address is skipped when the token doesn't work there")
    func skipsFirstAddressThatRejectsToken() async {
        PairingStub.reset([
            "https://route.tunnel.opentunnel.xyz/auth/connect/abc": .json(401, #"{"_tag":"UnauthorizedError"}"#),
            "http://192.168.1.20:4096/auth/connect/abc": .json(200, #"{"token":"t"}"#),
            "https://route.tunnel.opentunnel.xyz/api/info": .json(401, #"{"_tag":"UnauthorizedError"}"#),
        ])
        let result = await redeemer().redeem(OpenCodeOneTimePairing(urls: [remote, lan], code: "abc"))
        #expect(result == .paired(url: lan, token: "t"))
    }

    private func redeemer() -> OpenCodePairingRedeemer {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairingStub.self]
        return OpenCodePairingRedeemer(
            session: URLSession(configuration: configuration),
            timeout: 5,
            preferenceWindow: .seconds(2)
        )
    }
}

@Suite("OpenCode 2 pairing against the live fixture")
struct OpenCodeOneTimePairingLiveTests {
    private static let isLive = ProcessInfo.processInfo.environment["BYOT_LIVE_ACCEPTANCE"] == "1"

    @Test("A code from the real server redeems once and its token signs in", .enabled(if: isLive))
    func liveCodeRedeemsOnce() async throws {
        let server = URL(string: "https://127.0.0.1:4199")!
        var issue = URLRequest(url: server.appending(path: "api").appending(path: "pair"))
        issue.httpMethod = "POST"
        issue.setValue("Basic " + Data("opencode:byot-local-fixture-only".utf8).base64EncodedString(),
                       forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: issue)
        let code = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String)
        let pairing = try #require(try OpenCodeOneTimePairing.parse("https://127.0.0.1:4199/auth/connect/\(code)"))

        let result = await OpenCodePairingRedeemer().redeem(pairing)
        let payload = try #require(result.payload)
        #expect(payload.baseURL == server)
        let client = OpenCodeClient(
            profile: OpenCodeServerProfile(name: "Paired", baseURL: server.absoluteString, username: "opencode"),
            password: try #require(payload.password)
        )
        let probe = try await client.probeServer()
        #expect(probe.protocol == .v2)

        #expect(await OpenCodePairingRedeemer().redeem(pairing) == .expired)
    }
}

@Suite("OpenCode 2.0 route choices")
struct OpenCodeFormCancelRouteTests {
    @Test("2.0 releases take a permission reply as `decision`; betas as `reply`")
    func permissionReplyField() throws {
        let release = try decode(#"{"paths":{"/api/session/{sessionID}/permission/{requestID}/reply":{"post":{"requestBody":{"content":{"application/json":{"schema":{"type":"object","properties":{"decision":{},"message":{}}}}}}}}}}"#)
        let beta = try decode(##"{"paths":{"/api/session/{sessionID}/permission/{requestID}/reply":{"post":{"requestBody":{"content":{"application/json":{"schema":{"$ref":"#/components/schemas/Reply"}}}}}}},"components":{"schemas":{"Reply":{"properties":{"reply":{}}}}}}"##)
        #expect(OpenCodeV2Contract.permissionReplyField(release) == "decision")
        #expect(OpenCodeV2Contract.permissionReplyField(beta) == "reply")
        #expect(OpenCodeV2Contract.permissionReplyField(nil) == "reply")
    }

    @Test("2.0 releases publish DELETE …/form/{formID}")
    func releaseDeletes() throws {
        let schema = try decode(#"{"paths":{"/api/session/{sessionID}/form/{formID}":{"get":{},"delete":{}}}}"#)
        #expect(OpenCodeV2Contract.cancelsFormsWithDelete(schema))
    }

    @Test("Betas publish POST …/form/{formID}/cancel")
    func betaPosts() throws {
        let schema = try decode(
            #"{"paths":{"/api/session/{sessionID}/form/{formID}":{"delete":{}},"/api/session/{sessionID}/form/{formID}/cancel":{"post":{}}}}"#
        )
        #expect(!OpenCodeV2Contract.cancelsFormsWithDelete(schema))
        #expect(!OpenCodeV2Contract.cancelsFormsWithDelete(nil))
    }

    private func decode(_ json: String) throws -> OpenCodeJSONValue {
        try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(json.utf8))
    }
}

final class PairingStub: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: Data

        static func json(_ status: Int, _ body: String) -> Response {
            Response(status: status, body: Data(body.utf8))
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset(_ responses: [String: Response]) {
        lock.withLock {
            self.responses = responses
            requests = []
        }
    }

    static func acceptHeaders() -> [String?] {
        lock.withLock { requests.map { $0.value(forHTTPHeaderField: "Accept") } }
    }

    static func authorization(for url: String) -> String? {
        lock.withLock {
            requests.last { $0.url?.absoluteString == url }?.value(forHTTPHeaderField: "Authorization")
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        let response = Self.lock.withLock {
            Self.requests.append(request)
            return Self.responses[key]
        }
        guard let response, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let http = HTTPURLResponse(
            url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
