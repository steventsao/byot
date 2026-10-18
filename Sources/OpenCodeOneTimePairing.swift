import Foundation

// OpenCode 2's own pairing (`opencode pair`, `opencode pair --remote`). The
// terminal prints links `https://<host>/auth/connect/<code>` and a QR code that
// carries {"code":"…","urls":["…"]}. A code works once and expires after five
// minutes. Redeeming it with `Accept: application/json` returns {"token":"…"},
// which the server then accepts as the Basic-auth password for user `opencode`
// for 30 days. With --remote the address is an OpenTunnel hostname with a public
// certificate; TLS ends on the person's computer, so the phone needs nothing
// tunnel-specific. Mirrors anomalyco/opencode packages/protocol/src/groups/
// server.ts and packages/app/src/servers/connect/pairing.ts.

struct OpenCodeOneTimePairing: Equatable, Sendable {
    static let username = "opencode"

    /// Every address the code may reach, in the order the server listed them.
    let urls: [URL]
    let code: String

    /// Returns nil for text that isn't an OpenCode pairing code, so the caller
    /// can try byot's own formats; throws for an OpenCode code byot can't use.
    static func parse(_ rawCode: String) throws(OpenCodePairingError) -> OpenCodeOneTimePairing? {
        let text = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = object["code"] as? String,
                  let rawURLs = object["urls"] as? [String]
            else { return nil }
            return try make(code: code, rawURLs: rawURLs)
        }
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.query == nil, components.fragment == nil
        else { return nil }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "auth", parts[2] == "connect" else { return nil }
        var origin = components
        origin.path = ""
        guard let originText = origin.string else { throw .invalidServerURL }
        return try make(code: String(parts[3]), rawURLs: [originText])
    }

    private static func make(code: String, rawURLs: [String]) throws(OpenCodePairingError) -> OpenCodeOneTimePairing {
        guard !code.isEmpty,
              code.unicodeScalars.allSatisfy({ CharacterSet.pairingCode.contains($0) })
        else { throw .notPairingCode }
        var urls: [URL] = []
        var insecure = false
        for raw in rawURLs {
            do throws(OpenCodePairingError) {
                let url = try OpenCodePairingPayload.validatedServerURL(raw)
                if !urls.contains(url) { urls.append(url) }
            } catch {
                // An address the phone can't use (plain HTTP to a public host,
                // say) doesn't spoil the others the server listed.
                if error == .insecureServerURL { insecure = true }
            }
        }
        guard !urls.isEmpty else { throw insecure ? .insecureServerURL : .invalidServerURL }
        return OpenCodeOneTimePairing(urls: urls, code: code)
    }
}

enum OpenCodePairingRedemption: Equatable, Sendable {
    case paired(url: URL, token: String)
    /// The server answered that the code was already used or has expired.
    case expired
    /// No address answered.
    case unreachable

    var payload: OpenCodePairingPayload? {
        guard case .paired(let url, let token) = self else { return nil }
        // A relay hostname is a random route and tunnel id, which makes a poor name.
        let relay = url.host?.lowercased().hasSuffix(".opentunnel.xyz") == true
        return OpenCodePairingPayload(baseURL: url, username: OpenCodeOneTimePairing.username, password: token,
                                      name: relay ? String(localized: "OpenCode remote") : nil)
    }
}

struct OpenCodePairingRedeemer: Sendable {
    var session: URLSession = .shared
    /// A tunnel's first TLS handshake can be slow, so allow more than a LAN needs.
    var timeout: TimeInterval = 10
    /// After one address redeems, how long to wait for earlier-listed addresses.
    var preferenceWindow: Duration = .seconds(1)

    private enum Attempt: Sendable {
        case token(String)
        case unauthorized
        case failed
    }

    /// Tries every address at once. The code is single-use, so at most one
    /// attempt succeeds; the token then works on every address, so the
    /// earliest-listed address that answered is the one kept (the server lists
    /// the address the person chose first).
    func redeem(_ pairing: OpenCodeOneTimePairing) async -> OpenCodePairingRedemption {
        await withTaskGroup(of: (Int, Attempt)?.self) { group in
            for (index, url) in pairing.urls.enumerated() {
                group.addTask { (index, await attempt(url, code: pairing.code)) }
            }
            var results: [Int: Attempt] = [:]
            var redeemed: (index: Int, token: String)?
            // A nil element is the end of the preference window.
            while let element = await group.next(), let (index, result) = element {
                results[index] = result
                if case .token(let token) = result, redeemed == nil {
                    redeemed = (index, token)
                    let window = preferenceWindow
                    group.addTask {
                        try? await Task.sleep(for: window)
                        return nil
                    }
                }
                if redeemed != nil, Self.preferred(results, count: pairing.urls.count) != nil { break }
            }
            group.cancelAll()
            guard let redeemed else {
                return results.values.contains { if case .unauthorized = $0 { true } else { false } }
                    ? .expired : .unreachable
            }
            let winner = pairing.urls[redeemed.index]
            guard let index = Self.preferred(results, count: pairing.urls.count), index != redeemed.index
            else { return .paired(url: winner, token: redeemed.token) }
            // An earlier address answered too (401: the code was already spent).
            // Keep it only if the token works there, like OpenCode's own app.
            let earlier = pairing.urls[index]
            let works = await accepts(earlier, token: redeemed.token)
            return .paired(url: works ? earlier : winner, token: redeemed.token)
        }
    }

    private func accepts(_ url: URL, token: String) async -> Bool {
        var request = URLRequest(url: url.appending(path: "api").appending(path: "info"), timeoutInterval: timeout)
        let credentials = Data("\(OpenCodeOneTimePairing.username):\(token)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// The first address that answered at all, once every earlier one has
    /// finished; nil while an earlier address may still answer.
    private static func preferred(_ results: [Int: Attempt], count: Int) -> Int? {
        for index in 0..<count {
            switch results[index] {
            case .token, .unauthorized: return index
            case .failed: continue
            case nil: return nil
            }
        }
        return nil
    }

    private func attempt(_ url: URL, code: String) async -> Attempt {
        var request = URLRequest(
            url: url.appending(path: "auth").appending(path: "connect").appending(path: code),
            timeoutInterval: timeout
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return .failed }
        if http.statusCode == 401 { return .unauthorized }
        guard (200..<300).contains(http.statusCode),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty
        else { return .failed }
        return .token(token)
    }
}

private extension CharacterSet {
    static let pairingCode = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
}
