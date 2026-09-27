import Darwin
import Foundation

// Local discovery of `opencode serve --mdns` (#10).
//
// Upstream (packages/opencode/src/server/mdns.ts) publishes a generic Bonjour
// `_http._tcp` service named `opencode-{port}` on host `opencode.local` (or
// `--mdns-domain`), with the real port and TXT `path=/`. Because the service
// type is generic, BYOT keeps only `opencode-` names with a valid TXT path, and
// never trusts the advertised hostname for transport: the endpoint is built
// from a numeric local address taken from the resolved socket addresses.

struct OpenCodeBonjourServiceRecord: Equatable, Sendable {
    let name: String
    let type: String
    let domain: String
    /// Numeric local address chosen from the resolved socket addresses.
    let host: String
    let port: Int
    let txt: [String: String]
    /// The advertised target host, such as `opencode.local.`. Display only.
    var advertisedHost: String? = nil
}

struct OpenCodeDiscoveredServer: Equatable, Identifiable, Sendable {
    let name: String
    let host: String
    let port: Int
    let path: String
    let endpoint: URL
    let advertisedHost: String?

    var id: String { "\(name)|\(host)|\(port)|\(path)" }

    /// A person-facing title. A custom `--mdns-domain` such as `studio.local`
    /// names the computer; the upstream default `opencode.local` does not.
    var title: String {
        if let label = Self.computerLabel(advertisedHost) { return label }
        return "OpenCode on port \(port)"
    }

    /// The address shown under the title, without the scheme.
    var address: String {
        let host = self.host.contains(":") ? "[\(self.host)]" : self.host
        return path == "/" ? "\(host):\(port)" : "\(host):\(port)\(path)"
    }

    var pairingPayload: OpenCodePairingPayload {
        OpenCodePairingPayload(
            baseURL: endpoint,
            name: Self.computerLabel(advertisedHost) ?? "OpenCode (\(host))"
        )
    }

    private static func computerLabel(_ advertisedHost: String?) -> String? {
        guard var host = advertisedHost?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasSuffix(".local") { host.removeLast(".local".count) }
        guard !host.isEmpty, host != "opencode", !host.contains(".") else { return nil }
        return host
    }
}

enum OpenCodeLocalEndpointPolicy {
    /// True only for a parsed numeric loopback, link-local, or private
    /// (RFC 1918 / unique-local) address. Hostnames, including `.local`
    /// names, never qualify, and neither do zone-scoped IPv6 addresses
    /// (`fe80::1%en0`), which URLSession can't reach from a URL host.
    static func isLocalHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.contains("%") else { return false }
        return isLocalIPv4(host) || isLocalIPv6(host)
    }

    private static func isLocalIPv4(_ host: String) -> Bool {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        let values = pieces.compactMap { piece in
            piece.allSatisfy(\.isASCII) && piece.allSatisfy(\.isNumber) ? Int(piece) : nil
        }
        guard pieces.count == 4,
              values.count == 4,
              values.allSatisfy({ (0...255).contains($0) })
        else { return false }

        return values[0] == 10
            || values[0] == 127
            || (values[0] == 169 && values[1] == 254)
            || (values[0] == 172 && (16...31).contains(values[1]))
            || (values[0] == 192 && values[1] == 168)
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        let parsed = host.withCString { inet_pton(AF_INET6, $0, &address) }
        guard parsed == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
        return isLoopback || isLinkLocal || isUniqueLocal
    }
}

enum OpenCodeBonjourAddressResolver {
    /// Picks the address a URL can reach: IPv4 first, then IPv6. Addresses
    /// that need an interface scope (`fe80::1%en0`) are skipped because
    /// URLSession cannot carry a zone in a URL host.
    static func localHost(from addresses: [Data]) -> String? {
        let hosts = addresses.compactMap(numericHost)
            .filter(OpenCodeLocalEndpointPolicy.isLocalHost)
        return hosts.first { !$0.contains(":") } ?? hosts.first
    }

    private static func numericHost(from address: Data) -> String? {
        guard address.count >= MemoryLayout<sockaddr>.size else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = host.withUnsafeMutableBufferPointer { hostBuffer in
            address.withUnsafeBytes { addressBuffer in
                guard let addressBase = addressBuffer.baseAddress,
                      let hostBase = hostBuffer.baseAddress
                else { return Int32(EAI_FAIL) }
                return getnameinfo(
                    addressBase.assumingMemoryBound(to: sockaddr.self),
                    socklen_t(address.count),
                    hostBase,
                    socklen_t(hostBuffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
            }
        }
        guard result == 0 else { return nil }
        let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum OpenCodeBonjourServiceResolver {
    static func resolve(_ records: [OpenCodeBonjourServiceRecord]) -> [OpenCodeDiscoveredServer] {
        records.compactMap(resolve)
            .reduce(into: [String: OpenCodeDiscoveredServer]()) { result, server in
                result[server.id] = server
            }
            .values
            .sorted { lhs, rhs in
                if lhs.title == rhs.title { return lhs.endpoint.absoluteString < rhs.endpoint.absoluteString }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    static func resolve(_ record: OpenCodeBonjourServiceRecord) -> OpenCodeDiscoveredServer? {
        let type = record.type.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard type == "_http._tcp",
              record.name.lowercased().hasPrefix("opencode-"),
              (1...65_535).contains(record.port),
              OpenCodeLocalEndpointPolicy.isLocalHost(record.host),
              !record.host.contains("%"),
              let rawPath = record.txt["path"],
              rawPath.hasPrefix("/"),
              !rawPath.contains("?"),
              !rawPath.contains("#")
        else { return nil }

        var host = record.host.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix(".") { host.removeLast() }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host.contains(":") ? "[\(host)]" : host
        components.port = record.port
        components.path = rawPath
        guard let endpoint = components.url else { return nil }

        return OpenCodeDiscoveredServer(
            name: record.name,
            host: host,
            port: record.port,
            path: rawPath,
            endpoint: endpoint,
            advertisedHost: record.advertisedHost
        )
    }
}

enum OpenCodeDiscoveryUpdate: Equatable, Sendable {
    case services([OpenCodeBonjourServiceRecord])
    case settled
    case failure(String)
}

enum OpenCodeBonjourResolutionDisposition: Equatable, Sendable {
    case resolved(host: String)
    case awaitingAdditionalAddresses
}

enum OpenCodeBonjourResolutionPolicy {
    /// A resolve callback with only nonlocal addresses keeps the service
    /// registered, so a later dual-stack callback can still publish it.
    static func disposition(localHost: String?) -> OpenCodeBonjourResolutionDisposition {
        localHost.map(OpenCodeBonjourResolutionDisposition.resolved) ?? .awaitingAdditionalAddresses
    }
}

/// Identifies the current browser and its services so callbacks from a
/// stopped or replaced browse are ignored.
struct OpenCodeBonjourCallbackGeneration: Equatable, Sendable {
    private var browserIdentity: ObjectIdentifier?
    private var serviceIdentities: [String: ObjectIdentifier] = [:]

    mutating func begin(browser: AnyObject) {
        browserIdentity = ObjectIdentifier(browser)
        serviceIdentities.removeAll()
    }

    mutating func end() {
        browserIdentity = nil
        serviceIdentities.removeAll()
    }

    func accepts(browser: AnyObject) -> Bool {
        browserIdentity == ObjectIdentifier(browser)
    }

    mutating func register(service: AnyObject, key: String, browser: AnyObject) -> Bool {
        guard accepts(browser: browser) else { return false }
        serviceIdentities[key] = ObjectIdentifier(service)
        return true
    }

    func accepts(service: AnyObject, key: String) -> Bool {
        serviceIdentities[key] == ObjectIdentifier(service)
    }

    mutating func remove(service: AnyObject, key: String) -> Bool {
        guard accepts(service: service, key: key) else { return false }
        serviceIdentities.removeValue(forKey: key)
        return true
    }
}

/// Decides when the first search has finished, so the UI can move from
/// "Looking nearby" to results or an empty state while browsing continues.
/// Both find and remove callbacks end a browse batch, and every matching
/// service must finish resolving first.
struct OpenCodeDiscoveryInitialSearch: Sendable {
    private var pendingServiceKeys: Set<String> = []
    private var reachedBrowseBatchEnd = false
    private(set) var isSettled = false

    mutating func serviceFound(key: String?, moreComing: Bool) -> Bool {
        guard !isSettled else { return false }
        if let key { pendingServiceKeys.insert(key) }
        if !moreComing { reachedBrowseBatchEnd = true }
        return settleAfterBrowseBatchIfReady()
    }

    mutating func resolutionFinished(key: String) -> Bool {
        guard !isSettled else { return false }
        pendingServiceKeys.remove(key)
        return settleAfterBrowseBatchIfReady()
    }

    mutating func serviceRemoved(key: String?, moreComing: Bool) -> Bool {
        guard !isSettled else { return false }
        if let key { pendingServiceKeys.remove(key) }
        if !moreComing { reachedBrowseBatchEnd = true }
        return settleAfterBrowseBatchIfReady()
    }

    mutating func emptyWindowElapsed() -> Bool {
        guard !isSettled, pendingServiceKeys.isEmpty else { return false }
        isSettled = true
        return true
    }

    private mutating func settleAfterBrowseBatchIfReady() -> Bool {
        guard reachedBrowseBatchEnd, pendingServiceKeys.isEmpty else { return false }
        isSettled = true
        return true
    }
}

@MainActor
protocol OpenCodeBonjourBrowsing: AnyObject {
    func start(onUpdate: @escaping (OpenCodeDiscoveryUpdate) -> Void)
    func stop()
}
