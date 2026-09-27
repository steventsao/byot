import ActivityKit
import Foundation

/// What an open conversation reports about its latest turn. `startedAt` is
/// nil until the prompt that started the turn is in the transcript.
struct BYOTTurnSnapshot: Equatable, Sendable {
    var phase: BYOTTurnPhase
    var response: BYOTTurnResponseKind?
    var tool: String?
    var detail: String?
    var pendingCount = 0
    var startedAt: Date?

    /// Maps conversation state to the Live Activity. Returns nil when the
    /// transcript has no turn to describe.
    static func make(
        status: OpenCodeSessionStatus,
        permissions: [OpenCodePermissionRequest],
        questions: [OpenCodeQuestionRequest],
        messages: [OpenCodeMessageEnvelope]
    ) -> BYOTTurnSnapshot? {
        let userIndex = messages.lastIndex { $0.info.role.lowercased() == "user" }
        let startedAt = userIndex.map { Date(timeIntervalSince1970: messages[$0].info.time.created / 1000) }
        let turn = userIndex.map { Array(messages.suffix(from: $0 + 1)) } ?? []
        let pendingCount = permissions.count + questions.count

        if let permission = permissions.first {
            return BYOTTurnSnapshot(
                phase: .needsResponse, response: .approval,
                tool: OpenCodeToolPresentation(name: permission.permission, state: Self.placeholderState).title,
                pendingCount: pendingCount, startedAt: startedAt)
        }
        if !questions.isEmpty {
            return BYOTTurnSnapshot(phase: .needsResponse, response: .answer,
                                    pendingCount: pendingCount, startedAt: startedAt)
        }
        switch status {
        case .retry(let attempt, _, _):
            return BYOTTurnSnapshot(phase: .retrying, detail: String(localized: "Attempt \(attempt)"), startedAt: startedAt)
        case .busy:
            let parts = turn.filter { $0.info.role.lowercased() == "assistant" }.flatMap(\.parts)
            if let tool = parts.last(where: { $0.type == "tool" && Self.isRunning($0.state?.status) }),
               let state = tool.state {
                let name = tool.tool ?? String(localized: "Tool")
                return BYOTTurnSnapshot(
                    phase: .working, tool: OpenCodeToolPresentation(name: name, state: state).title,
                    detail: Self.detail(tool: name, input: state.input), startedAt: startedAt)
            }
            let hasOutput = parts.contains { part in
                part.type == "tool" ? part.state != nil : part.text?.trimmedWidgetText != nil
            }
            return BYOTTurnSnapshot(phase: hasOutput ? .working : .thinking, startedAt: startedAt)
        case .idle:
            guard userIndex != nil else { return nil }
            let error = turn.last { $0.info.role.lowercased() == "assistant" }?.info.error
            let phase: BYOTTurnPhase = switch error?.name {
            case nil: .completed
            case "MessageAbortedError": .stopped
            default: .failed
            }
            return BYOTTurnSnapshot(phase: phase, startedAt: startedAt)
        }
    }

    private static let placeholderState = OpenCodeToolState(
        status: "pending", input: nil, raw: nil, title: nil, output: nil, error: nil, time: nil)

    private static func isRunning(_ status: String?) -> Bool {
        status == "running" || status == "pending"
    }

    /// A glanceable target for the Lock Screen: a file name, search pattern,
    /// host, or the agent's own short description. Commands and paths above
    /// the file name are left out because the Lock Screen is visible to anyone.
    static func detail(tool: String, input: [String: OpenCodeJSONValue]?) -> String? {
        func value(_ keys: String...) -> String? {
            keys.lazy.compactMap { input?[$0]?.stringValue?.trimmedWidgetText }.first
        }
        let value: String? = switch tool.lowercased() {
        case "read", "write", "edit", "list", "patch", "multiedit":
            value("filePath", "path", "file").map { URL(fileURLWithPath: $0).lastPathComponent }
        case "glob", "grep": value("pattern", "query")
        case "webfetch": value("url").flatMap { URL(string: $0)?.host() }
        case "bash", "shell", "task": value("description")
        default: nil
        }
        return value?.trimmedWidgetText
    }
}

/// The subset of ActivityKit the controller uses, so tests can observe it.
@MainActor
protocol BYOTLiveActivityHosting: AnyObject {
    var areActivitiesEnabled: Bool { get }
    func existing() -> [(id: String, attributes: BYOTTurnActivityAttributes, state: BYOTTurnActivityAttributes.ContentState)]
    func start(_ attributes: BYOTTurnActivityAttributes, state: BYOTTurnActivityAttributes.ContentState,
               staleDate: Date) throws -> String
    func update(id: String, state: BYOTTurnActivityAttributes.ContentState, staleDate: Date?)
    func end(id: String, state: BYOTTurnActivityAttributes.ContentState, dismissAt: Date?)
}

/// Starts, updates, and ends one Live Activity per running turn. An open
/// conversation drives its activity from live events. When the conversation
/// closes, the activity stays up and the session list's status polling
/// finishes it, so a turn that completes after you leave still resolves.
@MainActor
final class BYOTLiveActivityController {
    static let enabledKey = "byot.live-activities.enabled"
    static let shared = BYOTLiveActivityController(
        host: BYOTActivityKitHost(), isSupported: isWidgetExtensionEmbedded && !BYOTLaunch.isAutomated)

    /// Without fresh events the system dims the activity and the Lock Screen
    /// asks you to open byot.
    static let staleInterval: TimeInterval = 10 * 60
    /// A finished turn stays on the Lock Screen long enough to be noticed.
    static let finishedDismissal: TimeInterval = 15 * 60
    /// iOS allows a handful of concurrent activities per app; stay under it.
    static let maximumActivities = 4

    private struct Tracked {
        let id: String
        let attributes: BYOTTurnActivityAttributes
        var state: BYOTTurnActivityAttributes.ContentState
        var isDriven: Bool
    }

    private let host: any BYOTLiveActivityHosting
    private let defaults: UserDefaults
    private let isSupported: Bool
    private var tracked: [String: Tracked] = [:]

    init(host: any BYOTLiveActivityHosting, defaults: UserDefaults = .standard,
         isSupported: Bool = BYOTLiveActivityController.isWidgetExtensionEmbedded) {
        self.host = host
        self.defaults = defaults
        self.isSupported = isSupported
        for activity in host.existing() {
            tracked[activity.attributes.key] = Tracked(
                id: activity.id, attributes: activity.attributes, state: activity.state, isDriven: false)
        }
    }

    /// Whether the person wants Live Activities. The system switch in
    /// Settings is checked separately, when an activity would start.
    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            if !newValue { endAll() }
        }
    }

    /// Live Activities render in the widget extension. A build that leaves it
    /// out (for example while its signing is pending) never starts one.
    nonisolated static var isWidgetExtensionEmbedded: Bool {
        guard let plugins = Bundle.main.builtInPlugInsURL else { return false }
        return FileManager.default.fileExists(atPath: plugins.appendingPathComponent("BYOTWidgets.appex").path)
    }

    var activeKeys: Set<String> { Set(tracked.keys) }

    /// Called by an open conversation whenever its turn changes. A new
    /// activity only starts while byot is in the foreground, as iOS requires.
    func drive(_ attributes: BYOTTurnActivityAttributes, snapshot: BYOTTurnSnapshot?,
               canStart: Bool, now: Date = .now) {
        let key = attributes.key
        guard let snapshot else { return }
        if var existing = tracked[key] {
            existing.isDriven = true
            tracked[key] = existing
            apply(snapshot, to: key, now: now)
            return
        }
        guard snapshot.phase.isActive, canStart, isEnabled, isSupported, host.areActivitiesEnabled,
              tracked.count < Self.maximumActivities else { return }
        // The server's clock can run ahead of the phone's; never start in the future.
        let state = Self.state(snapshot, startedAt: min(snapshot.startedAt ?? now, now), endedAt: now)
        guard let id = try? host.start(attributes, state: state, staleDate: now + Self.staleInterval) else { return }
        tracked[key] = Tracked(id: id, attributes: attributes, state: state, isDriven: true)
    }

    /// The conversation closed. Its activity keeps showing the last state
    /// until polling or the stale date takes over.
    func release(serverID: UUID, sessionID: String) {
        let key = BYOTTurnActivityAttributes.key(serverID: serverID, sessionID: sessionID)
        tracked[key]?.isDriven = false
    }

    /// Applies the session list's polled status to activities no open
    /// conversation is driving. Sessions missing from `statuses` are left alone.
    func reconcile(serverID: UUID, sessions: [OpenCodeSession], statuses: [String: OpenCodeSessionStatus],
                   pendingSessionIDs: Set<String>, failures: [String: String], now: Date = .now) {
        let updated = Dictionary(sessions.map { ($0.id, Date(timeIntervalSince1970: $0.time.updated / 1000)) },
                                 uniquingKeysWith: max)
        for (key, entry) in tracked where !entry.isDriven && entry.attributes.serverID == serverID {
            let sessionID = entry.attributes.sessionID
            guard let status = statuses[sessionID] else { continue }
            let current = entry.state
            var snapshot = BYOTTurnSnapshot(phase: current.phase, response: current.response, tool: current.tool,
                                            detail: current.detail, pendingCount: current.pendingCount,
                                            startedAt: current.startedAt)
            if pendingSessionIDs.contains(sessionID) {
                if current.phase != .needsResponse {
                    snapshot = BYOTTurnSnapshot(phase: .needsResponse, pendingCount: 1, startedAt: current.startedAt)
                }
            } else {
                switch status {
                case .idle:
                    snapshot = BYOTTurnSnapshot(phase: failures[sessionID] == nil ? .completed : .failed,
                                                startedAt: current.startedAt)
                case .retry(let attempt, _, _):
                    snapshot = BYOTTurnSnapshot(phase: .retrying, detail: String(localized: "Attempt \(attempt)"), startedAt: current.startedAt)
                case .busy:
                    if !current.phase.isActive || current.phase == .needsResponse || current.phase == .retrying {
                        snapshot = BYOTTurnSnapshot(phase: .working, startedAt: current.startedAt)
                    }
                }
            }
            // Polling can notice a finish long after it happened; the session's
            // last update is the better end time for the duration shown.
            apply(snapshot, to: key, now: now, endedAt: updated[sessionID].map { min($0, now) })
        }
    }

    /// Ends every activity, or only one server's, immediately.
    func endAll(serverID: UUID? = nil, now: Date = .now) {
        for (key, entry) in tracked where serverID == nil || entry.attributes.serverID == serverID {
            var state = entry.state
            if state.phase.isActive { state.endedAt = now }
            host.end(id: entry.id, state: state, dismissAt: nil)
            tracked[key] = nil
        }
    }

    private func apply(_ snapshot: BYOTTurnSnapshot, to key: String, now: Date, endedAt: Date? = nil) {
        guard let entry = tracked[key] else { return }
        // Keep the shown start so the timer never jumps, unless this is a
        // later turn in the same session (for example after a relaunch).
        var startedAt = entry.state.startedAt
        if let next = snapshot.startedAt, next.timeIntervalSince(startedAt) > 60 { startedAt = min(next, now) }
        let state = Self.state(snapshot, startedAt: startedAt, endedAt: max(startedAt, endedAt ?? now))
        if snapshot.phase.isActive {
            guard state != entry.state else { return }
            tracked[key]?.state = state
            host.update(id: entry.id, state: state, staleDate: now + Self.staleInterval)
        } else {
            host.end(id: entry.id, state: state, dismissAt: now + Self.finishedDismissal)
            tracked[key] = nil
        }
    }

    /// The turn's start stays fixed once shown, so the timer never jumps.
    private static func state(_ snapshot: BYOTTurnSnapshot, startedAt: Date, endedAt: Date)
        -> BYOTTurnActivityAttributes.ContentState {
        BYOTTurnActivityAttributes.ContentState(
            phase: snapshot.phase, response: snapshot.response, tool: snapshot.tool?.trimmedWidgetText,
            detail: snapshot.detail?.trimmedWidgetText, pendingCount: snapshot.pendingCount,
            startedAt: startedAt, endedAt: snapshot.phase.isActive ? nil : endedAt)
    }
}

/// ActivityKit-backed host. Activities are looked up by ID for each change.
@MainActor
final class BYOTActivityKitHost: BYOTLiveActivityHosting {
    private typealias TurnActivity = Activity<BYOTTurnActivityAttributes>
    /// Changes apply in the order the controller made them.
    private var queue: Task<Void, Never>?

    var areActivitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func existing() -> [(id: String, attributes: BYOTTurnActivityAttributes, state: BYOTTurnActivityAttributes.ContentState)] {
        TurnActivity.activities
            .filter { $0.activityState == .active || $0.activityState == .stale }
            .map { ($0.id, $0.attributes, $0.content.state) }
    }

    func start(_ attributes: BYOTTurnActivityAttributes, state: BYOTTurnActivityAttributes.ContentState,
               staleDate: Date) throws -> String {
        try TurnActivity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate),
                                 pushType: nil).id
    }

    func update(id: String, state: BYOTTurnActivityAttributes.ContentState, staleDate: Date?) {
        let content = ActivityContent(state: state, staleDate: staleDate)
        enqueue { await Self.activity(id)?.update(content) }
    }

    func end(id: String, state: BYOTTurnActivityAttributes.ContentState, dismissAt: Date?) {
        let content = ActivityContent(state: state, staleDate: nil)
        let policy: ActivityUIDismissalPolicy = dismissAt.map { .after($0) } ?? .immediate
        enqueue { await Self.activity(id)?.end(content, dismissalPolicy: policy) }
    }

    private func enqueue(_ change: @escaping @Sendable () async -> Void) {
        let previous = queue
        queue = Task.detached {
            await previous?.value
            await change()
        }
    }

    /// Resolved off the main actor, where the update runs.
    private nonisolated static func activity(_ id: String) -> TurnActivity? {
        TurnActivity.activities.first { $0.id == id }
    }
}
