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

        if host == "localhost" || host.hasSuffix(".local") { return true }
        if isLocalIPv4(host) { return true }
        return host == "::1"
            || host.hasPrefix("fe8")
            || host.hasPrefix("fe9")
            || host.hasPrefix("fea")
            || host.hasPrefix("feb")
            || host.hasPrefix("fc")
            || host.hasPrefix("fd")
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
    case failure(String)
}

@MainActor
protocol OpenCodeBonjourBrowsing: AnyObject {
    func start(onUpdate: @escaping (OpenCodeDiscoveryUpdate) -> Void)
    func stop()
}
