import Darwin
import Foundation
import Testing
@testable import byot

@Suite("Nearby server discovery (#10)")
struct OpenCodeDiscoveryTests {
    private static func record(
        name: String = "opencode-4096",
        host: String = "192.168.1.8",
        port: Int = 4096,
        txt: [String: String] = ["path": "/"],
        advertisedHost: String? = "opencode.local."
    ) -> OpenCodeBonjourServiceRecord {
        OpenCodeBonjourServiceRecord(
            name: name, type: "_http._tcp.", domain: "local.", host: host,
            port: port, txt: txt, advertisedHost: advertisedHost
        )
    }

    @Test("The resolver keeps only OpenCode services and builds the endpoint from the numeric address")
    func resolverFiltersAndBuildsEndpoint() throws {
        let servers = OpenCodeBonjourServiceResolver.resolve([
            Self.record(name: "printer-web-ui", port: 80),
            Self.record(name: "opencode-spoof", host: "opencode.local."),
            Self.record(name: "opencode-4097", port: 4097, txt: [:]),
            Self.record(name: "opencode-4098", port: 4098, txt: ["path": "/x?y"]),
            Self.record(name: "opencode-0", port: 0),
            Self.record(),
            Self.record(),
        ])

        let server = try #require(servers.first)
        #expect(servers.count == 1, "Duplicates collapse and invalid records are dropped")
        #expect(server.endpoint.absoluteString == "http://192.168.1.8:4096/")
        #expect(server.title == "OpenCode on port 4096")
        #expect(server.address == "192.168.1.8:4096")
        #expect(server.pairingPayload.allowsLocalHTTP)
        #expect(server.pairingPayload.name == "OpenCode (192.168.1.8)")
    }

    @Test("A custom --mdns-domain names the server; IPv6 endpoints are bracketed")
    func titlesAndIPv6() throws {
        let studio = try #require(OpenCodeBonjourServiceResolver.resolve(Self.record(advertisedHost: "Studio.local.")))
        #expect(studio.title == "studio")
        #expect(studio.pairingPayload.name == "studio")

        let ipv6 = try #require(OpenCodeBonjourServiceResolver.resolve(Self.record(host: "fd00::4", port: 4100)))
        #expect(ipv6.endpoint.absoluteString == "http://[fd00::4]:4100/")
        #expect(ipv6.address == "[fd00::4]:4100")
        let profile = OpenCodeServerProfile(
            name: "x", baseURL: ipv6.pairingPayload.baseURL.absoluteString, allowsLocalHTTP: true
        )
        #expect(throws: Never.self) { try profile.validatedBaseURL() }

        #expect(OpenCodeBonjourServiceResolver.resolve(Self.record(host: "fe80::1%en0")) == nil,
                "Scoped addresses can't be carried in a URL")
    }

    @Test("Servers sort by title")
    func sorting() {
        let servers = OpenCodeBonjourServiceResolver.resolve([
            Self.record(name: "opencode-1", host: "10.0.0.3", advertisedHost: "zeta.local."),
            Self.record(name: "opencode-2", host: "10.0.0.2", advertisedHost: "alpha.local."),
        ])
        #expect(servers.map(\.title) == ["alpha", "zeta"])
    }

    @Test("Local endpoint policy accepts only parsed local address ranges")
    func localEndpointPolicy() {
        for host in ["192.168.1.4", "10.0.0.8", "172.20.1.4", "169.254.10.20", "127.0.0.1",
                     "fe80::1", "fd00::4", "::1", "[fd00::4]", "192.168.1.4."] {
            #expect(OpenCodeLocalEndpointPolicy.isLocalHost(host), "Expected local host: \(host)")
        }
        for host in ["example.com", "opencode.local", "localhost", "fd.example.com", "fe80.example.com",
                     "fc-not-an-address", "8.8.8.8", "172.32.0.1", "2001:4860:4860::8888",
                     "+10.0.0.1", "10.0.0", "10.0.0.1.5", "", "100.64.0.1",
                     "fe80::1%en0", "[fe80::1%25en0]"] {
            #expect(!OpenCodeLocalEndpointPolicy.isLocalHost(host), "Expected public host: \(host)")
        }
    }

    @Test("Address selection prefers local IPv4 and never returns a public address")
    func resolvedBonjourAddressPolicy() {
        let publicAddress = ipv4SocketAddress("203.0.113.8")
        let localAddress = ipv4SocketAddress("192.168.1.8")
        let uniqueLocal = ipv6SocketAddress("fd00::4")

        #expect(OpenCodeBonjourAddressResolver.localHost(from: [publicAddress]) == nil)
        #expect(OpenCodeBonjourAddressResolver.localHost(from: [publicAddress, localAddress]) == "192.168.1.8")
        #expect(OpenCodeBonjourAddressResolver.localHost(from: [uniqueLocal, localAddress]) == "192.168.1.8")
        #expect(OpenCodeBonjourAddressResolver.localHost(from: [uniqueLocal]) == "fd00::4")
        #expect(OpenCodeBonjourAddressResolver.localHost(from: [Data([1, 2])]) == nil)
    }

    @Test("A nonlocal resolve callback remains eligible for later addresses")
    func nonlocalResolutionWaitsForAdditionalAddresses() {
        #expect(OpenCodeBonjourResolutionPolicy.disposition(localHost: nil) == .awaitingAdditionalAddresses)
        #expect(OpenCodeBonjourResolutionPolicy.disposition(localHost: "192.168.1.42") == .resolved(host: "192.168.1.42"))
    }

    @MainActor
    @Test("The store follows browser updates and restarts cleanly")
    func discoveryStore() {
        let browser = MockOpenCodeBonjourBrowser()
        let store = OpenCodeDiscoveryStore(browser: browser)
        store.start()
        #expect(store.isSearching)
        #expect(browser.startCount == 1)

        browser.send(.services([]))
        #expect(store.isSearching)
        #expect(store.servers.isEmpty)

        browser.send(.settled)
        #expect(!store.isSearching)

        browser.send(.services([Self.record()]))
        #expect(store.servers.map(\.endpoint.absoluteString) == ["http://192.168.1.8:4096/"],
                "Servers found after the first search still appear")

        browser.send(.services([]))
        #expect(store.servers.isEmpty, "Removed servers disappear")

        browser.send(.services([Self.record()]))
        store.start()
        #expect(store.isSearching)
        #expect(store.servers.isEmpty, "A new search never shows stale servers")
        #expect(browser.startCount == 2)

        browser.send(.failure("Local network permission denied"))
        #expect(store.errorMessage == "Local network permission denied")
        #expect(!store.isSearching)

        browser.send(.services([Self.record()]))
        #expect(store.errorMessage == nil)

        store.stop()
        #expect(!store.isSearching)
        #expect(browser.stopCount == 1)
    }

    @Test("Callback generations reject stale browser and service callbacks")
    func staleCallbackGeneration() {
        let firstBrowser = NSObject()
        let nextBrowser = NSObject()
        let staleService = NSObject()
        let currentService = NSObject()
        let key = "local.|_http._tcp.|opencode-4096"
        var generation = OpenCodeBonjourCallbackGeneration()

        generation.begin(browser: firstBrowser)
        let registeredInitial = generation.register(service: staleService, key: key, browser: firstBrowser)
        #expect(registeredInitial)
        #expect(generation.accepts(browser: firstBrowser))
        #expect(generation.accepts(service: staleService, key: key))

        generation.begin(browser: nextBrowser)
        #expect(!generation.accepts(browser: firstBrowser))
        #expect(!generation.accepts(service: staleService, key: key))
        let registeredFromStaleBrowser = generation.register(service: staleService, key: key, browser: firstBrowser)
        let registeredCurrent = generation.register(service: currentService, key: key, browser: nextBrowser)
        let removedStale = generation.remove(service: staleService, key: key)
        #expect(!registeredFromStaleBrowser)
        #expect(registeredCurrent)
        #expect(!removedStale)
        #expect(generation.accepts(service: currentService, key: key))

        generation.end()
        #expect(!generation.accepts(browser: nextBrowser))
        #expect(!generation.accepts(service: currentService, key: key))
    }

    @Test("The first search settles only after the browse batch and its resolutions finish")
    func initialSearchSettlement() {
        let key = "local|_http._tcp.|opencode-4096"

        var pending = OpenCodeDiscoveryInitialSearch()
        let settledOnFind = pending.serviceFound(key: key, moreComing: false)
        let settledOnEmptyWindow = pending.emptyWindowElapsed()
        let settledOnResolution = pending.resolutionFinished(key: key)
        let settledTwice = pending.resolutionFinished(key: key)
        #expect(!settledOnFind)
        #expect(!settledOnEmptyWindow, "A pending resolution holds the search open")
        #expect(settledOnResolution)
        #expect(pending.isSettled)
        #expect(!settledTwice, "Settles once")

        var empty = OpenCodeDiscoveryInitialSearch()
        let emptySettled = empty.emptyWindowElapsed()
        #expect(emptySettled)

        var genericHTTPOnly = OpenCodeDiscoveryInitialSearch()
        let genericSettled = genericHTTPOnly.serviceFound(key: nil, moreComing: false)
        #expect(genericSettled)

        var removedPending = OpenCodeDiscoveryInitialSearch()
        let pendingFound = removedPending.serviceFound(key: key, moreComing: true)
        let pendingRemoved = removedPending.serviceRemoved(key: key, moreComing: false)
        #expect(!pendingFound)
        #expect(pendingRemoved)

        var removedGeneric = OpenCodeDiscoveryInitialSearch()
        let genericFound = removedGeneric.serviceFound(key: nil, moreComing: true)
        let genericRemoved = removedGeneric.serviceRemoved(key: nil, moreComing: false)
        #expect(!genericFound)
        #expect(genericRemoved)
    }
}

private func ipv4SocketAddress(_ host: String) -> Data {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    let parsed = host.withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    precondition(parsed == 1)
    return Data(bytes: &address, count: MemoryLayout<sockaddr_in>.size)
}

private func ipv6SocketAddress(_ host: String) -> Data {
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    let parsed = host.withCString { inet_pton(AF_INET6, $0, &address.sin6_addr) }
    precondition(parsed == 1)
    return Data(bytes: &address, count: MemoryLayout<sockaddr_in6>.size)
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
