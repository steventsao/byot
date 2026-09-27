import SwiftUI

struct OpenCodeRootView: View {
    let openAppNavigation: () -> Void
    private let makeClient: (OpenCodeServerProfile, String) -> OpenCodeClient
    /// A `byot://pair` link opened from outside the app, such as a QR code
    /// scanned with the Camera app. Consumed (set back to nil) once handled.
    @Binding private var pairingLink: URL?

    init(
        openAppNavigation: @escaping () -> Void,
        pairingLink: Binding<URL?> = .constant(nil),
        profileStore: OpenCodeProfileStore? = nil,
        push: BYOTPushNotifications = .shared,
        makeClient: @escaping (OpenCodeServerProfile, String) -> OpenCodeClient = {
            OpenCodeClient(profile: $0, password: $1)
        }
    ) {
        self.openAppNavigation = openAppNavigation
        _pairingLink = pairingLink
        self.makeClient = makeClient
        _profileStore = StateObject(wrappedValue: profileStore ?? OpenCodeProfileStore())
        _push = ObservedObject(wrappedValue: push)
    }

    @StateObject private var profileStore: OpenCodeProfileStore
    @State private var path = NavigationPath()
    @ObservedObject private var push: BYOTPushNotifications
    @State private var pathServerID: UUID?
    @State private var notificationProfile: OpenCodeServerProfile?
    private struct ProfileEditor: Identifiable {
        let id = UUID()
        let profile: OpenCodeServerProfile?
        var start: OpenCodeServerSetupRoute?
        var pairing: OpenCodePairingPayload?
    }
    @State private var profileEditor: ProfileEditor?
    @State private var profilePendingRemoval: OpenCodeServerProfile?
    @State private var profileRemovalError: String?
    @State private var pairingLinkError: String?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Group {
                    if let profile = profileStore.activeProfile {
                        OpenCodeConnectedView(
                            client: makeClient(profile, profileStore.password(for: profile)),
                            openNewSession: { path.append(OpenCodeNewSessionRoute()) }
                        )
                        .id("\(profileFingerprint(profile))|\(profileStore.connectionGeneration)")
                    } else {
                        // Scrolls so the setup choices stay reachable at accessibility text sizes.
                        GeometryReader { geometry in
                            ScrollView {
                                ContentUnavailableView {
                                    Label("Connect your server", systemImage: "network")
                                } description: {
                                    Text("Scan the pairing code from your computer, find OpenCode on this network, or enter its HTTPS address.")
                                } actions: {
                                    VStack(spacing: BYOTBrand.Space.sm) {
                                        Button("Scan pairing code", systemImage: "qrcode.viewfinder") {
                                            profileEditor = ProfileEditor(profile: nil, start: .scan)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .foregroundStyle(BYOTBrand.accentInk)
                                        .accessibilityIdentifier("scan-pairing-code")
                                        Button("Find nearby", systemImage: "wifi") {
                                            profileEditor = ProfileEditor(profile: nil, start: .nearby)
                                        }
                                        .buttonStyle(.bordered)
                                        .accessibilityIdentifier("find-nearby-servers")
                                        Button { edit(nil) } label: {
                                            Label("Add server", systemImage: "plus")
                                                .frame(minHeight: 44)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .controlSize(.large)
                                }
                                .frame(minHeight: geometry.size.height)
                            }
                            .scrollBounceBehavior(.basedOnSize)
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
            .navigationDestination(for: OpenCodeNewSessionRoute.self) { _ in
                if let profile = profileStore.activeProfile {
                    OpenCodeNewSessionView(profiles: profileStore.profiles,
                        initialProfile: profile) { profile in
                        makeClient(profile, profileStore.password(for: profile))
                    }
                }
            }
            .navigationDestination(for: BYOTPushSessionRoute.self) { destination in
                if let profile = profileStore.profiles.first(where: { $0.id == destination.serverID }) {
                    OpenCodeSessionView(client: makeClient(profile, profileStore.password(for: profile)),
                        session: destination.session, directory: destination.session.directory)
                        .id(destination.id)
                }
            }
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
        .task(id: push.pendingDestination?.id) { await openNotification() }
        .sheet(item: $notificationProfile) { profile in BYOTPushSettingsView(profile: profile) }
        .alert("Couldn’t open notification", isPresented: Binding(get: { push.routingError != nil }, set: { if !$0 { push.routingError = nil } })) {
            Button("OK") { push.routingError = nil }
        } message: { Text(push.routingError ?? "") }
        .onChange(of: profileStore.activeProfileID) { _, id in
            if pathServerID != id { path = NavigationPath() }
            pathServerID = id
        }
        .sheet(item: $profileEditor) { editor in
            OpenCodeProfileEditorView(
                profile: editor.profile,
                existingPassword: editor.profile.map(profileStore.password(for:)) ?? "",
                savedProfiles: profileStore.profiles,
                savedPassword: profileStore.password(for:),
                start: editor.start,
                pairing: editor.pairing
            ) { profile, password in
                try profileStore.save(profile, password: password)
            }
        }
        .onChange(of: pairingLink, initial: true) { _, link in
            guard let link else { return }
            pairingLink = nil
            do {
                let payload = try OpenCodePairingPayload(code: link.absoluteString)
                profileEditor = ProfileEditor(profile: nil, pairing: payload)
            } catch {
                pairingLinkError = error.localizedDescription
            }
        }
        .alert(
            "Couldn’t use pairing link",
            isPresented: Binding(
                get: { pairingLinkError != nil },
                set: { if !$0 { pairingLinkError = nil } }
            )
        ) {
            Button("OK") { pairingLinkError = nil }
        } message: {
            Text(pairingLinkError ?? "")
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
            Button("Scan pairing code", systemImage: "qrcode.viewfinder") {
                profileEditor = ProfileEditor(profile: nil, start: .scan)
            }
        }
    }

    private func openNotification() async {
        guard let destination = push.pendingDestination else { return }
        let route = destination.route
        defer { if push.pendingDestination?.id == destination.id { push.pendingDestination = nil } }
        guard let profile = profileStore.profiles.first(where: { $0.id == route.serverID }),
              let credential = push.credentials[profile.id],
              credential.fingerprint == BYOTPushCredential.fingerprint(profile) else {
            push.routingError = "The saved server has changed or was removed. Open Notifications on the correct server to pair it again."
            return
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
            path.append(BYOTPushSessionRoute(serverID: profile.id, session: details.session))
        } catch is CancellationError { }
        catch { push.routingError = "Couldn’t load this session. It may have been deleted, or the server may be offline. Open the server and try again." }
    }

    private func edit(_ profile: OpenCodeServerProfile?) {
        profileEditor = ProfileEditor(profile: profile)
    }

    private func profileFingerprint(_ profile: OpenCodeServerProfile) -> String {
        [profile.id.uuidString, profile.baseURL, profile.username, profile.directory, "\(profile.allowsLocalHTTP)"]
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
    @State private var allowsLocalHTTP: Bool
    private let isEditingSavedProfile: Bool
    @State private var setupPath: [OpenCodeServerSetupRoute]
    @State private var pendingPairing: OpenCodePairingPayload?
    @State private var isFromLink: Bool
    @FocusState private var isPasswordFocused: Bool
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var compatibilitySummary: OpenCodeCompatibilitySummary?
    @State private var probedFingerprint: String?
    @State private var copyConfirmations = 0

    let savedProfiles: [OpenCodeServerProfile]
    let savedPassword: (OpenCodeServerProfile) -> String
    let save: (OpenCodeServerProfile, String) throws -> Void

    init(
        profile: OpenCodeServerProfile?,
        existingPassword: String,
        savedProfiles: [OpenCodeServerProfile] = [],
        savedPassword: @escaping (OpenCodeServerProfile) -> String = { _ in "" },
        start: OpenCodeServerSetupRoute? = nil,
        pairing: OpenCodePairingPayload? = nil,
        save: @escaping (OpenCodeServerProfile, String) throws -> Void
    ) {
        _id = State(initialValue: profile?.id ?? UUID())
        _name = State(initialValue: profile?.name ?? "Mac mini")
        _baseURL = State(initialValue: profile?.baseURL ?? "")
        _username = State(initialValue: profile?.username ?? "opencode")
        _password = State(initialValue: existingPassword)
        _directory = State(initialValue: profile?.directory ?? "")
        _allowsLocalHTTP = State(initialValue: profile?.allowsLocalHTTP ?? false)
        isEditingSavedProfile = profile != nil
        _setupPath = State(initialValue: start.map { [$0] } ?? [])
        _pendingPairing = State(initialValue: pairing)
        _isFromLink = State(initialValue: pairing != nil)
        self.savedProfiles = savedProfiles
        self.savedPassword = savedPassword
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
        NavigationStack(path: $setupPath) {
            Form {
                Section {
                    NavigationLink(value: OpenCodeServerSetupRoute.scan) {
                        Label("Scan pairing code", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityIdentifier("editor-scan-pairing-code")
                    NavigationLink(value: OpenCodeServerSetupRoute.nearby) {
                        Label("Find nearby", systemImage: "wifi")
                    }
                    .accessibilityIdentifier("editor-find-nearby")
                } footer: {
                    Text("Fill in the form from your computer’s pairing code or a server on this Wi-Fi network.")
                }

                Section {
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
                        .focused($isPasswordFocused)
                } header: {
                    Text("Server")
                } footer: {
                    if isFromLink {
                        // Links can come from anywhere, not only your own computer.
                        Text("Filled in from a pairing link. Check that this is your server before you save.")
                    }
                }

                if isLocalHTTP {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
                                Text("Local network, not encrypted")
                                    .font(.cleanBodySemibold)
                                Text("This server uses plain HTTP, so the password and your sessions can be read by others on this network. Use HTTPS, such as Tailscale Serve, on shared Wi-Fi.")
                                    .font(.cleanCaption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "lock.open")
                                .foregroundStyle(.orange)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("local-http-notice")
                    }
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
            .navigationDestination(for: OpenCodeServerSetupRoute.self) { route in
                switch route {
                case .scan:
                    OpenCodePairingScannerView { payload in
                        apply(payload, source: .pairingCode)
                    }
                case .nearby:
                    OpenCodeDiscoveryView { server in
                        apply(server.pairingPayload, source: .nearby)
                    }
                }
            }
            .task {
                guard let pairing = pendingPairing else { return }
                pendingPairing = nil
                apply(pairing, source: .link)
            }
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
            directory: directory.trimmingCharacters(in: .whitespacesAndNewlines),
            allowsLocalHTTP: allowsLocalHTTP
        )
    }

    private var isLocalHTTP: Bool {
        allowsLocalHTTP
            && baseURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("http://")
    }

    /// A scanned code tests the server right away; a nearby server has no
    /// password yet, and a link opened from outside waits for the person to
    /// check the address before byot contacts it.
    private enum SetupSource { case pairingCode, link, nearby }

    /// Fills the form from a pairing code or nearby server and returns to it.
    /// Nothing is saved until the person taps Save.
    private func apply(_ payload: OpenCodePairingPayload, source: SetupSource) {
        let draft = OpenCodePairing.draft(
            applying: payload,
            to: OpenCodeServerDraft(profile: profile, password: password),
            isEditingSavedProfile: isEditingSavedProfile,
            savedProfiles: savedProfiles,
            savedPassword: savedPassword
        )
        id = draft.profile.id
        name = draft.profile.name
        baseURL = draft.profile.baseURL
        username = draft.profile.username
        password = draft.password
        directory = draft.profile.directory
        allowsLocalHTTP = draft.profile.allowsLocalHTTP
        compatibilitySummary = nil
        probedFingerprint = nil
        isFromLink = source == .link
        setupPath = []
        Task { @MainActor in
            // Let the pop and the field updates settle before focusing or testing.
            try? await Task.sleep(for: .milliseconds(450))
            if password.isEmpty {
                isPasswordFocused = true
            } else if source == .pairingCode {
                testConnection()
            }
        }
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
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
