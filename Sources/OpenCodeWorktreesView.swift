import SwiftUI

/// A project's worktrees: separate checkouts on their own branches, so a session can
/// change files without touching the main checkout. Mirrors the web app's workspaces:
/// create (optionally named), start a session in one, reset to the default branch, delete.
struct OpenCodeWorktreesScreen<SessionView: View>: View {
    let route: OpenCodeWorktreeRoute
    @ViewBuilder let sessionView: (OpenCodeSession) -> SessionView
    @StateObject private var store: OpenCodeWorktreeStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var isOnScreen = false
    @State private var isNaming = false
    @State private var newName = ""
    @State private var pendingReset: OpenCodeWorktree?
    @State private var pendingRemoval: OpenCodeWorktree?
    @State private var openedSession: OpenCodeSessionRoute?

    init(service: any OpenCodeWorktreeServicing, route: OpenCodeWorktreeRoute,
         @ViewBuilder sessionView: @escaping (OpenCodeSession) -> SessionView) {
        self.route = route
        self.sessionView = sessionView
        _store = StateObject(wrappedValue: OpenCodeWorktreeStore(service: service))
    }

    var body: some View {
        List {
            if let message = store.actionError {
                Section {
                    Label(message.agentDisplayErrorText, systemImage: "exclamationmark.triangle")
                        .font(.cleanCaption)
                        .foregroundStyle(BYOTBrand.diffDeletion)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("worktrees-action-error")
                }
            }
            if let message = store.refreshError {
                Section {
                    Label("Couldn’t refresh. \(message.agentDisplayErrorText)", systemImage: "exclamationmark.triangle")
                        .font(.cleanCaption)
                        .foregroundStyle(BYOTBrand.diffDeletion)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if store.creation != nil || !store.worktrees.isEmpty {
                Section {
                    ForEach(store.worktrees) { worktree in
                        OpenCodeWorktreeRow(
                            worktree: worktree,
                            branch: store.branch(of: worktree),
                            summary: store.summaries[worktree.directory],
                            operation: store.operations[worktree.directory],
                            isPreparing: store.creation == .preparing(worktree),
                            startSession: { startSession(in: worktree) },
                            reset: { pendingReset = worktree },
                            remove: { pendingRemoval = worktree }
                        )
                    }
                    if case .creating(let name) = store.creation {
                        OpenCodeWorktreeCreatingRow(name: name)
                    }
                } footer: {
                    Text("Each worktree is a separate checkout of \(route.projectName) on its own branch, so its sessions can change files without touching your main checkout.")
                        .font(.cleanCaption)
                }
            }
        }
        .overlay { stateOverlay }
        .refreshable { await store.load() }
        .navigationTitle("Worktrees")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text("Worktrees").font(.cleanBodySemibold)
                    Text(route.projectName)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            if store.availability == .available {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New worktree", systemImage: "plus", action: askForName)
                        .tint(BYOTBrand.chromeTint)
                        .disabled(store.creation != nil)
                        .accessibilityIdentifier("worktree-new")
                }
            }
        }
        .alert("New worktree", isPresented: $isNaming) {
            TextField("Name (optional)", text: $newName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("worktree-name")
            Button("Create and Start Session") { create(startingSession: true) }
            Button("Create") { create(startingSession: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("OpenCode checks out a new branch, opencode/<name>, in its own folder on the server. Leave the name empty for a random one.")
        }
        .confirmationDialog(
            pendingReset.map { "Reset “\($0.name)”?" } ?? "Reset worktree?",
            isPresented: Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } }),
            titleVisibility: .visible, presenting: pendingReset
        ) { worktree in
            Button("Reset Worktree", role: .destructive) { Task { await store.reset(worktree) } }
            Button("Cancel", role: .cancel) {}
        } message: { worktree in
            Text(OpenCodeWorktreeCopy.resetMessage(worktree, summary: store.summaries[worktree.directory]))
        }
        .confirmationDialog(
            pendingRemoval.map { "Delete “\($0.name)”?" } ?? "Delete worktree?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible, presenting: pendingRemoval
        ) { worktree in
            Button("Delete Worktree", role: .destructive) { Task { await store.remove(worktree) } }
            Button("Cancel", role: .cancel) {}
        } message: { worktree in
            Text(OpenCodeWorktreeCopy.removalMessage(worktree, summary: store.summaries[worktree.directory]))
        }
        .navigationDestination(item: $openedSession) { route in
            sessionView(route.session)
        }
        .task { await store.load() }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
        .onChange(of: scenePhase) { _, phase in
            // Worktrees are created and deleted from other clients too.
            if phase == .active && isOnScreen { Task { await store.load() } }
        }
        .accessibilityIdentifier("worktrees")
    }

    @ViewBuilder private var stateOverlay: some View {
        if store.worktrees.isEmpty && store.creation == nil {
            if let message = store.loadError {
                ContentUnavailableView {
                    Label("Couldn’t load worktrees", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message.agentDisplayErrorText)
                } actions: {
                    Button("Try again", systemImage: "arrow.clockwise") { Task { await store.load() } }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(BYOTBrand.accentInk)
                }
            } else if store.availability == .unsupported {
                ContentUnavailableView("Worktrees aren’t available", systemImage: "arrow.triangle.branch",
                                       description: Text("This OpenCode server doesn’t manage worktrees."))
            } else if !store.hasLoaded {
                BYOTActivityView(.loading, title: String(localized: "Loading worktrees"), layout: .blocking)
            } else {
                ContentUnavailableView {
                    Label("No worktrees", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("A worktree is a separate checkout of \(route.projectName) on its own branch, for sessions that shouldn’t touch your main checkout.")
                } actions: {
                    Button(action: askForName) {
                        Text("New worktree")
                            .fixedSize(horizontal: true, vertical: true)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .tint(BYOTBrand.chromeTint)
                    .accessibilityIdentifier("worktree-new-empty")
                }
            }
        }
    }

    private func askForName() {
        newName = ""
        isNaming = true
    }

    private func create(startingSession: Bool) {
        let name = newName
        Task {
            guard let worktree = await store.create(name: name), startingSession else { return }
            startSession(in: worktree)
        }
    }

    private func startSession(in worktree: OpenCodeWorktree) {
        Task {
            if let session = await store.createSession(in: worktree) {
                openedSession = OpenCodeSessionRoute(session: session)
            }
        }
    }
}

extension OpenCodeWorktreesScreen where SessionView == OpenCodeSessionView {
    init(client: OpenCodeClient, route: OpenCodeWorktreeRoute, attention: OpenCodeSessionAttentionStore? = nil) {
        self.init(service: OpenCodeWorktreeService(client: client, route: route), route: route) { session in
            OpenCodeSessionView(client: client, session: session, directory: session.directory,
                                attention: attention, startsWithComposerFocused: true)
        }
    }
}

// MARK: - Rows

private struct OpenCodeWorktreeRow: View {
    let worktree: OpenCodeWorktree
    let branch: String?
    let summary: OpenCodeWorktreeSummary?
    let operation: OpenCodeWorktreeStore.Operation?
    let isPreparing: Bool
    let startSession: () -> Void
    let reset: () -> Void
    let remove: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var iconWidth: CGFloat = 22

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(BYOTBrand.accent)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(worktree.name)
                        .font(.cleanBodySemibold)
                        .foregroundStyle(BYOTBrand.ink)
                    if let branch, branch != worktree.name {
                        Text(branch)
                            .font(.cleanCaption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text(detail)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityActions {
                if operation == nil && !isPreparing {
                    Button("New session", action: startSession)
                    Button("Reset to default branch", action: reset)
                    Button("Delete worktree", action: remove)
                }
            }
            .accessibilityIdentifier("worktree-\(worktree.name)")
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            trailing
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
        .opacity(operation == .removing ? 0.6 : 1)
        .contextMenu { if operation == nil && !isPreparing { actions } }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if operation == nil && !isPreparing {
                Button("Delete", systemImage: "trash", role: .destructive, action: remove)
                Button("Reset", systemImage: "arrow.uturn.backward", action: reset)
                    .tint(.orange)
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        if let status = progressTitle {
            HStack(spacing: 8) {
                ProgressView()
                Text(status)
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        } else {
            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.cleanControlIcon)
                    .foregroundStyle(BYOTBrand.chromeTint)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Actions for \(worktree.name)")
            .accessibilityIdentifier("worktree-actions-\(worktree.name)")
        }
    }

    @ViewBuilder private var actions: some View {
        Button("New Session", systemImage: "square.and.pencil", action: startSession)
        Button("Reset to Default Branch…", systemImage: "arrow.uturn.backward", action: reset)
        Divider()
        Button("Delete Worktree…", systemImage: "trash", role: .destructive, action: remove)
    }

    private var progressTitle: String? {
        if isPreparing { return String(localized: "Preparing…") }
        switch operation {
        case .resetting: return String(localized: "Resetting…")
        case .removing: return String(localized: "Deleting…")
        case .startingSession: return String(localized: "Starting…")
        case nil: return nil
        }
    }

    private var detail: String {
        guard let summary else { return String(localized: "Checking…") }
        let parts = [summary.changes.map(OpenCodeWorktreeCopy.changes),
                     summary.sessions.map(OpenCodeWorktreeCopy.sessions)].compactMap { $0 }
        return parts.isEmpty ? String(localized: "Details unavailable") : parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [String(localized: "Worktree \(worktree.name)")]
        if let branch { parts.append(String(localized: "branch \(branch)")) }
        parts.append(detail)
        if let progressTitle { parts.append(progressTitle) }
        return parts.joined(separator: ", ")
    }
}

private struct OpenCodeWorktreeCreatingRow: View {
    let name: String?

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            VStack(alignment: .leading, spacing: 3) {
                Text(name.map { "Creating “\($0)”…" } ?? "Creating a worktree…")
                    .font(.cleanBodySemibold)
                Text("Checking out a new branch on the server.")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 44)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("worktree-creating")
    }
}
