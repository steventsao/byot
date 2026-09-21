import CryptoKit
import Foundation

/// Drafts stay on this device and never enter either message queue until Send.
struct OpenCodeComposerDraft: Codable, Equatable {
    var text = ""
    var references: [OpenCodePromptFileReference] = []
}

struct OpenCodeComposerDraftStore {
    private let directory: URL

    init(serverID: UUID, sessionID: String, directory: String, workspace: String?, root: URL? = nil) {
        let root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ComposerDrafts")
        // Encode components before hashing so delimiters in remote paths cannot collide.
        let context = [sessionID, directory, workspace].map { value in
            value.map { "\($0.utf8.count):\($0)" } ?? "nil"
        }.joined()
        let key = SHA256.hash(data: Data(context.utf8)).map { String(format: "%02x", $0) }.joined()
        self.directory = root.appending(path: serverID.uuidString).appending(path: key)
    }

    func load() throws -> (OpenCodeComposerDraft, [OpenCodePromptAttachment]) {
        let draft: OpenCodeComposerDraft = try read("draft.plist") ?? OpenCodeComposerDraft()
        let attachments: [OpenCodePromptAttachment] = try read("attachments.plist") ?? []
        try OpenCodePromptAttachment.validate(attachments)
        return (draft, attachments)
    }

    func save(_ draft: OpenCodeComposerDraft) throws {
        try write(draft, name: "draft.plist", empty: draft.text.isEmpty && draft.references.isEmpty)
    }

    // Attachment bytes are written only when the selection changes, never on each keystroke.
    func saveAttachments(_ attachments: [OpenCodePromptAttachment]) throws {
        try OpenCodePromptAttachment.validate(attachments)
        try write(attachments, name: "attachments.plist", empty: attachments.isEmpty)
    }

    private func read<T: Decodable>(_ name: String) throws -> T? {
        let url = directory.appending(path: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try PropertyListDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, name: String, empty: Bool) throws {
        let url = directory.appending(path: name)
        if empty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try excluded.setResourceValues(resources)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtection])
    }
}
