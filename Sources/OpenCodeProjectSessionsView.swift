import SwiftUI

struct OpenCodeProjectSessionsView: View {
    @State private var client: OpenCodeClient
    @StateObject private var store: OpenCodeProjectStore
    @State private var isCreatingSession = false
    @State private var newSessionTitle = ""
    @State private var createdSession: OpenCodeSession?
    let name: String

    init(
        client: OpenCodeClient,
        name: String,
        directory: String
    ) {
        self.name = name
        _client = State(initialValue: client)
        _store = StateObject(
            wrappedValue: OpenCodeProjectStore(service: client, directory: directory)
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
                        client: client,
                        session: session,
                        directory: session.directory
                    )
                } label: {
                    OpenCodeSessionRow(
                        session: session,
                        status: store.statuses[session.id] ?? .idle
                    )
                }
            }
        }
        .overlay {
            if store.isLoading && store.sessions.isEmpty {
                BYOTActivityView(
                    .loading,
                    title: "Loading sessions",
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
            ToolbarItem(placement: .topBarTrailing) {
                Button("New session", systemImage: "plus") {
                    isCreatingSession = true
                }
                .disabled(store.isCreating)
            }
        }
        .refreshable { await store.load() }
        .task { await store.load() }
        .navigationDestination(isPresented: Binding(
            get: { createdSession != nil },
            set: { if !$0 { createdSession = nil } }
        )) {
            if let createdSession {
                OpenCodeSessionView(
                    client: client,
                    session: createdSession,
                    directory: createdSession.directory
                )
            }
        }
        .alert("New session", isPresented: $isCreatingSession) {
            TextField("Optional title", text: $newSessionTitle)
            Button("Cancel", role: .cancel) {
                newSessionTitle = ""
            }
            Button("Create") {
                let title = newSessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                newSessionTitle = ""
                Task {
                    createdSession = await store.createSession(title: title.isEmpty ? nil : title)
                }
            }
        } message: {
            Text("\(client.profile.name) · \(store.directory)")
        }
    }
}

struct OpenCodeSessionRow: View {
    let session: OpenCodeSession
    let status: OpenCodeSessionStatus?
    var projectName: String? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                Text(session.title)
                    .font(.cleanBodySemibold)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                statusView

                VStack(alignment: .leading, spacing: 4) {
                    if let projectName { Text(projectName) }
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
                    statusView
                }
                HStack(spacing: 12) {
                    if let projectName { Text(projectName).lineLimit(1) }
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

            if let statusErrorMessage {
                Label(statusErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.cleanCaption)
                    .foregroundStyle(.red)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var statusView: some View {
        if let status {
            OpenCodeStatusLabel(status: status, eventConnected: nil)
        } else {
            Label("Status unavailable", systemImage: "questionmark.circle")
                .font(.cleanCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusErrorMessage: String? {
        guard case .retry(_, let message, _) = status else { return nil }
        return message.trimmedNonEmpty
    }

    private var updatedText: some View {
        Text(Date(timeIntervalSince1970: session.time.updated / 1_000), format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
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
                .fixedSize(horizontal: true, vertical: false)
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
