import SwiftUI

/// Chooses where something shared from another app goes: a new session on one
/// of your servers, or a recent session. Either way the composer opens with
/// the shared text and attachments in place; nothing is sent until you do.
struct BYOTShareDestinationView: View {
    let content: BYOTShareContent
    let profiles: [OpenCodeServerProfile]
    let activeProfileID: UUID?
    let errorMessage: String?
    let loadSessions: @MainActor () async -> [BYOTIntentSession]
    /// Returns once byot has opened the destination, or failed to.
    let choose: @MainActor (BYOTShareDestination) async -> Void
    let discard: () -> Void
    /// Nil while loading.
    @State private var sessions: [BYOTIntentSession]? = nil
    /// The destination byot is opening; the sheet stays up until it has.
    @State private var opening: BYOTShareDestination?

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.cleanCaption)
                            .foregroundStyle(.primary)
                            .symbolRenderingMode(.multicolor)
                            .accessibilityIdentifier("share-destination-error")
                    }
                }
                Section {
                    BYOTSharePreview(content: content)
                } header: {
                    Text("Sharing")
                } footer: {
                    if !content.notes.isEmpty {
                        Text(content.notes.joined(separator: "\n"))
                    }
                }
                if profiles.isEmpty {
                    Section {
                        Text("Add an OpenCode server in byot, then share again.")
                            .font(.cleanBody)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("New session") {
                        ForEach(orderedProfiles) { profile in
                            let destination = BYOTShareDestination.newSession(serverID: profile.id)
                            Button { open(destination) } label: {
                                destinationRow(symbol: "plus.bubble", title: "New session", subtitle: profile.name,
                                               isOpening: opening == destination)
                            }
                            .disabled(opening != nil)
                            .accessibilityHint("Choose a project, then finish the message.")
                            .accessibilityIdentifier("share-new-session-\(profile.name)")
                        }
                    }
                    Section {
                        recentSessions
                    } header: {
                        Text("Recent sessions")
                    } footer: {
                        Text("byot adds this to the session’s message without sending it.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Send to byot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: discard)
                        .disabled(opening != nil)
                        .accessibilityHint("Discards what you shared.")
                        .accessibilityIdentifier("share-destination-cancel")
                }
            }
            .task {
                guard !profiles.isEmpty, sessions == nil else { return }
                sessions = await loadSessions()
            }
        }
        // Swiping away would silently drop the share; Cancel says so.
        .interactiveDismissDisabled()
    }

    private func open(_ destination: BYOTShareDestination) {
        opening = destination
        Task {
            await choose(destination)
            opening = nil
        }
    }

    /// The server you're looking at comes first.
    private var orderedProfiles: [OpenCodeServerProfile] {
        profiles.filter { $0.id == activeProfileID } + profiles.filter { $0.id != activeProfileID }
    }

    @ViewBuilder
    private var recentSessions: some View {
        if let sessions {
            if sessions.isEmpty {
                Text("No recent sessions. Check that your server is running, or start a new session.")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sessions) { session in
                    Button { open(.session(session)) } label: {
                        sessionRow(session, isOpening: opening == .session(session))
                    }
                        .disabled(opening != nil)
                        .accessibilityHint("Opens this session with what you shared in the message.")
                }
            }
        } else {
            HStack(spacing: BYOTBrand.Space.sm) {
                ProgressView()
                Text("Loading sessions…")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        }
    }

    private func destinationRow(symbol: String, title: String, subtitle: String, isOpening: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.cleanBodySemibold)
                .foregroundStyle(BYOTBrand.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.cleanBodySemibold)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isOpening { ProgressView() }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOpening ? "Opening" : "")
    }

    private func sessionRow(_ session: BYOTIntentSession, isOpening: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: session.state?.symbol ?? "bubble.left")
                .font(.cleanCaptionBold)
                .foregroundStyle(session.state?.tint ?? .secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.cleanBodySemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(detail(session))
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if isOpening { ProgressView() }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(isOpening ? "Opening" : "")
    }

    private func detail(_ session: BYOTIntentSession) -> String {
        var parts = [session.projectName]
        if profiles.count > 1 { parts.append(session.serverName) }
        if let state = session.state { parts.append(state.title) }
        parts.append(session.updatedAt.formatted(.relative(presentation: .named)))
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// What's being shared: the message text and a strip of attachment chips.
struct BYOTSharePreview: View {
    let content: BYOTShareContent
    var textLineLimit = 6
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !content.text.isEmpty {
                Text(content.text)
                    .font(.cleanBody)
                    .lineLimit(textLineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("share-preview-text")
            }
            if !content.attachments.isEmpty {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(content.attachments) { chip($0) }
                    }
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(content.attachments) { chip($0) }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sharing \(content.summary)")
    }

    private func chip(_ attachment: OpenCodePromptAttachment) -> some View {
        HStack(spacing: 8) {
            OpenCodeAttachmentThumbnail(attachment: attachment)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename)
                    .font(.cleanCaptionBold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(attachment.formattedByteCount)
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 150, alignment: .leading)
        }
        .padding(6)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(BYOTBrand.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(attachment.filename), \(attachment.formattedByteCount)")
    }
}
