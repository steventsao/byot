import CoreImage
import Foundation
import Testing
@testable import byot

@Suite("Server pairing codes (#93)")
struct OpenCodeServerPairingTests {
    // MARK: Payload

    @Test("A full pairing link fills every field")
    func parsesFullLink() throws {
        let payload = try OpenCodePairingPayload(code: """
            byot://pair?v=1&url=https%3A%2F%2Fstudio.tail1234.ts.net%2F&username=me\
            &password=p%26ss%3Dw%2Brd%20%C3%A9&directory=%2FUsers%2Fme%2Fmy%20proj&name=Studio%20Mac
            """)
        #expect(payload.baseURL.absoluteString == "https://studio.tail1234.ts.net")
        #expect(payload.username == "me")
        #expect(payload.password == "p&ss=w+rd é", "+ is a literal plus, %20 a space")
        #expect(payload.directory == "/Users/me/my proj")
        #expect(payload.name == "Studio Mac")
        #expect(!payload.allowsLocalHTTP)
    }

    @Test("The link printed by scripts/byot-pair-qr.sh parses")
    func parsesHelperScriptOutput() throws {
        // `OPENCODE_SERVER_PASSWORD='p&ss=w+rd é/ü~' byot-pair-qr.sh --link -n "Studio Mac"
        //  -d "/Users/me/my proj" https://studio.tail1234.ts.net/`
        let script = "byot://pair?v=1&url=https%3A%2F%2Fstudio.tail1234.ts.net&username=opencode"
            + "&password=p%26ss%3Dw%2Brd%20%C3%A9%2F%C3%BC~&directory=%2FUsers%2Fme%2Fmy%20proj&name=Studio%20Mac"
        let payload = try OpenCodePairingPayload(code: script)
        #expect(payload == OpenCodePairingPayload(
            baseURL: URL(string: "https://studio.tail1234.ts.net")!,
            username: "opencode",
            password: "p&ss=w+rd é/ü~",
            directory: "/Users/me/my proj",
            name: "Studio Mac"
        ))
        #expect(payload.link.absoluteString == script, "The app encodes exactly like the helper")
    }

    @Test("Only the URL is required, and optional fields stay unset when blank")
    func minimalLink() throws {
        let payload = try OpenCodePairingPayload(code: "  byot://pair?url=https://mac.example.test&password=&name=\n")
        #expect(payload == OpenCodePairingPayload(baseURL: URL(string: "https://mac.example.test")!))
        #expect(try OpenCodePairingPayload(code: "byot:pair?url=https://mac.example.test").baseURL.host == "mac.example.test")
        #expect(try OpenCodePairingPayload(code: "BYOT://PAIR?url=https://mac.example.test").baseURL.host == "mac.example.test")
    }

    @Test("The first occurrence of a field wins and unknown fields are ignored")
    func duplicateAndUnknownFields() throws {
        let payload = try OpenCodePairingPayload(
            code: "byot://pair?url=https://a.example.test&url=https://b.example.test&future=1&password=one&password=two"
        )
        #expect(payload.baseURL.host == "a.example.test")
        #expect(payload.password == "one")
    }

    @Test("A bare server address works as a code, with credentials lifted out of the URL")
    func bareServerAddress() throws {
        let plain = try OpenCodePairingPayload(code: "https://mac.example.test:8443/")
        #expect(plain.baseURL.absoluteString == "https://mac.example.test:8443")
        #expect(plain.username == nil && plain.password == nil)

        let withCredentials = try OpenCodePairingPayload(code: "https://opencode:s3cret@mac.example.test")
        #expect(withCredentials.baseURL.absoluteString == "https://mac.example.test")
        #expect(withCredentials.username == "opencode")
        #expect(withCredentials.password == "s3cret")
    }

    @Test("Plain HTTP is accepted only for a numeric local-network address")
    func httpPolicy() throws {
        let lan = try OpenCodePairingPayload(code: "byot://pair?url=http%3A%2F%2F192.168.1.8%3A4096")
        #expect(lan.baseURL.absoluteString == "http://192.168.1.8:4096")
        #expect(lan.allowsLocalHTTP)
        #expect(try OpenCodePairingPayload(code: "http://[fd00::4]:4096").allowsLocalHTTP)

        for code in [
            "http://example.com:4096",
            "http://opencode.local:4096",
            "http://8.8.8.8:4096",
            "byot://pair?url=http://172.32.0.1",
        ] {
            #expect(throws: OpenCodePairingError.insecureServerURL, "\(code)") {
                try OpenCodePairingPayload(code: code)
            }
        }
    }

    @Test("Foreign, malformed, and future codes are refused with a specific reason")
    func refusals() {
        #expect(throws: OpenCodePairingError.notPairingCode) { try OpenCodePairingPayload(code: "hello") }
        #expect(throws: OpenCodePairingError.notPairingCode) { try OpenCodePairingPayload(code: "WIFI:S:home;T:WPA;P:x;;") }
        #expect(throws: OpenCodePairingError.notPairingCode) { try OpenCodePairingPayload(code: "byot://session?id=1") }
        #expect(throws: OpenCodePairingError.notPairingCode) { try OpenCodePairingPayload(code: "ftp://mac.example.test") }
        #expect(throws: OpenCodePairingError.missingServerURL) { try OpenCodePairingPayload(code: "byot://pair?password=x") }
        #expect(throws: OpenCodePairingError.unsupportedVersion) {
            try OpenCodePairingPayload(code: "byot://pair?v=2&url=https://mac.example.test")
        }
        #expect(throws: OpenCodePairingError.invalidServerURL) {
            try OpenCodePairingPayload(code: "byot://pair?url=https%3A%2F%2Fmac.example.test%3Fx%3D1")
        }
        #expect(throws: OpenCodePairingError.invalidServerURL) {
            try OpenCodePairingPayload(code: "byot://pair?url=not%20a%20url")
        }
        #expect(OpenCodePairingError.unsupportedVersion.errorDescription?.contains("newer version") == true)
    }

    @Test("A generated link round-trips, including through a QR image")
    func linkRoundTrip() throws {
        let payload = OpenCodePairingPayload(
            baseURL: URL(string: "http://192.168.1.8:4096")!,
            username: "me",
            password: "a+b &c=d/é#?",
            directory: "/Users/me/p",
            name: "Studio"
        )
        #expect(try OpenCodePairingPayload(code: payload.link.absoluteString) == payload)

        let image = try #require(OpenCodeQRCode.image(for: payload.link.absoluteString))
        let decoded = OpenCodeQRCode.messages(in: image)
        #expect(decoded == [payload.link.absoluteString])
        #expect(try OpenCodePairingPayload(code: decoded[0]) == payload)
    }

    @Test("Photo import finds a QR code in encoded image data")
    func readsImageData() throws {
        let image = try #require(OpenCodeQRCode.image(for: "byot://pair?url=https%3A%2F%2Fmac.example.test"))
        let context = CIContext()
        let data = try #require(context.pngRepresentation(
            of: image, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()
        ))
        #expect(OpenCodeQRCode.messages(inImageData: data) == ["byot://pair?url=https%3A%2F%2Fmac.example.test"])
        #expect(OpenCodeQRCode.messages(inImageData: Data("not an image".utf8)).isEmpty)
    }

    // MARK: Filling the form

    private static let saved = OpenCodeServerProfile(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
        name: "Studio",
        baseURL: "https://studio.example.test",
        username: "opencode",
        directory: "/repo"
    )

    private static func blank() -> OpenCodeServerDraft {
        OpenCodeServerDraft(profile: OpenCodeServerProfile(name: "Mac mini", baseURL: ""), password: "")
    }

    @Test("A new server takes the code's fields and a name from its host")
    func fillsNewServer() throws {
        let current = Self.blank()
        let payload = try OpenCodePairingPayload(code: "byot://pair?url=https://mac-mini.tail1.ts.net&password=pw")
        let draft = OpenCodePairing.draft(
            applying: payload, to: current, isEditingSavedProfile: false,
            savedProfiles: [Self.saved], savedPassword: { _ in "old" }
        )
        #expect(draft.profile.id == current.profile.id)
        #expect(draft.profile.name == "mac-mini")
        #expect(draft.profile.baseURL == "https://mac-mini.tail1.ts.net")
        #expect(draft.profile.username == "opencode")
        #expect(draft.profile.directory.isEmpty)
        #expect(!draft.profile.allowsLocalHTTP)
        #expect(draft.password == "pw")
    }

    @Test("Scanning a saved server's address updates it instead of adding a duplicate")
    func repairsSavedServer() throws {
        let payload = try OpenCodePairingPayload(code: "byot://pair?url=HTTPS://Studio.example.test:443/&password=new")
        let draft = OpenCodePairing.draft(
            applying: payload, to: Self.blank(), isEditingSavedProfile: false,
            savedProfiles: [Self.saved], savedPassword: { _ in "old" }
        )
        #expect(draft.profile.id == Self.saved.id)
        #expect(draft.profile.name == "Studio", "The saved name is kept")
        #expect(draft.profile.directory == "/repo")
        #expect(draft.password == "new")

        let withoutPassword = OpenCodePairing.draft(
            applying: try OpenCodePairingPayload(code: "https://studio.example.test"), to: Self.blank(),
            isEditingSavedProfile: false, savedProfiles: [Self.saved], savedPassword: { _ in "old" }
        )
        #expect(withoutPassword.password == "old", "Same address keeps the saved password")
    }

    @Test("A saved password is never carried to a different address")
    func neverLeaksPasswordToNewHost() throws {
        let editing = OpenCodeServerDraft(profile: Self.saved, password: "old")
        let payload = try OpenCodePairingPayload(code: "https://other.example.test")
        let draft = OpenCodePairing.draft(
            applying: payload, to: editing, isEditingSavedProfile: true,
            savedProfiles: [Self.saved], savedPassword: { _ in "old" }
        )
        #expect(draft.profile.id == Self.saved.id, "Editing re-points the same server")
        #expect(draft.profile.name == "Studio")
        #expect(draft.password.isEmpty)
        #expect(draft.profile.directory.isEmpty)

        let sameHost = OpenCodePairing.draft(
            applying: try OpenCodePairingPayload(code: "https://studio.example.test/"), to: editing,
            isEditingSavedProfile: true, savedProfiles: [Self.saved], savedPassword: { _ in "unused" }
        )
        #expect(sameHost.password == "old")
        #expect(sameHost.profile.directory == "/repo")
    }

    @Test("A local HTTP code marks the profile for local HTTP, and it validates")
    func localHTTPDraftValidates() throws {
        let payload = try OpenCodePairingPayload(code: "byot://pair?url=http%3A%2F%2F192.168.1.8%3A4096&password=pw")
        let draft = OpenCodePairing.draft(
            applying: payload, to: Self.blank(), isEditingSavedProfile: false,
            savedProfiles: [], savedPassword: { _ in "" }
        )
        #expect(draft.profile.allowsLocalHTTP)
        #expect(draft.profile.name == "OpenCode (192.168.1.8)")
        #expect(try draft.profile.validatedBaseURL().absoluteString == "http://192.168.1.8:4096")
        try draft.profile.validate(password: draft.password)
    }

    @Test("Endpoint keys ignore case, default ports, and trailing slashes")
    func endpointKeys() {
        #expect(OpenCodePairing.endpointKey("HTTPS://Mac.Example.test/") == OpenCodePairing.endpointKey("https://mac.example.test:443"))
        #expect(OpenCodePairing.endpointKey("http://10.0.0.2") == OpenCodePairing.endpointKey("http://10.0.0.2:80/"))
        #expect(OpenCodePairing.endpointKey("https://mac.example.test") != OpenCodePairing.endpointKey("http://mac.example.test"))
        #expect(OpenCodePairing.endpointKey("") == nil)
    }

    // MARK: Scanner

    @Test("The scan gate reports each code once and stops after success")
    func scanGate() {
        var gate = OpenCodePairingScanGate()
        let first = gate.shouldHandle("bad")
        let repeated = gate.shouldHandle("bad")
        let next = gate.shouldHandle("good")
        gate.finish()
        let afterFinish = gate.shouldHandle("other")
        gate.reset()
        let afterReset = gate.shouldHandle("bad")
        #expect(first)
        #expect(!repeated, "Repeated frames of one code are ignored")
        #expect(next)
        #expect(!afterFinish)
        #expect(afterReset)
    }

    // MARK: Transport policy

    @Test("Typed addresses stay HTTPS-only, with a hint toward pairing for local HTTP")
    func manualProfilesStayHTTPS() throws {
        let https = OpenCodeServerProfile(name: "Mac", baseURL: "https://mac.example.test/")
        #expect(try https.validatedBaseURL().absoluteString == "https://mac.example.test")

        let localHTTP = OpenCodeServerProfile(name: "Mac", baseURL: "http://192.168.1.8:4096")
        #expect(throws: OpenCodeConnectionError.self) { try localHTTP.validatedBaseURL() }
        do {
            _ = try localHTTP.validatedBaseURL()
        } catch {
            #expect(error.localizedDescription.contains("pairing code"))
        }

        for (baseURL, allowsLocalHTTP) in [
            ("http://example.com:4096", false),
            ("http://example.com:4096", true),
            ("http://opencode.local:4096", true),
            ("http://fd.example.com:4096", true),
            ("ftp://192.168.1.8", true),
        ] {
            let profile = OpenCodeServerProfile(name: "x", baseURL: baseURL, allowsLocalHTTP: allowsLocalHTTP)
            #expect(throws: OpenCodeConnectionError.self, "\(baseURL)") { try profile.validatedBaseURL() }
        }

        let ipv6 = OpenCodeServerProfile(name: "x", baseURL: "http://[fd00::4]:4096", allowsLocalHTTP: true)
        #expect(try ipv6.validatedBaseURL().absoluteString == "http://[fd00::4]:4096")
    }

    @Test("Profiles saved before discovery decode as HTTPS-only and the flag round-trips")
    func profileCoding() throws {
        let legacy = try JSONDecoder().decode(OpenCodeServerProfile.self, from: Data(
            #"{"id":"00000000-0000-0000-0000-000000000010","name":"Legacy","baseURL":"https://mac.example.test","username":"opencode","directory":""}"#.utf8
        ))
        #expect(!legacy.allowsLocalHTTP)
        #expect(legacy.compatibility == nil)

        let local = OpenCodeServerProfile(name: "LAN", baseURL: "http://10.0.0.2:4096", allowsLocalHTTP: true)
        let decoded = try JSONDecoder().decode(OpenCodeServerProfile.self, from: JSONEncoder().encode(local))
        #expect(decoded == local)
    }

    @Test("Redirects keep credentials only on the exact original origin")
    func redirectOrigin() throws {
        let local = OpenCodeRedirectDelegate(baseURL: URL(string: "http://192.168.1.8:4096"))
        #expect(local.allowsRedirect(to: URL(string: "http://192.168.1.8:4096/session")))
        #expect(!local.allowsRedirect(to: URL(string: "https://192.168.1.8:4096/session")))
        #expect(!local.allowsRedirect(to: URL(string: "http://192.168.1.8:4097/session")))
        #expect(!local.allowsRedirect(to: URL(string: "http://192.168.1.9:4096/session")))

        let secure = OpenCodeRedirectDelegate(baseURL: URL(string: "https://mac.example.test"))
        #expect(!secure.allowsRedirect(to: URL(string: "http://mac.example.test:443/session")), "Never downgrade")
        #expect(!OpenCodeRedirectDelegate(baseURL: URL(string: "ftp://mac.example.test"))
            .allowsRedirect(to: URL(string: "ftp://mac.example.test/x")))
    }

    @Test("The app declares scoped local networking, camera use, and the byot scheme")
    func infoPlist() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect((info["NSLocalNetworkUsageDescription"] as? String)?.isEmpty == false)
        #expect((info["NSCameraUsageDescription"] as? String)?.isEmpty == false)
        #expect(info["NSBonjourServices"] as? [String] == ["_http._tcp"])
        let ats = try #require(info["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(ats["NSAllowsArbitraryLoads"] == nil)
        let urlTypes = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        #expect(urlTypes.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("byot") == true })
    }
}
