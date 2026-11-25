import SwiftUI

struct DesktopRootView: View {
    @ObservedObject var appState: DesktopAppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 256, ideal: 292, max: 372)
        } detail: {
            detailArea
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $appState.showServerSheet, onDismiss: {
            appState.incomingPairingURL = nil
            appState.editingProfile = nil
        }) {
            DesktopServerSheet(
                appState: appState,
                editing: appState.editingProfile,
                initialPairingURL: appState.incomingPairingURL
            )
        }
        .sheet(isPresented: $appState.showPairPhoneSheet) {
            DesktopPairPhoneView(appState: appState, pairing: appState.pairing)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                serverMenu
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    appState.openPairPhone()
                } label: {
                    Label("Pair iPhone", systemImage: "qrcode")
                }
                .help("Pair iPhone (⌘⇧P)")

                Button {
                    appState.refreshActiveServer()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh (⌘R)")

                Toggle(isOn: $appState.showDiffInspector) {
                    Label("Changes", systemImage: "doc.text.magnifyingglass")
                }
                .help("Changes (⌘⇧D)")
                .disabled(appState.selectedSession == nil)

                Toggle(isOn: $appState.showTerminalDrawer) {
                    Label("Terminal", systemImage: "apple.terminal")
                }
                .help("Terminal (⌘⇧T)")
                .disabled(appState.selectedSession == nil)
            }
        }
    }

    private var serverMenu: some View {
        Menu {
            if !appState.profileStore.profiles.isEmpty {
                Section("Servers") {
                    ForEach(appState.profileStore.profiles) { profile in
                        Button {
                            appState.selectServer(profile)
                        } label: {
                            HStack {
                                Text(profile.name)
                                if profile.id == appState.activeProfile?.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Divider()
            }

            Button("Add Server…", systemImage: "plus") {
                appState.editingProfile = nil
                appState.showServerSheet = true
            }

            if let active = appState.activeProfile {
                Button("Edit “\(active.name)”…", systemImage: "pencil") {
                    appState.editingProfile = active
                    appState.showServerSheet = true
                }
            }

            Divider()

            Button("Pair iPhone…", systemImage: "qrcode") {
                appState.openPairPhone()
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionStatusColor)
                    .frame(width: 7, height: 7)
                Text(appState.activeProfile?.name ?? "Servers")
                    .font(.callout.weight(.medium))
            }
        }
    }

    private var connectionStatusColor: Color {
        guard let workspace = appState.workspaceStore else {
            return appState.pairing.localOpenCode.isReachable ? DesktopBrand.statusLive : .secondary
        }
        if workspace.errorMessage != nil { return .orange }
        if workspace.compatibility != nil { return DesktopBrand.statusLive }
        return .secondary
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider()

            if let error = appState.bannerError ?? appState.workspaceStore?.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .lineLimit(3)
                    Spacer()
                    Button("Retry") { appState.refreshActiveServer() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                .padding(10)
                .background(Color.orange.opacity(0.1))
                Divider()
            }

            if appState.activeProfile == nil {
                emptyServerSidebar
            } else if let workspace = appState.workspaceStore, let browser = appState.browserStore {
                DesktopSessionsListView(
                    appState: appState,
                    workspace: workspace,
                    browser: browser
                )
            }
        }
    }

    private var sidebarHeader: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                DesktopWordmark(size: 19)
                Spacer()
                if appState.activeProfile != nil {
                    Picker("Sort", selection: $appState.sortOrder) {
                        ForEach(OpenCodeSessionSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 110)
                }
            }

            if appState.activeProfile != nil {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter sessions", text: $appState.searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !appState.searchText.isEmpty {
                        Button {
                            appState.searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(DesktopBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(DesktopBrand.hairline, lineWidth: 1))
            }
        }
        .padding(12)
    }

    private var emptyServerSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("THIS MAC")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.pairing.localOpenCode.isReachable ? DesktopBrand.statusLive : .secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text("opencode")
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(appState.pairing.localOpenCode.isReachable ? ":4096" : "offline")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                if let ts = appState.pairing.tailscale {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(ts.serveURL != nil ? DesktopBrand.statusLive : .orange)
                            .frame(width: 7, height: 7)
                        Text("tailscale")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(ts.serveURL != nil ? "https" : (ts.isOnline ? "ready" : "off"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .background(DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DesktopBrand.hairline))

            VStack(spacing: 8) {
                Button {
                    appState.openPairPhone()
                } label: {
                    Label("Pair iPhone", systemImage: "qrcode")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DesktopPrimaryButtonStyle(compact: true))

                Button {
                    appState.editingProfile = nil
                    appState.showServerSheet = true
                } label: {
                    Label("Add Server…", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(DesktopSecondaryButtonStyle(compact: true))
            }

            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private var detailArea: some View {
        if let selected = appState.selectedSession, let client = appState.activeClient {
            VSplitView {
                HSplitView {
                    DesktopSessionView(
                        client: client,
                        session: selected.session,
                        directory: selected.directory,
                        projectName: selected.projectName,
                        onOpenDiffs: { appState.showDiffInspector = true }
                    )
                    .id(selected.id)
                    .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)

                    if appState.showDiffInspector {
                        DesktopDiffInspectorView(
                            client: client,
                            session: selected.session,
                            directory: selected.directory,
                            onClose: { appState.showDiffInspector = false }
                        )
                        .id("diff:\(selected.id)")
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 580, maxHeight: .infinity)
                    }
                }
                .frame(minHeight: 320, maxHeight: .infinity)

                if appState.showTerminalDrawer {
                    DesktopTerminalDrawerView(
                        client: client,
                        route: OpenCodeTerminalRoute(
                            directory: selected.directory,
                            workspace: selected.session.workspaceID,
                            projectName: selected.projectName
                        ),
                        onClose: { appState.showTerminalDrawer = false }
                    )
                    .id("term:\(selected.directory)|\(selected.session.workspaceID ?? "")")
                    .frame(minHeight: 180, idealHeight: 240, maxHeight: 420)
                }
            }
        } else {
            DesktopWelcomeDetailView(appState: appState)
        }
    }
}

private struct DesktopSessionsListView: View {
    @ObservedObject var appState: DesktopAppState
    @ObservedObject var workspace: OpenCodeWorkspaceStore
    @ObservedObject var browser: OpenCodeSessionBrowserStore

    private var filteredGroups: [OpenCodeSessionGroup] {
        let query = appState.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ordered = browser.orderedGroups(by: appState.sortOrder, attention: browser.needsInputIDs)
        guard !query.isEmpty else { return ordered }
        return ordered.compactMap { group in
            let projectMatches = group.project.displayName.lowercased().contains(query)
                || group.project.worktree.lowercased().contains(query)
            let sessions = projectMatches
                ? group.sessions
                : group.sessions.filter { $0.title.lowercased().contains(query) }
            guard projectMatches || !sessions.isEmpty else { return nil }
            var copy = group
            copy.sessions = sessions
            return copy
        }
    }

    var body: some View {
        if workspace.isLoading && browser.groups.isEmpty {
            VStack(spacing: 10) {
                ProgressView()
                Text("Connecting to \(appState.activeProfile?.name ?? "server")…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filteredGroups.isEmpty {
            ContentUnavailableView(
                appState.searchText.isEmpty ? "No sessions yet" : "No matching sessions",
                systemImage: "bubble.left.and.bubble.right",
                description: Text(appState.searchText.isEmpty
                    ? "Start a session from any project or refresh."
                    : "Try another filter.")
            )
        } else {
            List(selection: $appState.selectedSession) {
                ForEach(filteredGroups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            let item = DesktopAppState.SelectedSession(
                                serverID: appState.activeProfile?.id ?? UUID(),
                                session: session,
                                directory: session.directory,
                                projectName: group.project.displayName
                            )
                            DesktopSessionRow(
                                session: session,
                                status: group.status(for: session),
                                needsInput: browser.needsInputIDs.contains(session.id)
                            )
                            .tag(item)
                        }
                    } header: {
                        HStack {
                            Text(group.project.displayName)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Button {
                                appState.createSession(in: group.project)
                            } label: {
                                Image(systemName: "plus")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("New session in \(group.project.displayName)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct DesktopSessionRow: View {
    let session: OpenCodeSession
    let status: OpenCodeSessionStatus?
    let needsInput: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                statusIndicator
                Text(session.title.isEmpty ? "Untitled session" : session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(relativeDate)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 8) {
                if needsInput {
                    Text("Needs input")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if let status, status.isActive {
                    Text(status.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(DesktopBrand.statusLive)
                }

                if let summary = session.summary, summary.files > 0 {
                    Text("+\(summary.additions) -\(summary.deletions)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if needsInput {
            Circle().fill(.orange).frame(width: 7, height: 7)
        } else if case .busy = status {
            Circle().fill(DesktopBrand.statusLive).frame(width: 7, height: 7)
        } else if case .retry = status {
            Circle().fill(.yellow).frame(width: 7, height: 7)
        } else {
            Circle().fill(Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
        }
    }

    private var relativeDate: String {
        let date = Date(timeIntervalSince1970: session.time.updated / 1000)
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }
}

/// Restrained monochrome welcome screen matching BYOT's iOS & web voice.
private struct DesktopWelcomeDetailView: View {
    @ObservedObject var appState: DesktopAppState

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                DesktopWordmark(size: 36)
                Text("Your OpenCode server, on Mac and iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if appState.pairing.localOpenCode.isReachable || appState.pairing.tailscale?.serveURL != nil {
                HStack(spacing: 14) {
                    if appState.pairing.localOpenCode.isReachable {
                        statusChip("127.0.0.1:4096", live: true)
                    }
                    if let serveURL = appState.pairing.tailscale?.serveURL {
                        statusChip(serveURL.replacingOccurrences(of: "https://", with: ""), live: true)
                    }
                }
            }

            HStack(spacing: 10) {
                Button {
                    appState.openPairPhone()
                } label: {
                    Label("Pair iPhone", systemImage: "qrcode")
                }
                .buttonStyle(DesktopPrimaryButtonStyle())

                Button {
                    appState.editingProfile = nil
                    appState.showServerSheet = true
                } label: {
                    Label(
                        appState.pairing.localOpenCode.isReachable ? "Connect Server…" : "Add Server…",
                        systemImage: "server.rack"
                    )
                }
                .buttonStyle(DesktopSecondaryButtonStyle())
            }

            HStack(spacing: 18) {
                shortcutHint("⌘⇧P", "Pair iPhone")
                shortcutHint("⌘K", "Servers")
                shortcutHint("⌘N", "New Session")
                shortcutHint("⌘⇧D", "Changes")
                shortcutHint("⌘⇧T", "Terminal")
            }
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesktopBrand.canvas)
    }

    private func statusChip(_ label: String, live: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(live ? DesktopBrand.statusLive : .secondary)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(DesktopBrand.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(DesktopBrand.hairline))
    }

    private func shortcutHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.caption2.monospaced().weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(DesktopBrand.hairline))
            Text(label)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
