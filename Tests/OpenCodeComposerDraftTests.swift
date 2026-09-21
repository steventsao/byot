import Foundation
import Testing
@testable import byot

@Suite("Composer drafts")
struct OpenCodeComposerDraftTests {
    @Test("Relaunch restores text, attachment bytes and remote references; clearing removes them")
    func roundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = UUID()
        func store(_ session: String = "session", _ directory: String = "/project", _ workspace: String? = nil) -> OpenCodeComposerDraftStore {
            OpenCodeComposerDraftStore(serverID: server, sessionID: session, directory: directory, workspace: workspace, root: root)
        }
        let reference = OpenCodePromptFileReference(serverID: server, projectID: "project", directory: "/project", path: "notes.txt")
        let draft = OpenCodeComposerDraft(text: "Review this\nwithout losing my draft", references: [reference])
        let attachments = [OpenCodePromptAttachment(filename: "notes.txt", mimeType: "text/plain", data: Data("hello".utf8))]
        try store().save(draft)
        try store().saveAttachments(attachments)
        let restored = try store().load()
        #expect(restored.0 == draft)
        #expect(restored.1 == attachments)
        #expect(try store("different-session").load().0.text.isEmpty)
        #expect(try store("session", "/other-project").load().1.isEmpty)
        #expect(try store("session", "/project", "other-workspace").load().0.text.isEmpty)
        let otherServer = OpenCodeComposerDraftStore(serverID: UUID(), sessionID: "session", directory: "/project", workspace: nil, root: root)
        #expect(try otherServer.load().0.text.isEmpty)
        try store().save(OpenCodeComposerDraft())
        try store().saveAttachments([])
        #expect(try store().load().0 == OpenCodeComposerDraft())
        #expect(try store().load().1.isEmpty)
    }

    @Test("Draft storage reports write failure instead of silently discarding content")
    func writeFailure() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let store = OpenCodeComposerDraftStore(serverID: UUID(), sessionID: "session", directory: "/project", workspace: nil, root: root)
        #expect(throws: (any Error).self) { try store.save(OpenCodeComposerDraft(text: "Keep me")) }
    }

    @Test("Editing text leaves saved attachments intact")
    func editText() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = OpenCodeComposerDraftStore(serverID: UUID(), sessionID: "session", directory: "/project", workspace: nil, root: root)
        let attachment = OpenCodePromptAttachment(filename: "image.png", mimeType: "image/png", data: Data([1, 2, 3]))
        try store.saveAttachments([attachment])
        try store.save(OpenCodeComposerDraft(text: "First"))
        try store.save(OpenCodeComposerDraft(text: "Edited"))
        #expect(try store.load().0.text == "Edited")
        #expect(try store.load().1 == [attachment])
    }
}
