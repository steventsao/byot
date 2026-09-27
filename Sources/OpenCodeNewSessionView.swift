import SwiftUI

/// New conversations choose their context on the page instead of presenting a
/// long, mixed server/project modal. Creating a session remains explicit.
struct OpenCodeNewSessionView: View {
    let profiles: [OpenCodeServerProfile]
    let makeClient: (OpenCodeServerProfile) -> OpenCodeClient
    private let share: BYOTShareContent?
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

    init(profiles: [OpenCodeServerProfile], initialProfile: OpenCodeServerProfile,
         share: BYOTShareContent? = nil, shares: BYOTShareCenter = .shared,
         makeClient: @escaping (OpenCodeServerProfile) -> OpenCodeClient) {
        self.profiles = profiles
        self.makeClient = makeClient
        self.share = share
        _shares = ObservedObject(wrappedValue: shares)
        _selectedServerID = State(initialValue: initialProfile.id)
    }

    var body: some View {
        Group {
            if let createdSession, let client {
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
                            Picker("Server", selection: $selectedServerID) {
                                ForEach(profiles) { Text($0.name).tag($0.id) }
                            }
                            .accessibilityIdentifier("new-session-server")
                            if isLoading {
                                ProgressView("Loading projects")
                            } else {
                                Picker("Project", selection: $directory) {
                                    ForEach(projects) { Text($0.displayName).tag($0.worktree) }
                                    Text("Other directory…").tag("")
                                }
                                .accessibilityIdentifier("new-session-project")
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
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(BYOTBrand.chromeTint)
                        .disabled(isCreating)
                        if let error {
                            ErrorBanner(message: error, actionTitle: "Refresh") {
                                Task { await loadProjects() }
                            }
                        }
                        if let share { shareBanner(share) }
                        Button {
                            createSession()
                        } label: {
                            HStack(spacing: 8) {
                                if isCreating { ProgressView() }
                                Text("Start session")
                                Image(systemName: "arrow.right")
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
        let directory = targetDirectory
        Task {
            defer { isCreating = false }
            do {
                let session = try await client.createSession(directory: directory, title: nil)
                if let share { deliver(share, to: session, serverID: client.profile.id) }
                createdSession = session
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
            shares.notice = "byot couldn’t add what you shared to this session’s message. "
                + "It’s kept for the next time you open byot."
        }
    }
}
