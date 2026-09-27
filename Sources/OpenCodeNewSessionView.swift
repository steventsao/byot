import SwiftUI

/// Where a new session runs: the project's own checkout, an existing worktree, or a
/// worktree created for it (as the web app's new-session view offers).
enum OpenCodeNewSessionWorkspace: Hashable, Sendable {
    case main
    case existing(String)
    case new
}

/// New conversations choose their context on the page instead of presenting a
/// long, mixed server/project modal. Creating a session remains explicit.
struct OpenCodeNewSessionView: View {
    let profiles: [OpenCodeServerProfile]
    let makeClient: (OpenCodeServerProfile) -> OpenCodeClient
    private let share: BYOTShareContent?
    /// On regular width the split view opens the new session in its detail
    /// column and selects it in the sidebar, instead of showing it here.
    private let onCreated: ((OpenCodeSessionSelection) -> Void)?
    @ObservedObject private var shares: BYOTShareCenter
    @State private var selectedServerID: UUID
    @State private var client: OpenCodeClient?
    @State private var projects: [OpenCodeProject] = []
    @State private var directory = ""
    @State private var customDirectory = ""
    @State private var isLoading = true
    @State private var isCreating = false
    @State private var error: String?
    @State private var canCreate = false
    @State private var createdSession: OpenCodeSession?
    @State private var attention: OpenCodeSessionAttentionStore?
    @State private var loadID = UUID()
    @StateObject private var worktrees = OpenCodeWorktreeStore()
    @State private var workspace = OpenCodeNewSessionWorkspace.main
    @State private var worktreeName = ""
    @State private var worktreeRoute: OpenCodeWorktreeRoute?

    init(profiles: [OpenCodeServerProfile], initialProfile: OpenCodeServerProfile,
         share: BYOTShareContent? = nil, shares: BYOTShareCenter = .shared,
         onCreated: ((OpenCodeSessionSelection) -> Void)? = nil,
         makeClient: @escaping (OpenCodeServerProfile) -> OpenCodeClient) {
        self.profiles = profiles
        self.makeClient = makeClient
        self.share = share
        self.onCreated = onCreated
        _shares = ObservedObject(wrappedValue: shares)
        _selectedServerID = State(initialValue: initialProfile.id)
    }

    var body: some View {
        Group {
            if let createdSession, let client, onCreated == nil {
                OpenCodeSessionView(client: client, session: createdSession,
                                    directory: createdSession.directory, attention: attention,
                                    startsWithComposerFocused: true)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        BYOTWordmark()
                            .padding(.top, 56)
                        Text("Start a conversation")
                            .font(.cleanTitleBold)
                            .multilineTextAlignment(.center)
                        VStack(alignment: .leading, spacing: 12) {
                            choiceMenu("Server", selection: $selectedServerID, value: serverName,
                                       identifier: "new-session-server") {
                                ForEach(profiles) { Text($0.name).tag($0.id) }
                            }
                            if isLoading {
                                ProgressView("Loading projects")
                            } else {
                                choiceMenu("Project", selection: $directory, value: projectName,
                                           identifier: "new-session-project") {
                                    ForEach(projects) { Text($0.displayName).tag($0.worktree) }
                                    Text("Other directory…").tag("")
                                }
                                if directory.isEmpty {
                                    TextField("Working directory", text: $customDirectory)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .padding(12)
                                        .background(BYOTBrand.controlSurface,
                                                    in: RoundedRectangle(cornerRadius: 12))
                                        .accessibilityIdentifier("new-session-directory")
                                } else {
                                    Text(directory)
                                        .font(.cleanCaption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if worktrees.availability == .available && !directory.isEmpty {
                                    workspacePicker
                                }
                            }
                        }
                        // Full width, so the column stays put when the worktree
                        // name field appears and the menus line up with their captions.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tint(BYOTBrand.chromeTint)
                        .disabled(isCreating)
                        if let error {
                            ErrorBanner(message: error, actionTitle: String(localized: "Refresh")) {
                                Task { await loadProjects() }
                            }
                        }
                        if let share { shareBanner(share) }
                        Button {
                            createSession()
                        } label: {
                            HStack(spacing: 8) {
                                if isCreating { ProgressView() }
                                Text(startTitle)
                                if !isCreating { Image(systemName: "arrow.right").accessibilityHidden(true) }
                            }
                            .frame(minHeight: 36)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(BYOTBrand.primaryAction)
                        .foregroundStyle(BYOTBrand.primaryActionInk)
                        .disabled(isLoading || isCreating || !canCreate || targetDirectory.isEmpty)
                        .accessibilityIdentifier("start-session")
                    }
                    .frame(maxWidth: 460)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .navigationTitle("New session")
                .navigationBarTitleDisplayMode(.inline)
                .task(id: selectedServerID) { await loadProjects() }
                .task(id: worktreeScope) { await loadWorktrees() }
                .onChange(of: worktrees.worktrees) { _, listed in
                    // A worktree deleted from the manage screen can't stay selected.
                    if case .existing(let chosen) = workspace, !listed.contains(where: { $0.directory == chosen }) {
                        workspace = .main
                    }
                }
                .navigationDestination(item: $worktreeRoute) { route in
                    if let client {
                        OpenCodeWorktreesScreen(client: client, route: route, attention: attention)
                    }
                }
                .onChange(of: worktreeRoute) { _, route in
                    if route == nil { Task { await worktrees.load() } }
                }
            }
        }
        .background(BYOTBrand.canvas)
        .onDisappear {
            // Backing out keeps the share in the inbox for the next time byot opens.
            if let share, createdSession == nil { shares.release(share) }
        }
    }

    private func shareBanner(_ share: BYOTShareContent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Adding to your first message", systemImage: "square.and.arrow.down")
                .font(.cleanCaptionBold)
                .foregroundStyle(.secondary)
            BYOTSharePreview(content: share, textLineLimit: 3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BYOTBrand.controlSurface, in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius))
        .accessibilityIdentifier("new-session-share")
    }

    /// Offered only for Git projects on servers with worktree routes.
    @ViewBuilder
    private var workspacePicker: some View {
        choiceMenu("Workspace", selection: $workspace, value: workspaceName,
                   identifier: "new-session-workspace") {
            Label("Main checkout", systemImage: "folder").tag(OpenCodeNewSessionWorkspace.main)
            ForEach(worktrees.worktrees) { worktree in
                Label(worktree.name, systemImage: "arrow.triangle.branch")
                    .tag(OpenCodeNewSessionWorkspace.existing(worktree.directory))
            }
            Label("New worktree", systemImage: "plus").tag(OpenCodeNewSessionWorkspace.new)
        }
        if workspace == .new {
            TextField("Worktree name (optional)", text: $worktreeName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(createSession)
                .padding(12)
                .background(BYOTBrand.controlSurface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("new-session-worktree-name")
        }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                workspaceHint
                Spacer(minLength: 8)
                manageWorktreesButton
            }
            VStack(alignment: .leading, spacing: 4) {
                workspaceHint
                manageWorktreesButton
            }
        }
    }

    /// A menu picker whose collapsed label is plain text. The system menu
    /// picker insets its label, so it didn't line up with the captions below
    /// it, and clipped a wrapped choice at accessibility text sizes.
    private func choiceMenu<Value: Hashable, Options: View>(
        _ title: LocalizedStringKey,
        selection: Binding<Value>,
        value: String,
        identifier: String,
        @ViewBuilder options: () -> Options
    ) -> some View {
        Menu {
            Picker(title, selection: selection, content: options)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.cleanCaptionBold)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
        .accessibilityIdentifier(identifier)
    }

    private var serverName: String {
        profiles.first { $0.id == selectedServerID }?.name ?? ""
    }

    private var projectName: String {
        if directory.isEmpty { return String(localized: "Other directory…") }
        return projects.first { $0.worktree == directory }?.displayName ?? directory
    }

    private var workspaceName: String {
        switch workspace {
        case .main: String(localized: "Main checkout")
        case .existing(let directory):
            worktrees.worktrees.first { $0.directory == directory }?.name ?? String(localized: "Worktree")
        case .new: String(localized: "New worktree")
        }
    }

    private var workspaceHint: some View {
        Text(workspaceDescription)
            .font(.cleanCaption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var manageWorktreesButton: some View {
        Button("Manage worktrees") {
            guard let project = projects.first(where: { $0.worktree == directory }) else { return }
            worktreeRoute = OpenCodeWorktreeRoute(directory: project.worktree, projectName: project.displayName)
        }
        .font(.cleanCaptionBold)
        .frame(minHeight: 44)
        .tint(BYOTBrand.interactionTint)
        .accessibilityIdentifier("new-session-manage-worktrees")
    }

    private var workspaceDescription: String {
        switch workspace {
        case .main:
            String(localized: "Works in the project’s own checkout.")
        case .existing(let directory):
            worktrees.worktrees.first { $0.directory == directory }.flatMap(worktrees.branch(of:))
                .map { String(localized: "Works on \($0), apart from the main checkout.") } ?? String(localized: "Works apart from the main checkout.")
        case .new:
            OpenCodeWorktreeNaming.branch(for: worktreeName)
                .map { String(localized: "Creates the branch \($0) in a new folder on the server.") }
                ?? String(localized: "OpenCode picks a name and creates its branch in a new folder on the server.")
        }
    }

    private var startTitle: String {
        switch worktrees.creation {
        case .creating: String(localized: "Creating worktree…")
        case .preparing: String(localized: "Preparing worktree…")
        case nil: isCreating ? String(localized: "Starting session…") : String(localized: "Start session")
        }
    }

    private var worktreeScope: String { "\(selectedServerID)|\(directory)|\(canCreate)" }

    private func loadWorktrees() async {
        workspace = .main
        worktreeName = ""
        guard canCreate, let client, let project = projects.first(where: { $0.worktree == directory }),
              project.vcs == "git" else {
            worktrees.use(nil)
            return
        }
        worktrees.use(OpenCodeWorktreeService(
            client: client, route: OpenCodeWorktreeRoute(directory: project.worktree, projectName: project.displayName)))
        await worktrees.load()
    }

    private var targetDirectory: String {
        (directory.isEmpty ? customDirectory : directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadProjects() async {
        guard let profile = profiles.first(where: { $0.id == selectedServerID }) else { return }
        let id = selectedServerID
        let requestID = UUID()
        loadID = requestID
        let client = makeClient(profile)
        self.client = client
        attention = OpenCodeSessionAttentionStore(serverID: profile.id)
        isLoading = true
        canCreate = false
        error = nil
        projects = []
        directory = ""
        customDirectory = ""
        defer { if loadID == requestID { isLoading = false } }
        do {
            let compatibility = try await client.probeCompatibility()
            guard !Task.isCancelled, id == selectedServerID, loadID == requestID else { return }
            guard compatibility.state != .unsupported else {
                error = compatibility.redactedSummary
                return
            }
            let available = try await client.listProjects()
            guard !Task.isCancelled, id == selectedServerID, loadID == requestID else { return }
            var seen = Set<String>()
            projects = available.filter { seen.insert($0.worktree).inserted }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            if let configured = profile.normalizedDirectory {
                if projects.contains(where: { $0.worktree == configured }) { directory = configured }
                else { customDirectory = configured }
            } else {
                directory = projects.first?.worktree ?? ""
            }
            canCreate = true
        } catch {
            guard !Task.isCancelled, id == selectedServerID, loadID == requestID else { return }
            self.error = error.localizedDescription
        }
    }

    private func createSession() {
        guard let client, canCreate, !isCreating, !targetDirectory.isEmpty else { return }
        isCreating = true
        error = nil
        var directory = targetDirectory
        // Worktrees belong to a listed project; a typed directory always starts in place.
        let workspace = worktrees.availability == .available && !self.directory.isEmpty ? workspace : .main
        Task {
            defer { isCreating = false }
            switch workspace {
            case .main:
                break
            case .existing(let worktree):
                directory = worktree
            case .new:
                guard let worktree = await worktrees.create(name: worktreeName) else {
                    error = worktrees.actionError ?? String(localized: "Couldn’t create the worktree.")
                    return
                }
                // A retry after a failed start reuses this worktree instead of making another.
                self.workspace = .existing(worktree.directory)
                worktreeName = ""
                directory = worktree.directory
            }
            do {
                let session = try await client.createSession(directory: directory, title: nil)
                if let share { deliver(share, to: session, serverID: client.profile.id) }
                createdSession = session
                onCreated?(OpenCodeSessionSelection(client: client, session: session, attention: attention,
                                                    focusesComposer: true))
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Puts the share in the new session's draft before its composer loads.
    private func deliver(_ share: BYOTShareContent, to session: OpenCodeSession, serverID: UUID) {
        let store = OpenCodeComposerDraftStore(serverID: serverID, sessionID: session.id,
                                               directory: session.directory, workspace: session.workspaceID)
        do {
            try shares.deliver(share, into: store)
        } catch {
            shares.release(share)
            shares.notice = String(localized: "byot couldn’t add what you shared to this session’s message. It’s kept for the next time you open byot.")
        }
    }
}
