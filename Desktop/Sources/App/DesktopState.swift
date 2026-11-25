import Combine
import Foundation
import SwiftUI

/// Desktop application state: owns saved servers, local OpenCode + Tailscale
/// pairing status, active workspace/session selection, and live SSE updates.
@MainActor
final class DesktopAppState: ObservableObject {
    struct LocalServerProbe: Equatable {
        let baseURL: String
        let requiresAuth: Bool
        let version: String?
    }

    struct SelectedSession: Hashable, Identifiable {
        let serverID: UUID
        let session: OpenCodeSession
        let directory: String
        let projectName: String

        var id: String { "\(serverID.uuidString):\(session.id)" }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.id == rhs.id && lhs.directory == rhs.directory
        }
    }

    @Published var profileStore: OpenCodeProfileStore
    @Published var pairing: DesktopPairingManager
    @Published private(set) var workspaceStore: OpenCodeWorkspaceStore?
    @Published private(set) var browserStore: OpenCodeSessionBrowserStore?
    @Published private(set) var activeClient: OpenCodeClient?
    @Published var selectedSession: SelectedSession?
    @Published var searchText = ""
    @Published var sortOrder: OpenCodeSessionSort = .recent
    @Published var showDiffInspector = false
    @Published var showTerminalDrawer = false
    @Published var showServerSheet = false
    @Published var showPairPhoneSheet = false
    @Published var editingProfile: OpenCodeServerProfile?
    @Published var incomingPairingURL: URL?
    @Published private(set) var localProbe: LocalServerProbe?
    @Published private(set) var isCreatingSession = false
    @Published var bannerError: String?

    private var cancellables: Set<AnyCancellable> = []
    private var liveTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var connectedServerFingerprint: String?

    init(profileStore: OpenCodeProfileStore? = nil) {
        let profiles = profileStore ?? OpenCodeProfileStore()
        let pairingManager = DesktopPairingManager()
        self.profileStore = profiles
        self.pairing = pairingManager

        profiles.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        pairingManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        rebuildActiveConnectionIfNeeded()
        Task {
            await probeLocalOpenCode()
            await pairingManager.refreshAll(activeProfile: profiles.activeProfile)
        }
    }

    var activeProfile: OpenCodeServerProfile? {
        profileStore.activeProfile
    }

    func selectServer(_ profile: OpenCodeServerProfile) {
        profileStore.select(profile)
        selectedSession = nil
        rebuildActiveConnectionIfNeeded(force: true)
    }

    func saveServer(_ profile: OpenCodeServerProfile, password: String) throws {
        try profileStore.save(profile, password: password)
        rebuildActiveConnectionIfNeeded(force: true)
    }

    func removeServer(_ profile: OpenCodeServerProfile) {
        do {
            try profileStore.remove(profile)
            if selectedSession?.serverID == profile.id {
                selectedSession = nil
            }
            rebuildActiveConnectionIfNeeded(force: true)
        } catch {
            bannerError = error.localizedDescription
        }
    }

    func refreshActiveServer() {
        Task {
            await probeLocalOpenCode()
            await pairing.refreshAll(activeProfile: activeProfile)
        }
        guard activeProfile != nil else { return }
        startServerLoad(showsProgress: true)
    }

    func openPairPhone() {
        showServerSheet = false
        showPairPhoneSheet = true
    }

    func createSession(in project: OpenCodeProject) {
        guard let client = activeClient, let profile = activeProfile, !isCreatingSession else { return }
        isCreatingSession = true
        bannerError = nil
        Task {
            defer { isCreatingSession = false }
            do {
                let created = try await client.createSession(directory: project.worktree, title: nil)
                selectedSession = SelectedSession(
                    serverID: profile.id,
                    session: created,
                    directory: created.directory,
                    projectName: project.displayName
                )
                await reloadSessions(showsProgress: false)
            } catch {
                bannerError = error.localizedDescription
            }
        }
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == OpenCodePairingPayload.scheme else { return }
        incomingPairingURL = url
        editingProfile = nil
        showPairPhoneSheet = false
        showServerSheet = true
    }

    func probeLocalOpenCode() async {
        let baseURL = "http://127.0.0.1:4096"
        guard let url = URL(string: "\(baseURL)/global/health") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                localProbe = nil
                return
            }
            if http.statusCode == 401 {
                localProbe = LocalServerProbe(baseURL: baseURL, requiresAuth: true, version: nil)
            } else if (200..<300).contains(http.statusCode) {
                let health = try? JSONDecoder().decode(OpenCodeHealth.self, from: data)
                localProbe = LocalServerProbe(baseURL: baseURL, requiresAuth: false, version: health?.version)
            } else {
                localProbe = nil
            }
        } catch {
            localProbe = nil
        }
    }

    private func rebuildActiveConnectionIfNeeded(force: Bool = false) {
        guard let profile = activeProfile else {
            liveTask?.cancel()
            loadTask?.cancel()
            activeClient = nil
            workspaceStore = nil
            browserStore = nil
            connectedServerFingerprint = nil
            return
        }

        let fingerprint = "\(profile.id.uuidString)|\(profileStore.connectionGeneration)|\(profile.baseURL)"
        guard force || fingerprint != connectedServerFingerprint else { return }
        connectedServerFingerprint = fingerprint

        liveTask?.cancel()
        loadTask?.cancel()

        let password = profileStore.password(for: profile)
        let client = OpenCodeClient(profile: profile, password: password)
        let workspace = OpenCodeWorkspaceStore(service: client)
        let browser = OpenCodeSessionBrowserStore(service: client, cache: client.offlineCache)

        activeClient = client
        workspaceStore = workspace
        browserStore = browser

        startServerLoad(showsProgress: true)
        startLiveSubscription(browser: browser)
    }

    private func startServerLoad(showsProgress: Bool) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.loadWorkspaceAndSessions(showsProgress: showsProgress)
        }
    }

    private func loadWorkspaceAndSessions(showsProgress: Bool) async {
        guard let workspace = workspaceStore, let browser = browserStore else { return }
        await workspace.load()
        guard !Task.isCancelled else { return }
        if !workspace.projects.isEmpty {
            await browser.load(projects: workspace.projects, showsProgress: showsProgress)
            if selectedSession == nil, let profile = activeProfile {
                if let firstGroup = browser.orderedGroups(by: sortOrder).first,
                   let firstSession = firstGroup.sessions.first {
                    selectedSession = SelectedSession(
                        serverID: profile.id,
                        session: firstSession,
                        directory: firstSession.directory,
                        projectName: firstGroup.project.displayName
                    )
                }
            }
        }
    }

    private func reloadSessions(showsProgress: Bool) async {
        guard let workspace = workspaceStore, let browser = browserStore else { return }
        await browser.load(projects: workspace.projects, showsProgress: showsProgress)
    }

    private func startLiveSubscription(browser: OpenCodeSessionBrowserStore) {
        liveTask?.cancel()
        liveTask = Task { [weak self] in
            let handlers = OpenCodeSessionBrowserStore.LiveHandlers(
                reconcile: { [weak self] scope in
                    guard let self else { return }
                    switch scope {
                    case .projects:
                        await self.loadWorkspaceAndSessions(showsProgress: false)
                    case .sessions:
                        await self.reloadSessions(showsProgress: false)
                    }
                }
            )
            _ = await browser.followLiveUpdates(handlers)
        }
    }
}
