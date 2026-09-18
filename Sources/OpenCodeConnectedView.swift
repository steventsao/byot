import SwiftUI

struct OpenCodeSessionRoute: Hashable {
    let session: OpenCodeSession
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session.id == rhs.session.id && lhs.session.directory == rhs.session.directory
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(session.id)
        hasher.combine(session.directory)
    }
}

struct OpenCodeNewSessionRoute: Hashable {}

struct OpenCodeConnectedView: View {
    let openNewSession: () -> Void
    @State private var client: OpenCodeClient
    @StateObject private var workspace: OpenCodeWorkspaceStore
    @StateObject private var browser: OpenCodeSessionBrowserStore
    @StateObject private var attention: OpenCodeSessionAttentionStore
    @AppStorage("byot.sessions.group-by-project") private var groupByProject = false
    @AppStorage("byot.sessions.sort") private var sort: OpenCodeSessionSort = .recent
    @AppStorage("byot.projects.sort") private var projectSort: OpenCodeSessionSort = .recent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var isConnectingProvider = false
    @State private var isVisible = false
    @State private var search = ""
    @State private var collapsedProjects = Set<String>()
    @State private var createdRoute: OpenCodeSessionRoute?
    @State private var isCreating = false
    @State private var creationError: String?
    @FocusState private var isSearching: Bool

    init(client: OpenCodeClient, openNewSession: @escaping () -> Void) {
        self.openNewSession = openNewSession
        _client = State(initialValue: client)
        _workspace = StateObject(wrappedValue: OpenCodeWorkspaceStore(service: client))
        _browser = StateObject(wrappedValue: OpenCodeSessionBrowserStore(service: client))
        _attention = StateObject(wrappedValue: OpenCodeSessionAttentionStore(serverID: client.profile.id))
    }

    @State private var canArchiveSessions = false
    @State private var archiveError: String?

    var body: some View {
        List {
            Group {
                if let error = creationError ?? archiveError ?? workspace.errorMessage {
                    Section { ErrorBanner(message: error) }
                }
                if !browser.groups.isEmpty && (groupByProject || !visibleSessions(browser.sessions).isEmpty) {
                    Section {
                        if groupByProject {
                            ForEach(browser.orderedGroups(by: projectSort, attention: attentionIDs)) { group in
                                projectSection(group)
                            }
                        } else {
                            ForEach(visibleSessions(browser.sessions)) { session in
                                sessionLink(session, showProject: true)
                            }
                        }
                    } header: {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(groupByProject ? "Projects" : "Sessions")
                                Text(groupByProject ? projectSort.title : sort.title)
                            }
                            .font(.cleanCaption)
                        } else {
                            HStack {
                                Text(groupByProject ? "Projects" : "Sessions")
                                Spacer()
                                Text(groupByProject ? projectSort.title : sort.title)
                            }
                            .font(.cleanCaption)
                        }
                    }
                }
                if !groupByProject {
                    ForEach(browser.groups.filter { $0.error != nil }) { group in
                        Section(group.project.displayName) {
                            ErrorBanner(message: group.error ?? "Couldn’t refresh sessions")
                        }
                    }
                }
                if browser.isLoading {
                    Section {
                        BYOTActivityView(.loading, title: "Refreshing sessions", layout: .inline)
                    }
                }
                if !workspace.isLoading && !browser.isLoading && browser.sessions.isEmpty && workspace.errorMessage == nil {
                    Section {
                        ContentUnavailableView {
                            Label("No sessions", systemImage: "bubble.left.and.bubble.right")
                        } actions: {
                            newSessionMenu
                        }
                    }
                } else if !browser.sessions.isEmpty && visibleSessions(browser.sessions).isEmpty {
                    Section {
                        Text("No matching sessions")
                            .font(.cleanBody)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let compatibility = workspace.compatibility {
                    Section {
                        DisclosureGroup("Server details") {
                            Text(compatibility.redactedSummary)
                                .font(.cleanCaption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listSectionSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(BYOTBrand.canvas)
        .overlay {
            if workspace.isLoading && browser.groups.isEmpty {
                BYOTActivityView(.connecting, layout: .blocking)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        .font(.cleanControlIcon)
                        .accessibilityHidden(true)
                    TextField("Search", text: $search)
                        .focused($isSearching)
                        .font(.cleanBody)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { isSearching = false }
                        .accessibilityLabel("Search sessions or projects")
                        .accessibilityIdentifier("session-search")
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.cleanControlIcon)
                                .frame(width: 44, height: 44)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, search.isEmpty ? 14 : 0)
                .frame(minHeight: 48)
                .background(BYOTBrand.controlSurface, in: RoundedRectangle(cornerRadius: 24))
                newSessionMenu
                    .labelStyle(.iconOnly)
                    .font(.cleanControlIcon)
                    .frame(width: 48, height: 48)
                    .background(BYOTBrand.controlSurface, in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(BYOTBrand.canvas)
        }
        .sheet(isPresented: $isConnectingProvider) {
            OpenCodeProviderConnectionView(client: client, directory: client.profile.directory.trimmedNonEmpty ?? projects.first?.worktree ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Connect provider", systemImage: "person.badge.key") { isConnectingProvider = true }
                    .accessibilityIdentifier("connect-provider")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Session list options", systemImage: "line.3.horizontal.decrease") {
                    Toggle("Group by project", isOn: $groupByProject)
                    Picker("Sort sessions", selection: $sort) {
                        ForEach(OpenCodeSessionSort.allCases) { sort in
                            Text(sort.title).tag(sort)
                        }
                    }
                    if groupByProject {
                        Menu("Project order") {
                            Picker("Sort projects", selection: $projectSort) {
                                ForEach(OpenCodeSessionSort.allCases) { option in
                                    Text(option.title).tag(option)
                                }
                            }
                        }
                    }
                }
                .tint(BYOTBrand.chromeTint)
            }
        }
        .refreshable { await reload() }
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .task(id: isVisible && scenePhase == .active) {
            guard isVisible && scenePhase == .active else { return }
            await reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) }
                catch { break }
                guard !Task.isCancelled else { break }
                guard workspace.compatibility != nil,
                      workspace.compatibility?.state != .unsupported else { continue }
                await browser.load(projects: projects)
                await attention.refresh(sessions: browser.sessions, service: client)
            }
        }
        .navigationDestination(for: OpenCodeSessionRoute.self) { route in
            sessionView(route)
        }
        .navigationDestination(item: $createdRoute) { route in
            sessionView(route, startsWithComposerFocused: true)
        }
    }

    @ViewBuilder
    private var newSessionMenu: some View {
        Button(action: openNewSession) {
            Label("New session", systemImage: "square.and.pencil")
                .frame(minWidth: 48, minHeight: 48)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func projectSection(_ group: OpenCodeSessionGroup) -> some View {
        if search.isEmpty || !visibleSessions(group.sessions).isEmpty || group.project.displayName.localizedStandardContains(search) {
            DisclosureGroup(isExpanded: Binding(
                get: { !collapsedProjects.contains(group.id) || !search.isEmpty },
                set: { expanded in
                    if expanded { collapsedProjects.remove(group.id) }
                    else { collapsedProjects.insert(group.id) }
                }
            )) {
                if let error = group.error { ErrorBanner(message: error) }
                ForEach(visibleSessions(group.sessions)) { session in
                    sessionLink(session, showProject: false)
                }
                Button("New session in \(group.project.displayName)", systemImage: "plus") {
                    createSession(in: group.project)
                }
                .disabled(isCreating)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(group.project.displayName).font(.cleanBodySemibold)
                    projectSummary(group)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func projectSummary(_ group: OpenCodeSessionGroup) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                projectStatus(group)
                Text("·")
                projectUpdatedText(group)
            }
            VStack(alignment: .leading, spacing: 4) {
                projectStatus(group)
                projectUpdatedText(group)
            }
        }
    }

    @ViewBuilder
    private func projectUpdatedText(_ group: OpenCodeSessionGroup) -> some View {
        if group.updated > 0 {
            Text(Date(timeIntervalSince1970: group.updated / 1_000), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
        } else {
            Text("No activity")
        }
    }

    @ViewBuilder
    private func projectStatus(_ group: OpenCodeSessionGroup) -> some View {
        if group.error != nil {
            Label("Needs attention", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        } else if !group.isLoaded {
            Text("Loading sessions")
        } else {
            let countLabel = group.sessions.count == 1 ? "1 session" : "\(group.sessions.count) sessions"
            let retries = group.sessions.filter {
                if case .retry = group.status(for: $0) { return true }
                return false
            }.count
            let failures = group.sessions.filter { attentionIDs.contains($0.id) }.count
            let active = group.sessions.filter { group.status(for: $0)?.isActive == true }.count
            if failures > 0 {
                Label("\(failures) need attention · \(countLabel)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if retries > 0 {
                Label("\(retries) retrying · \(countLabel)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if active > 0 {
                Label("\(active) active · \(countLabel)", systemImage: "circle.dotted")
            } else {
                Text(countLabel)
            }
        }
    }

    @State private var openSwipeSessionID: String?

    private func sessionLink(_ session: OpenCodeSession, showProject: Bool) -> some View {
        SwipeToArchive(isEnabled: canArchiveSessions, isOpen: Binding(
            get: { openSwipeSessionID == session.id },
            set: { open in
                if open { openSwipeSessionID = session.id }
                else if openSwipeSessionID == session.id { openSwipeSessionID = nil }
            }
        )) {
            archive(session)
        } content: {
            NavigationLink(value: OpenCodeSessionRoute(session: session)) {
                OpenCodeSessionRow(
                    session: session,
                    status: browser.statuses[session.id],
                    projectName: showProject ? projectName(for: session) : nil,
                    attentionMessage: attentionIDs.contains(session.id) ? attention.failures[session.id] : nil
                )
            }
            .accessibilityIdentifier("session-\(session.id)")
        }
    }

    /// Swipe left to reveal a red, horizontal Archive pill. Native swipe actions
    /// draw a round button with the title underneath and cannot take this shape.
    private struct SwipeToArchive<Content: View>: View {
        let isEnabled: Bool
        @Binding var isOpen: Bool
        let archive: () -> Void
        @ViewBuilder let content: Content

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @GestureState(resetTransaction: Transaction(animation: .snappy(duration: BYOTBrand.Motion.quick)))
        private var drag: CGFloat = 0
        @State private var pillWidth: CGFloat = 132

        private var revealWidth: CGFloat { pillWidth + BYOTBrand.Space.sm }
        private var offset: CGFloat {
            min(0, max(-revealWidth * 1.3, (isOpen ? -revealWidth : 0) + drag))
        }

        var body: some View {
            content
                .overlay {
                    // While open, a tap on the row closes it instead of navigating.
                    if isOpen {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { setOpen(false) }
                    }
                }
                .offset(x: offset)
                .overlay(alignment: .trailing) {
                    // Only a revealed pill exists, so closed rows expose no Archive button.
                    if offset < 0 {
                        Button(role: .destructive) {
                            setOpen(false)
                            archive()
                        } label: {
                            Label("Archive", systemImage: "archivebox")
                                .labelStyle(.titleAndIcon)
                                .fixedSize()
                                .font(.cleanBodySemibold)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 18)
                                .frame(minHeight: 44)
                                .background(Color(uiColor: .systemRed), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pillWidth = $0 }
                        .opacity(min(1, -offset / revealWidth))
                        .allowsHitTesting(isOpen)
                    }
                }
                .simultaneousGesture(swipe, including: isEnabled ? .all : .subviews)
                .accessibilityActions {
                    if isEnabled { Button("Archive", action: archive) }
                }
        }

        private var swipe: some Gesture {
            DragGesture(minimumDistance: 16)
                .updating($drag) { value, state, _ in
                    // Leave vertical drags to the list's scrolling.
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    state = value.translation.width
                }
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    let end = (isOpen ? -revealWidth : 0) + value.predictedEndTranslation.width
                    setOpen(end < -revealWidth / 2)
                }
        }

        private func setOpen(_ open: Bool) {
            withAnimation(reduceMotion ? nil : .snappy(duration: BYOTBrand.Motion.quick)) { isOpen = open }
        }
    }

    private func archive(_ session: OpenCodeSession) {
        archiveError = nil
        browser.markArchived(session.id)
        Task {
            do {
                try await client.archiveSession(sessionID: session.id, directory: session.directory, workspace: session.workspaceID)
            } catch {
                browser.unmarkArchived(session.id)
                archiveError = "Couldn’t archive “\(session.title)”: \(error.localizedDescription)"
                await browser.load(projects: projects)
            }
        }
    }

    private func sessionView(
        _ route: OpenCodeSessionRoute,
        startsWithComposerFocused: Bool = false
    ) -> some View {
        OpenCodeSessionView(client: client, session: route.session, directory: route.session.directory,
                            attention: attention,
                            startsWithComposerFocused: startsWithComposerFocused)
    }

    private func projectName(for session: OpenCodeSession) -> String {
        projects.first { $0.worktree == session.directory }?.displayName
            ?? projects.first { $0.id == session.projectID }?.displayName
            ?? URL(fileURLWithPath: session.directory).lastPathComponent
    }

    private func visibleSessions(_ sessions: [OpenCodeSession]) -> [OpenCodeSession] {
        sort.ordered(sessions.filter {
            search.isEmpty || $0.title.localizedStandardContains(search)
                || $0.directory.localizedStandardContains(search)
                || projectName(for: $0).localizedStandardContains(search)
        }, statuses: browser.statuses, attention: attentionIDs)
    }

    private var attentionIDs: Set<String> {
        Set(attention.failures.keys.filter { browser.statuses[$0]?.isActive != true })
    }

    private var projects: [OpenCodeProject] {
        var result = workspace.projects
        if let directory = client.profile.normalizedDirectory,
           !result.contains(where: { $0.worktree == directory }) {
            result.append(Self.project(directory: directory))
        }
        return result
    }

    private static func project(directory: String) -> OpenCodeProject {
        OpenCodeProject(id: directory, worktree: directory, vcs: nil, name: nil,
                        time: OpenCodeProjectTime(created: 0, updated: 0), sandboxes: [])
    }

    private func reload() async {
        attention.reload()
        await workspace.load()
        guard !Task.isCancelled else { return }
        if workspace.compatibility?.state == .unsupported {
            await browser.load(projects: [])
            return
        }
        guard workspace.compatibility != nil else { return }
        // Swipe to archive only where the server can archive (v1 today).
        async let support = try? client.sessionFeatureSupport()
        await browser.load(projects: projects)
        canArchiveSessions = await support?.archive ?? false
        await attention.refresh(sessions: browser.sessions, service: client)
    }

    private func createSession(in project: OpenCodeProject) {
        guard !isCreating else { return }
        isCreating = true
        creationError = nil
        Task {
            defer { isCreating = false }
            do {
                let session = try await client.createSession(directory: project.worktree, title: nil)
                createdRoute = OpenCodeSessionRoute(session: session)
            } catch { creationError = error.localizedDescription }
        }
    }
}
