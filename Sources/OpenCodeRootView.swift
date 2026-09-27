import SwiftUI

struct OpenCodeRootView: View {
    let openAppNavigation: () -> Void
    private let makeClient: (OpenCodeServerProfile, String) -> OpenCodeClient

    init(
        openAppNavigation: @escaping () -> Void,
        profileStore: OpenCodeProfileStore? = nil,
        push: BYOTPushNotifications = .shared,
        shares: BYOTShareCenter = .shared,
        makeClient: @escaping (OpenCodeServerProfile, String) -> OpenCodeClient = {
            OpenCodeClient(profile: $0, password: $1)
        }
    ) {
        self.openAppNavigation = openAppNavigation
        self.makeClient = makeClient
        _profileStore = StateObject(wrappedValue: profileStore ?? OpenCodeProfileStore())
        _push = ObservedObject(wrappedValue: push)
        _shares = ObservedObject(wrappedValue: shares)
    }

    @StateObject private var profileStore: OpenCodeProfileStore
    @State private var path = NavigationPath()
    @ObservedObject private var push: BYOTPushNotifications
    @ObservedObject private var shares: BYOTShareCenter
    @State private var pathServerID: UUID?
    @State private var notificationProfile: OpenCodeServerProfile?
    /// The share on screen in the picker; follows `shares.incoming` once any
    /// other sheet has finished closing.
    @State private var sharePicker: BYOTShareContent?
    private struct ProfileEditor: Identifiable {
        let id = UUID()
        let profile: OpenCodeServerProfile?
    }
    @State private var profileEditor: ProfileEditor?
    @State private var profilePendingRemoval: OpenCodeServerProfile?
    @State private var profileRemovalError: String?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The detail column on regular width. The iPhone layout uses `path`.
    @State private var splitDetail: OpenCodeSplitDetail?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var listRequest: OpenCodeSessionListRequest?
    /// Held without observing: only the shortcut buttons redraw for it.
    @State private var keyboard = OpenCodeKeyboardRouter()
    @State private var visibleSessions = OpenCodeVisibleSessions()

    /// iPad (and large iPhones in landscape) show the sessions beside the
    /// conversation. Without a server there is nothing to put beside it.
    private var isSplit: Bool {
        horizontalSizeClass == .regular && profileStore.activeProfile != nil
    }

    var body: some View {
        presentations(
            navigation
                .environment(\.openCodeKeyboardRouter, keyboard)
                .environment(\.openCodeVisibleSessions, visibleSessions)
                .background {
                    OpenCodeKeyboardShortcuts(app: appCommands, router: keyboard, isEnabled: !isPresentingSheet)
                }
                .onChange(of: isSplit) { _, isSplit in adaptNavigation(toSplit: isSplit) }
        )
    }

    @ViewBuilder
    private var navigation: some View {
        if isSplit {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sessionsColumn
                    .navigationSplitViewColumnWidth(min: 300, ideal: BYOTBrand.sidebarWidth, max: 440)
            } detail: {
                // A new selection starts a fresh stack, so a fork or new
                // session pushed inside the last conversation doesn't linger.
                NavigationStack { detailColumn }
                    .id(splitDetail?.id)
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: $path) {
                sessionsColumn
                    .navigationDestination(for: OpenCodeNewSessionRoute.self) { route in
                        if let profile = profileStore.activeProfile {
                            OpenCodeNewSessionView(profiles: profileStore.profiles,
                                initialProfile: profile, share: route.share, shares: shares) { profile in
                                makeClient(profile, profileStore.password(for: profile))
                            }
                        }
                    }
                    .navigationDestination(for: BYOTPushSessionRoute.self) { destination in
                        if let profile = profileStore.profiles.first(where: { $0.id == destination.serverID }) {
                            OpenCodeSessionView(client: makeClient(profile, profileStore.password(for: profile)),
                                session: destination.session, directory: destination.session.directory,
                                startsWithComposerFocused: destination.focusesComposer)
                                .id(destination.id)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        switch splitDetail {
        case .session(let selection):
            OpenCodeSessionView(client: selection.client, session: selection.session,
                directory: selection.session.directory, attention: selection.attention,
                startsWithComposerFocused: selection.focusesComposer,
                onDelete: {
                    splitDetail = nil
                    listRequest = OpenCodeSessionListRequest(kind: .refresh)
                })
        case .newSession(let route, let serverID):
            if let profile = profileStore.profiles.first(where: { $0.id == serverID }) {
                OpenCodeNewSessionView(profiles: profileStore.profiles, initialProfile: profile,
                    share: route.share, shares: shares, onCreated: openCreatedSession) { profile in
                    makeClient(profile, profileStore.password(for: profile))
                }
            }
        case nil:
            OpenCodeSplitPlaceholderView(openNewSession: openNewSession)
        }
    }

    private var sessionsColumn: some View {
        VStack(spacing: 0) {
            Group {
                if let profile = profileStore.activeProfile {
                    OpenCodeConnectedView(
                        client: makeClient(profile, profileStore.password(for: profile)),
                        openNewSession: openNewSession,
                        selection: isSplit ? $splitDetail : nil,
                        request: listRequest
                    )
                    .id("\(profileFingerprint(profile))|\(profileStore.connectionGeneration)")
                } else {
                    ContentUnavailableView {
                        Label("Connect your server", systemImage: "network")
                    } description: {
                        Text("Add the HTTPS address of your OpenCode server.")
                    } actions: {
                        Button("Add server", systemImage: "plus") {
                            edit(nil)
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(BYOTBrand.accentInk)
                    }
                }
            }
        }
        .background(BYOTBrand.canvas)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !profileStore.profiles.isEmpty {
                OpenCodeServerBar(
                    profiles: profileStore.profiles,
                    selectedID: profileStore.activeProfileID,
                    select: profileStore.select,
                    add: { edit(nil) }
                )
                .background(BYOTBrand.canvas)
            }
        }
        .navigationTitle(BYOTBrand.wordmark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("About byot", systemImage: "info.circle", action: openAppNavigation)
                    .labelStyle(.iconOnly)
                    .tint(BYOTBrand.chromeTint)
                    .accessibilityIdentifier("about-byot")
            }
            ToolbarItem(placement: .principal) { BYOTWordmark() }
            if profileStore.activeProfile != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    profileMenu
                        .tint(BYOTBrand.chromeTint)
                }
            }
        }
    }

    /// Sheets, alerts and routing shared by both layouts.
    private func presentations(_ content: some View) -> some View {
        content
            .task(id: push.pendingDestination?.id) { await openNotification() }
            .sheet(item: $sharePicker) { content in
                BYOTShareDestinationView(
                    content: content, profiles: profileStore.profiles, activeProfileID: profileStore.activeProfileID,
                    errorMessage: shares.deliveryError,
                    loadSessions: { (try? await BYOTIntentService.live.recentSessions(limit: 15)) ?? [] },
                    choose: { destination in await openShare(content, at: destination) },
                    discard: { shares.discard(content) })
            }
            .task(id: shares.incoming?.id) { await presentSharePicker() }
            .alert("Shared to byot", isPresented: Binding(get: { shares.notice != nil }, set: { if !$0 { shares.notice = nil } })) {
                Button("OK") { shares.notice = nil }
            } message: { Text(shares.notice ?? "") }
            .sheet(item: $notificationProfile) { profile in BYOTPushSettingsView(profile: profile) }
            .alert("Couldn’t open session", isPresented: Binding(get: { push.routingError != nil }, set: { if !$0 { push.routingError = nil } })) {
                Button("OK") { push.routingError = nil }
            } message: { Text(push.routingError ?? "") }
            .onChange(of: profileStore.activeProfileID) { _, id in
                if pathServerID != id { path = NavigationPath() }
                pathServerID = id
                splitDetail = splitDetail?.retained(forActiveServer: id)
            }
            .sheet(item: $profileEditor) { editor in
                OpenCodeProfileEditorView(
                    profile: editor.profile,
                    existingPassword: editor.profile.map(profileStore.password(for:)) ?? ""
                ) { profile, password in
                    try profileStore.save(profile, password: password)
                }
            }
            .confirmationDialog(
                "Remove this server?",
                isPresented: Binding(
                    get: { profilePendingRemoval != nil },
                    set: { if !$0 { profilePendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let profilePendingRemoval {
                    Button("Remove \(profilePendingRemoval.name)", role: .destructive) {
                        Task {
                            do {
                                try await push.remove(profilePendingRemoval.id)
                                try profileStore.remove(profilePendingRemoval)
                                BYOTWidgetSync.shared.removeServer(profilePendingRemoval.id)
                                BYOTLiveActivityController.shared.endAll(serverID: profilePendingRemoval.id)
                            } catch { profileRemovalError = error.localizedDescription }
                            self.profilePendingRemoval = nil
                        }
                    }
                }
                Button("Cancel", role: .cancel) {
                    profilePendingRemoval = nil
                }
            } message: {
                Text("The saved password will also be deleted from this iPhone.")
            }
            .alert(
                "Couldn’t remove server",
                isPresented: Binding(
                    get: { profileRemovalError != nil },
                    set: { if !$0 { profileRemovalError = nil } }
                )
            ) {
                Button("OK") { profileRemovalError = nil }
            } message: {
                Text(
                    profileRemovalError
                        ?? "The server profile and password were left unchanged."
                )
            }
    }

    private var profileMenu: some View {
        Menu("OpenCode servers", systemImage: "server.rack") {
            if profileStore.profiles.count > 1 {
                Picker("Servers", selection: Binding(
                    get: { profileStore.activeProfileID },
                    set: { id in
                        if let profile = profileStore.profiles.first(where: { $0.id == id }) {
                            profileStore.select(profile)
                        }
                    }
                )) {
                    ForEach(profileStore.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .pickerStyle(.inline)
            }
            if let profile = profileStore.activeProfile {
                Button("Notifications", systemImage: "bell") { notificationProfile = profile }
                Button("Edit server", systemImage: "pencil") {
                    edit(profile)
                }
                Button("Remove server", systemImage: "trash", role: .destructive) {
                    profilePendingRemoval = profile
                }
            }
            Button("Add server", systemImage: "plus") {
                edit(nil)
            }
        }
    }

    private func openNotification() async {
        guard let destination = push.pendingDestination else { return }
        let route = destination.route
        defer { if push.pendingDestination?.id == destination.id { push.pendingDestination = nil } }
        guard let profile = profileStore.profiles.first(where: { $0.id == route.serverID }) else {
            push.routingError = destination.origin != .notification
                ? "This server was removed from byot. Add it again to open its sessions."
                : "The saved server has changed or was removed. Open Notifications on the correct server to pair it again."
            return
        }
        if destination.origin == .notification {
            guard let credential = push.credentials[profile.id],
                  credential.fingerprint == BYOTPushCredential.fingerprint(profile) else {
                push.routingError = "The saved server has changed or was removed. Open Notifications on the correct server to pair it again."
                return
            }
        }
        profileEditor = nil
        notificationProfile = nil
        path = NavigationPath()
        pathServerID = profile.id
        profileStore.select(profile)
        if route.sessionID.isEmpty { notificationProfile = profile; return }
        do {
            let client = makeClient(profile, profileStore.password(for: profile))
            let details = try await client.sessionDetails(sessionID: route.sessionID, directory: route.directory, workspace: route.workspace)
            try Task.checkCancellation()
            guard push.pendingDestination?.id == destination.id, profileStore.activeProfileID == profile.id else { return }
            guard details.session.id == route.sessionID else { throw BYOTPushError.invalidNotification }
            show(details.session, on: profile)
        } catch is CancellationError { }
        catch { push.routingError = "Couldn’t load this session. It may have been deleted, or the server may be offline. Open the server and try again." }
    }

    /// Shows the picker for the waiting share. It replaces any sheet the root
    /// (or About, closed by the app) has open; SwiftUI drops a sheet presented
    /// while another is still closing, which would leave the share unseen.
    private func presentSharePicker() async {
        guard let content = shares.incoming else {
            sharePicker = nil
            return
        }
        let wasCovered = profileEditor != nil || notificationProfile != nil
        profileEditor = nil
        notificationProfile = nil
        if sharePicker == nil {
            try? await Task.sleep(for: .milliseconds(wasCovered ? 650 : 350))
        }
        guard !Task.isCancelled, shares.incoming?.id == content.id else { return }
        sharePicker = content
    }

    /// Opens the chosen destination with the share in its composer. The share
    /// stays in the inbox until it is written into a draft. An existing
    /// session is loaded before the picker closes, so a slow or offline server
    /// shows progress there and leaves you free to choose again.
    private func openShare(_ content: BYOTShareContent, at destination: BYOTShareDestination) async {
        let serverID = switch destination {
        case .newSession(let serverID): serverID
        case .session(let session): session.serverID
        }
        guard let profile = profileStore.profiles.first(where: { $0.id == serverID }) else {
            shares.release(content, error: "This server was removed from byot. Choose another.")
            return
        }
        var session: OpenCodeSession?
        if case .session(let target) = destination {
            do {
                let client = makeClient(profile, profileStore.password(for: profile))
                let details = try await client.sessionDetails(sessionID: target.sessionID, directory: target.directory,
                                                              workspace: target.workspace)
                guard details.session.id == target.sessionID else { throw BYOTPushError.invalidNotification }
                session = details.session
            } catch {
                guard shares.incoming?.id == content.id else { return }
                shares.release(content, error: "Couldn’t open “\(target.title)”. It may have been deleted, or the "
                    + "server may be offline. Choose another session or try again.")
                return
            }
            // Another share may have replaced this one while the session loaded.
            guard shares.incoming?.id == content.id else { return }
        }
        shares.claim(content)
        profileEditor = nil
        notificationProfile = nil
        path = NavigationPath()
        pathServerID = profile.id
        profileStore.select(profile)
        guard let session else {
            showNewSession(OpenCodeNewSessionRoute(share: content), on: profile)
            return
        }
        do {
            try shares.deliver(content, into: OpenCodeComposerDraftStore(
                serverID: profile.id, sessionID: session.id, directory: session.directory,
                workspace: session.workspaceID))
        } catch {
            shares.release(content, error: "byot couldn’t add this to that session’s message. Choose another "
                + "session or try again.")
            return
        }
        show(session, on: profile, focusesComposer: true)
    }

    // MARK: Adaptive navigation

    /// Opens a conversation reached from outside the session list: a
    /// notification, a widget, Siri, or a share.
    private func show(_ session: OpenCodeSession, on profile: OpenCodeServerProfile, focusesComposer: Bool = false) {
        if isSplit {
            splitDetail = .session(OpenCodeSessionSelection(
                client: makeClient(profile, profileStore.password(for: profile)), session: session,
                focusesComposer: focusesComposer))
        } else {
            path.append(BYOTPushSessionRoute(serverID: profile.id, session: session, focusesComposer: focusesComposer))
        }
    }

    private func showNewSession(_ route: OpenCodeNewSessionRoute, on profile: OpenCodeServerProfile) {
        if isSplit {
            splitDetail = .newSession(route, serverID: profile.id)
        } else {
            path.append(route)
        }
    }

    private func openNewSession() {
        guard let profile = profileStore.activeProfile else { return }
        // The form already open keeps what was chosen in it.
        if isSplit, case .newSession(_, profile.id) = splitDetail { return }
        showNewSession(OpenCodeNewSessionRoute(), on: profile)
    }

    /// ⌘N from anywhere: on iPhone the form replaces whatever was pushed,
    /// instead of stacking on top of a conversation.
    private func openNewSessionFromKeyboard() {
        if !isSplit { path = NavigationPath() }
        openNewSession()
    }

    /// Selects a session made in the detail column's form, switching the
    /// sidebar to its server if another one was chosen there.
    private func openCreatedSession(_ selection: OpenCodeSessionSelection) {
        let profile = selection.client.profile
        if profileStore.activeProfileID != profile.id,
           let saved = profileStore.profiles.first(where: { $0.id == profile.id }) {
            pathServerID = saved.id
            profileStore.select(saved)
        }
        splitDetail = .session(selection)
        listRequest = OpenCodeSessionListRequest(kind: .refresh)
    }

    /// Carries the open conversation across a size change: an iPad window
    /// resized in Split View or Stage Manager, or a large iPhone rotated.
    private func adaptNavigation(toSplit isSplit: Bool) {
        if isSplit {
            // The conversation on screen, however deep in the stack, opens
            // beside the list; the screens it was pushed over are dropped.
            splitDetail = visibleSessions.top.flatMap {
                OpenCodeSplitDetail.session($0).retained(forActiveServer: profileStore.activeProfileID)
            }
            path = NavigationPath()
            columnVisibility = .all
            return
        }
        var carried = NavigationPath()
        switch splitDetail?.retained(forActiveServer: profileStore.activeProfileID) {
        case .session(let selection):
            carried.append(OpenCodeSessionRoute(session: selection.session))
        case .newSession(let route, _):
            carried.append(route)
        case nil:
            break
        }
        splitDetail = nil
        path = carried
    }

    private var isPresentingSheet: Bool {
        profileEditor != nil || notificationProfile != nil || sharePicker != nil || profilePendingRemoval != nil
    }

    private var appCommands: OpenCodeAppCommandActions {
        let availability = OpenCodeAppCommandActions.Availability(
            hasServer: profileStore.activeProfile != nil, isSplit: isSplit, isPresentingSheet: isPresentingSheet)
        var actions = OpenCodeAppCommandActions()
        if availability.newSession { actions.newSession = { openNewSessionFromKeyboard() } }
        if availability.searchSessions { actions.searchSessions = { searchSessions() } }
        if availability.switchSessions {
            actions.previousSession = { step(.previous) }
            actions.nextSession = { step(.next) }
        }
        return actions
    }

    /// ⌘K brings the session list forward and puts the cursor in its search.
    private func searchSessions() {
        if isSplit {
            if columnVisibility == .detailOnly {
                withAnimation(reduceMotion ? nil : .default) { columnVisibility = .all }
            }
        } else {
            path = NavigationPath()
        }
        listRequest = OpenCodeSessionListRequest(kind: .focusSearch)
    }

    private func step(_ step: OpenCodeSessionStep) {
        listRequest = OpenCodeSessionListRequest(kind: .step(step))
    }

    private func edit(_ profile: OpenCodeServerProfile?) {
        profileEditor = ProfileEditor(profile: profile)
    }

    private func profileFingerprint(_ profile: OpenCodeServerProfile) -> String {
        [profile.id.uuidString, profile.baseURL, profile.username, profile.directory]
            .joined(separator: "|")
    }
}

private struct OpenCodeProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var id: UUID
    @State private var name: String
    @State private var baseURL: String
    @State private var username: String
    @State private var password: String
    @State private var directory: String
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var compatibilitySummary: OpenCodeCompatibilitySummary?
    @State private var probedFingerprint: String?
    @State private var copyConfirmations = 0

    let save: (OpenCodeServerProfile, String) throws -> Void

    init(
        profile: OpenCodeServerProfile?,
        existingPassword: String,
        save: @escaping (OpenCodeServerProfile, String) throws -> Void
    ) {
        _id = State(initialValue: profile?.id ?? UUID())
        _name = State(initialValue: profile?.name ?? "Mac mini")
        _baseURL = State(initialValue: profile?.baseURL ?? "")
        _username = State(initialValue: profile?.username ?? "opencode")
        _password = State(initialValue: existingPassword)
        _directory = State(initialValue: profile?.directory ?? "")
        _compatibilitySummary = State(initialValue: profile?.compatibility)
        if let profile, profile.compatibility != nil {
            _probedFingerprint = State(
                initialValue: Self.connectionFingerprint(
                    baseURL: profile.baseURL,
                    username: profile.username,
                    password: existingPassword,
                    directory: profile.directory
                )
            )
        }
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                    TextField("https://your-mac.example.ts.net", text: $baseURL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Server password", text: $password)
                        .textContentType(.password)
                }

                Section {
                    TextField("/Users/me/project", text: $directory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Working directory (optional)")
                } footer: {
                    Text("Leave blank to list known projects.")
                }

                Section {
                    Button {
                        testConnection()
                    } label: {
                        HStack {
                            Label("Test connection", systemImage: "bolt.horizontal.circle")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }
                    .disabled(isTesting || isSaving)

                    if let statusMessage {
                        Label(
                            statusMessage,
                            systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle"
                        )
                        .foregroundStyle(statusIsError ? Color.red : BYOTBrand.accent)
                        .font(.cleanCaption)
                    }
                }

                if let compatibilitySummary, probedFingerprint == connectionFingerprint {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(compatibilitySummary.stateTitle)
                                .font(.cleanBodySemibold)
                            Text(compatibilitySummary.redactedSummary)
                                .font(.cleanCaption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .combine)

                        Button("Copy compatibility summary", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = compatibilitySummary.redactedSummary
                            copyConfirmations += 1
                        }
                        .sensoryFeedback(.success, trigger: copyConfirmations)
                    } header: {
                        Text("Compatibility")
                    } footer: {
                        Text("Does not include the server address or credentials.")
                    }
                }
            }
            .onChange(of: baseURL) { _, _ in statusMessage = nil }
            .onChange(of: username) { _, _ in statusMessage = nil }
            .onChange(of: password) { _, _ in statusMessage = nil }
            .onChange(of: directory) { _, _ in statusMessage = nil }
            .navigationTitle("OpenCode server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .accessibilityLabel("Saving server")
                    } else {
                        Button("Save") { saveProfile() }
                            .disabled(isTesting)
                    }
                }
            }
        }
    }

    private var profile: OpenCodeServerProfile {
        OpenCodeServerProfile(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            directory: directory.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private var connectionFingerprint: String {
        Self.connectionFingerprint(
            baseURL: baseURL,
            username: username,
            password: password,
            directory: directory
        )
    }

    private static func connectionFingerprint(
        baseURL: String,
        username: String,
        password: String,
        directory: String
    ) -> String {
        [
            baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
            username.trimmingCharacters(in: .whitespacesAndNewlines),
            password,
            directory.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "|")
    }

    private func probeConnection() async throws -> (OpenCodeCompatibilitySummary, [OpenCodeProject]?) {
        let client = OpenCodeClient(profile: profile, password: password)
        let summary = try await client.probeCompatibility()
        compatibilitySummary = summary
        probedFingerprint = connectionFingerprint
        guard summary.state != .unsupported else { return (summary, nil) }
        let projects = try await client.listProjects()
        return (summary, projects)
    }

    private func testConnection() {
        isTesting = true
        statusMessage = nil
        Task {
            do {
                try profile.validate(password: password)
                let (summary, projects) = try await probeConnection()
                switch summary.state {
                case .compatible:
                    let projects = projects ?? []
                    let projectLine = projects.isEmpty
                        ? "No projects."
                        : "Connected to \(projects.count) project\(projects.count == 1 ? "" : "s")."
                    statusIsError = false
                    statusMessage = "\(projectLine) \(summary.stateTitle)."
                case .degraded:
                    statusIsError = false
                    statusMessage = summary.detail ?? summary.stateTitle
                case .unsupported:
                    statusIsError = true
                    statusMessage = summary.detail ?? summary.stateTitle
                }
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func saveProfile() {
        isSaving = true
        statusMessage = nil
        Task {
            do {
                try profile.validate(password: password)
                let (summary, _) = try await probeConnection()
                guard summary.state != .unsupported else {
                    statusIsError = true
                    statusMessage = summary.detail
                        ?? "This OpenCode server version is not supported."
                    isSaving = false
                    return
                }
                var profile = profile
                profile.compatibility = summary
                try save(profile, password)
                dismiss()
            } catch {
                statusIsError = true
                statusMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private struct BYOTPushSessionRoute: Hashable {
    let id = UUID()
    let serverID: UUID
    let session: OpenCodeSession
    /// Set when a share was just added to the draft, so you can finish it.
    var focusesComposer = false
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
