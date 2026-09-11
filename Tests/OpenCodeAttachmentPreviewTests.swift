import Foundation
import Testing
@testable import byot

@Suite("Attachment previews")
struct OpenCodeAttachmentPreviewTests {
    @Test("Preview owns a private copy and never treats a filename as a path",
          arguments: ["../notes.txt", "C:\\private\\notes.txt", "/etc/notes.txt", "..", "notes"])
    func previewLifetime(filename: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("Preview this text".utf8)
        let attachment = OpenCodePromptAttachment(filename: filename, mimeType: "text/plain", data: data)
        let first = try OpenCodeAttachmentPreviewFile(attachment: attachment, root: root)
        let second = try OpenCodeAttachmentPreviewFile(attachment: attachment, root: root)
        #expect(first.url.deletingLastPathComponent() == first.directory)
        #expect(first.directory.deletingLastPathComponent() == root)
        #expect(first.url.pathExtension == "txt")
        #expect(try Data(contentsOf: first.url) == data)
        first.remove()
        #expect(!FileManager.default.fileExists(atPath: first.directory.path))
        #expect(try Data(contentsOf: second.url) == data)
        second.remove()
    }

    @Test("Reject empty preview data before creating files")
    func rejectsEmptyData() {
        #expect(throws: OpenCodePromptAttachmentError.self) {
            try OpenCodeAttachmentPreviewFile(attachment: OpenCodePromptAttachment(
                filename: "empty.png", mimeType: "image/png", data: Data()
            ))
        }
    }
}
