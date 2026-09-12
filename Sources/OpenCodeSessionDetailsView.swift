import SwiftUI

struct OpenCodeSessionDetailsView: View {
    @ObservedObject var store: OpenCodeSessionStore
    let openSession: (OpenCodeSession) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isRenaming = false
    @State private var title = ""
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationStack {
            List {
                Section("Conversation") {
                    LabeledContent("Name", value: store.session.title)
                    LabeledContent("Project", value: store.directory)
                    LabeledContent("Session ID", value: store.session.id)
                        .textSelection(.enabled)
                    if let agent = store.session.agent { LabeledContent("Agent", value: agent) }
                    Button("Rename", systemImage: "pencil") {
                        title = store.session.title
                        isRenaming = true
                    }
                    .disabled(!store.sessionFeatures.rename || store.isPerformingSessionAction)
                    .accessibilityIdentifier("session-rename")
                    if !store.sessionFeatures.rename { Text("Renaming is unavailable on this server.").font(.cleanCaption).foregroundStyle(.secondary) }
                }
                Section("Related sessions") {
                    if let parent = store.parentSession {
                        Button { openSession(parent) } label: {
                            Label("\(store.session.parentID == nil ? "Forked from" : "Parent"): \(parent.title)", systemImage: "arrow.turn.up.left")
                        }
                        .accessibilityIdentifier("session-parent")
                    }
                    ForEach(store.childSessions) { child in
                        Button { openSession(child) } label: {
                            Label(child.title, systemImage: "arrow.triangle.branch")
                        }
                        .accessibilityIdentifier("session-child-\(child.id)")
                    }
                    if store.isLoadingRelatedSessions { ProgressView("Loading related sessions") }
                    else if !store.sessionFeatures.children { Text("Child-session browsing is unavailable on this server.").foregroundStyle(.secondary) }
                    else if store.childSessions.isEmpty && store.parentSession == nil { Text("No related sessions").foregroundStyle(.secondary) }
                }
                Section("History") {
                    ForEach(OpenCodeSessionAction.allCases) { action in
                        Button { Task { await store.performSessionAction(action) } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(action.title, systemImage: action.symbol)
                                if let reason = store.actionUnavailableReason(action) {
                                    Text(reason).font(.cleanCaption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(store.actionUnavailableReason(action) != nil)
                        .accessibilityIdentifier("session-\(action.rawValue)")
                    }
                    Text(!store.sessionFeatures.undoIncludesFileChanges
                         ? "Undo changes the conversation history. Files remain unchanged. Queued prompts are paused for review."
                         : "Undo asks OpenCode to rewind history and available file snapshots. Queued prompts are paused for review.")
                        .font(.cleanCaption).foregroundStyle(.secondary)
                }
                if let error = store.sessionDetailsError ?? store.actionErrorMessage {
                    Section { ErrorBanner(message: error, actionTitle: "Refresh") {
                        Task { await store.refreshSessionFeatures(); await store.loadRelatedSessions() }
                    } }
                }
                Section {
                    Button("Delete conversation", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                        .disabled(!store.sessionFeatures.delete || store.isPerformingSessionAction || store.status.isActive || store.isSending)
                        .accessibilityIdentifier("session-delete")
                    if store.status.isActive { Text("Stop the current turn before deleting.").font(.cleanCaption).foregroundStyle(.secondary) }
                    if !store.sessionFeatures.delete { Text("Deleting is unavailable on this server.").font(.cleanCaption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Session details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Rename conversation", isPresented: $isRenaming) {
                TextField("Name", text: $title)
                Button("Cancel", role: .cancel) {}
                Button("Save") { Task { _ = await store.renameSession(title) } }
            }
            .confirmationDialog("Delete this conversation and its child sessions?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                Button("Delete conversation", role: .destructive) {
                    Task { if await store.deleteSession() { dismiss() } }
                }
            } message: {
                Text("This removes the conversation from the server. It cannot be undone.")
            }
            .task { await store.loadRelatedSessions() }
        }
    }
}

struct OpenCodeTaskProgressView: View {
    let progress: OpenCodeTodoProgress
    let supportsSnapshot: Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(progress.summary).font(.cleanBodySemibold)
                    if progress.totalCount > 0 {
                        ProgressView(value: Double(progress.resolvedCount), total: Double(progress.totalCount))
                            .accessibilityLabel(progress.summary)
                    }
                    if progress.isStale {
                        Label("Last reported tasks. Reconnecting to refresh progress.", systemImage: "wifi.exclamationmark")
                            .font(.cleanCaption).foregroundStyle(.secondary)
                    }
                    if progress.items == nil && !supportsSnapshot {
                        Text("This server does not provide a task snapshot. Tasks appear here if it reports live task updates.")
                            .foregroundStyle(.secondary)
                    }
                    if let error = progress.error { Text(error).foregroundStyle(.red) }
                }
                if let items = progress.items {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.symbol)
                                .foregroundStyle(item.status == "completed" ? BYOTBrand.accent : .secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.content).font(.cleanBody)
                                Text([item.statusLabel, item.priority.map { "\($0.capitalized) priority" }].compactMap { $0 }.joined(separator: " · "))
                                    .font(.cleanCaption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("Tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
