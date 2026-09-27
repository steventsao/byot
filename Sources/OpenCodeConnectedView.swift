import SwiftUI

struct OpenCodeSessionRoute: Hashable {
    let session: OpenCodeSession
    /// Set when the session was just made, so the message field is ready.
    var focusesComposer = false
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session.id == rhs.session.id && lhs.session.directory == rhs.session.directory
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(session.id)
        hasher.combine(session.directory)
    }
}

struct OpenCodeNewSessionRoute: Hashable {
    let id = UUID()
    /// Something shared from another app, added to the new session's message.
    var share: BYOTShareContent?
}

struct OpenCodeConnectedView: View {
    let openNewSession: () -> Void
    /// Shows a conversation in the iPhone stack, in place of whatever was
    /// pushed over the list.
    private let openSession: (OpenCodeSessionRoute) -> Void
    /// The split view's detail on regular width. Rows then select into it
    /// instead of pushing; nil keeps the iPhone navigation stack.
    private let selection: Binding<OpenCodeSplitDetail?>?
    private let request: OpenCodeSessionListRequest?
    @State private var client: OpenCodeClient
    @StateObject private var workspace: OpenCodeWorkspaceStore
    @StateObject private var browser: OpenCodeSessionBrowserStore
    @StateObject private var attention: OpenCodeSessionAttentionStore
    @AppStorage("byot.sessions.group-by-project") private var groupByProject = false
    @AppStorage("byot.sessions.sort") private var sort: OpenCodeSessionSort = .recent
    @AppStorage("byot.projects.sort") private var projectSort: OpenCodeSessionSort = .recent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openCodeVisibleSessions) private var onScreenConversations
    @State private var isVisible = false
    @State private var search = ""
    @State private var collapsedProjects = Set<String>()
    @State private var isCreating = false
    @State private var creationError: String?
    @State private var focusesSearchOnAppear = false
    @FocusState private var isSearching: Bool

    init(client: OpenCodeClient, openNewSession: @escaping () -> Void,
         openSession: @escaping (OpenCodeSessionRoute) -> Void,
         selection: Binding<OpenCodeSplitDetail?>? = nil, request: OpenCodeSessionListRequest? = nil) {
        self.openNewSession = openNewSession
        self.openSession = openSession
        self.selection = selection
        self.request = request
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
                            Button(action: openNewSession) {
                                // The compact icon button's label can collapse to
                                // one character per line in ContentUnavailableView.
                                Text("New session")
                                    .fixedSize(horizontal: true, vertical: true)
                                    .frame(minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                            .tint(BYOTBrand.chromeTint)
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
        .toolbar {
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
        .onAppear {
            isVisible = true
            if focusesSearchOnAppear {
                focusesSearchOnAppear = false
                focusSearch()
            }
        }
        .onDisappear { isVisible = false }
        .onChange(of: request) { _, request in
            if let request { handle(request) }
        }
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
                publishActivity()
            }
        }
        .navigationDestination(for: OpenCodeSessionRoute.self) { route in
            sessionView(route)
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
            let row = OpenCodeSessionRow(
                session: session,
                status: browser.statuses[session.id],
                projectName: showProject ? projectName(for: session) : nil,
                attentionMessage: attentionIDs.contains(session.id) ? attention.failures[session.id] : nil
            )
            if selection != nil {
                let isSelected = selection?.wrappedValue?.shows(session, on: client.profile.id) == true
                Button { select(session) } label: { row }
                    .buttonStyle(OpenCodeSidebarRowStyle(isSelected: isSelected))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("session-\(session.id)")
            } else {
                NavigationLink(value: OpenCodeSessionRoute(session: session)) { row }
                    .accessibilityIdentifier("session-\(session.id)")
            }
        }
    }

    /// A sidebar row: the open conversation keeps a quiet highlight, and the
    /// pointer highlights the whole row on iPad.
    private struct OpenCodeSidebarRowStyle: ButtonStyle {
        let isSelected: Bool

        func makeBody(configuration: Configuration) -> some View {
            let shape = RoundedRectangle(cornerRadius: BYOTBrand.controlRadius, style: .continuous)
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, BYOTBrand.Space.sm + 2)
                .padding(.vertical, BYOTBrand.Space.xs)
                .background {
                    shape.fill(isSelected || configuration.isPressed ? BYOTBrand.selectedSurface : .clear)
                }
                .contentShape(.hoverEffect, shape)
                .contentShape(shape)
                .hoverEffect(.highlight)
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
        // Like OpenCode's web app, archiving the open session moves on to
        // its neighbour in the list, or leaves the detail empty.
        if let selection, selection.wrappedValue?.shows(session, on: client.profile.id) == true {
            let sessions = displayedSessions
            if let id = OpenCodeSessionListOrder.neighbour(of: session.id, in: sessions.map(\.id)),
               let next = sessions.first(where: { $0.id == id }) {
                select(next)
            } else {
                selection.wrappedValue = nil
            }
        }
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

    /// Opens `session` in the split view's detail column. Choosing the open
    /// conversation again keeps it, with its scroll position and draft.
    private func select(_ session: OpenCodeSession, focusesComposer: Bool = false) {
        guard let selection, selection.wrappedValue?.shows(session, on: client.profile.id) != true else { return }
        openSwipeSessionID = nil
        selection.wrappedValue = .session(OpenCodeSessionSelection(
            client: client, session: session, attention: attention, focusesComposer: focusesComposer))
    }

    private func handle(_ request: OpenCodeSessionListRequest) {
        switch request.kind {
        case .focusSearch:
            // A list covered by a conversation focuses once it is back on screen.
            if isVisible { focusSearch() } else { focusesSearchOnAppear = true }
        case .step(let step):
            let sessions = displayedSessions
            guard let id = step.target(from: currentSessionID, in: sessions.map(\.id)),
                  let session = sessions.first(where: { $0.id == id }) else { return }
            if selection != nil {
                select(session)
            } else if onScreenConversations?.top?.session.id != session.id {
                openSession(OpenCodeSessionRoute(session: session))
            }
        case .refresh:
            Task { await browser.load(projects: projects) }
        }
    }

    /// The session ⌘[ and ⌘] step from: the split view's selection, or on
    /// iPhone the conversation on screen.
    private var currentSessionID: String? {
        if let selection {
            guard selection.wrappedValue?.serverID == client.profile.id else { return nil }
            return selection.wrappedValue?.session?.id
        }
        guard let top = onScreenConversations?.top, top.client.profile.id == client.profile.id else { return nil }
        return top.session.id
    }

    private func focusSearch() {
        // Let a sidebar that is sliding in, or a pop, settle before the
        // field takes the keyboard.
        Task {
            await Task.yield()
            isSearching = true
        }
    }

    /// The sessions in the order the list shows them, for ⌘[ and ⌘].
    private var displayedSessions: [OpenCodeSession] {
        guard groupByProject else { return visibleSessions(browser.sessions) }
        return OpenCodeSessionListOrder.displayed(
            groups: browser.orderedGroups(by: projectSort, attention: attentionIDs)
                .map { (id: $0.id, sessions: visibleSessions($0.sessions)) },
            collapsed: collapsedProjects, isSearching: !search.isEmpty)
    }

    private func sessionView(_ route: OpenCodeSessionRoute) -> some View {
        OpenCodeSessionView(client: client, session: route.session, directory: route.session.directory,
                            attention: attention,
                            startsWithComposerFocused: route.focusesComposer)
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
        publishActivity()
    }

    /// Shares this server's running and attention-needing sessions with the
    /// home-screen widget and settles Live Activities for conversations that
    /// are no longer open. A refresh that reached no project changes nothing.
    private func publishActivity() {
        guard !Task.isCancelled, browser.groups.contains(where: { $0.statuses != nil }) else { return }
        let statuses = browser.statuses
        let pending = browser.pendingSessionIDs
        BYOTWidgetSync.shared.publish(BYOTWidgetSync.server(
            profile: client.profile, sessions: browser.sessions, statuses: statuses,
            pendingSessionIDs: pending, failures: attention.failures))
        BYOTLiveActivityController.shared.reconcile(
            serverID: client.profile.id, sessions: browser.sessions, statuses: statuses,
            pendingSessionIDs: pending, failures: attention.failures)
    }

    private func createSession(in project: OpenCodeProject) {
        guard !isCreating else { return }
        isCreating = true
        creationError = nil
        Task {
            defer { isCreating = false }
            do {
                let session = try await client.createSession(directory: project.worktree, title: nil)
                if selection != nil {
                    select(session, focusesComposer: true)
                    await browser.load(projects: projects)
                } else {
                    openSession(OpenCodeSessionRoute(session: session, focusesComposer: true))
                }
            } catch { creationError = error.localizedDescription }
        }
    }
}
