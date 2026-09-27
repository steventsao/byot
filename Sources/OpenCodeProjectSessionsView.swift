import SwiftUI

struct OpenCodeProjectSessionsView: View {
    @State private var client: OpenCodeClient
    @StateObject private var store: OpenCodeProjectStore
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
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
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
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(BYOTBrand.canvas)
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
                    .foregroundStyle(BYOTBrand.accentInk)
                }
            } else if !store.isLoading,
                      store.sessions.isEmpty,
                      store.errorMessage == nil {
                ContentUnavailableView {
                    Label("No sessions", systemImage: "bubble.left.and.bubble.right")
                } actions: {
                    Button("New session", systemImage: "plus") {
                        createSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(BYOTBrand.accentInk)
                    .disabled(store.isCreating)
                }
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: createSession) {
                    if store.isCreating { ProgressView() }
                    else { Image(systemName: "plus") }
                }
                .accessibilityLabel(store.isCreating ? "Creating session" : "New session")
                .tint(BYOTBrand.chromeTint)
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
                    directory: createdSession.directory,
                    startsWithComposerFocused: true
                )
            }
        }
    }

    private func createSession() {
        guard !store.isCreating else { return }
        Task { createdSession = await store.createSession(title: nil) }
    }

}

struct OpenCodeSessionRow: View {
    let session: OpenCodeSession
    let status: OpenCodeSessionStatus?
    var projectName: String? = nil
    var attentionMessage: String? = nil
    /// Waiting on a permission or question; outranks every other status.
    var needsInput = false

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
                    if session.share?.link != nil { OpenCodeSharedSessionBadge() }
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
                    if session.share?.link != nil { OpenCodeSharedSessionBadge() }
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
        if needsInput {
            // Sized like the other status glyphs, but in primary text: this
            // is the one status that asks the user to act.
            HStack(spacing: 5) {
                Image(systemName: "hand.raised.fill")
                    .imageScale(.small)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Needs input")
                    .fixedSize(horizontal: true, vertical: false)
            }
            .font(.cleanCaptionBold)
            .accessibilityElement(children: .combine)
        } else if attentionMessage != nil {
            Label("Needs attention", systemImage: "exclamationmark.circle.fill")
                .font(.cleanCaption)
                .foregroundStyle(.red)
        } else if let status {
            OpenCodeStatusLabel(status: status, eventConnected: nil)
        } else {
            Label("Status unavailable", systemImage: "questionmark.circle")
                .font(.cleanCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusErrorMessage: String? {
        if let attentionMessage { return attentionMessage }
        guard case .retry(_, let message, _) = status else { return nil }
        return message.trimmedNonEmpty
    }

    private var updatedText: some View {
        // A live list no longer reloads on a timer, so the row keeps its own
        // relative time current instead of saying "Just now" indefinitely.
        TimelineView(.everyMinute) { context in
            let updated = Date(timeIntervalSince1970: session.time.updated / 1_000)
            // A session that just arrived live can carry a server clock slightly
            // ahead of the device; never show it as updated "in 0 sec.".
            if updated.timeIntervalSince(context.date) > -60 {
                Text("Just now")
            } else {
                Text(updated, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
            }
        }
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
