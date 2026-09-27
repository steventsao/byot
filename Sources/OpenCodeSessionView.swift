import SwiftUI

struct OpenCodeSessionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store: OpenCodeSessionStore
    @StateObject private var diffReview: OpenCodeDiffReviewStore
    @State private var diffRequest: OpenCodeDiffReviewRequest?
    /// Starts shown so v1 servers don't shift the toolbar; hidden once negotiation
    /// finds nothing to compare.
    @State private var canReviewChanges = true
    @State private var isShowingQueue = false
    @ObservedObject private var push = BYOTPushNotifications.shared
    @State private var notificationError: String?
    @State private var isShowingRecoveryModelPicker = false
    @State private var isAtBottom = true
    @State private var hasPositionedTranscript = false
    @State private var isShowingDetails = false
    @State private var isShowingTasks = false
    @State private var isShowingNewSession = false
    @State private var nextSession: OpenCodeSessionRoute?
    @State private var terminalRoute: OpenCodeTerminalRoute?
    @State private var canOpenTerminal = false
    @State private var statusRoute: OpenCodeProjectStatusRoute?
    @State private var canOpenStatus = false
    /// The project's checked-out branch, shown beside the project name.
    @State private var branch: String?
    /// Bumped by each branch event, so a slower fetch never overwrites a newer report.
    @State private var branchGeneration = 0
    private let client: OpenCodeClient
    private let terminalService: OpenCodeTerminalService
    private let contextService: OpenCodeServerContextService
    private let serverName: String
    private let attention: OpenCodeSessionAttentionStore?
    private let startsWithComposerFocused: Bool

    private let bottomAnchorID = "opencode-session-bottom"

    init(
        client: OpenCodeClient,
        session: OpenCodeSession,
        directory: String,
        attention: OpenCodeSessionAttentionStore? = nil,
        startsWithComposerFocused: Bool = false
    ) {
        self.client = client
        serverName = client.profile.name
        self.attention = attention
        self.startsWithComposerFocused = startsWithComposerFocused
        terminalService = OpenCodeTerminalService(
            client: client, route: OpenCodeTerminalRoute(directory: directory, workspace: session.workspaceID))
        contextService = OpenCodeServerContextService(
            client: client, route: OpenCodeProjectStatusRoute(directory: directory, workspace: session.workspaceID))
        _store = StateObject(
            wrappedValue: OpenCodeSessionStore(
                client: client,
                session: session,
                directory: directory
            )
        )
        _diffReview = StateObject(
            wrappedValue: OpenCodeDiffReviewStore(
                service: OpenCodeDiffReviewService(client: client, session: session, directory: directory),
                directory: directory
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let errorMessage = store.errorMessage, hasConversationContent {
                        ErrorBanner(
                            message: errorMessage,
                            actionTitle: "Refresh",
                            action: refreshSession
                        )
                    }

                    if let eventErrorMessage = store.eventErrorMessage,
                       eventErrorMessage != store.errorMessage {
                        ErrorBanner(
                            message: eventErrorMessage,
                            actionTitle: "Refresh",
                            action: refreshSession
                        )
                    }

                    if let actionErrorMessage = store.actionErrorMessage,
                       actionErrorMessage != store.errorMessage,
                       actionErrorMessage != store.eventErrorMessage {
                        ErrorBanner(
                            message: actionErrorMessage,
                            actionTitle: "Refresh",
                            action: refreshSession
                        )
                    }

                    if store.revertMessageID != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Conversation rewound", systemImage: "arrow.uturn.backward")
                                .font(.cleanBodySemibold)
                            Text("Edit the restored prompt to take a different direction, or redo the turn. Queued prompts are paused for review.")
                                .font(.cleanCaption).foregroundStyle(.secondary)
                            Button("Redo turn") { Task { await store.performSessionAction(.redo) } }
                                .disabled(store.actionUnavailableReason(.redo) != nil)
                        }
                        .padding(12)
                        .background(BYOTBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius))
                    }

                    ForEach(store.messages) { message in
                        messageRow(message).id(message.id)
                    }

                    if store.todoProgress.totalCount > 0 {
                        Button { isShowingTasks = true } label: {
                            HStack {
                                Label(store.todoProgress.summary, systemImage: "checklist")
                                Spacer()
                                Image(systemName: "chevron.right")
                            }
                            .font(.cleanCaptionBold)
                            .padding(12)
                            .background(BYOTBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("session-task-progress")
                    }

                    if store.modelFailure != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Choose an available model to continue.")
                                .font(.cleanBodySemibold)
                            Button("Choose another model", systemImage: "cpu") {
                                isShowingRecoveryModelPicker = true
                            }
                            if store.canRetryWithSelectedModel {
                                Button("Retry last message", systemImage: "arrow.clockwise") {
                                    store.retryWithSelectedModel()
                                }
                                .accessibilityIdentifier("retry-model-failure")
                            }
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(BYOTBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius))
                    }

                    if store.canRetryUnansweredPrompt {
                        ErrorBanner(
                            message: "OpenCode returned to idle without a reply. Choose another model if needed, then retry the last message.",
                            actionTitle: "Retry last message"
                        ) {
                            Task { await store.retryUnansweredPrompt() }
                        }
                        .id("opencode-unanswered-prompt-recovery")
                    }

                    if showsSessionActivity {
                        BYOTActivityView(
                            sessionActivityPhase,
                            title: sessionActivityTitle,
                            detail: sessionActivityDetail,
                            layout: sessionActivityPhase == .thinking || sessionActivityPhase == .working ? .indicator : .inline,
                            accessibilityLabel: sessionActivityAccessibilityLabel
                        )
                        .id("opencode-session-activity")
                    }

                    if let queue = store.durableQueue {
                        BYOTQueueSummary(queue: queue) { isShowingQueue = true }
                    }

                    if !store.queuedPrompts.isEmpty {
                        OpenCodeQueuedPromptsView(
                            prompts: store.queuedPrompts,
                            canRetryFirst: store.canRetryFirstQueuedPrompt,
                            retry: retryQueuedPrompt,
                            remove: store.removeQueuedPrompt
                        )
                        .id("opencode-queued-prompts")
                    }

                    if store.isLoading && store.messages.isEmpty {
                        BYOTActivityView(
                            .loading,
                            title: "Loading transcript",
                            layout: .blocking
                        )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                    } else if !store.isLoading,
                              !hasConversationContent,
                              let errorMessage = store.errorMessage {
                        ContentUnavailableView {
                            Label("Couldn’t load this session", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(errorMessage.agentDisplayErrorText)
                        } actions: {
                            Button("Try again", systemImage: "arrow.clockwise") {
                                Task { await store.refresh(showLoading: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(BYOTBrand.accentInk)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                    }

                    if store.pendingActionCount > 0 {
                        pendingActions
                            .id("opencode-pending-actions")
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchorID)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: OpenCodeScrollMetricsKey.self,
                                    value: .init(bottomY: geometry.frame(in: .named("transcript")).maxY)
                                )
                            }
                        }
                }
                .frame(maxWidth: BYOTBrand.conversationMaxWidth)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .coordinateSpace(name: "transcript")
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: OpenCodeScrollMetricsKey.self,
                        value: .init(viewportHeight: geometry.size.height)
                    )
                }
            }
            .onPreferenceChange(OpenCodeScrollMetricsKey.self) { metrics in
                guard let bottomY = metrics.bottomY,
                      let height = metrics.viewportHeight else { return }
                isAtBottom = bottomY <= height + 32 && bottomY >= 0
            }
            .overlay(alignment: .bottom) {
                if !isAtBottom && hasConversationContent {
                    Button {
                        scrollToBottom(proxy)
                    } label: {
                        Label(
                            store.pendingActionCount > 0 ? "Response needed" : "Jump to latest",
                            systemImage: store.pendingActionCount > 0
                                ? "bubble.left.and.exclamationmark.bubble.right" : "arrow.down"
                        )
                        .font(.cleanCaptionBold)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(.regularMaterial, in: Capsule())
                        .overlay {
                            Capsule().stroke(BYOTBrand.hairline, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("jump-to-latest")
                    .padding(.bottom, 8)
                }
            }
            .onChange(of: store.transcriptRevision) { _, _ in
                rememberAttention()
                if !hasPositionedTranscript && !store.messages.isEmpty {
                    hasPositionedTranscript = true
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                    return
                }
                scrollToConversationBottomIfNeeded(proxy)
            }
            .onChange(of: sessionActivityAnnouncementKey) { _, newValue in
                guard newValue != nil else { return }
                if sessionActivityPhase != .waiting {
                    AccessibilityNotification.Announcement(
                        sessionActivityAccessibilityLabel
                    ).post()
                }
                scrollToConversationBottomIfNeeded(proxy)
            }
            .onChange(of: store.pendingActionCount) { oldValue, newValue in
                guard newValue > oldValue else { return }
                AccessibilityNotification.Announcement(
                    "Response required"
                ).post()
                scrollToConversationBottomIfNeeded(proxy)
            }
            .onChange(of: store.queueAnnouncementRevision) { _, _ in
                AccessibilityNotification.Announcement("Message queued").post()
                proxy.scrollTo("opencode-queued-prompts", anchor: .bottom)
            }
        }
        .background(BYOTBrand.canvas)
        .navigationTitle(store.session.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    sessionContext
                    Spacer(minLength: 8)
                    sessionStatus
                }
                VStack(alignment: .leading, spacing: 8) {
                    sessionContext
                    sessionStatus
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(BYOTBrand.canvas)
        }
        .safeAreaInset(edge: .bottom) {
            OpenCodeSessionComposerView(
                store: store,
                startsFocused: startsWithComposerFocused,
                onNewSession: { isShowingNewSession = true },
                sessionActions: OpenCodeSessionAction.allCases.map { action in
                    OpenCodeComposerAction(name: action.rawValue, title: action.title,
                        unavailableReason: store.actionUnavailableReason(action),
                        run: { Task { await store.performSessionAction(action) } })
                },
                restoredMessage: store.restoredPrompt?.message,
                onRestoreConsumed: { store.consumeRestoredPrompt() }
            )
        }
        .environment(\.openCodeRemoteFiles, store.remoteFiles)
        .environment(\.openCodeReviewChanges, isReviewChangesVisible ? OpenCodeReviewChangesAction { request in
            diffRequest = request
        } : nil)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Message queue", systemImage: "list.bullet.rectangle") { isShowingQueue = true }
                        .accessibilityIdentifier("session-queue")
                    Button("Session details", systemImage: "info.circle") { isShowingDetails = true }
                    Button("Tasks", systemImage: "checklist") { isShowingTasks = true }
                    if isReviewChangesVisible {
                        Button("Review changes", systemImage: "plusminus") { diffRequest = OpenCodeDiffReviewRequest() }
                            .accessibilityIdentifier("session-menu-review-changes")
                    }
                    if canOpenTerminal {
                        Button("Terminal", systemImage: "apple.terminal") {
                            terminalRoute = OpenCodeTerminalRoute(
                                directory: terminalService.directory, workspace: terminalService.workspace)
                        }
                        .accessibilityIdentifier("session-menu-terminal")
                    }
                    if canOpenStatus {
                        Button("Project status", systemImage: "gauge.with.dots.needle.33percent", action: openStatus)
                            .accessibilityIdentifier("session-menu-status")
                    }
                    if push.credentials[client.profile.id] != nil {
                        Button(push.isMuted(serverID: client.profile.id, sessionID: store.session.id) ? "Unmute notifications" : "Mute notifications", systemImage: "bell.slash") {
                            Task {
                                do { try await push.toggleMute(serverID: client.profile.id, sessionID: store.session.id) }
                                catch { notificationError = error.localizedDescription }
                            }
                        }
                    }
                    ForEach(OpenCodeSessionAction.allCases) { action in
                        Button(action.title, systemImage: action.symbol) {
                            Task { await store.performSessionAction(action) }
                        }.disabled(store.actionUnavailableReason(action) != nil)
                            .accessibilityIdentifier("session-menu-\(action.rawValue)")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .tint(BYOTBrand.chromeTint)
                .accessibilityLabel("Session actions")
                .accessibilityIdentifier("session-actions")
            }
            if isReviewChangesVisible {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Changes", systemImage: "plusminus") {
                        diffRequest = OpenCodeDiffReviewRequest()
                    }
                    .labelStyle(.iconOnly)
                    .tint(BYOTBrand.chromeTint)
                    .accessibilityHint("Review files changed in this session")
                }
            }
        }
        .sheet(isPresented: $isShowingQueue) {
            if let queue = store.durableQueue { BYOTDurableQueueView(queue: queue) }
        }
        .sheet(isPresented: $isShowingDetails) {
            OpenCodeSessionDetailsView(store: store) { session in
                isShowingDetails = false
                nextSession = OpenCodeSessionRoute(session: session)
            }
        }
        .sheet(isPresented: $isShowingTasks) {
            OpenCodeTaskProgressView(progress: store.todoProgress, supportsSnapshot: store.sessionFeatures.todoSnapshot)
        }
        .navigationDestination(item: $nextSession) { route in
            OpenCodeSessionView(client: client, session: route.session, directory: route.session.directory, attention: attention)
        }
        .navigationDestination(item: $terminalRoute) { route in
            OpenCodeTerminalScreen(client: client, route: route)
        }
        .navigationDestination(item: $statusRoute) { route in
            OpenCodeProjectStatusScreen(client: client, route: route)
        }
        .navigationDestination(isPresented: $isShowingNewSession) {
            OpenCodeNewSessionView(profiles: [client.profile], initialProfile: client.profile, makeClient: { _ in client })
        }
        .onChange(of: store.forkedSession) { _, session in
            if let session {
                isShowingDetails = false
                nextSession = OpenCodeSessionRoute(session: session)
                store.consumeForkedSession()
            }
        }
        .onChange(of: store.didDeleteSession) { _, deleted in
            if deleted { isShowingDetails = false; dismiss() }
        }
        .sheet(item: $diffRequest) { request in
            OpenCodeDiffReviewView(
                store: diffReview,
                request: request,
                latestTurnMessageID: store.messages.last { $0.info.role == "user" }?.id,
                sessionDiffs: store.diffs
            )
        }
        .sheet(isPresented: $isShowingRecoveryModelPicker) {
            OpenCodeModelPickerView(store: store)
                .task { await store.reloadModels() }
        }
        .onAppear { push.activeRoute = BYOTPushRoute(serverID: client.profile.id, sessionID: store.session.id, directory: store.session.directory, workspace: store.session.workspaceID) }
        .alert("Couldn’t update notifications", isPresented: Binding(get: { notificationError != nil }, set: { if !$0 { notificationError = nil } })) {
            Button("OK") { notificationError = nil }
        } message: { Text(notificationError ?? "") }
        .task { await store.start() }
        .task { canOpenTerminal = await terminalService.isAvailable() }
        .task { canReviewChanges = await diffReview.isReviewAvailable() }
        .task {
            canOpenStatus = await contextService.isAvailable()
            await refreshBranch()
        }
        .onChange(of: store.reportedBranch) { _, reported in
            guard let reported else { return }
            branchGeneration &+= 1
            branch = reported.name
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.refreshAfterForeground()
                Task { await refreshBranch() }
            }
        }
        .onChange(of: store.errorMessage) { _, _ in rememberAttention() }
        .onDisappear {
            if push.activeRoute?.serverID == client.profile.id && push.activeRoute?.sessionID == store.session.id { push.activeRoute = nil }
            rememberAttention()
            store.stop()
        }
    }

    @ViewBuilder
    private func messageRow(_ message: OpenCodeMessageEnvelope) -> some View {
        if message.info.role == "user" {
            OpenCodeMessageView(message: message)
                .contextMenu {
                    Button("Undo to this prompt", systemImage: "arrow.uturn.backward") {
                        Task { await store.performSessionAction(.undo, messageID: message.id) }
                    }.disabled(store.actionUnavailableReason(.undo) != nil)
                    Button("Fork before this prompt", systemImage: "arrow.triangle.branch") {
                        Task { await store.performSessionAction(.fork, messageID: message.id) }
                    }.disabled(store.actionUnavailableReason(.fork) != nil)
                }
        } else {
            OpenCodeMessageView(message: message, turnMessageID: turnMessageID(for: message))
        }
    }

    /// A legacy session snapshot is reviewable even where negotiation found nothing else.
    private var isReviewChangesVisible: Bool { canReviewChanges || !store.diffs.isEmpty }

    /// The user prompt an assistant reply answers: its declared parent, else the
    /// nearest earlier prompt in the transcript.
    private func turnMessageID(for message: OpenCodeMessageEnvelope) -> String? {
        if let parentID = message.info.parentID { return parentID }
        // Only patch rows use it; skip the transcript scan for every other message.
        guard message.parts.contains(where: { $0.type == "patch" }),
              let index = store.messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        return store.messages[..<index].last { $0.info.role == "user" }?.id
    }

    private func rememberAttention() {
        guard !store.messages.isEmpty || store.errorMessage != nil else { return }
        attention?.record(sessionID: store.session.id,
            message: OpenCodeSessionAttentionStore.message(in: store.messages) ?? store.errorMessage)
    }

    /// Server, project and branch; opens the project's status where the server has one.
    @ViewBuilder
    private var sessionContext: some View {
        let project = URL(fileURLWithPath: store.directory).lastPathComponent
        let label = Group {
            if let branch {
                Text("\(serverName) · \(project) · \(Image(systemName: "arrow.triangle.branch")) \(branch)")
            } else {
                Text("\(serverName) · \(project)")
            }
        }
        .font(.cleanCaption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        let accessibilityLabel = "Server \(serverName), project \(store.directory)" + (branch.map { ", branch \($0)" } ?? "")
        if canOpenStatus {
            // The padding grows the tap target to 44pt without making the header taller.
            Button(action: openStatus) {
                label.padding(.vertical, 14).contentShape(Rectangle())
            }
            .padding(.vertical, -14)
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Shows the project’s status")
            .accessibilityIdentifier("session-context")
        } else {
            label.accessibilityLabel(accessibilityLabel)
        }
    }

    private func openStatus() {
        statusRoute = OpenCodeProjectStatusRoute(
            directory: contextService.directory, workspace: contextService.workspace)
    }

    private func refreshBranch() async {
        let generation = branchGeneration
        let current = await contextService.currentBranch()
        if !Task.isCancelled, generation == branchGeneration { branch = current }
    }

    private var sessionStatus: some View {
        OpenCodeStatusLabel(status: store.status, eventConnected: store.isEventConnected)
            .fixedSize()
    }

    private var hasConversationContent: Bool {
        !store.messages.isEmpty
            || !store.queuedPrompts.isEmpty
            || store.pendingActionCount > 0
    }

    private func refreshSession() {
        Task { await store.refresh(showLoading: true) }
    }

    private var showsSessionActivity: Bool {
        store.status.isActive || store.pendingActionCount > 0
    }

    private var sessionActivityPhase: BYOTActivityPhase {
        if store.pendingActionCount > 0 {
            return .waiting
        }
        switch store.status {
        case .idle:
            return .waiting
        case .busy:
            return store.isAwaitingFirstVisibleOutput
                || store.hasVisibleAssistantActivityAfterLatestUserMessage == false
                ? .thinking
                : .working
        case .retry:
            return .retrying
        }
    }

    private var sessionActivityTitle: String? {
        switch store.status {
        case .retry(let attempt, _, _) where store.pendingActionCount == 0:
            "Retrying · attempt \(attempt)"
        default:
            nil
        }
    }

    private var sessionActivityDetail: String? {
        guard store.pendingActionCount == 0 else { return nil }
        return switch store.status {
        case .retry(_, let message, _):
            message.trimmedNonEmpty
        default:
            nil
        }
    }

    private var sessionActivityAccessibilityLabel: String {
        sessionActivityPhase.accessibilityDescription(
            title: sessionActivityTitle,
            detail: sessionActivityDetail
        )
    }

    private var sessionActivityAnnouncementKey: String? {
        guard showsSessionActivity else { return nil }
        return [
            sessionActivityPhase.rawValue,
            sessionActivityTitle ?? "",
            sessionActivityDetail ?? "",
        ].joined(separator: "|")
    }

    private func scrollToConversationBottomIfNeeded(_ proxy: ScrollViewProxy) {
        guard isAtBottom else { return }
        // Streaming can update faster than an animation completes. Follow immediately;
        // reserve animation for the user's explicit jump.
        proxy.scrollTo(bottomAnchorID, anchor: .bottom)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if reduceMotion {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        } else {
            withAnimation(.easeOut(duration: BYOTBrand.Motion.quick)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var pendingActions: some View {
        ForEach(store.permissions, id: \.presentationID) { permission in
            OpenCodePermissionCard(
                request: permission,
                isWorking: store.actionInFlightID != nil
            ) { reply in
                await store.reply(to: permission, with: reply)
            }
        }

        ForEach(store.questions, id: \.presentationID) { question in
            OpenCodeQuestionCard(
                request: question,
                isWorking: store.actionInFlightID != nil
            ) { answers in
                await store.answer(question, answers: answers)
            } reject: {
                await store.reject(question)
            }
        }
    }

    private func retryQueuedPrompt(_ id: UUID) {
        store.retryQueuedPrompt(id)
    }

}

private struct OpenCodeScrollMetrics: Equatable {
    var bottomY: CGFloat?
    var viewportHeight: CGFloat?
}

private struct OpenCodeScrollMetricsKey: PreferenceKey {
    static let defaultValue = OpenCodeScrollMetrics()

    static func reduce(value: inout OpenCodeScrollMetrics, nextValue: () -> OpenCodeScrollMetrics) {
        let next = nextValue()
        value.bottomY = next.bottomY ?? value.bottomY
        value.viewportHeight = next.viewportHeight ?? value.viewportHeight
    }
}

/// OpenCode's turn layout: the prompt is a trailing pill and the reply runs
/// full width beneath it, with no role headers.
private struct OpenCodeMessageView: View {
    let message: OpenCodeMessageEnvelope
    var turnMessageID: String? = nil

    private var isUser: Bool { message.info.role == "user" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(message.parts) { part in
                OpenCodePartView(part: part, isUser: isUser, turnMessageID: turnMessageID)
            }
            if let error = message.info.error {
                Label(error.displayMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.cleanCaption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, isUser ? 16 : 0)
        .padding(.vertical, isUser ? 10 : 0)
        .background {
            if isUser {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(BYOTBrand.surface)
            }
        }
        .padding(.leading, isUser ? 48 : 0)
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? "You" : message.info.agent ?? "OpenCode")
    }
}

private struct OpenCodePartView: View {
    @Environment(\.openCodeReviewChanges) private var reviewChanges
    let part: OpenCodePart
    let isUser: Bool
    var turnMessageID: String? = nil

    var body: some View {
        switch part.type {
        case "text":
            if let text = part.text, !text.isEmpty {
                AgentMarkdownText(text: text)
            }
        case "reasoning":
            if let text = part.text, !text.isEmpty {
                DisclosureGroup {
                    AgentMarkdownText(text: text)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .textSelection(.enabled)
                } label: {
                    Text("Reasoning")
                        .font(.cleanMono)
                        .foregroundStyle(.secondary)
                }
                .disclosureGroupStyle(OpenCodeInlineDisclosureStyle())
            }
        case "tool":
            if let state = part.state {
                OpenCodeToolView(name: part.tool ?? "Tool", state: state)
            }
        case "file":
            OpenCodeRemoteFilePartView(part: part)
        case "patch":
            if let files = part.files, !files.isEmpty {
                OpenCodePatchPartRow(files: files) {
                    reviewChanges?(OpenCodeDiffReviewRequest(messageID: turnMessageID, files: files))
                }
                .disabled(reviewChanges == nil)
            }
        case "subtask":
            VStack(alignment: .leading, spacing: 4) {
                Label(part.description ?? "Subtask", systemImage: "arrow.triangle.branch")
                    .font(.cleanCaptionBold)
                if let agent = part.agent {
                    Text(agent)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
            }
        default:
            EmptyView()
        }
    }
}

/// A turn's patch summary; opens the reviewer pinned to that turn.
private struct OpenCodePatchPartRow: View {
    @Environment(\.isEnabled) private var isEnabled
    let files: [String]
    let action: () -> Void

    private var title: String {
        guard files.count == 1, let file = files.first else { return "Changed \(files.count) files" }
        return "Changed \(file.split(separator: "/").last.map(String.init) ?? file)"
    }

    var body: some View {
        Button(action: action) {
            // Same glyph column as the tool rows' disclosure chevrons.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "plusminus")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.cleanMono)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                // Where the server can't review changes the row is a plain summary.
                if isEnabled {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.vertical, 3)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(isEnabled ? "Reviews the changes from this turn" : "")
        .accessibilityIdentifier("transcript-patch")
    }
}
