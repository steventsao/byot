import StoreKit
import SwiftUI

/// A conversation screen. A subagent session can step to a sibling or up to
/// its parent in place, so the host swaps the session it shows rather than
/// deepening the navigation stack.
struct OpenCodeSessionView: View {
    private let client: OpenCodeClient
    private let directory: String
    private let attention: OpenCodeSessionAttentionStore?
    private let startsWithComposerFocused: Bool
    private let presentingSessionID: String?
    private let onDelete: (() -> Void)?
    @State private var session: OpenCodeSession
    @State private var didReplaceSession = false

    /// `presentingSessionID` is the conversation beneath this one on the
    /// navigation stack, so returning to it can pop instead of push.
    init(
        client: OpenCodeClient,
        session: OpenCodeSession,
        directory: String,
        attention: OpenCodeSessionAttentionStore? = nil,
        startsWithComposerFocused: Bool = false,
        presentingSessionID: String? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.client = client
        self.directory = directory
        self.attention = attention
        self.startsWithComposerFocused = startsWithComposerFocused
        self.presentingSessionID = presentingSessionID
        self.onDelete = onDelete
        _session = State(initialValue: session)
    }

    var body: some View {
        OpenCodeSessionScreen(
            client: client,
            session: session,
            directory: directory,
            attention: attention,
            startsWithComposerFocused: startsWithComposerFocused && !didReplaceSession,
            presentingSessionID: presentingSessionID,
            onDelete: onDelete
        ) { next in
            guard next.id != session.id else { return }
            didReplaceSession = true
            session = next
            AccessibilityNotification.Announcement(String(localized: "Showing \(OpenCodeSubagentTitle.displayTitle(of: next))")).post()
        }
        .id(session.id)
    }
}

struct OpenCodeSessionScreen: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL
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
    @State private var transcriptViewportHeight = CGFloat.infinity
    @State private var hasPositionedTranscript = false
    @State private var isShowingDetails = false
    @State private var isShowingTasks = false
    @State private var isShowingUsage = false
    @State private var isShowingNewSession = false
    @State private var isShowingExport = false
    @State private var isShowingAgentsSetup = false
    @State private var transcriptCopies = 0
    @State private var showsTranscriptCopied = false
    @State private var isShowingShare = false
    @State private var nextSession: OpenCodeSessionRoute?
    @State private var terminalRoute: OpenCodeTerminalRoute?
    @State private var canOpenTerminal = false
    @State private var statusRoute: OpenCodeProjectStatusRoute?
    @State private var canOpenStatus = false
    /// The project's checked-out branch, shown beside the project name.
    @State private var branch: String?
    /// Bumped by each branch event, so a slower fetch never overwrites a newer report.
    @State private var branchGeneration = 0
    @State private var visibility = UUID()
    @Environment(\.openCodeVisibleSessions) private var visibleSessions
    private let client: OpenCodeClient
    private let terminalService: OpenCodeTerminalService
    private let contextService: OpenCodeServerContextService
    private let serverName: String
    private let attention: OpenCodeSessionAttentionStore?
    private let startsWithComposerFocused: Bool
    private let presentingSessionID: String?
    private let replaceSession: (OpenCodeSession) -> Void
    /// Closes the conversation when it is the split view's detail, where
    /// there is nothing to pop back to once the session is deleted.
    private let onDelete: (() -> Void)?

    private let bottomAnchorID = "opencode-session-bottom"

    init(
        client: OpenCodeClient,
        session: OpenCodeSession,
        directory: String,
        attention: OpenCodeSessionAttentionStore?,
        startsWithComposerFocused: Bool,
        presentingSessionID: String?,
        onDelete: (() -> Void)?,
        replaceSession: @escaping (OpenCodeSession) -> Void
    ) {
        self.client = client
        self.onDelete = onDelete
        serverName = client.profile.name
        self.attention = attention
        self.startsWithComposerFocused = startsWithComposerFocused
        self.presentingSessionID = presentingSessionID
        self.replaceSession = replaceSession
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
                    if let offline = store.offlineTranscript, let errorMessage = store.errorMessage {
                        // One notice covers the failed load and the dropped event stream.
                        OpenCodeOfflineNotice(
                            subject: .transcript,
                            savedAt: offline.savedAt,
                            detail: errorMessage,
                            isTruncated: offline.isTruncated,
                            isRetrying: store.isLoading,
                            retry: refreshSession
                        )
                    } else if let errorMessage = store.errorMessage, hasConversationContent {
                        ErrorBanner(
                            message: errorMessage,
                            actionTitle: String(localized: "Refresh"),
                            action: refreshSession
                        )
                    }

                    if let eventErrorMessage = store.eventErrorMessage,
                       store.offlineTranscript == nil || store.errorMessage == nil,
                       eventErrorMessage != store.errorMessage {
                        ErrorBanner(
                            message: eventErrorMessage,
                            actionTitle: String(localized: "Refresh"),
                            action: refreshSession
                        )
                    }

                    if let actionErrorMessage = store.actionErrorMessage,
                       actionErrorMessage != store.errorMessage,
                       actionErrorMessage != store.eventErrorMessage {
                        ErrorBanner(
                            message: actionErrorMessage,
                            actionTitle: String(localized: "Refresh"),
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

                    ForEach(OpenCodeShellTranscript.rows(for: store.messages, local: store.localShell)) { row in
                        switch row {
                        case .message(let message): messageRow(message).id(message.id)
                        case .shell(let run): shellRow(run).id(run.id)
                        }
                    }

                    if store.todoProgress.totalCount > 0 && !showsTranscriptLoading {
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
                            message: String(localized: "OpenCode returned to idle without a reply. Choose another model if needed, then retry the last message."),
                            actionTitle: String(localized: "Retry last message")
                        ) {
                            Task { await store.retryUnansweredPrompt() }
                        }
                        .id("opencode-unanswered-prompt-recovery")
                    }

                    if showsSessionActivity && !showsTranscriptLoading {
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

                    if !store.isLoadingTranscript,
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
                // A transcript shorter than the screen still fills it, so its rows
                // always rest under the header.
                .frame(
                    minHeight: OpenCodeTranscriptLayout.minimumContentHeight(viewportHeight: transcriptViewportHeight),
                    alignment: .top
                )
            }
            .overlay {
                if showsTranscriptLoading {
                    BYOTActivityView(
                        .loading,
                        title: String(localized: "Loading transcript"),
                        layout: .blocking
                    )
                    .multilineTextAlignment(.center)
                    .padding(20)
                    .accessibilityIdentifier("session-transcript-loading")
                }
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
                transcriptViewportHeight = height
                isAtBottom = bottomY <= height + 32 && bottomY >= 0
            }
            .overlay(alignment: .bottom) {
                // With the keyboard and slash suggestions up, the transcript can
                // shrink to a sliver where the pill would sit clipped under the header.
                if !isAtBottom && hasConversationContent && transcriptViewportHeight >= 160 {
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
                    revealConversationBottom(proxy)
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
                    String(localized: "Response required")
                ).post()
                scrollToConversationBottomIfNeeded(proxy)
            }
            .onChange(of: store.localShell) { _, newValue in
                guard let newValue else { return }
                // Follow a new command and its outcome, even from an older scroll position.
                revealConversationBottom(proxy)
                switch newValue.phase {
                case .sending: break
                case .failed(let message):
                    AccessibilityNotification.Announcement(String(localized: "Command didn’t run. \(message)")).post()
                case .unconfirmed:
                    AccessibilityNotification.Announcement(String(localized: "Command result unconfirmed")).post()
                }
            }
            .onChange(of: store.queueAnnouncementRevision) { _, _ in
                AccessibilityNotification.Announcement(String(localized: "Message queued")).post()
                proxy.scrollTo("opencode-queued-prompts")
            }
        }
        .background(BYOTBrand.canvas)
        .navigationTitle(OpenCodeSubagentTitle.displayTitle(of: store.session))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    sessionHeader
                    Spacer(minLength: 8)
                    contextMeter
                    sessionStatus
                }
                VStack(alignment: .leading, spacing: 8) {
                    sessionHeader
                    HStack(spacing: 12) {
                        contextMeter
                        sessionStatus
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(BYOTBrand.canvas)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if store.nudge == .star {
                    BYOTStarNudgeCard(
                        star: {
                            openURL(BYOTNudgeGate.repoURL)
                            store.answerNudge(.starred)
                        },
                        later: { store.answerNudge(.later) }
                    )
                    .padding(.horizontal, 12)
                }
                if let family = store.subagentFamily {
                    OpenCodeSubagentBar(
                        agentLabel: OpenCodeSubagentTitle.agentLabel(OpenCodeSubagentTitle.agent(of: store.session)),
                        family: family,
                        canStop: store.canStopTurn,
                        isStopping: store.isStoppingTurn,
                        stop: { Task { await store.stopTurn() } },
                        open: replaceSession
                    )
                } else {
                    composer
                }
            }
        }
        .onChange(of: store.nudge) { _, ask in
            // Apple shows its prompt at most three times a year; the ask is
            // recorded whether or not a dialog appears.
            guard ask == .review else { return }
            requestReview()
            store.answerNudge(.reviewRequested)
        }
        .environment(\.openCodeRemoteFiles, store.remoteFiles)
        .environment(\.openCodeContextLimits, store.modelContextLimits)
        .environment(\.openCodeSubagents, OpenCodeSubagentLinks(
            activity: store.subagents.activity,
            children: store.childSessions,
            openingSessionID: store.openingSubagentID,
            canOpenUnlisted: store.sessionFeatures.details
        ) { sessionID in
            openSubagent(sessionID)
        })
        .environment(\.openCodeDiffNavigator, OpenCodeDiffNavigator(diffs: store.diffs, directory: store.directory))
        .environment(\.openCodeReviewChanges, isReviewChangesVisible ? OpenCodeReviewChangesAction { request in
            diffRequest = request
        } : nil)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Message queue", systemImage: "list.bullet.rectangle") { isShowingQueue = true }
                        .accessibilityIdentifier("session-queue")
                    Button("Session details", systemImage: "info.circle") { isShowingDetails = true }
                    Button("Context and usage", systemImage: "chart.pie") { isShowingUsage = true }
                        .accessibilityIdentifier("session-usage")
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
                    if store.sharePresentation.isAvailable {
                        Button(store.sharePresentation.menuTitle, systemImage: store.sharePresentation.menuSymbol) { isShowingShare = true }
                            .accessibilityIdentifier("session-menu-share")
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
                    Section {
                        if store.supportsAgentsSetup {
                            Button("Set up AGENTS.md…", systemImage: "doc.badge.gearshape") { isShowingAgentsSetup = true }
                                .disabled(store.agentsSetupUnavailableReason != nil)
                                .accessibilityIdentifier("session-menu-init")
                        }
                        Button("Export transcript…", systemImage: "square.and.arrow.up") { isShowingExport = true }
                            .disabled(store.transcriptUnavailableReason != nil)
                            .accessibilityIdentifier("session-menu-export")
                        Button("Copy transcript", systemImage: "doc.on.doc", action: copyTranscript)
                            .disabled(store.transcriptUnavailableReason != nil)
                            .accessibilityIdentifier("session-menu-copy")
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
                open(session)
            }
        }
        .sheet(isPresented: $isShowingUsage) {
            OpenCodeSessionUsageView(store: store)
        }
        .sheet(isPresented: $isShowingShare) {
            OpenCodeSessionShareView(store: store)
        }
        .sheet(isPresented: $isShowingTasks) {
            OpenCodeTaskProgressView(progress: store.todoProgress, supportsSnapshot: store.sessionFeatures.todoSnapshot)
        }
        .sheet(isPresented: $isShowingExport) {
            OpenCodeTranscriptExportView(export: store.transcriptExport)
        }
        .openCodeAgentsSetupAlert(isPresented: $isShowingAgentsSetup, store: store)
        .overlay(alignment: .top) {
            if showsTranscriptCopied {
                Label("Transcript copied", systemImage: "checkmark.circle.fill")
                    .font(.cleanCaptionBold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(BYOTBrand.hairline, lineWidth: 1) }
                    .padding(.top, 8)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("transcript-copied")
            }
        }
        .task(id: transcriptCopies) {
            guard transcriptCopies > 0 else { return }
            try? await Task.sleep(for: .seconds(2.4))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: BYOTBrand.Motion.quick)) { showsTranscriptCopied = false }
        }
        .navigationDestination(item: $nextSession) { route in
            OpenCodeSessionView(client: client, session: route.session, directory: route.session.directory,
                                attention: attention, presentingSessionID: store.session.id)
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
            guard deleted else { return }
            isShowingDetails = false
            if let onDelete { onDelete() } else { dismiss() }
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
        .onAppear {
            push.activeRoute = BYOTPushRoute(serverID: client.profile.id, sessionID: store.session.id, directory: store.session.directory, workspace: store.session.workspaceID)
            visibleSessions?.update(visibility, OpenCodeSessionSelection(client: client, session: store.session, attention: attention))
        }
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
            } else if phase == .background {
                store.saveOfflineTranscriptNow()
            }
        }
        .onChange(of: store.errorMessage) { _, _ in rememberAttention() }
        .onChange(of: liveTurn, initial: true) { _, turn in publishLiveTurn(turn) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { publishLiveTurn(liveTurn) }
        }
        .onDisappear {
            visibleSessions?.update(visibility, nil)
            if push.activeRoute?.serverID == client.profile.id && push.activeRoute?.sessionID == store.session.id { push.activeRoute = nil }
            rememberAttention()
            BYOTLiveActivityController.shared.release(serverID: client.profile.id, sessionID: store.session.id)
            store.stop()
        }
    }

    private var composer: some View {
        OpenCodeSessionComposerView(
            store: store,
            startsFocused: startsWithComposerFocused,
            serverName: serverName,
            onNewSession: { isShowingNewSession = true },
            sessionActions: OpenCodeSessionAction.allCases.map { action in
                OpenCodeComposerAction(name: action.rawValue, title: action.title,
                    unavailableReason: store.actionUnavailableReason(action),
                    run: { Task { await store.performSessionAction(action) } })
            } + [
                OpenCodeComposerAction(name: "export", title: String(localized: "Export transcript as Markdown"),
                    unavailableReason: store.transcriptUnavailableReason, run: { isShowingExport = true }),
                OpenCodeComposerAction(name: "copy", title: String(localized: "Copy transcript as Markdown"),
                    unavailableReason: store.transcriptUnavailableReason, run: copyTranscript),
            ],
            restoredMessage: store.restoredPrompt?.message,
            onRestoreConsumed: { store.consumeRestoredPrompt() },
            keyboardCommandsEnabled: !isPresentingSheet
        )
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

    /// The TUI's `/copy`: the whole conversation as Markdown, with the
    /// choices last made in Export transcript.
    private func copyTranscript() {
        OpenCodeTranscriptClipboard.copy(store.transcriptExport)
        transcriptCopies += 1
        withAnimation(reduceMotion ? nil : .spring(duration: BYOTBrand.Motion.composerResize)) { showsTranscriptCopied = true }
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

    /// v1 shell turns keep the user message's id, so they can be undone or
    /// forked like a prompt; v2 records the run outside the prompt history.
    private func shellRow(_ run: OpenCodeShellRun) -> some View {
        let isUserTurn = store.messages.contains { $0.id == run.id && $0.info.role == "user" }
        return OpenCodeShellRunView(run: run, dismiss: run.id.hasPrefix("shell-local-") && !run.isRunning
            ? { store.dismissShellFailure() } : nil)
            .contextMenu {
                Button("Copy Command", systemImage: "doc.on.doc") { UIPasteboard.general.string = run.command }
                if !run.output.isEmpty {
                    Button("Copy Output", systemImage: "doc.on.clipboard") { UIPasteboard.general.string = run.output }
                }
                if isUserTurn {
                    Button("Undo to this command", systemImage: "arrow.uturn.backward") {
                        Task { await store.performSessionAction(.undo, messageID: run.id) }
                    }.disabled(store.actionUnavailableReason(.undo) != nil)
                    Button("Fork before this command", systemImage: "arrow.triangle.branch") {
                        Task { await store.performSessionAction(.fork, messageID: run.id) }
                    }.disabled(store.actionUnavailableReason(.fork) != nil)
                }
            }
    }

    private func rememberAttention() {
        guard !store.messages.isEmpty || store.errorMessage != nil else { return }
        attention?.record(sessionID: store.session.id,
            message: OpenCodeSessionAttentionStore.message(in: store.messages) ?? store.errorMessage)
    }

    /// A subagent names the conversation that started it; any other session
    /// names its server and project.
    @ViewBuilder
    private var sessionHeader: some View {
        // The breadcrumb needs a way back: the parent beneath on the stack,
        // or one the server can look up.
        if let family = store.subagentFamily,
           family.parent != nil || family.parentID == presentingSessionID || store.sessionFeatures.details {
            OpenCodeSubagentBreadcrumb(parentTitle: family.parentTitle) { openParent(family.parentID) }
        } else {
            sessionContext
        }
    }

    /// Opens a subagent from one of its task cards.
    private func openSubagent(_ sessionID: String) {
        Task {
            if let session = await store.relatedSession(sessionID) { open(session) }
        }
    }

    /// Goes to a related session. Returning to the conversation beneath this
    /// one pops back to it; stepping to the parent from anywhere else, or to a
    /// sibling, swaps this screen in place so the stack never loops.
    private func open(_ session: OpenCodeSession) {
        if session.id == presentingSessionID {
            dismiss()
        } else if session.id == store.session.parentID || (session.parentID != nil && session.parentID == store.session.parentID) {
            replaceSession(session)
        } else {
            nextSession = OpenCodeSessionRoute(session: session)
        }
    }

    private func openParent(_ parentID: String) {
        if parentID == presentingSessionID {
            dismiss()
            return
        }
        Task {
            if let parent = await store.relatedSession(parentID) { replaceSession(parent) }
        }
    }

    /// The latest turn as the Live Activity shows it. Until the first status
    /// arrives the store reports idle, which must not end a running activity.
    private var liveTurn: BYOTTurnSnapshot? {
        guard store.isStatusReady else { return nil }
        return BYOTTurnSnapshot.make(status: store.status, permissions: store.permissions,
                                     questions: store.questions, messages: store.messages)
    }

    private func publishLiveTurn(_ turn: BYOTTurnSnapshot?) {
        guard store.isStatusReady else { return }
        let profile = client.profile
        let session = store.session
        BYOTLiveActivityController.shared.drive(
            BYOTTurnActivityAttributes(
                serverID: profile.id, serverName: serverName, sessionID: session.id,
                sessionTitle: session.title.trimmedWidgetText ?? String(localized: "Untitled session"),
                projectName: URL(fileURLWithPath: session.directory).lastPathComponent,
                directory: session.directory, workspace: session.workspaceID),
            snapshot: turn, canStart: scenePhase == .active)
        let state = BYOTWidgetSync.state(
            status: store.status, isPending: store.pendingActionCount > 0,
            hasFailure: OpenCodeSessionAttentionStore.message(in: store.messages) != nil)
        BYOTWidgetSync.shared.update(state.map { BYOTWidgetSync.row(profile: profile, session: session, state: $0) },
                                     serverID: profile.id, sessionID: session.id, serverName: profile.name)
    }

    /// Server, project and branch, with the public-link badge while shared.
    @ViewBuilder
    private var sessionContext: some View {
        // At accessibility sizes the badge takes its own line instead of
        // squeezing the server and project name.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: BYOTBrand.Space.xs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: BYOTBrand.Space.sm))
        layout {
            serverProjectLabel
            if store.sharePresentation.isPublished { sharedIndicator }
        }
    }

    /// Server, project and branch; opens the project's status where the server has one.
    @ViewBuilder
    private var serverProjectLabel: some View {
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
        let accessibilityLabel = String(localized: "Server \(serverName), project \(store.directory)") + (branch.map { String(localized: ", branch \($0)") } ?? "")
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

    @ViewBuilder
    private var contextMeter: some View {
        if let meter = OpenCodeContextMeterPresentation(usage: store.usage) {
            OpenCodeContextMeter(presentation: meter) { isShowingUsage = true }
        }
    }

    @ViewBuilder
    private var sharedIndicator: some View {
        if store.sharePresentation.isAvailable {
            Button { isShowingShare = true } label: {
                OpenCodeSharedSessionBadge()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -12)
            .accessibilityHint("Shows the public link.")
            .accessibilityIdentifier("session-shared-indicator")
        } else {
            OpenCodeSharedSessionBadge()
        }
    }

    @ViewBuilder
    private var sessionStatus: some View {
        if store.isStatusReady || store.status.isActive {
            OpenCodeStatusLabel(status: store.status, eventConnected: store.isEventConnected)
                .fixedSize()
        }
    }

    private var isPresentingSheet: Bool {
        diffRequest != nil || isShowingQueue || isShowingDetails || isShowingTasks || isShowingUsage
            || isShowingExport || isShowingShare || isShowingRecoveryModelPicker || isShowingAgentsSetup
            || notificationError != nil
    }

    private var hasConversationContent: Bool {
        !store.messages.isEmpty
            || store.localShell != nil
            || !store.queuedPrompts.isEmpty
            || store.pendingActionCount > 0
    }

    private var showsTranscriptLoading: Bool {
        store.isLoadingTranscript && !hasConversationContent
    }

    private func refreshSession() {
        Task { await store.refresh(showLoading: true) }
    }

    // A running shell card already shows its own progress.
    private var showsSessionActivity: Bool {
        (store.status.isActive && !store.isShellSending) || store.pendingActionCount > 0
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
            String(localized: "Retrying · attempt \(attempt)")
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
        revealConversationBottom(proxy)
    }

    /// Scrolls only as far as it takes to show the end of the conversation.
    /// Asking for the end to sit on the bottom edge instead would pull a
    /// transcript that already fits on screen down to the composer.
    private func revealConversationBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(bottomAnchorID)
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
/// full width beneath it, with no role headers. Conversation markers such as
/// compaction sit outside the pill.
private struct OpenCodeMessageView: View {
    let message: OpenCodeMessageEnvelope
    @Environment(\.openCodeContextLimits) private var contextLimits
    var turnMessageID: String? = nil

    private var isUser: Bool { message.info.role == "user" }

    private var contextLimit: Int? {
        guard let providerID = message.info.providerID, let modelID = message.info.modelID else { return nil }
        return contextLimits["\(providerID)/\(modelID)"]
    }

    var body: some View {
        let items = OpenCodeTranscriptLayout.items(for: message.parts, inPrompt: isUser)
        let bubble = isUser ? items.filter { !$0.isBanner } : items
        let banners = isUser ? items.filter(\.isBanner) : []
        let reply = OpenCodeStepSummary(reply: message, contextLimit: contextLimit)
        VStack(alignment: .leading, spacing: 12) {
            if !bubble.isEmpty || message.info.error != nil || reply != nil {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(bubble) { item in
                        OpenCodeTranscriptItemView(item: item, isUser: isUser, contextLimit: contextLimit,
                                                   turnMessageID: turnMessageID)
                    }
                    if let reply {
                        OpenCodeStepSummaryView(summary: reply)
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
            }
            ForEach(banners) { item in
                OpenCodeTranscriptItemView(item: item, isUser: false, contextLimit: nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? String(localized: "You") : message.info.agent ?? "OpenCode")
    }
}

private struct OpenCodeTranscriptItemView: View {
    let item: OpenCodeTranscriptItem
    let isUser: Bool
    let contextLimit: Int?
    var turnMessageID: String? = nil

    var body: some View {
        switch item {
        case .images(let parts):
            OpenCodeInlineImageGallery(parts: parts)
        case .part(let part):
            OpenCodePartView(part: part, isUser: isUser, contextLimit: contextLimit, turnMessageID: turnMessageID)
        }
    }
}

private struct OpenCodePartView: View {
    let part: OpenCodePart
    let isUser: Bool
    let contextLimit: Int?
    var turnMessageID: String? = nil

    var body: some View {
        switch part.type {
        case "text":
            if let context = OpenCodeSyntheticContextPresentation(part: part) {
                OpenCodeSyntheticContextView(presentation: context)
            } else if part.synthetic != true, let text = part.text, !text.isEmpty {
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
            if let task = OpenCodeSubagentTask(part: part) {
                OpenCodeSubagentTaskCard(task: task)
            } else if let state = part.state {
                OpenCodeToolView(name: part.tool ?? String(localized: "Tool"), state: state)
            }
        case "file":
            OpenCodeRemoteFilePartView(part: part)
        case "patch":
            if let files = part.files, !files.isEmpty {
                OpenCodePatchPartView(files: files, turnMessageID: turnMessageID)
            }
        case "subtask":
            VStack(alignment: .leading, spacing: 4) {
                Label(part.description ?? String(localized: "Subtask"), systemImage: "arrow.triangle.branch")
                    .font(.cleanCaptionBold)
                if let agent = part.agent {
                    Text(agent)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
            }
        case "compaction":
            OpenCodeCompactionDivider(presentation: OpenCodeCompactionPresentation(part: part))
        case "retry":
            OpenCodeRetryNotice(presentation: OpenCodeRetryPresentation(part: part))
        case "agent", "model":
            if let presentation = OpenCodeSwitchPresentation(part: part, inPrompt: isUser) {
                if isUser {
                    OpenCodeAgentMentionChip(presentation: presentation)
                } else {
                    OpenCodeTranscriptMarkerRow(symbol: presentation.symbol, title: presentation.title,
                                                accessibilityLabel: presentation.accessibilityLabel)
                }
            }
        case "step-finish":
            if let summary = OpenCodeStepSummary(part: part, contextLimit: contextLimit) {
                OpenCodeStepSummaryView(summary: summary)
            }
        case "snapshot":
            if let snapshot = OpenCodeSnapshotPresentation(part: part) {
                OpenCodeTranscriptMarkerRow(symbol: "clock.arrow.circlepath", title: snapshot.title,
                                            accessibilityLabel: snapshot.accessibilityLabel)
            }
        default:
            EmptyView()
        }
    }
}
