import Foundation

/// Opens byot on something the share extension just saved. The link only
/// names an inbox entry; the content stays in the App Group container, so
/// another app opening this scheme can at most bring byot forward.
struct BYOTShareLink: Equatable, Sendable {
    static let scheme = "byot-share"

    let shareID: UUID

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "inbox"
        components.queryItems = [URLQueryItem(name: "id", value: shareID.uuidString)]
        return components.url!
    }

    init(shareID: UUID) {
        self.shareID = shareID
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == "inbox",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value,
              let id = UUID(uuidString: value) else { return nil }
        shareID = id
    }
}

/// One share waiting for the app: the message text and a manifest of the
/// attachment files saved beside it.
struct BYOTSharedItem: Codable, Identifiable, Equatable, Sendable {
    struct File: Codable, Identifiable, Equatable, Sendable {
        let id: UUID
        let filename: String
        let mimeType: String
        let byteCount: Int
    }

    let id: UUID
    let createdAt: Date
    var text: String
    var files: [File]
    /// Plain-language reasons some of what was shared was left out.
    var notes: [String]
}

enum BYOTShareInboxError: LocalizedError, Equatable {
    case unavailable
    case empty
    case missingFile(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: "byot can’t receive shared items right now. Update byot, then try again."
        case .empty: "There’s nothing here byot can send."
        case .missingFile(let filename): "\(filename) is no longer available. Share it again."
        }
    }
}

/// The hand-off between the share extension and the app. Each share is a
/// folder in the App Group container holding the attachment bytes and, written
/// last, a manifest; a folder without a manifest is still being written or was
/// abandoned. File names on disk are generated, never taken from the sender.
struct BYOTShareInbox: Sendable {
    /// Shares the app never picked up are discarded after this long.
    static let lifetime: TimeInterval = 2 * 24 * 60 * 60
    /// A folder without a manifest older than this was abandoned mid-write.
    static let abandonedAfter: TimeInterval = 60 * 60
    private static let manifestName = "share.plist"

    let root: URL

    /// Nil when the App Group isn't available, such as an unsigned build.
    static var appGroup: BYOTShareInbox? {
        BYOTAppGroup.containerURL.map { BYOTShareInbox(root: $0.appending(path: "ShareInbox", directoryHint: .isDirectory)) }
    }

    @discardableResult
    func save(text: String, attachments: [OpenCodePromptAttachment], notes: [String],
              now: Date = .now) throws -> BYOTSharedItem {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !attachments.isEmpty else { throw BYOTShareInboxError.empty }
        try OpenCodePromptAttachment.validate(attachments)
        let item = BYOTSharedItem(
            id: UUID(), createdAt: now, text: text,
            files: attachments.map {
                .init(id: UUID(), filename: $0.filename, mimeType: $0.mimeType, byteCount: $0.byteCount)
            },
            notes: notes)
        let folder = folder(item.id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, attachment) in zip(item.files, attachments) {
                try attachment.data.write(to: fileURL(file, in: folder), options: [.atomic, .completeFileProtection])
            }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(item).write(to: folder.appending(path: Self.manifestName),
                                           options: [.atomic, .completeFileProtection])
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return item
    }

    /// Shares waiting for the app, oldest first. Expired, abandoned and
    /// unreadable entries are removed along the way.
    func pending(now: Date = .now) -> [BYOTSharedItem] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var items: [BYOTSharedItem] = []
        for folder in folders {
            let manifest = folder.appending(path: Self.manifestName)
            guard manager.fileExists(atPath: manifest.path) else {
                let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if now.timeIntervalSince(created) > Self.abandonedAfter { try? manager.removeItem(at: folder) }
                continue
            }
            guard let data = try? Data(contentsOf: manifest),
                  let item = try? PropertyListDecoder().decode(BYOTSharedItem.self, from: data),
                  item.id.uuidString == folder.lastPathComponent,
                  now.timeIntervalSince(item.createdAt) <= Self.lifetime else {
                try? manager.removeItem(at: folder)
                continue
            }
            items.append(item)
        }
        return items.sorted { $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString }
    }

    /// Reads the attachment bytes back in the order they were shared.
    func attachments(for item: BYOTSharedItem) throws -> [OpenCodePromptAttachment] {
        let folder = folder(item.id)
        let attachments = try item.files.map { file in
            guard let data = try? Data(contentsOf: fileURL(file, in: folder)), data.count == file.byteCount else {
                throw BYOTShareInboxError.missingFile(file.filename)
            }
            return OpenCodePromptAttachment(id: file.id, filename: file.filename, mimeType: file.mimeType, data: data)
        }
        try OpenCodePromptAttachment.validate(attachments)
        return attachments
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(id))
    }

    private func folder(_ id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func fileURL(_ file: BYOTSharedItem.File, in folder: URL) -> URL {
        folder.appending(path: "\(file.id.uuidString).bin")
    }
}
