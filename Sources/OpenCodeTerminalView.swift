import SwiftUI
import UIKit

/// Terminal tabs for one project on one server, over the OpenCode PTY API.
struct OpenCodeTerminalScreen: View {
    let route: OpenCodeTerminalRoute
    @StateObject private var store: OpenCodeTerminalStore
    @State private var cache = OpenCodeTerminalViewCache()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("byot.terminal.text-size-adjustment") private var textSizeAdjustment = 0.0
    @State private var isOnScreen = false
    @State private var isControlLatched = false
    @State private var isKeyboardVisible = false
    @State private var renaming: OpenCodeTerminalSession?
    @State private var renameText = ""
    @State private var closing: OpenCodeTerminalSession?

    init(client: OpenCodeClient, route: OpenCodeTerminalRoute) {
        self.init(service: OpenCodeTerminalService(client: client, route: route), route: route)
    }

    init(service: any OpenCodeTerminalServicing, route: OpenCodeTerminalRoute) {
        self.route = route
        _store = StateObject(wrappedValue: OpenCodeTerminalStore(service: service))
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.phase == .ready && !store.terminals.isEmpty {
                OpenCodeTerminalTabStrip(
                    store: store,
                    newTerminal: newTerminal,
                    newTerminalWithShell: newTerminal(shell:),
                    rename: beginRename,
                    close: requestClose
                )
            }
            if let error = store.actionError {
                ErrorBanner(message: error, actionTitle: String(localized: "Dismiss")) { store.actionError = nil }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(BYOTBrand.canvas)
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if let session = store.selected {
                    OpenCodeTerminalTitle(session: session, projectName: route.projectName)
                } else {
                    OpenCodeTerminalTitle.label(subtitle: route.projectName)
                }
            }
            ToolbarItem(placement: .topBarTrailing) { actionsMenu }
        }
        .task { await store.load() }
        .onAppear {
            isOnScreen = true
            store.resume()
        }
        .onDisappear {
            isOnScreen = false
            store.suspend()
        }
        .onChange(of: scenePhase) { _, phase in
            guard isOnScreen else { return }
            if phase == .active { store.resume() }
            if phase == .background { store.suspend() }
        }
        .onChange(of: store.selectedID) { _, _ in isControlLatched = false }
        .onChange(of: store.terminals.map(\.id)) { _, ids in cache.remove(keeping: Set(ids)) }
        .onReceive(NotificationCenter.default.publisher(for: OpenCodeTerminalViewCache.controlLatchConsumed)) { _ in
            isControlLatched = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            isKeyboardVisible = false
        }
        .alert("Rename terminal", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let session = renaming {
                    Task { await store.rename(session, to: renameText) }
                }
                renaming = nil
            }
        }
        .confirmationDialog(
            "Close \(closing?.pty.title ?? String(localized: "terminal"))?",
            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }),
            titleVisibility: .visible
        ) {
            if let closing {
                Button("Close terminal", role: .destructive) { close(closing) }
            }
        } message: {
            Text("The shell and anything running in it will stop.")
        }
    }

    @ViewBuilder private var content: some View {
        switch store.phase {
        case .loading:
            BYOTActivityView(.connecting, title: String(localized: "Opening terminal"), layout: .blocking)
        case .unavailable(let reason):
            ContentUnavailableView("Terminal unavailable", systemImage: "apple.terminal", description: Text(reason))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t open the terminal", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message.agentDisplayErrorText)
            } actions: {
                Button("Try again", systemImage: "arrow.clockwise") { Task { await store.load() } }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(BYOTBrand.accentInk)
            }
        case .ready:
            if let session = store.selected {
                OpenCodeTerminalPane(
                    session: session,
                    cache: cache,
                    appearance: appearance,
                    isControlLatched: $isControlLatched,
                    isKeyboardVisible: isKeyboardVisible,
                    // The pane only offers Close once the process has ended; nothing to confirm.
                    close: { close(session) },
                    newTerminal: newTerminal
                )
            } else {
                ContentUnavailableView {
                    Label("No terminals", systemImage: "apple.terminal")
                } description: {
                    Text("Open a shell in \(route.projectName) on this server.")
                } actions: {
                    Button("New terminal", systemImage: "plus", action: newTerminal)
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(BYOTBrand.accentInk)
                        .disabled(store.isCreating)
                }
            }
        }
    }

    private var actionsMenu: some View {
        Menu {
            // Where the server lists shells, New terminal opens a shell picker in place, so
            // the menu keeps its length at large text sizes.
            if store.phase == .ready && !store.shells.isEmpty {
                Menu("New terminal", systemImage: "plus") {
                    OpenCodeTerminalShellPicker(shells: store.shells, open: newTerminal(shell:))
                }
                .disabled(store.isCreating)
            } else {
                Button("New terminal", systemImage: "plus", action: newTerminal)
                    .disabled(store.phase != .ready || store.isCreating)
            }
            if let session = store.selected {
                OpenCodeTerminalSessionActions(
                    session: session,
                    paste: { cache.paste() },
                    rename: { beginRename(session) },
                    close: { requestClose(session) }
                )
            }
            Section("Text size") {
                Button("Larger text", systemImage: "textformat.size.larger") { adjustText(by: 1) }
                    .disabled(appearance.fontSize >= OpenCodeTerminalAppearance.fontSizes.upperBound)
                Button("Smaller text", systemImage: "textformat.size.smaller") { adjustText(by: -1) }
                    .disabled(appearance.fontSize <= OpenCodeTerminalAppearance.fontSizes.lowerBound)
                if textSizeAdjustment != 0 {
                    Button("Default size", systemImage: "arrow.uturn.backward") { textSizeAdjustment = 0 }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .tint(BYOTBrand.chromeTint)
        .accessibilityLabel("Terminal actions")
        .accessibilityIdentifier("terminal-actions")
    }

    private var appearance: OpenCodeTerminalAppearance {
        OpenCodeTerminalAppearance(
            fontSize: OpenCodeTerminalAppearance.fontSize(for: dynamicTypeSize, adjustment: textSizeAdjustment),
            isDark: colorScheme == .dark,
            increasedContrast: contrast == .increased
        )
    }

    private func adjustText(by step: Double) {
        let current = appearance.fontSize
        textSizeAdjustment += step
        // A clamped size would otherwise need extra taps to walk back.
        if appearance.fontSize == current { textSizeAdjustment -= step }
    }

    private func newTerminal() {
        Task { await store.newTerminal() }
    }

    private func newTerminal(shell: OpenCodeTerminalShell?) {
        Task { await store.newTerminal(shell: shell) }
    }

    private func beginRename(_ session: OpenCodeTerminalSession) {
        renameText = session.pty.title
        renaming = session
    }

    /// Ending a running shell is destructive, so it asks first; an ended one closes at once.
    private func requestClose(_ session: OpenCodeTerminalSession) {
        if session.isExited { close(session) } else { closing = session }
    }

    private func close(_ session: OpenCodeTerminalSession) {
        closing = nil
        Task { await store.close(session) }
    }
}

/// The screen title, with the running program's OSC title (else the project) beneath.
/// Observes the tab so the subtitle follows the program as it changes.
private struct OpenCodeTerminalTitle: View {
    @ObservedObject var session: OpenCodeTerminalSession
    let projectName: String

    var body: some View {
        Self.label(subtitle: session.processTitle ?? projectName)
    }

    static func label(subtitle: String) -> some View {
        VStack(spacing: 0) {
            Text("Terminal").font(.cleanBodySemibold)
            Text(subtitle)
                .font(.cleanCaption)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// The selected tab's menu actions. Observes the tab so Paste and Reconnect follow its
/// connection instead of the state when the screen last rendered.
private struct OpenCodeTerminalSessionActions: View {
    @ObservedObject var session: OpenCodeTerminalSession
    let paste: () -> Void
    let rename: () -> Void
    let close: () -> Void

    var body: some View {
        Button("Paste", systemImage: "doc.on.clipboard", action: paste)
            .disabled(session.state != .connected)
        Button("Rename…", systemImage: "pencil", action: rename)
        if case .failed = session.state {
            Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnectNow() }
        }
        Button("Close terminal", systemImage: "xmark", role: .destructive, action: close)
    }
}

/// The emulator, its connection status, and the accessory key row for one tab.
private struct OpenCodeTerminalPane: View {
    @ObservedObject var session: OpenCodeTerminalSession
    let cache: OpenCodeTerminalViewCache
    let appearance: OpenCodeTerminalAppearance
    @Binding var isControlLatched: Bool
    let isKeyboardVisible: Bool
    let close: () -> Void
    let newTerminal: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            OpenCodeTerminalSurface(session: session, cache: cache, appearance: appearance)
                .overlay(alignment: .top) { status }
                .animation(reduceMotion ? nil : .snappy(duration: BYOTBrand.Motion.quick), value: session.state)
            if session.isExited {
                exitedCard
            } else {
                OpenCodeTerminalKeyRow(
                    isControlLatched: $isControlLatched,
                    isKeyboardVisible: isKeyboardVisible,
                    press: { key in
                        if key == .control {
                            isControlLatched.toggle()
                            cache.press(.control, control: isControlLatched)
                        } else {
                            cache.press(key, control: isControlLatched)
                            isControlLatched = false
                        }
                    },
                    toggleKeyboard: { cache.setFocused(!isKeyboardVisible) }
                )
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch session.state {
        case .connecting:
            statusCapsule(BYOTActivityView(.connecting, title: String(localized: "Connecting"), layout: .compact))
        case .reconnecting(let attempt):
            statusCapsule(BYOTActivityView(.reconnecting, title: attempt > 1 ? String(localized: "Reconnecting (\(attempt))") : String(localized: "Reconnecting"),
                                           layout: .compact, accessibilityLabel: String(localized: "Reconnecting to the terminal")))
        case .failed(let message):
            ErrorBanner(message: message, actionTitle: String(localized: "Reconnect")) { session.reconnectNow() }
                .transition(.opacity)
        case .idle, .connected, .exited:
            EmptyView()
        }
    }

    private func statusCapsule(_ content: some View) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().stroke(BYOTBrand.hairline, lineWidth: 1) }
            .padding(.top, BYOTBrand.Space.sm)
            .transition(.opacity)
            .accessibilityIdentifier("terminal-status")
    }

    private var exitedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(exitTitle, systemImage: exitSymbol)
                .font(.cleanBodySemibold)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(exitTitle)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("terminal-exit-status")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { exitButtons }
                VStack(alignment: .leading, spacing: 10) { exitButtons }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BYOTBrand.Space.md)
        .background(BYOTBrand.surface)
        .overlay(alignment: .top) { Rectangle().fill(BYOTBrand.hairline).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var exitButtons: some View {
        Button("New terminal", systemImage: "plus", action: newTerminal)
            .buttonStyle(.borderedProminent)
            .foregroundStyle(BYOTBrand.accentInk)
            .frame(minHeight: 44)
        Button("Close tab", systemImage: "xmark", action: close)
            .buttonStyle(.bordered)
            .tint(BYOTBrand.chromeTint)
            .frame(minHeight: 44)
    }

    private var exitTitle: String {
        guard case .exited(let code) = session.state else { return String(localized: "Session ended") }
        switch code {
        case .none: return String(localized: "Session ended")
        case .some(0): return String(localized: "Process exited")
        case .some(let code): return String(localized: "Process exited with code \(code)")
        }
    }

    private var exitSymbol: String {
        if case .exited(let code?) = session.state, code != 0 { return "exclamationmark.circle" }
        return "checkmark.circle"
    }
}

/// Tabs for every PTY in the project, plus a button to open another.
private struct OpenCodeTerminalTabStrip: View {
    @ObservedObject var store: OpenCodeTerminalStore
    let newTerminal: () -> Void
    let newTerminalWithShell: (OpenCodeTerminalShell?) -> Void
    let rename: (OpenCodeTerminalSession) -> Void
    let close: (OpenCodeTerminalSession) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.terminals) { session in
                            OpenCodeTerminalTab(
                                session: session,
                                isSelected: session.id == store.selected?.id,
                                select: { store.select(session) },
                                rename: { rename(session) },
                                close: { close(session) }
                            )
                            .id(session.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onChange(of: store.selectedID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .snappy(duration: BYOTBrand.Motion.quick)) { proxy.scrollTo(id) }
                }
            }
            newButton
                .foregroundStyle(BYOTBrand.chromeTint)
                .disabled(store.isCreating)
                .accessibilityLabel("New terminal")
                .accessibilityIdentifier("terminal-new")
                .padding(.trailing, 6)
        }
        .padding(.vertical, 4)
        .background(BYOTBrand.canvas)
        .overlay(alignment: .bottom) { Rectangle().fill(BYOTBrand.hairline).frame(height: 1) }
        // Like a tab bar, the strip stops growing at the first accessibility size so the
        // terminal keeps its rows; long-press shows each tab in the large content viewer.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// A tap opens the default shell; where the server lists shells, a long press picks
    /// another one (the Terminal actions menu offers the same list).
    @ViewBuilder private var newButton: some View {
        let label = Image(systemName: "plus")
            .font(.cleanControlIcon)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        if store.shells.isEmpty {
            Button(action: newTerminal) { label }
                .buttonStyle(.plain)
        } else {
            Menu {
                OpenCodeTerminalShellPicker(shells: store.shells, open: newTerminalWithShell)
            } label: {
                label
            } primaryAction: {
                newTerminal()
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityHint("Opens the default shell. Touch and hold to choose another.")
        }
    }
}

/// "Default shell" followed by each shell the server lists.
struct OpenCodeTerminalShellPicker: View {
    let shells: [OpenCodeTerminalShell]
    let open: (OpenCodeTerminalShell?) -> Void

    var body: some View {
        Section("Shell") {
            Button("Default shell", systemImage: "apple.terminal") { open(nil) }
            ForEach(OpenCodeTerminalShell.choices(shells)) { choice in
                Button(choice.label) { open(choice.shell) }
                    .accessibilityHint(choice.shell.path)
            }
        }
    }
}

private struct OpenCodeTerminalTab: View {
    @ObservedObject var session: OpenCodeTerminalSession
    let isSelected: Bool
    let select: () -> Void
    let rename: () -> Void
    let close: () -> Void

    private var title: String { session.pty.title.trimmedNonEmpty ?? String(localized: "Terminal") }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(title)
                    .font(isSelected ? .cleanCaptionBold : .cleanCaption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(isSelected ? BYOTBrand.selectedSurface : .clear, in: Capsule())
            .overlay { Capsule().stroke(isSelected ? BYOTBrand.strongHairline : BYOTBrand.hairline, lineWidth: 1) }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
        .accessibilityShowsLargeContentViewer {
            Label(title, systemImage: "apple.terminal")
        }
        .contextMenu {
            Button("Rename…", systemImage: "pencil", action: rename)
            Button("Close terminal", systemImage: "xmark", role: .destructive, action: close)
        }
        .accessibilityLabel(title)
        .accessibilityValue(statusText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Shows this terminal")
        .accessibilityAction(named: "Rename", rename)
        .accessibilityAction(named: "Close terminal", close)
        .accessibilityIdentifier("terminal-tab-\(title)")
    }

    private var statusColor: Color {
        switch session.state {
        case .connected: BYOTBrand.accent
        case .connecting, .reconnecting: .orange
        case .failed: .red
        case .idle, .exited: .secondary.opacity(0.6)
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: String(localized: "Not connected")
        case .connecting: String(localized: "Connecting")
        case .connected: session.pty.shellName.map { String(localized: "Connected, \($0)") } ?? String(localized: "Connected")
        case .reconnecting: String(localized: "Reconnecting")
        case .exited(let code): code.map { String(localized: "Exited with code \($0)") } ?? String(localized: "Ended")
        case .failed: String(localized: "Disconnected")
        }
    }
}

/// Escape, Tab, a Control latch, repeating arrows and common shell symbols above the
/// keyboard. The row scrolls horizontally when large text needs more room.
struct OpenCodeTerminalKeyRow: View {
    @Binding var isControlLatched: Bool
    let isKeyboardVisible: Bool
    let press: (OpenCodeTerminalKey) -> Void
    let toggleKeyboard: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var keyHeight = 40.0

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(OpenCodeTerminalKey.allCases) { key in
                        keyButton(key)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            Button(action: toggleKeyboard) {
                Image(systemName: isKeyboardVisible ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.cleanControlIcon)
                    .frame(width: 48, height: max(44, keyHeight))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(BYOTBrand.chromeTint)
            .accessibilityLabel(isKeyboardVisible ? "Hide keyboard" : "Show keyboard")
            .accessibilityIdentifier("terminal-keyboard")
            .padding(.trailing, 4)
        }
        .background(BYOTBrand.surface)
        .overlay(alignment: .top) { Rectangle().fill(BYOTBrand.hairline).frame(height: 1) }
        // Keycaps stop growing at the first accessibility size, like the system keyboard;
        // long-press shows a key in the large content viewer.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func keyButton(_ key: OpenCodeTerminalKey) -> some View {
        let latched = key == .control && isControlLatched
        return Button { press(key) } label: {
            Group {
                if let symbol = key.symbol {
                    Image(systemName: symbol).font(.cleanCaptionBold)
                } else {
                    Text(key.title).font(.cleanMono.weight(.semibold))
                }
            }
            .padding(.horizontal, key.title.count > 1 ? 8 : 0)
            .frame(minWidth: 44, minHeight: max(44, keyHeight))
            .background(latched ? BYOTBrand.primaryAction : BYOTBrand.elevatedSurface,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(BYOTBrand.hairline, lineWidth: 1) }
            .foregroundStyle(latched ? BYOTBrand.primaryActionInk : BYOTBrand.ink)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(key.repeats ? .enabled : .disabled)
        .accessibilityShowsLargeContentViewer {
            if let symbol = key.symbol {
                Label(key.accessibilityLabel, systemImage: symbol)
            } else {
                Text(key.title)
            }
        }
        .accessibilityLabel(key.accessibilityLabel)
        .accessibilityValue(key == .control ? (latched ? "On" : "Off") : "")
        .accessibilityHint(key == .control ? "Applies Control to the next key you type." : "")
        .accessibilityAddTraits(latched ? .isSelected : [])
        .accessibilityIdentifier("terminal-key-\(key.rawValue)")
    }
}
