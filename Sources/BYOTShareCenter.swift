import Foundation

/// A share read back from the inbox, with its attachment bytes, ready to go
/// into a composer draft.
struct BYOTShareContent: Identifiable, Hashable, Sendable {
    let item: BYOTSharedItem
    let attachments: [OpenCodePromptAttachment]

    var id: UUID { item.id }
    var text: String { item.text }
    var notes: [String] { item.notes }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// "A link and 2 images", for banners and VoiceOver.
    var summary: String {
        var parts: [String] = []
        if !text.isEmpty {
            let isLink = !text.contains(where: \.isWhitespace) && URL(string: text)?.scheme?.hasPrefix("http") == true
            parts.append(isLink ? String(localized: "a link") : String(localized: "text"))
        }
        let images = attachments.filter { $0.mimeType.hasPrefix("image/") }.count
        let files = attachments.count - images
        if images > 0 { parts.append(images == 1 ? String(localized: "an image") : String(localized: "\(images) images")) }
        if files > 0 { parts.append(files == 1 ? String(localized: "a file") : String(localized: "\(files) files")) }
        let joined = ListFormatter.localizedString(byJoining: parts)
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

/// Where the share picker sends a share.
enum BYOTShareDestination: Equatable {
    case newSession(serverID: UUID)
    case session(BYOTIntentSession)
}

/// Adds a share to a session's composer draft. Nothing is sent: the composer
/// opens with the text and attachments in place for you to finish.
enum BYOTShareDraft {
    struct Merged: Equatable {
        var draft: OpenCodeComposerDraft
        var attachments: [OpenCodePromptAttachment]
        /// Shared files that didn't fit beside the draft's own attachments.
        var leftOut: [String]
    }

    static func merge(_ content: BYOTShareContent, into draft: OpenCodeComposerDraft,
                      attachments: [OpenCodePromptAttachment]) -> Merged {
        var draft = draft
        let existing = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.text.isEmpty {
            draft.text = existing.isEmpty ? content.text : existing + "\n\n" + content.text
        }
        var merged = attachments
        var leftOut: [String] = []
        for attachment in content.attachments where !merged.contains(where: { $0.id == attachment.id }) {
            if (try? OpenCodePromptAttachment.validate(merged + [attachment])) != nil {
                merged.append(attachment)
            } else {
                leftOut.append(attachment.filename)
            }
        }
        return Merged(draft: draft, attachments: merged, leftOut: leftOut)
    }

    /// Returns the names of shared files that didn't fit. An unreadable old
    /// draft is replaced rather than blocking the share.
    static func apply(_ content: BYOTShareContent, to store: OpenCodeComposerDraftStore) throws -> [String] {
        let (draft, attachments) = (try? store.load()) ?? (OpenCodeComposerDraft(), [])
        let merged = merge(content, into: draft, attachments: attachments)
        try store.save(merged.draft)
        try store.saveAttachments(merged.attachments)
        return merged.leftOut
    }

    static func leftOutNotice(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let limit = ByteCountFormatter.string(fromByteCount: Int64(OpenCodePromptAttachment.maximumTotalBytes),
                                              countStyle: .file)
        let maximum = OpenCodePromptAttachment.maximumCount
        let leftOut = ListFormatter.localizedString(byJoining: names)
        return String(localized: "\(leftOut) didn’t fit beside the attachments already in this message. A message can carry \(maximum) files, up to \(limit) in total.")
    }
}

/// Picks up what the share extension saved and tracks it until it is in a
/// composer draft. A share leaves the inbox only once it is written into a
/// draft or discarded, so backing out of a new session keeps it for later.
@MainActor
final class BYOTShareCenter: ObservableObject {
    static let shared = BYOTShareCenter(inbox: .appGroup)

    /// The share waiting for a destination; the app shows the picker for it.
    @Published var incoming: BYOTShareContent?
    /// Why the last destination didn't work, shown in the picker.
    @Published private(set) var deliveryError: String?
    /// Something to tell you after a share lands, such as files that didn't fit.
    @Published var notice: String?

    private let inbox: BYOTShareInbox?
    private let now: () -> Date
    /// Handed to a destination but not yet in a draft; not offered again.
    private var claimed: Set<UUID> = []

    init(inbox: BYOTShareInbox?, now: @escaping () -> Date = Date.init) {
        self.inbox = inbox
        self.now = now
    }

    /// Offers the oldest waiting share, or the one a share-extension link
    /// names, which replaces an older share already on screen (that one keeps
    /// waiting in the inbox).
    func refresh(preferring id: UUID? = nil) {
        guard let inbox, incoming == nil || (id != nil && incoming?.id != id) else { return }
        let pending = inbox.pending(now: now()).filter { !claimed.contains($0.id) }
        guard let item = pending.first(where: { $0.id == id }) ?? (incoming == nil ? pending.first : nil) else { return }
        do {
            incoming = BYOTShareContent(item: item, attachments: try inbox.attachments(for: item))
            deliveryError = nil
        } catch {
            inbox.remove(item.id)
            notice = error.localizedDescription
        }
    }

    /// A destination was chosen; the picker closes while byot opens it.
    func claim(_ content: BYOTShareContent) {
        claimed.insert(content.id)
        if incoming?.id == content.id { incoming = nil }
        deliveryError = nil
    }

    /// The destination failed or was abandoned. With an error the picker comes
    /// back so you can choose again; without one the share waits for the next
    /// time byot opens.
    func release(_ content: BYOTShareContent, error: String? = nil) {
        claimed.remove(content.id)
        guard let error else { return }
        deliveryError = error
        incoming = content
    }

    /// Writes the share into a session's composer draft and removes it from the inbox.
    func deliver(_ content: BYOTShareContent, into store: OpenCodeComposerDraftStore) throws {
        let leftOut = try BYOTShareDraft.apply(content, to: store)
        finish(content)
        notice = BYOTShareDraft.leftOutNotice(leftOut)
    }

    func discard(_ content: BYOTShareContent) {
        finish(content)
    }

    private func finish(_ content: BYOTShareContent) {
        claimed.remove(content.id)
        inbox?.remove(content.id)
        if incoming?.id == content.id { incoming = nil }
        deliveryError = nil
    }
}
