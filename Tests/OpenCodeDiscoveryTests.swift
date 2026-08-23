import Foundation
import Testing
@testable import byot

@Suite("OpenCode local Bonjour discovery (#10)")
struct OpenCodeDiscoveryTests {
    @Test("Resolver filters generic HTTP services and builds the advertised endpoint")
    func resolverFiltersAndBuildsEndpoint() throws {
        let records = [
            OpenCodeBonjourServiceRecord(
                name: "printer-web-ui",
                type: "_http._tcp.",
                domain: "local.",
                host: "printer.local.",
                port: 80,
                txt: ["path": "/"]
            ),
            OpenCodeBonjourServiceRecord(
                name: "opencode-4096",
                type: "_http._tcp.",
                domain: "local.",
                host: "opencode.local.",
                port: 4096,
                txt: ["path": "/"]
            ),
        ]

        let servers = OpenCodeBonjourServiceResolver.resolve(records)

        let server = try #require(servers.first)
        #expect(servers.count == 1)
        #expect(server.name == "opencode-4096")
        #expect(server.endpoint.absoluteString == "http://opencode.local:4096/")
        #expect(server.profile().allowsLocalHTTP)
    }

    @Test("Local endpoint policy accepts only local names and address ranges")
    func localEndpointPolicy() {
        for host in [
            "opencode.local",
            "localhost",
            "192.168.1.4",
            "10.0.0.8",
            "172.20.1.4",
            "169.254.10.20",
            "127.0.0.1",
            "fe80::1",
            "fd00::4",
            "::1",
        ] {
            #expect(OpenCodeLocalEndpointPolicy.isLocalHost(host), "Expected local host: \(host)")
        }
        for host in [
            "example.com",
            "fd.example.com",
            "fe80.example.com",
            "fc-not-an-address",
            "8.8.8.8",
            "172.32.0.1",
            "2001:4860:4860::8888",
        ] {
            #expect(!OpenCodeLocalEndpointPolicy.isLocalHost(host), "Expected public host: \(host)")
        }
    }

    @Test("Only discovered local profiles may use HTTP and legacy profiles stay secure")
    func discoveredProfileTransportPolicy() throws {
        let manual = OpenCodeServerProfile(
            name: "Manual",
            baseURL: "http://opencode.local:4096"
        )
        #expect(throws: OpenCodeConnectionError.self) {
            try manual.validatedBaseURL()
        }

        let discovered = OpenCodeServerProfile(
            name: "Nearby Mac",
            baseURL: "http://opencode.local:4096",
            allowsLocalHTTP: true
        )
        #expect(try discovered.validatedBaseURL().absoluteString == "http://opencode.local:4096")

        let publicHTTP = OpenCodeServerProfile(
            name: "Unsafe",
            baseURL: "http://example.com:4096",
            allowsLocalHTTP: true
        )
        #expect(throws: OpenCodeConnectionError.self) {
            try publicHTTP.validatedBaseURL()
        }
        let ipv6PrefixHostname = OpenCodeServerProfile(
            name: "Prefix is not an address",
            baseURL: "http://fd.example.com:4096",
            allowsLocalHTTP: true
        )
        #expect(throws: OpenCodeConnectionError.self) {
            try ipv6PrefixHostname.validatedBaseURL()
        }

        let legacyData = Data(
            #"{"id":"00000000-0000-0000-0000-000000000010","name":"Legacy","baseURL":"https://mac.example.test","username":"opencode","directory":""}"#.utf8
        )
        let legacy = try JSONDecoder().decode(OpenCodeServerProfile.self, from: legacyData)
        #expect(!legacy.allowsLocalHTTP)
    }

    @Test("Redirect policy preserves the exact HTTP origin for discovered profiles")
    func discoveredRedirectPolicy() throws {
        let base = try #require(URL(string: "http://opencode.local:4096"))
        let delegate = OpenCodeRedirectDelegate(baseURL: base)

        #expect(delegate.allowsRedirect(to: URL(string: "http://opencode.local:4096/session")))
        #expect(!delegate.allowsRedirect(to: URL(string: "https://opencode.local:4096/session")))
        #expect(!delegate.allowsRedirect(to: URL(string: "http://opencode.local:4097/session")))
        #expect(!delegate.allowsRedirect(to: URL(string: "http://other.local:4096/session")))
    }

    @MainActor
    @Test("Discovery store exposes deterministic browser updates and lifecycle")
    func discoveryStore() throws {
        let browser = MockOpenCodeBonjourBrowser()
        let store = OpenCodeDiscoveryStore(browser: browser)
        store.start()
        #expect(store.isSearching)
        #expect(browser.startCount == 1)

        browser.send(.services([]))
        #expect(!store.isSearching)
        #expect(store.servers.isEmpty)

        browser.send(.services([
            OpenCodeBonjourServiceRecord(
                name: "opencode-4096",
                type: "_http._tcp.",
                domain: "local.",
                host: "192.168.1.8",
                port: 4096,
                txt: ["path": "/"]
            ),
        ]))
        #expect(store.servers.map(\.endpoint.absoluteString) == ["http://192.168.1.8:4096/"])

        browser.send(.failure("Local network permission denied"))
        #expect(store.errorMessage == "Local network permission denied")

        store.stop()
        #expect(!store.isSearching)
        #expect(browser.stopCount == 1)
    }

    @Test("Info plist declares scoped local networking without arbitrary loads")
    func localNetworkPlist() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/Info.plist")
        let object = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL),
            options: [],
            format: nil
        )
        let plist = try #require(object as? [String: Any])
        #expect(plist["NSLocalNetworkUsageDescription"] as? String != nil)
        #expect(plist["NSBonjourServices"] as? [String] == ["_http._tcp"])
        let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(ats["NSAllowsArbitraryLoads"] == nil)
    }
}

@MainActor
private final class MockOpenCodeBonjourBrowser: OpenCodeBonjourBrowsing {
    private var onUpdate: ((OpenCodeDiscoveryUpdate) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(onUpdate: @escaping (OpenCodeDiscoveryUpdate) -> Void) {
        startCount += 1
        self.onUpdate = onUpdate
    }

    func stop() {
        stopCount += 1
        onUpdate = nil
    }

    func send(_ update: OpenCodeDiscoveryUpdate) {
        onUpdate?(update)
    }
}
