import SwiftUI

struct OpenCodeProjectSessionsView: View {
    @StateObject private var store: OpenCodeProjectStore
    @State private var isCreatingSession = false
    @State private var newSessionTitle = ""
    @State private var renameTarget: OpenCodeSession?
    @State private var deleteTarget: OpenCodeSession?
    @State private var isShowingProviders = false
    let name: String
    let openAppNavigation: () -> Void

    init(
        client: OpenCodeClient,
        name: String,
        directory: String,
        openAppNavigation: @escaping () -> Void
    ) {
        self.name = name
        self.openAppNavigation = openAppNavigation
        _store = StateObject(
            wrappedValue: OpenCodeProjectStore(client: client, directory: directory)
        )
    }

    var body: some View {
        List {
            if let errorMessage = store.errorMessage, !store.sessions.isEmpty {
                ErrorBanner(message: errorMessage)
                    .listRowInsets(EdgeInsets())
            }
            ForEach(store.sessions) { session in
                NavigationLink {
                    OpenCodeSessionView(
                        client: store.client,
                        session: session,
                        directory: session.directory,
                        sessionDidChange: { store.reconcileSession($0) },
                        openAppNavigation: openAppNavigation
                    )
                } label: {
                    OpenCodeSessionRow(
                        session: session,
                        status: store.statuses[session.id] ?? .idle
                    )
                }
                .contextMenu {
                    if store.lifecyclePolicy?.canRename == true {
                        Button("Rename", systemImage: "pencil") {
                            renameTarget = session
                        }
                        .disabled(store.isMutating(sessionID: session.id))
                    }
                    if store.lifecyclePolicy?.canDelete == true {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deleteTarget = session
                        }
                        .disabled(store.isMutating(sessionID: session.id))
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if store.lifecyclePolicy?.canDelete == true {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deleteTarget = session
                        }
                        .disabled(store.isMutating(sessionID: session.id))
                    }
                    if store.lifecyclePolicy?.canRename == true {
                        Button("Rename", systemImage: "pencil") {
                            renameTarget = session
                        }
                        .tint(BYOTBrand.accent)
                        .disabled(store.isMutating(sessionID: session.id))
                    }
                }
            }
        }
        .overlay {
            if store.isLoading && store.sessions.isEmpty {
                BYOTActivityView(
                    .loading,
                    title: "Loading sessions",
                    detail: "Syncing recent OpenCode work.",
                    layout: .blocking
                )
            } else if !store.isLoading,
                      store.sessions.isEmpty,
                      let errorMessage = store.errorMessage {
                ContentUnavailableView {
                    Label("Couldn’t load sessions", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage.agentDisplayErrorText)
                } actions: {
                    Button("Try again", systemImage: "arrow.clockwise") {
                        Task { await store.load() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if !store.isLoading,
                      store.sessions.isEmpty,
                      store.errorMessage == nil {
                ContentUnavailableView {
                    Label("No sessions", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Start a coding session for this project.")
                } actions: {
                    Button("New session", systemImage: "plus") {
                        isCreatingSession = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                AppNavigationButton(isToolbarItem: true, action: openAppNavigation)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Providers", systemImage: "key.horizontal") {
                    isShowingProviders = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("New session", systemImage: "plus") {
                    isCreatingSession = true
                }
                .disabled(store.isCreating)
            }
        }
        .refreshable { await store.load() }
        .task { await store.load() }
        .alert("New OpenCode session", isPresented: $isCreatingSession) {
            TextField("Optional title", text: $newSessionTitle)
            Button("Cancel", role: .cancel) {
                newSessionTitle = ""
            }
            Button("Create") {
                let title = newSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                newSessionTitle = ""
                Task {
                    _ = await store.createSession(title: title.isEmpty ? nil : title)
                }
            }
        } message: {
            Text("The session runs in \(store.directory).")
        }
        .sheet(item: $renameTarget) { session in
            OpenCodeRenameSessionView(session: session) { title in
                Task { _ = await store.renameSession(session, title: title) }
            }
        }
        .sheet(isPresented: $isShowingProviders) {
            OpenCodeProviderConnectionView(
                client: store.client,
                directory: store.directory
            )
        }
        .confirmationDialog(
            "Delete this session permanently?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete session", role: .destructive) {
                guard let session = deleteTarget else { return }
                deleteTarget = nil
                Task { _ = await store.deleteSession(session) }
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("Messages, history, and session metadata will be removed from OpenCode. This cannot be undone.")
        }
    }
}

private struct OpenCodeRenameSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    let save: (String) -> Void

    init(session: OpenCodeSession, save: @escaping (String) -> Void) {
        _title = State(initialValue: session.title)
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Session title", text: $title)
                    .textInputAutocapitalization(.sentences)
            }
            .navigationTitle("Rename session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        dismiss()
                        save(value)
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct OpenCodeSessionRow: View {
    let session: OpenCodeSession
    let status: OpenCodeSessionStatus

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(session.title)
                    .font(.cleanBodySemibold)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                OpenCodeStatusLabel(status: status, eventConnected: nil)

                VStack(alignment: .leading, spacing: 4) {
                    if let agent = session.agent {
                        Text(agent)
                    }
                    if let summary = session.summary, summary.files > 0 {
                        Text("\(summary.files) files · +\(summary.additions) −\(summary.deletions)")
                    }
                    updatedText
                }
                .font(.cleanCaption)
                .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title)
                        .font(.cleanBodySemibold)
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    OpenCodeStatusLabel(status: status, eventConnected: nil)
                }
                HStack(spacing: 12) {
                    if let agent = session.agent {
                        Text(agent)
                    }
                    if let summary = session.summary, summary.files > 0 {
                        Text("\(summary.files) files")
                        Text("+\(summary.additions) −\(summary.deletions)")
                    }
                    Spacer()
                    updatedText
                }
                .font(.cleanCaption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private var updatedText: some View {
        Text(Date(timeIntervalSince1970: session.time.updated / 1_000), style: .relative)
    }
}

struct OpenCodeStatusLabel: View {
    let status: OpenCodeSessionStatus
    let eventConnected: Bool?

    var body: some View {
        HStack(spacing: 5) {
            statusIndicator
            Text(displayLabel)
                .font(.cleanCaptionBold)
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if eventConnected == false {
            BYOTActivityGlyph(phase: .reconnecting, size: 12, tint: .orange)
        } else {
            switch status {
            case .idle:
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
            case .busy:
                BYOTActivityGlyph(phase: .working, size: 12)
            case .retry:
                BYOTActivityGlyph(phase: .retrying, size: 12)
            }
        }
    }

    private var displayLabel: String {
        eventConnected == false ? "Reconnecting" : status.label
    }
}
