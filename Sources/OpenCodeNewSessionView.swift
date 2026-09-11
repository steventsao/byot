import SwiftUI

/// New conversations choose their context on the page instead of presenting a
/// long, mixed server/project modal. Creating a session remains explicit.
struct OpenCodeNewSessionView: View {
    let profiles: [OpenCodeServerProfile]
    let makeClient: (OpenCodeServerProfile) -> OpenCodeClient
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
         makeClient: @escaping (OpenCodeServerProfile) -> OpenCodeClient) {
        self.profiles = profiles
        self.makeClient = makeClient
        _selectedServerID = State(initialValue: initialProfile.id)
    }

    var body: some View {
        Group {
            if let createdSession, let client {
                OpenCodeSessionView(client: client, session: createdSession,
                                    directory: createdSession.directory, attention: attention)
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
                        .disabled(isCreating)
                        if let error {
                            ErrorBanner(message: error, actionTitle: "Refresh") {
                                Task { await loadProjects() }
                            }
                        }
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
                        .foregroundStyle(BYOTBrand.accentInk)
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
                createdSession = try await client.createSession(directory: directory, title: nil)
            } catch { self.error = error.localizedDescription }
        }
    }
}
