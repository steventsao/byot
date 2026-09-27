import Foundation

// Server pairing codes (#93). The format is documented in
// docs/features/server-pairing.md and produced by scripts/byot-pair-qr.sh:
//
//   byot://pair?v=1&url=<server URL>&username=<u>&password=<p>&directory=<d>&name=<n>
//
// Only `url` is required. Values are percent-encoded; `+` is a literal plus.
// A bare `https://` server address (optionally with `user:password@`) is
// accepted too, so any QR generator works.

struct OpenCodePairingPayload: Equatable, Sendable {
    static let scheme = "byot"
    static let action = "pair"
    static let version = 1

    var baseURL: URL
    var username: String?
    var password: String?
    var directory: String?
    var name: String?

    init(
        baseURL: URL,
        username: String? = nil,
        password: String? = nil,
        directory: String? = nil,
        name: String? = nil
    ) {
        self.baseURL = baseURL
        self.username = username.nonEmpty
        self.password = password.nonEmpty
        self.directory = directory.nonEmpty
        self.name = name.nonEmpty
    }

    /// Parses a scanned or pasted pairing code.
    init(code rawCode: String) throws(OpenCodePairingError) {
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: code), let scheme = components.scheme?.lowercased()
        else { throw .notPairingCode }

        switch scheme {
        case Self.scheme:
            guard components.host?.lowercased() == Self.action || components.path.lowercased() == Self.action
            else { throw .notPairingCode }
            var fields: [String: String] = [:]
            for item in components.queryItems ?? [] where fields[item.name] == nil {
                fields[item.name] = item.value ?? ""
            }
            if let version = fields["v"], version != String(Self.version) {
                throw .unsupportedVersion
            }
            guard let rawURL = fields["url"].nonEmpty else { throw .missingServerURL }
            let server = try Self.serverAddress(rawURL)
            self.init(
                baseURL: server.url,
                username: fields["username"].nonEmpty ?? server.username,
                password: fields["password"].nonEmpty ?? server.password,
                directory: fields["directory"],
                name: fields["name"]
            )
        case "https", "http":
            let server = try Self.serverAddress(code)
            self.init(baseURL: server.url, username: server.username, password: server.password)
        default:
            throw .notPairingCode
        }
    }

    /// Plain HTTP is only ever produced for a numeric local-network address.
    var allowsLocalHTTP: Bool { baseURL.scheme?.lowercased() == "http" }

    /// The `byot://pair` link for this payload. Every value is encoded with
    /// only RFC 3986 unreserved characters left bare, like the helper script.
    var link: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.action
        let fields: [(String, String?)] = [
            ("v", String(Self.version)),
            ("url", baseURL.absoluteString),
            ("username", username),
            ("password", password),
            ("directory", directory),
            ("name", name),
        ]
        components.percentEncodedQuery = fields.compactMap { key, value in
            value.map { "\(key)=\(Self.encode($0))" }
        }
        .joined(separator: "&")
        return components.url!
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .pairingUnreserved) ?? ""
    }

    private struct ServerAddress {
        let url: URL
        let username: String?
        let password: String?
    }

    private static func serverAddress(_ raw: String) throws(OpenCodePairingError) -> ServerAddress {
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              components.query == nil,
              components.fragment == nil
        else { throw .invalidServerURL }
        if scheme == "http", !OpenCodeLocalEndpointPolicy.isLocalHost(host) {
            throw .insecureServerURL
        }
        let username = components.user
        let password = components.password
        components.user = nil
        components.password = nil
        components.scheme = scheme
        components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let url = components.url else { throw .invalidServerURL }
        return ServerAddress(url: url, username: username, password: password)
    }
}

enum OpenCodePairingError: LocalizedError, Equatable, Sendable {
    case notPairingCode
    case unsupportedVersion
    case missingServerURL
    case invalidServerURL
    case insecureServerURL

    var errorDescription: String? {
        switch self {
        case .notPairingCode:
            "This isn’t a byot pairing code. Show the code from byot-pair-qr.sh, or an HTTPS server address."
        case .unsupportedVersion:
            "This pairing code needs a newer version of byot."
        case .missingServerURL:
            "This pairing code doesn’t include a server address."
        case .invalidServerURL:
            "The server address in this pairing code isn’t a complete HTTPS URL."
        case .insecureServerURL:
            "Plain HTTP pairing codes must use a local network IP address. Use an HTTPS address, such as one from Tailscale Serve."
        }
    }
}

/// The editable server form: what a pairing code or nearby server fills in.
struct OpenCodeServerDraft: Equatable, Sendable {
    var profile: OpenCodeServerProfile
    var password: String
}

enum OpenCodePairing {
    /// Applies a payload to the form. Re-pairing a saved server keeps its
    /// identity, so a new password updates it instead of adding a duplicate.
    /// A saved password or directory is reused only for the same address.
    static func draft(
        applying payload: OpenCodePairingPayload,
        to current: OpenCodeServerDraft,
        isEditingSavedProfile: Bool,
        savedProfiles: [OpenCodeServerProfile],
        savedPassword: (OpenCodeServerProfile) -> String
    ) -> OpenCodeServerDraft {
        let endpoint = endpointKey(payload.baseURL.absoluteString)
        let currentMatches = endpointKey(current.profile.baseURL) == endpoint
        let saved = isEditingSavedProfile
            ? nil
            : savedProfiles.first { endpointKey($0.baseURL) == endpoint }

        var profile = saved ?? current.profile
        if saved == nil, !isEditingSavedProfile {
            // An earlier code in this form may have matched a saved server;
            // a different address is a new server, not an edit of that one.
            if savedProfiles.contains(where: { $0.id == profile.id }) { profile.id = UUID() }
            profile.name = payload.name ?? (currentMatches ? current.profile.name : suggestedName(for: payload.baseURL))
        }
        let reused: OpenCodeServerDraft? = saved.map { OpenCodeServerDraft(profile: $0, password: savedPassword($0)) }
            ?? (currentMatches ? current : nil)

        profile.baseURL = payload.baseURL.absoluteString
        profile.username = payload.username ?? reused?.profile.username ?? "opencode"
        profile.directory = payload.directory ?? reused?.profile.directory ?? ""
        profile.allowsLocalHTTP = payload.allowsLocalHTTP
        profile.compatibility = nil
        return OpenCodeServerDraft(
            profile: profile,
            password: payload.password ?? reused?.password ?? ""
        )
    }

    /// Scheme, host and port compared case-insensitively; trailing slashes ignored.
    static func endpointKey(_ raw: String) -> String? {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : 80)
        let path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return "\(scheme)://\(host):\(port)\(path)"
    }

    /// `mac-mini.tail1234.ts.net` suggests "mac-mini"; an IP address
    /// suggests "OpenCode (192.168.1.8)".
    static func suggestedName(for url: URL) -> String {
        let host = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if OpenCodeLocalEndpointPolicy.isLocalHost(host) || host.contains(":")
            || host.split(separator: ".").allSatisfy({ Int($0) != nil }) {
            return "OpenCode (\(host))"
        }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        return label.isEmpty ? "OpenCode" : label
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

private extension CharacterSet {
    static let pairingUnreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}
