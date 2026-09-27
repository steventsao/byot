import Foundation
import WidgetKit

/// Publishes session state for the home-screen widget. The session list
/// replaces a server's entry after each refresh; an open conversation updates
/// its own row as events arrive. Timeline reloads are coalesced because a
/// streaming turn can change state several times a second.
@MainActor
final class BYOTWidgetSync {
    static let shared = BYOTWidgetSync(isEnabled: !BYOTLaunch.isAutomated)

    private let isEnabled: Bool
    private let store: BYOTWidgetSnapshotStore
    private let reload: @MainActor () -> Void
    private let reloadDelay: Duration
    private var snapshot: BYOTWidgetSnapshot
    private var pendingReload: Task<Void, Never>?

    init(store: BYOTWidgetSnapshotStore = BYOTWidgetSnapshotStore(),
         isEnabled: Bool = true,
         reloadDelay: Duration = .seconds(1),
         reload: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: BYOTWidgetKind.sessions) }) {
        self.isEnabled = isEnabled
        self.store = store
        self.reload = reload
        self.reloadDelay = reloadDelay
        snapshot = store.load()
    }

    var current: BYOTWidgetSnapshot { snapshot }

    func publish(_ server: BYOTWidgetServer) {
        var next = snapshot
        next.replace(server)
        commit(next)
    }

    func update(_ session: BYOTWidgetSession?, serverID: UUID, sessionID: String, serverName: String, at date: Date = .now) {
        var next = snapshot
        next.upsert(session, serverID: serverID, sessionID: sessionID, serverName: serverName, at: date)
        commit(next)
    }

    func removeServer(_ id: UUID) {
        var next = snapshot
        next.removeServer(id)
        commit(next)
    }

    /// Writes immediately and schedules the widget reload.
    private func commit(_ next: BYOTWidgetSnapshot) {
        guard isEnabled, next != snapshot else { return }
        snapshot = next
        store.save(next)
        pendingReload?.cancel()
        pendingReload = Task { [reloadDelay, weak self] in
            try? await Task.sleep(for: reloadDelay)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// The widget rows for one server after a session-list refresh.
    nonisolated static func server(
        profile: OpenCodeServerProfile,
        sessions: [OpenCodeSession],
        statuses: [String: OpenCodeSessionStatus],
        pendingSessionIDs: Set<String>,
        failures: [String: String],
        at date: Date = .now
    ) -> BYOTWidgetServer {
        let rows = sessions.compactMap { session -> BYOTWidgetSession? in
            guard let state = state(status: statuses[session.id], isPending: pendingSessionIDs.contains(session.id),
                                    hasFailure: failures[session.id] != nil) else { return nil }
            return row(profile: profile, session: session, state: state)
        }
        return BYOTWidgetServer(serverID: profile.id, name: profile.name, refreshedAt: date, sessions: rows)
    }

    nonisolated static func row(profile: OpenCodeServerProfile, session: OpenCodeSession,
                                state: BYOTWidgetSessionState) -> BYOTWidgetSession {
        BYOTWidgetSession(
            serverID: profile.id, serverName: profile.name, sessionID: session.id,
            title: session.title.trimmedWidgetText ?? "Untitled session",
            projectName: URL(fileURLWithPath: session.directory).lastPathComponent,
            directory: session.directory, workspace: session.workspaceID, state: state,
            updatedAt: Date(timeIntervalSince1970: session.time.updated / 1000))
    }

    /// A waiting request outranks the run status; a failure only shows once
    /// the session has stopped. Idle sessions without a failure are omitted.
    nonisolated static func state(status: OpenCodeSessionStatus?, isPending: Bool,
                                  hasFailure: Bool) -> BYOTWidgetSessionState? {
        if isPending { return .needsResponse }
        switch status {
        case .busy: return .running
        case .retry: return .retrying
        case .idle, nil: return hasFailure ? .failed : nil
        }
    }
}

enum BYOTLaunch {
    private static let fixtureArguments: Set<String> = [
        "--polish-ui-tests", "--durable-queue-fixture", "--text-selection-fixture", "--remote-files-fixture",
        "--session-browser-fixture", "--attachment-screenshot", "--app-store-screenshots",
    ]

    /// Unit tests and UI fixtures render canned sessions. Keep them off the
    /// Lock Screen and out of the home-screen widget.
    static let isAutomated: Bool = {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.arguments.contains(where: fixtureArguments.contains)
    }()
}
