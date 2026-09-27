import SwiftUI

// MARK: - Split view detail

/// A session opened in the split view's detail column. Each open gets its own
/// identity, so choosing a session again from a notification or a share
/// rebuilds the conversation, while reselecting it in the sidebar does not.
struct OpenCodeSessionSelection: Identifiable {
    let id = UUID()
    let client: OpenCodeClient
    let session: OpenCodeSession
    /// The session list's store, so failures seen here reach the sidebar.
    var attention: OpenCodeSessionAttentionStore?
    /// Set when a share was added to the draft or the session was just made.
    var focusesComposer = false
}

/// What the detail column shows beside the session list on regular width.
enum OpenCodeSplitDetail: Identifiable, Equatable {
    case session(OpenCodeSessionSelection)
    case newSession(OpenCodeNewSessionRoute, serverID: UUID)

    var id: UUID {
        switch self {
        case .session(let selection): selection.id
        case .newSession(let route, _): route.id
        }
    }

    var serverID: UUID {
        switch self {
        case .session(let selection): selection.client.profile.id
        case .newSession(_, let serverID): serverID
        }
    }

    /// The open conversation, if the detail shows one.
    var session: OpenCodeSession? {
        guard case .session(let selection) = self else { return nil }
        return selection.session
    }

    /// Whether the sidebar row for `session` on `serverID` is the one shown.
    func shows(_ session: OpenCodeSession, on serverID: UUID) -> Bool {
        self.serverID == serverID && self.session?.id == session.id
            && self.session?.directory == session.directory
    }

    /// The detail to keep once `activeServerID` is the connected server.
    /// Another server's conversation or new-session form would otherwise sit
    /// beside a session list it doesn't belong to.
    func retained(forActiveServer activeServerID: UUID?) -> Self? {
        serverID == activeServerID ? self : nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// MARK: - Session switching

/// Moving through the visible session list with ⌘[ and ⌘]. Like OpenCode's
/// web app, the ends wrap around and nothing selected starts from an end.
enum OpenCodeSessionStep: Equatable, Sendable {
    case previous
    case next

    func target(from currentID: String?, in orderedIDs: [String]) -> String? {
        guard !orderedIDs.isEmpty else { return nil }
        guard let currentID, let index = orderedIDs.firstIndex(of: currentID) else {
            return self == .next ? orderedIDs.first : orderedIDs.last
        }
        let offset = self == .next ? 1 : -1
        return orderedIDs[(index + offset + orderedIDs.count) % orderedIDs.count]
    }
}

enum OpenCodeSessionListOrder {
    /// The sessions in the order the list shows them. A collapsed project's
    /// sessions are hidden, so switching skips them, except while searching,
    /// which expands every project.
    static func displayed<ID: Hashable>(
        groups: [(id: ID, sessions: [OpenCodeSession])],
        collapsed: Set<ID>,
        isSearching: Bool
    ) -> [OpenCodeSession] {
        var seen = Set<String>()
        return groups
            .filter { isSearching || !collapsed.contains($0.id) }
            .flatMap(\.sessions)
            .filter { seen.insert($0.id).inserted }
    }
}

/// Something the root asks of the session list: the list owns the search
/// field, the displayed order and the session stores.
struct OpenCodeSessionListRequest: Equatable {
    enum Kind: Equatable {
        case focusSearch
        case step(OpenCodeSessionStep)
        case refresh
    }

    let id = UUID()
    let kind: Kind
}

// MARK: - Hardware keyboard shortcuts

/// App-level shortcuts the root view offers.
struct OpenCodeAppCommandActions {
    var newSession: (@MainActor () -> Void)?
    var searchSessions: (@MainActor () -> Void)?
    var previousSession: (@MainActor () -> Void)?
    var nextSession: (@MainActor () -> Void)?

    /// Which shortcuts apply. Nothing works without a server or behind a
    /// sheet; switching sessions needs the sidebar the order comes from.
    struct Availability: Equatable {
        var newSession: Bool
        var searchSessions: Bool
        var switchSessions: Bool

        init(hasServer: Bool, isSplit: Bool, isPresentingSheet: Bool) {
            let isAvailable = hasServer && !isPresentingSheet
            newSession = isAvailable
            searchSessions = isAvailable
            switchSessions = isAvailable && isSplit
        }
    }
}

/// Shortcuts the conversation on screen offers for its composer.
struct OpenCodeComposerCommandActions {
    var send: (@MainActor () -> Void)?
    var stop: (@MainActor () -> Void)?
    /// "Queue Message" while a turn runs, so the shortcut list says what ⌘↩ does.
    var sendTitle = "Send Message"

    /// What the shortcut list shows. The composer reports only changes to it.
    struct State: Equatable {
        var canSend: Bool
        var canStop: Bool
        var sendTitle: String
    }

    var state: State { State(canSend: send != nil, canStop: stop != nil, sendTitle: sendTitle) }
}

/// The value offered by whichever of several stacked screens is on top, such
/// as the composer shortcuts or the conversation of the screen showing. When
/// one screen covers another, the newer one is on top, whichever of the two
/// reports first.
@MainActor
final class OpenCodeTopmost<Value>: ObservableObject {
    @Published private(set) var top: Value?
    private var entries: [(id: UUID, value: Value)] = []

    /// Offers `value` for the screen `id`, or withdraws it.
    func update(_ id: UUID, _ value: Value?) {
        if let value {
            if let index = entries.firstIndex(where: { $0.id == id }) {
                entries[index].value = value
            } else {
                entries.append((id, value))
            }
        } else {
            entries.removeAll { $0.id == id }
        }
        top = entries.last?.value
    }
}

/// Carries the composer shortcuts of the conversation on screen up to the
/// root, which holds every shortcut. Shortcuts registered deeper only fire
/// while that screen's text field has focus; the root's always do.
typealias OpenCodeKeyboardRouter = OpenCodeTopmost<OpenCodeComposerCommandActions>

/// The conversation on screen, so a size change can carry it between the
/// iPhone stack and the split view.
typealias OpenCodeVisibleSessions = OpenCodeTopmost<OpenCodeSessionSelection>

private struct OpenCodeKeyboardRouterKey: EnvironmentKey {
    static let defaultValue: OpenCodeKeyboardRouter? = nil
}

private struct OpenCodeVisibleSessionsKey: EnvironmentKey {
    static let defaultValue: OpenCodeVisibleSessions? = nil
}

extension EnvironmentValues {
    var openCodeKeyboardRouter: OpenCodeKeyboardRouter? {
        get { self[OpenCodeKeyboardRouterKey.self] }
        set { self[OpenCodeKeyboardRouterKey.self] = newValue }
    }

    var openCodeVisibleSessions: OpenCodeVisibleSessions? {
        get { self[OpenCodeVisibleSessionsKey.self] }
        set { self[OpenCodeVisibleSessionsKey.self] = newValue }
    }
}

/// The hardware keyboard shortcuts, as buttons that take no space and no
/// touches. Holding ⌘ on iPad lists them by title; a disabled one is left
/// out. Buttons rather than scene commands, so they also work on iPhone.
struct OpenCodeKeyboardShortcuts: View {
    let app: OpenCodeAppCommandActions
    @ObservedObject var router: OpenCodeKeyboardRouter
    /// Off while a sheet covers the screen the shortcuts act on.
    let isEnabled: Bool

    private struct Shortcut {
        let title: String
        let key: KeyEquivalent
        let action: (@MainActor () -> Void)?
    }

    private var shortcuts: [Shortcut] {
        let composer = router.top
        return [
            Shortcut(title: "New Session", key: "n", action: app.newSession),
            Shortcut(title: composer?.sendTitle ?? "Send Message", key: .return, action: composer?.send),
            Shortcut(title: "Stop Turn", key: ".", action: composer?.stop),
            Shortcut(title: "Search Sessions", key: "k", action: app.searchSessions),
            Shortcut(title: "Previous Session", key: "[", action: app.previousSession),
            Shortcut(title: "Next Session", key: "]", action: app.nextSession),
        ]
    }

    var body: some View {
        ZStack {
            ForEach(shortcuts, id: \.key.character) { shortcut in
                Button(shortcut.title) { shortcut.action?() }
                    .keyboardShortcut(shortcut.key, modifiers: .command)
                    .disabled(!isEnabled || shortcut.action == nil)
                    // Still a shortcut, but out of sight and out of VoiceOver,
                    // which reaches each action through its visible control.
                    .hidden()
            }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

// MARK: - Empty detail

/// The detail column before a session is chosen.
struct OpenCodeSplitPlaceholderView: View {
    let openNewSession: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No session selected", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Choose a session from the list, or start a new one.")
        } actions: {
            Button(action: openNewSession) {
                Text("New session")
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(BYOTBrand.chromeTint)
            .accessibilityIdentifier("split-new-session")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BYOTBrand.canvas)
    }
}
