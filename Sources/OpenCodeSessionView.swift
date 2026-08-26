import SwiftUI

struct OpenCodeSessionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var store: OpenCodeSessionStore
    @State private var isShowingDiff = false
    @State private var isAtBottom = true
    let openAppNavigation: () -> Void

    private let bottomAnchorID = "opencode-session-bottom"

    init(
        client: OpenCodeClient,
        session: OpenCodeSession,
        directory: String,
        openAppNavigation: @escaping () -> Void
    ) {
        self.openAppNavigation = openAppNavigation
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

                    ForEach(store.messages) { message in
                        OpenCodeMessageView(message: message)
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
        .safeAreaInset(edge: .bottom) {
            OpenCodeSessionComposerView(store: store)
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
                .disabled(store.diffs.isEmpty)
            }
        }
        .sheet(isPresented: $isShowingDiff) {
            OpenCodeDiffView(diffs: store.diffs)
        }
        .task { await store.start() }
        .onDisappear { store.stop() }
    }

    private var hasConversationContent: Bool {
        !store.messages.isEmpty
            || !store.queuedPrompts.isEmpty
            || store.pendingActionCount > 0
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
        switch store.status {
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
                        .fill(BYOTBrand.elevatedSurface)
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
    let diffs: [OpenCodeDiff]

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
