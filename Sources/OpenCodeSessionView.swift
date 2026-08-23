import SwiftUI

struct OpenCodeSessionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store: OpenCodeSessionStore
    @StateObject private var inputStore: OpenCodeSessionInputStore
    @State private var isShowingDiff = false
    @State private var isShowingChildren = false
    @State private var isShowingTodos = false
    @State private var isShowingFiles = false
    @State private var isAtBottom = true
    @State private var pendingRevertTarget: OpenCodeSessionRevertTarget?
    @State private var isConfirmingRestore = false
    @State private var forkedSession: OpenCodeSession?
    let openAppNavigation: () -> Void
    private let client: OpenCodeClient

    private let bottomAnchorID = "opencode-session-bottom"

    init(
        client: OpenCodeClient,
        session: OpenCodeSession,
        directory: String,
        openAppNavigation: @escaping () -> Void
    ) {
        self.client = client
        self.openAppNavigation = openAppNavigation
        _store = StateObject(
            wrappedValue: OpenCodeSessionStore(
                client: client,
                session: session,
                directory: directory
            )
        )
        _inputStore = StateObject(
            wrappedValue: OpenCodeSessionInputStore(
                client: client,
                directory: directory,
                workspace: session.workspaceID,
                initialAgentID: session.agent
            )
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let errorMessage = store.errorMessage, hasConversationContent {
                        ErrorBanner(message: errorMessage)
                    }

                    if let eventErrorMessage = store.eventErrorMessage,
                       eventErrorMessage != store.errorMessage {
                        ErrorBanner(message: eventErrorMessage)
                    }

                    if let actionErrorMessage = store.actionErrorMessage,
                       actionErrorMessage != store.errorMessage,
                       actionErrorMessage != store.eventErrorMessage {
                        ErrorBanner(message: actionErrorMessage)
                    }

                    if !store.historyPresentation.revertedUserMessages.isEmpty {
                        OpenCodeRevertedHistoryCard(
                            messages: store.historyPresentation.revertedUserMessages,
                            canRestore: store.canUnrevertSession,
                            canReviewChanges: store.diffPresentation.canPresent,
                            restore: { isConfirmingRestore = true },
                            reviewChanges: { isShowingDiff = true }
                        )
                    }

                    if !store.todos.isEmpty {
                        Button {
                            isShowingTodos = true
                        } label: {
                            OpenCodeTodoProgressCard(
                                presentation: store.todoPresentation
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open session tasks")
                        .accessibilityValue(store.todoPresentation.progressAccessibilityValue)
                    }

                    ForEach(store.historyPresentation.visibleMessages) { message in
                        OpenCodeMessageView(
                            message: message,
                            canRevert: store.historyPolicy?.canRevert == true
                                && store.historyActionInFlight == nil,
                            canFork: store.historyPolicy?.canFork == true
                                && store.historyActionInFlight == nil,
                            revert: { messageID in
                                pendingRevertTarget = store.historyPresentation.revertTarget(
                                    messageID: messageID
                                )
                            },
                            fork: forkSession
                        )
                            .id(message.id)
                    }

                    if showsSessionActivity {
                        BYOTActivityView(
                            sessionActivityPhase,
                            title: sessionActivityTitle,
                            detail: sessionActivityDetail,
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
                            detail: "Syncing messages and tool activity.",
                            layout: .blocking
                        )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                    } else if !store.isLoading,
                              !hasConversationContent {
                        if let errorMessage = store.errorMessage {
                            ContentUnavailableView {
                                Label("Couldn’t load this session", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(errorMessage.agentDisplayErrorText)
                            } actions: {
                                Button("Try again", systemImage: "arrow.clockwise") {
                                    Task { await store.refresh(showLoading: true) }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                        } else {
                            ContentUnavailableView(
                                "Ready for a prompt",
                                systemImage: "terminal",
                                description: Text("Ask OpenCode to inspect, change, or explain this project.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                        }
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
            .refreshable {
                await store.refresh()
                await inputStore.refresh()
            }
            .onChange(of: store.transcriptRevision) { _, _ in
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
                    "OpenCode requires your response"
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
        .safeAreaInset(edge: .bottom) {
            OpenCodeSessionComposerView(store: store, inputStore: inputStore)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AppNavigationButton(isToolbarItem: true, action: openAppNavigation)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                OpenCodeStatusLabel(
                    status: store.status,
                    eventConnected: store.isEventConnected
                )
                Button("Changes", systemImage: "doc.text.magnifyingglass") {
                    isShowingDiff = true
                }
                .labelStyle(.iconOnly)
                .disabled(!store.diffPresentation.canPresent)
                Button("Tasks", systemImage: "checklist") {
                    isShowingTodos = true
                }
                .labelStyle(.iconOnly)
                .disabled(!store.todoPresentation.canPresent)
                .accessibilityValue(store.todoPresentation.toolbarAccessibilityValue)
                Button("Files", systemImage: "folder") {
                    isShowingFiles = true
                }
                .labelStyle(.iconOnly)
                if store.lifecyclePolicy?.canListChildren == true {
                    Button("Subagents", systemImage: "person.2") {
                        isShowingChildren = true
                    }
                    .labelStyle(.iconOnly)
                    .accessibilityValue("\(store.childSessions.count) sessions")
                }
                Menu("History", systemImage: "clock.arrow.circlepath") {
                    Button("Undo latest prompt", systemImage: "arrow.uturn.backward") {
                        pendingRevertTarget = store.historyPresentation.latestRevertTarget
                    }
                    .disabled(!store.canRevertLatestPrompt)
                    Button("Restore reverted prompts", systemImage: "arrow.uturn.forward") {
                        isConfirmingRestore = true
                    }
                    .disabled(!store.canUnrevertSession)
                    Divider()
                    Button("Compact session", systemImage: "rectangle.compress.vertical") {
                        Task { _ = await store.summarizeSession() }
                    }
                    .disabled(!store.canSummarizeSession)
                    if store.historyPolicy?.canFork == true {
                        Button("Fork session", systemImage: "arrow.triangle.branch") {
                            forkSession(store.historyPresentation.latestForkMessageID)
                        }
                        .disabled(!store.canForkSession)
                    }
                }
                .labelStyle(.iconOnly)
                .disabled(store.historyActionInFlight != nil)
            }
        }
        .sheet(isPresented: $isShowingDiff) {
            OpenCodeDiffView(presentation: store.diffPresentation)
        }
        .sheet(isPresented: $isShowingChildren) {
            OpenCodeSessionChildrenView(
                client: client,
                children: store.childSessions,
                openAppNavigation: openAppNavigation
            )
        }
        .sheet(isPresented: $isShowingTodos) {
            OpenCodeTodoListView(presentation: store.todoPresentation)
        }
        .sheet(isPresented: $isShowingFiles) {
            OpenCodeFileBrowserView(
                client: client,
                directory: store.directory,
                workspace: store.session.workspaceID
            )
        }
        .confirmationDialog(
            "Undo this prompt and everything after it?",
            isPresented: Binding(
                get: { pendingRevertTarget != nil },
                set: { if !$0 { pendingRevertTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Undo messages and file changes", role: .destructive) {
                guard let target = pendingRevertTarget else { return }
                pendingRevertTarget = nil
                Task {
                    if await store.revertSession(to: target) {
                        isShowingDiff = true
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingRevertTarget = nil }
        } message: {
            Text("OpenCode will roll the conversation back to this boundary. Review the resulting file changes before continuing.")
        }
        .confirmationDialog(
            "Restore reverted prompts?",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("Restore messages and files") {
                Task { _ = await store.unrevertSession() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("OpenCode will clear the rollback boundary and restore its file snapshot.")
        }
        .navigationDestination(
            isPresented: Binding(
                get: { forkedSession != nil },
                set: { if !$0 { forkedSession = nil } }
            )
        ) {
            if let forkedSession {
                OpenCodeSessionView(
                    client: client,
                    session: forkedSession,
                    directory: forkedSession.directory,
                    openAppNavigation: openAppNavigation
                )
            }
        }
        .task { await store.start() }
        .task { await inputStore.load() }
        .onDisappear { store.stop() }
    }

    private var hasConversationContent: Bool {
        !store.historyPresentation.visibleMessages.isEmpty
            || !store.queuedPrompts.isEmpty
            || store.pendingActionCount > 0
            || !store.todos.isEmpty
            || store.historyPresentation.canRestore
    }

    private func forkSession(_ messageID: String?) {
        Task {
            if let session = await store.forkSession(at: messageID) {
                forkedSession = session
            }
        }
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

    private var sessionActivityTitle: String {
        if store.pendingActionCount > 0 {
            return "Waiting for your response"
        }
        switch store.status {
        case .idle:
            return "Waiting for your response"
        case .busy:
            return sessionActivityPhase == .thinking
                ? "OpenCode is thinking"
                : "OpenCode is working"
        case .retry(let attempt, _, _):
            return "Retrying request · attempt \(attempt)"
        }
    }

    private var sessionActivityDetail: String? {
        if store.pendingActionCount > 0 {
            return "Review the request below to continue."
        }
        switch store.status {
        case .idle, .busy:
            return nil
        case .retry(_, let message, _):
            return message.trimmedNonEmpty
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
            sessionActivityTitle,
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

private struct OpenCodeTodoProgressCard: View {
    let presentation: OpenCodeTodoPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Session tasks", systemImage: "checklist")
                    .font(.cleanBodySemibold)
                Spacer()
                Text("\(presentation.resolvedCount)/\(presentation.totalCount)")
                    .font(.cleanCaptionBold)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: presentation.progress)
                .tint(BYOTBrand.accent)
            if let headline = presentation.headline {
                Text(headline)
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(14)
        .background(
            BYOTBrand.elevatedSurface,
            in: RoundedRectangle(cornerRadius: BYOTBrand.panelRadius)
        )
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            "\(presentation.resolvedCount) of \(presentation.totalCount) resolved"
        )
    }
}

private struct OpenCodeTodoListView: View {
    @Environment(\.dismiss) private var dismiss
    let presentation: OpenCodeTodoPresentation

    var body: some View {
        NavigationStack {
            Group {
                if let reason = presentation.unavailableReason {
                    ContentUnavailableView(
                        "Session tasks unavailable",
                        systemImage: "checklist",
                        description: Text(reason)
                    )
                } else if presentation.todos.isEmpty {
                    ContentUnavailableView(
                        "No session tasks",
                        systemImage: "checklist",
                        description: Text("OpenCode has not published a task list for this session.")
                    )
                } else {
                    List {
                        Section {
                            ProgressView(value: presentation.progress) {
                                Text("\(presentation.resolvedCount) of \(presentation.totalCount) resolved")
                            }
                            .tint(BYOTBrand.accent)
                        }
                        Section("Tasks") {
                            ForEach(Array(presentation.todos.enumerated()), id: \.offset) { _, todo in
                                OpenCodeTodoRow(todo: todo)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Session tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct OpenCodeTodoRow: View {
    let todo: OpenCodeTodo

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(statusColor)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(todo.content)
                    .font(.cleanBody)
                    .strikethrough(todo.resolvedStatus == .completed)
                HStack(spacing: 8) {
                    Text(statusLabel)
                    Text(todo.priority.capitalized + " priority")
                }
                .font(.cleanCaption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var systemImage: String {
        switch todo.resolvedStatus {
        case .pending: "circle"
        case .inProgress: "arrow.triangle.2.circlepath.circle"
        case .completed: "checkmark.circle.fill"
        case .cancelled: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch todo.resolvedStatus {
        case .pending, .unknown: .secondary
        case .inProgress: BYOTBrand.accent
        case .completed: .green
        case .cancelled: .orange
        }
    }

    private var statusLabel: String {
        switch todo.resolvedStatus {
        case .pending: "Pending"
        case .inProgress: "In progress"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        case .unknown: todo.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private struct OpenCodeSessionChildrenView: View {
    @Environment(\.dismiss) private var dismiss
    let client: OpenCodeClient
    let children: [OpenCodeSession]
    let openAppNavigation: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if children.isEmpty {
                    ContentUnavailableView(
                        "No subagent sessions",
                        systemImage: "person.2",
                        description: Text("This session has not created any child sessions.")
                    )
                } else {
                    List(children) { child in
                        NavigationLink {
                            OpenCodeSessionView(
                                client: client,
                                session: child,
                                directory: child.directory,
                                openAppNavigation: openAppNavigation
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(child.title)
                                    .font(.cleanBodySemibold)
                                HStack(spacing: 8) {
                                    if let agent = child.agent { Text(agent) }
                                    Text(
                                        Date(timeIntervalSince1970: child.time.updated / 1_000),
                                        style: .relative
                                    )
                                }
                                .font(.cleanCaption)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Subagent sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct OpenCodeRevertedHistoryCard: View {
    let messages: [OpenCodeMessageEnvelope]
    let canRestore: Bool
    let canReviewChanges: Bool
    let restore: () -> Void
    let reviewChanges: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                        .font(.cleanBodySemibold)
                    if let preview = messages.first?.historyPreview, !preview.isEmpty {
                        Text(preview)
                            .font(.cleanCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: 10) {
                Button("Restore", systemImage: "arrow.uturn.forward", action: restore)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRestore)
                Button("Review changes", systemImage: "doc.text.magnifyingglass", action: reviewChanges)
                    .buttonStyle(.bordered)
                    .disabled(!canReviewChanges)
            }
        }
        .padding(14)
        .background(BYOTBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: BYOTBrand.panelRadius))
        .accessibilityElement(children: .contain)
    }

    private var summary: String {
        "\(messages.count) reverted prompt\(messages.count == 1 ? "" : "s")"
    }
}

private struct OpenCodeMessageView: View {
    let message: OpenCodeMessageEnvelope
    let canRevert: Bool
    let canFork: Bool
    let revert: (String) -> Void
    let fork: (String?) -> Void

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
                        .fill(BYOTBrand.elevatedSurface)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.info.role == "user" ? .trailing : .leading)
        .accessibilityElement(children: .contain)
        .contextMenu {
            if message.info.role.lowercased() == "user" {
                if canRevert {
                    Button("Undo from here", systemImage: "arrow.uturn.backward") {
                        revert(message.id)
                    }
                }
                if canFork {
                    Button("Fork from here", systemImage: "arrow.triangle.branch") {
                        fork(message.id)
                    }
                }
            }
        }
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
                    .textSelection(.enabled)
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
            Label(part.filename ?? part.mime ?? "Attachment", systemImage: "paperclip")
                .font(.cleanCaption)
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
    let presentation: OpenCodeSessionDiffPresentation

    var body: some View {
        NavigationStack {
            Group {
                if let reason = presentation.unavailableReason {
                    ContentUnavailableView(
                        "Session changes unavailable",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(reason)
                    )
                } else {
                    List(presentation.diffs) { diff in
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
