import SwiftUI

enum BYOTWidgetKind {
    static let sessions = "BYOTSessionsWidget"
}

enum BYOTWidgetSessionState: String, Codable, Hashable, Sendable {
    case needsResponse
    case failed
    case retrying
    case running

    var needsAttention: Bool { self == .needsResponse || self == .failed }
    var isActive: Bool { self != .failed }

    var title: String {
        switch self {
        case .needsResponse: "Needs you"
        case .failed: "Failed"
        case .retrying: "Retrying"
        case .running: "Running"
        }
    }

    var symbol: String {
        switch self {
        case .needsResponse: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .retrying: "arrow.clockwise"
        case .running: "gearshape.2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .needsResponse, .retrying: .orange
        case .failed: .red
        case .running: BYOTBrand.accent
        }
    }

    fileprivate var rank: Int {
        switch self {
        case .needsResponse: 0
        case .failed: 1
        case .retrying: 2
        case .running: 3
        }
    }
}

struct BYOTWidgetSession: Codable, Hashable, Identifiable, Sendable {
    var serverID: UUID
    var serverName: String
    var sessionID: String
    var title: String
    var projectName: String
    var directory: String
    var workspace: String?
    var state: BYOTWidgetSessionState
    var updatedAt: Date

    var id: String { BYOTTurnActivityAttributes.key(serverID: serverID, sessionID: sessionID) }

    var link: URL {
        BYOTWidgetLink(serverID: serverID, sessionID: sessionID, directory: directory, workspace: workspace).url
    }

    var accessibilityLabel: String {
        "\(title), \(state.title), \(projectName) on \(serverName)"
    }
}

struct BYOTWidgetServer: Codable, Hashable, Sendable {
    var serverID: UUID
    var name: String
    var refreshedAt: Date
    var sessions: [BYOTWidgetSession]
}

/// Active and attention-needing sessions across every server the app has
/// refreshed. Only the app writes it, and only while it is running, so each
/// server carries the time it was last seen.
struct BYOTWidgetSnapshot: Codable, Hashable, Sendable {
    /// After this long without a refresh the widget says it may be out of date.
    static let freshness: TimeInterval = 30 * 60
    /// Bounds the shared payload; widgets show at most a handful of rows.
    static let sessionLimit = 12

    var servers: [BYOTWidgetServer] = []

    /// Attention first, then retrying, then running; newest first within each.
    var sessions: [BYOTWidgetSession] {
        servers.flatMap(\.sessions).sorted { lhs, rhs in
            if lhs.state.rank != rhs.state.rank { return lhs.state.rank < rhs.state.rank }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
    }

    var attentionCount: Int { servers.flatMap(\.sessions).filter(\.state.needsAttention).count }
    var activeCount: Int { servers.flatMap(\.sessions).filter(\.state.isActive).count }
    var refreshedAt: Date? { servers.map(\.refreshedAt).min() }
    var isEmpty: Bool { servers.isEmpty }

    func isStale(at date: Date) -> Bool {
        guard let refreshedAt else { return false }
        return date.timeIntervalSince(refreshedAt) > Self.freshness
    }

    /// The link a whole-widget tap opens: the most urgent session, else the app.
    var primaryLink: URL { sessions.first(where: \.state.needsAttention)?.link ?? BYOTWidgetLink.app }

    mutating func replace(_ server: BYOTWidgetServer) {
        var server = server
        server.sessions = Array(server.sessions.sorted { lhs, rhs in
            if lhs.state.rank != rhs.state.rank { return lhs.state.rank < rhs.state.rank }
            return lhs.updatedAt > rhs.updatedAt
        }.prefix(Self.sessionLimit))
        // byot polls only the server that is open. One not refreshed within
        // `freshness` of this refresh is one you've moved away from; keeping it
        // would show its old rows as running and the whole widget as out of date.
        servers.removeAll {
            $0.serverID == server.serverID || server.refreshedAt.timeIntervalSince($0.refreshedAt) > Self.freshness
        }
        servers.append(server)
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Updates one session from a live conversation, leaving the rest of its
    /// server's last refresh untouched. `nil` removes the session.
    mutating func upsert(_ session: BYOTWidgetSession?, serverID: UUID, sessionID: String,
                         serverName: String, at date: Date) {
        var server = servers.first { $0.serverID == serverID }
            ?? BYOTWidgetServer(serverID: serverID, name: serverName, refreshedAt: date, sessions: [])
        server.sessions.removeAll { $0.sessionID == sessionID }
        if let session { server.sessions.append(session) }
        server.name = serverName
        if server.sessions.isEmpty && !servers.contains(where: { $0.serverID == serverID }) { return }
        replace(server)
    }

    mutating func removeServer(_ id: UUID) {
        servers.removeAll { $0.serverID == id }
    }
}

/// Reads and writes the snapshot as JSON in the shared suite.
struct BYOTWidgetSnapshotStore {
    static let key = "byot.widgets.snapshot.v1"
    let defaults: UserDefaults

    init(defaults: UserDefaults = BYOTAppGroup.defaults) {
        self.defaults = defaults
    }

    func load() -> BYOTWidgetSnapshot {
        guard let data = defaults.data(forKey: Self.key),
              let snapshot = try? JSONDecoder().decode(BYOTWidgetSnapshot.self, from: data) else { return BYOTWidgetSnapshot() }
        return snapshot
    }

    func save(_ snapshot: BYOTWidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
