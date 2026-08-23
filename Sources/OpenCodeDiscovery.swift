import Darwin
import Foundation

struct OpenCodeBonjourServiceRecord: Equatable, Sendable {
    let name: String
    let type: String
    let domain: String
    let host: String
    let port: Int
    let txt: [String: String]
}

struct OpenCodeDiscoveredServer: Equatable, Identifiable, Sendable {
    let name: String
    let host: String
    let port: Int
    let path: String
    let endpoint: URL

    var id: String {
        "\(name)|\(host)|\(port)|\(path)"
    }

    func profile() -> OpenCodeServerProfile {
        OpenCodeServerProfile(
            name: name,
            baseURL: endpoint.absoluteString,
            allowsLocalHTTP: true
        )
    }
}

enum OpenCodeLocalEndpointPolicy {
    static func isLocalHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if let zone = host.firstIndex(of: "%") {
            host = String(host[..<zone])
        }

        if isLocalIPv4(host) { return true }
        return isLocalIPv6(host)
    }

    private static func isLocalIPv4(_ host: String) -> Bool {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        let values = pieces.compactMap { Int($0) }
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
        let parsed = host.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard parsed == 1 else { return false }
        let bytes = withUnsafeBytes(of: &address) { Array($0) }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 }
            && bytes.last == 1
        let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
        return isLoopback || isLinkLocal || isUniqueLocal
    }
}

enum OpenCodeBonjourAddressResolver {
    static func localHost(from addresses: [Data]) -> String? {
        for address in addresses {
            guard let host = numericHost(from: address) else { continue }
            if OpenCodeLocalEndpointPolicy.isLocalHost(host) {
                return host
            }
        }
        return nil
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
    static func resolve(
        _ records: [OpenCodeBonjourServiceRecord]
    ) -> [OpenCodeDiscoveredServer] {
        records.compactMap(resolve)
            .reduce(into: [String: OpenCodeDiscoveredServer]()) { result, server in
                result[server.id] = server
            }
            .values
            .sorted { lhs, rhs in
                if lhs.name == rhs.name { return lhs.endpoint.absoluteString < rhs.endpoint.absoluteString }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func resolve(
        _ record: OpenCodeBonjourServiceRecord
    ) -> OpenCodeDiscoveredServer? {
        let type = record.type.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard type == "_http._tcp",
              record.name.lowercased().hasPrefix("opencode-"),
              (1...65_535).contains(record.port),
              OpenCodeLocalEndpointPolicy.isLocalHost(record.host),
              let rawPath = record.txt["path"],
              rawPath.hasPrefix("/"),
              !rawPath.contains("?"),
              !rawPath.contains("#")
        else { return nil }

        var host = record.host.trimmingCharacters(in: .whitespacesAndNewlines)
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = record.port
        components.path = rawPath
        guard let endpoint = components.url else { return nil }

        return OpenCodeDiscoveredServer(
            name: record.name,
            host: host,
            port: record.port,
            path: rawPath,
            endpoint: endpoint
        )
    }
}

enum OpenCodeDiscoveryUpdate: Equatable, Sendable {
    case services([OpenCodeBonjourServiceRecord])
    case settled
    case failure(String)
}

struct OpenCodeDiscoveryInitialSearch: Sendable {
    private var pendingServiceKeys: Set<String> = []
    private var reachedBrowseBatchEnd = false
    private(set) var isSettled = false

    mutating func serviceFound(key: String?, moreComing: Bool) -> Bool {
        guard !isSettled else { return false }
        if let key {
            pendingServiceKeys.insert(key)
        }
        if !moreComing {
            reachedBrowseBatchEnd = true
        }
        return settleAfterBrowseBatchIfReady()
    }

    mutating func resolutionFinished(key: String) -> Bool {
        guard !isSettled else { return false }
        pendingServiceKeys.remove(key)
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
