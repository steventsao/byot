import SwiftUI

struct OpenCodeRootView: View {
    let openAppNavigation: () -> Void
    private let makeClient: (OpenCodeServerProfile, String) -> OpenCodeClient

    init(
        openAppNavigation: @escaping () -> Void,
        profileStore: OpenCodeProfileStore? = nil,
        makeClient: @escaping (OpenCodeServerProfile, String) -> OpenCodeClient = {
            OpenCodeClient(profile: $0, password: $1)
        }
    ) {
        self.openAppNavigation = openAppNavigation
        self.makeClient = makeClient
        _profileStore = StateObject(wrappedValue: profileStore ?? OpenCodeProfileStore())
    }

    @StateObject private var profileStore: OpenCodeProfileStore
    @State private var path = NavigationPath()
    @State private var isShowingProfileEditor = false
    @State private var profileBeingEdited: OpenCodeServerProfile?
    @State private var profilePendingRemoval: OpenCodeServerProfile?
    @State private var profileRemovalError: String?

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if !profileStore.profiles.isEmpty {
                    OpenCodeServerBar(
                        profiles: profileStore.profiles,
                        selectedID: profileStore.activeProfileID,
                        select: profileStore.select,
                        add: { edit(nil) }
                    )
                }
                Group {
                    if let profile = profileStore.activeProfile {
                        OpenCodeConnectedView(
                            client: makeClient(profile, profileStore.password(for: profile))
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
            .navigationTitle("BYOT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("About BYOT", systemImage: "info.circle", action: openAppNavigation)
                        .labelStyle(.iconOnly)
                }
                if profileStore.activeProfile != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        profileMenu
                    }
                }
            }
        }
        .onChange(of: profileStore.activeProfileID) { _, _ in path = NavigationPath() }
        .sheet(isPresented: $isShowingProfileEditor) {
            OpenCodeProfileEditorView(
                profile: profileBeingEdited,
                existingPassword: profileBeingEdited.map(profileStore.password(for:)) ?? ""
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
                    do {
                        try profileStore.remove(profilePendingRemoval)
                    } catch {
                        profileRemovalError = error.localizedDescription
                    }
                    self.profilePendingRemoval = nil
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
                Section("Servers") {
                    ForEach(profileStore.profiles) { profile in
                        Button {
                            profileStore.select(profile)
                        } label: {
                            if profile.id == profileStore.activeProfileID {
                                Label(profile.name, systemImage: "checkmark")
                            } else {
                                Text(profile.name)
                            }
                        }
                    }
                }
            }
            if let profile = profileStore.activeProfile {
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

    private func edit(_ profile: OpenCodeServerProfile?) {
        profileBeingEdited = profile
        isShowingProfileEditor = true
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
