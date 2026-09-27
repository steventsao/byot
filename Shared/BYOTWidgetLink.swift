import Foundation

/// Deep links from home-screen widgets and Live Activities. iOS hands these
/// URLs straight to the containing app, so the scheme is deliberately not
/// registered in Info.plist: other apps and web pages cannot open it.
struct BYOTWidgetLink: Equatable, Sendable {
    static let scheme = "byot-widget"
    /// Opens byot without choosing a session.
    static let app = URL(string: "\(scheme)://open")!

    let serverID: UUID
    let sessionID: String
    let directory: String
    let workspace: String?

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "session"
        components.queryItems = [
            URLQueryItem(name: "server", value: serverID.uuidString),
            URLQueryItem(name: "session", value: sessionID),
            URLQueryItem(name: "directory", value: directory),
        ] + (workspace.map { [URLQueryItem(name: "workspace", value: $0)] } ?? [])
        return components.url ?? Self.app
    }

    init(serverID: UUID, sessionID: String, directory: String, workspace: String?) {
        self.serverID = serverID
        self.sessionID = sessionID
        self.directory = directory
        self.workspace = workspace
    }

    /// Returns nil for the plain "open" link and for anything malformed.
    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "session",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let server = value("server").flatMap(UUID.init(uuidString:)),
              let session = value("session"), !session.isEmpty,
              let directory = value("directory") else { return nil }
        self.init(serverID: server, sessionID: session, directory: directory,
                  workspace: value("workspace").flatMap { $0.isEmpty ? nil : $0 })
    }
}
