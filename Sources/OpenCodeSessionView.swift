import SwiftUI

struct OpenCodeSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store: OpenCodeSessionStore
    @State private var isShowingDiff = false
    @State private var isShowingRecoveryModelPicker = false
    @State private var isAtBottom = true
    @State private var isShowingDetails = false
    @State private var isShowingTasks = false
    @State private var isShowingNewSession = false
    @State private var nextSession: OpenCodeSessionRoute?
    private let client: OpenCodeClient
    private let serverName: String
    private let attention: OpenCodeSessionAttentionStore?

    private let bottomAnchorID = "opencode-session-bottom"

    init(
        client: OpenCodeClient,
        session: OpenCodeSession,
        directory: String,
        attention: OpenCodeSessionAttentionStore? = nil
    ) {
        self.client = client
        serverName = client.profile.name
        self.attention = attention
        _store = StateObject(
            wrappedValue: OpenCodeSessionStore(
                client: client,
                session: session,
                directory: directory
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
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
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .frame(maxWidth: BYOTBrand.conversationMaxWidth)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.transcriptRevision) { _, _ in
                rememberAttention()
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
                if reduceMotion {
                    proxy.scrollTo("opencode-pending-actions", anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("opencode-pending-actions", anchor: .bottom)
                    }
                }
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
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(BYOTBrand.canvas)
        }
        .safeAreaInset(edge: .bottom) {
            OpenCodeSessionComposerView(
                store: store,
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Session details", systemImage: "info.circle") { isShowingDetails = true }
                    Button("Tasks", systemImage: "checklist") { isShowingTasks = true }
                    ForEach(OpenCodeSessionAction.allCases) { action in
                        Button(action.title, systemImage: action.symbol) {
                            Task { await store.performSessionAction(action) }
                        }.disabled(store.actionUnavailableReason(action) != nil)
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Session actions")
                .accessibilityIdentifier("session-actions")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Changes", systemImage: "doc.text.magnifyingglass") {
                    isShowingDiff = true
                }
                .labelStyle(.iconOnly)
                .disabled(!store.diffPresentation.canPresent)
            }
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
        .sheet(isPresented: $isShowingDiff) {
            OpenCodeDiffView(diffs: store.diffs, unavailableReason: store.diffPresentation.unavailableReason)
        }
        .sheet(isPresented: $isShowingRecoveryModelPicker) {
            OpenCodeModelPickerView(store: store)
                .task { await store.reloadModels() }
        }
        .task { await store.start() }
        .onChange(of: store.errorMessage) { _, _ in rememberAttention() }
        .onDisappear {
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
            OpenCodeMessageView(message: message)
        }
    }

    private func rememberAttention() {
        guard !store.messages.isEmpty || store.errorMessage != nil else { return }
        attention?.record(sessionID: store.session.id,
            message: OpenCodeSessionAttentionStore.message(in: store.messages) ?? store.errorMessage)
    }

    private var sessionContext: some View {
        Text("\(serverName) · \(URL(fileURLWithPath: store.directory).lastPathComponent)")
            .font(.cleanCaption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Server \(serverName), project \(store.directory)")
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

private struct OpenCodeMessageView: View {
    let message: OpenCodeMessageEnvelope

    var body: some View {
        VStack(alignment: message.info.role == "user" ? .trailing : .leading, spacing: 8) {
            if showsMessageHeader {
                HStack(spacing: 7) {
                    if message.info.role == "assistant" {
                        Image(systemName: "terminal")
                            .foregroundStyle(BYOTBrand.accent)
                        Text(message.info.agent ?? "OpenCode")
                    } else {
                        Text("You")
                    }
                }
                .font(.cleanCaptionBold)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(message.parts) { part in
                    OpenCodePartView(part: part, isUser: message.info.role == "user")
                }
                if let error = message.info.error {
                    Label(error.displayMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.cleanCaption)
                        .foregroundStyle(.red)
                }
            }
            .padding(message.info.role == "user" ? 14 : 0)
            .background {
                if message.info.role == "user" {
                    RoundedRectangle(cornerRadius: BYOTBrand.panelRadius)
                        .fill(BYOTBrand.surface)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.info.role == "user" ? .trailing : .leading)
        .accessibilityElement(children: .contain)
    }

    private var showsMessageHeader: Bool {
        guard message.info.role == "assistant" else { return true }
        return message.parts.contains { part in
            part.type == "text"
                && part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
    }
}

private struct OpenCodePartView: View {
    let part: OpenCodePart
    let isUser: Bool

    var body: some View {
        switch part.type {
        case "text":
            if let text = part.text, !text.isEmpty {
                AgentMarkdownText(text: text)
            }
        case "reasoning":
            if let text = part.text, !text.isEmpty {
                DisclosureGroup("Reasoning") {
                    AgentMarkdownText(text: text)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                        .textSelection(.enabled)
                }
                .font(.cleanCaptionBold)
                .tint(.secondary)
            }
        case "tool":
            if let state = part.state {
                OpenCodeToolView(name: part.tool ?? "Tool", state: state)
            }
        case "file":
            OpenCodeRemoteFilePartView(part: part)
        case "patch":
            if let files = part.files, !files.isEmpty {
                Label("Changed \(files.count) file\(files.count == 1 ? "" : "s")", systemImage: "plusminus")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
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

private struct OpenCodeDiffView: View {
    @Environment(\.dismiss) private var dismiss
    let diffs: [OpenCodeDiff]
    let unavailableReason: String?

    var body: some View {
        NavigationStack {
            List(diffs) { diff in
                DisclosureGroup {
                    if let patch = diff.patch, !patch.isEmpty {
                        ScrollView(.horizontal) {
                            Text(patch)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(.vertical, 8)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(diff.file ?? "Changed file")
                            .font(.cleanBodySemibold)
                        Text("+\(diff.additions) −\(diff.deletions)")
                            .font(.cleanCaptionBold)
                            .foregroundStyle(BYOTBrand.accent)
                    }
                }
            }
            .overlay {
                if let unavailableReason {
                    ContentUnavailableView("Session changes unavailable", systemImage: "doc.text.magnifyingglass", description: Text(unavailableReason))
                }
            }
            .navigationTitle("Session changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
