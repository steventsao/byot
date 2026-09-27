import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import byot

@Suite("Share extension hand-off")
@MainActor
struct BYOTShareTests {
    // MARK: Link and inbox

    @Test("Share links name an inbox entry and reject anything else")
    func links() {
        let id = UUID()
        let link = BYOTShareLink(shareID: id)
        #expect(link.url.absoluteString == "byot-share://inbox?id=\(id.uuidString)")
        #expect(BYOTShareLink(url: link.url) == link)
        #expect(BYOTShareLink(url: URL(string: "byot-share://inbox?id=nope")!) == nil)
        #expect(BYOTShareLink(url: URL(string: "byot-share://other?id=\(id.uuidString)")!) == nil)
        #expect(BYOTShareLink(url: URL(string: "byot-widget://inbox?id=\(id.uuidString)")!) == nil)
        #expect(BYOTPushDestination(widgetURL: link.url) == nil)
    }

    @Test("The inbox round-trips text and attachment bytes, oldest first, and removes entries")
    func inboxRoundTrip() throws {
        let inbox = try temporaryInbox()
        defer { cleanUp(inbox) }
        let photo = OpenCodePromptAttachment(filename: "../../etc/Photo.png", mimeType: "image/png", data: Data([1, 2, 3]))
        let later = try inbox.save(text: "  Second  ", attachments: [], notes: [], now: date(200))
        let first = try inbox.save(text: "Look at this", attachments: [photo], notes: ["Movie.mov is too large"],
                                   now: date(100))
        #expect(later.text == "Second")
        #expect(inbox.pending(now: date(300)).map(\.id) == [first.id, later.id])
        let restored = try inbox.attachments(for: first)
        #expect(restored.map(\.data) == [photo.data])
        #expect(restored.map(\.filename) == ["../../etc/Photo.png"])
        #expect(restored.map(\.mimeType) == ["image/png"])
        #expect(first.notes == ["Movie.mov is too large"])
        // Bytes live under generated names inside the share's own folder.
        let stored = try FileManager.default.contentsOfDirectory(atPath: inbox.root.appending(path: first.id.uuidString).path)
        #expect(stored.sorted() == ["\(first.files[0].id.uuidString).bin", "share.plist"].sorted())
        inbox.remove(first.id)
        #expect(inbox.pending(now: date(300)).map(\.id) == [later.id])
    }

    @Test("Empty and over-limit shares are refused")
    func inboxRefusals() throws {
        let inbox = try temporaryInbox()
        defer { cleanUp(inbox) }
        #expect(throws: BYOTShareInboxError.empty) { try inbox.save(text: " \n", attachments: [], notes: []) }
        let many = (0...OpenCodePromptAttachment.maximumCount).map {
            OpenCodePromptAttachment(filename: "\($0).txt", mimeType: "text/plain", data: Data("x".utf8))
        }
        #expect(throws: OpenCodePromptAttachmentError.tooMany(maximum: OpenCodePromptAttachment.maximumCount)) {
            try inbox.save(text: "", attachments: many, notes: [])
        }
        #expect(inbox.pending().isEmpty)
    }

    @Test("Expired, unreadable and abandoned entries are cleaned up; in-progress ones are left alone")
    func inboxCleanup() throws {
        let inbox = try temporaryInbox()
        defer { cleanUp(inbox) }
        let old = try inbox.save(text: "old", attachments: [], notes: [], now: date(0))
        let fresh = try inbox.save(text: "fresh", attachments: [], notes: [], now: date(BYOTShareInbox.lifetime))
        let corrupt = inbox.root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: corrupt.appending(path: "share.plist"))

        #expect(inbox.pending(now: date(BYOTShareInbox.lifetime + 1)).map(\.id) == [fresh.id])
        #expect(!FileManager.default.fileExists(atPath: inbox.root.appending(path: old.id.uuidString).path))
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))

        // A folder the extension is still writing has no manifest yet.
        let writing = inbox.root.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: writing, withIntermediateDirectories: true)
        let now = Date().addingTimeInterval(1)
        _ = inbox.pending(now: now)
        #expect(FileManager.default.fileExists(atPath: writing.path))
        _ = inbox.pending(now: now.addingTimeInterval(BYOTShareInbox.abandonedAfter + 1))
        #expect(!FileManager.default.fileExists(atPath: writing.path))
    }

    // MARK: Reading shared items

    @Test("Items are read by the most specific type they offer")
    func kinds() {
        #expect(BYOTShareImport.kind(of: ["public.heic", "public.jpeg"]) == .image(.heic))
        #expect(BYOTShareImport.kind(of: ["public.url", "public.plain-text"]) == .webURL)
        // A file from Files offers its type and its location.
        #expect(BYOTShareImport.kind(of: ["com.adobe.pdf", "public.file-url", "public.url"]) == .file(.pdf))
        #expect(BYOTShareImport.kind(of: ["public.plain-text", "public.file-url", "public.url"]) == .fileURL)
        #expect(BYOTShareImport.kind(of: ["public.data", "public.file-url"]) == .fileURL)
        #expect(BYOTShareImport.kind(of: ["public.utf8-plain-text"]) == .text("public.utf8-plain-text"))
        #expect(BYOTShareImport.kind(of: ["public.swift-source"]) == .text("public.swift-source"))
        #expect(BYOTShareImport.kind(of: ["com.adobe.pdf"]) == .file(.pdf))
        #expect(BYOTShareImport.kind(of: ["public.data"]) == .file(.data))
        #expect(BYOTShareImport.kind(of: ["public.folder"]) == nil)
        #expect(BYOTShareImport.kind(of: ["dyn.unknown-type"]) == nil)
        #expect(BYOTShareImport.kind(of: []) == nil)
    }

    @Test("Shared text joins into one message without blanks, repeats or links it already quotes")
    func message() {
        #expect(BYOTShareImport.message([" Fix the login bug ", "", "https://example.com/issue/1",
                                         "See https://example.com/issue/1 for logs", "Fix the login bug"])
                == "Fix the login bug\n\nSee https://example.com/issue/1 for logs")
        #expect(BYOTShareImport.message(["https://a.test", "https://b.test"]) == "https://a.test\n\nhttps://b.test")
    }

    @Test("Names drop sender paths, gain an extension, and fall back to a numbered label")
    func naming() {
        let file = BYOTShareImport.Naming(suggested: "..\\secret/Report", index: 1, kind: .file(.pdf))
        #expect(file.name() == "Report")
        #expect(BYOTShareImport.filename(file.name(), type: .pdf) == "Report.pdf")
        #expect(BYOTShareImport.filename("notes.md", type: .plainText) == "notes.md")
        let image = BYOTShareImport.Naming(suggested: " ", index: 3, kind: .image(.png))
        #expect(image.name() == "Image 3")
        #expect(BYOTShareImport.Naming(suggested: nil, index: 2, kind: .file(.data)).name(for: URL(filePath: "/tmp/a.zip"))
                == "a.zip")
        #expect(BYOTShareImport.Naming(suggested: "..", index: 4, kind: .text("public.text")).name() == "File 4")
    }

    @Test("Text, links, images and files from the share sheet become a message and attachments")
    func loadsProviders() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appending(path: "Spec.pdf")
        try Data("%PDF-1.4 spec".utf8).write(to: pdf)
        let notes = folder.appending(path: "notes.txt")
        try Data("TODO: retry on 503".utf8).write(to: notes)
        let png = try #require(Self.imageData(type: .png))
        let image = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
        image.suggestedName = "Screenshot"

        let result = await BYOTShareImport.load(texts: ["Please review"], providers: [
            NSItemProvider(object: "The crash is on launch" as NSString),
            NSItemProvider(object: URL(string: "https://example.com/bug/42")! as NSURL),
            image,
            try #require(NSItemProvider(contentsOf: pdf)),
            // A text file keeps its name instead of joining the message.
            try #require(NSItemProvider(contentsOf: notes)),
        ])
        #expect(result.text == "Please review\n\nThe crash is on launch\n\nhttps://example.com/bug/42")
        #expect(result.attachments.map(\.filename) == ["Screenshot.png", "Spec.pdf", "notes.txt"])
        #expect(result.attachments.map(\.mimeType) == ["image/png", "application/pdf", "text/plain"])
        #expect(result.attachments.first?.data == png)
        #expect(result.attachments.last.map { String(decoding: $0.data, as: UTF8.self) } == "TODO: retry on 503")
        #expect(result.notes.isEmpty)
    }

    @Test("Images in formats models don't take are re-encoded as JPEG")
    func reencodesImages() throws {
        let tiff = try #require(Self.imageData(type: .tiff))
        let budget = BYOTShareImport.Budget(bytes: OpenCodePromptAttachment.maximumTotalBytes)
        guard case .attachment(let attachment) = BYOTShareImport.image(tiff, type: .tiff, name: "Scan.tiff", budget: budget)
        else { Issue.record("Expected an attachment"); return }
        #expect(attachment.filename == "Scan.jpg")
        #expect(attachment.mimeType == "image/jpeg")
        let source = try #require(CGImageSourceCreateWithData(attachment.data as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let png = try #require(Self.imageData(type: .png))
        guard case .attachment(let unchanged) = BYOTShareImport.image(png, type: .png, name: "Chart", budget: budget)
        else { Issue.record("Expected an attachment"); return }
        #expect(unchanged.filename == "Chart.png")
        #expect(unchanged.data == png)
    }

    @Test("Attachment limits leave extra files out and say why")
    func limits() async {
        let providers = (1...OpenCodePromptAttachment.maximumCount + 2).map { index in
            let provider = NSItemProvider(item: Data("page \(index)".utf8) as NSData, typeIdentifier: UTType.pdf.identifier)
            provider.suggestedName = "Doc \(index)"
            return provider
        }
        let result = await BYOTShareImport.load(providers: providers)
        #expect(result.attachments.count == OpenCodePromptAttachment.maximumCount)
        #expect(result.attachments.first?.filename == "Doc 1.pdf")
        #expect(result.notes == ["A message can carry \(OpenCodePromptAttachment.maximumCount) files, so 2 more weren’t added."])

        let maximum = OpenCodePromptAttachment.maximumFileBytes
        #expect(BYOTShareImport.limitNote(maximum + 1, name: "Movie.mov", budget: .init(bytes: maximum))?
            .hasPrefix("Movie.mov is larger than") == true)
        #expect(BYOTShareImport.limitNote(600, name: "Log.txt", budget: .init(bytes: 500))?
            .hasPrefix("Log.txt wasn’t added: attachments can total") == true)
        #expect(BYOTShareImport.limitNote(500, name: "Log.txt", budget: .init(bytes: 500)) == nil)
        #expect(BYOTShareImport.attachment(Data(), type: .plainText, name: "Empty", budget: .init(bytes: maximum))
                == .skipped("Empty.txt is empty, so it wasn’t added."))
    }

    @Test("Very long text is attached as a text file instead of filling the composer")
    func longText() async {
        let long = String(repeating: "log line\n", count: BYOTShareImport.longTextLimit / 8)
        let result = await BYOTShareImport.load(providers: [NSItemProvider(object: long as NSString)])
        #expect(result.text.isEmpty)
        #expect(result.attachments.map(\.filename) == [BYOTShareImport.longTextFilename])
        #expect(result.attachments.first?.mimeType == "text/plain")
        #expect(result.attachments.first.map { String(decoding: $0.data, as: UTF8.self) }
                == long.trimmingCharacters(in: .whitespacesAndNewlines))

        let short = await BYOTShareImport.load(providers: [NSItemProvider(object: "short" as NSString)])
        #expect(short.text == "short")
        #expect(short.attachments.isEmpty)
    }

    // MARK: Composer drafts

    @Test("A share adds to the draft's text and attachments without replacing them")
    func mergesIntoDraft() throws {
        let existing = (1...OpenCodePromptAttachment.maximumCount - 1).map {
            OpenCodePromptAttachment(filename: "old \($0).txt", mimeType: "text/plain", data: Data("x".utf8))
        }
        let shared = [OpenCodePromptAttachment(filename: "new.png", mimeType: "image/png", data: Data([1])),
                      OpenCodePromptAttachment(filename: "extra.pdf", mimeType: "application/pdf", data: Data([2]))]
        let content = Self.content(text: "https://example.com", attachments: shared)
        let merged = BYOTShareDraft.merge(content, into: OpenCodeComposerDraft(text: "Compare with\n"), attachments: existing)
        #expect(merged.draft.text == "Compare with\n\nhttps://example.com")
        #expect(merged.attachments.map(\.filename) == existing.map(\.filename) + ["new.png"])
        #expect(merged.leftOut == ["extra.pdf"])
        #expect(BYOTShareDraft.leftOutNotice(merged.leftOut)?.hasPrefix("extra.pdf didn’t fit") == true)
        #expect(BYOTShareDraft.leftOutNotice([]) == nil)

        let blank = BYOTShareDraft.merge(content, into: OpenCodeComposerDraft(text: " \n"), attachments: [])
        #expect(blank.draft.text == "https://example.com")
        #expect(blank.leftOut.isEmpty)
    }

    @Test("Delivering a share writes the session's draft and empties the inbox")
    func delivers() throws {
        let inbox = try temporaryInbox()
        defer { cleanUp(inbox) }
        let draftRoot = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: draftRoot) }
        let photo = OpenCodePromptAttachment(filename: "Photo.jpg", mimeType: "image/jpeg", data: Data([9, 9]))
        let item = try inbox.save(text: "What’s wrong here?", attachments: [photo], notes: [])
        let center = BYOTShareCenter(inbox: inbox)
        center.refresh()
        let content = try #require(center.incoming)
        #expect(content.id == item.id)
        #expect(content.attachments.map(\.data) == [photo.data])

        let store = OpenCodeComposerDraftStore(serverID: UUID(), sessionID: "ses_1", directory: "/repo",
                                               workspace: nil, root: draftRoot)
        try store.save(OpenCodeComposerDraft(text: "Draft in progress"))
        center.claim(content)
        #expect(center.incoming == nil)
        try center.deliver(content, into: store)
        let (draft, attachments) = try store.load()
        #expect(draft.text == "Draft in progress\n\nWhat’s wrong here?")
        #expect(attachments.map(\.data) == [photo.data])
        #expect(inbox.pending().isEmpty)
        #expect(center.notice == nil)
    }

    @Test("Claimed shares aren't offered twice; failures and abandoned choices bring them back")
    func centerLifecycle() throws {
        let inbox = try temporaryInbox()
        defer { cleanUp(inbox) }
        let first = try inbox.save(text: "first", attachments: [], notes: [], now: .now.addingTimeInterval(-20))
        let second = try inbox.save(text: "second", attachments: [], notes: [], now: .now.addingTimeInterval(-10))
        let center = BYOTShareCenter(inbox: inbox)

        center.refresh()
        #expect(center.incoming?.id == first.id)
        // The share the extension just opened byot for replaces an older one.
        center.refresh(preferring: second.id)
        #expect(center.incoming?.id == second.id)
        center.refresh()
        #expect(center.incoming?.id == second.id)

        let content = try #require(center.incoming)
        center.claim(content)
        center.refresh(preferring: second.id)
        #expect(center.incoming?.id == first.id)

        center.release(content, error: "Couldn’t open that session.")
        #expect(center.incoming?.id == second.id)
        #expect(center.deliveryError == "Couldn’t open that session.")

        center.discard(content)
        #expect(center.incoming == nil)
        #expect(center.deliveryError == nil)
        #expect(inbox.pending().map(\.id) == [first.id])

        center.refresh()
        let abandoned = try #require(center.incoming)
        center.claim(abandoned)
        center.release(abandoned)
        #expect(center.incoming == nil)
        center.refresh()
        #expect(center.incoming?.id == first.id)
    }

    @Test("A share whose files went missing is dropped with an explanation")
    func missingFiles() throws {
        let inbox = try temporaryInbox()
        defer { cleanUp(inbox) }
        let item = try inbox.save(text: "", attachments: [
            OpenCodePromptAttachment(filename: "Gone.pdf", mimeType: "application/pdf", data: Data([1])),
        ], notes: [])
        try FileManager.default.removeItem(at: inbox.root.appending(path: item.id.uuidString)
            .appending(path: "\(item.files[0].id.uuidString).bin"))
        let center = BYOTShareCenter(inbox: inbox)
        center.refresh()
        #expect(center.incoming == nil)
        #expect(center.notice == BYOTShareInboxError.missingFile("Gone.pdf").localizedDescription)
        #expect(inbox.pending().isEmpty)
        #expect(BYOTShareCenter(inbox: nil).incoming == nil)
    }

    @Test("Summaries count what's being shared")
    func summaries() {
        let image = OpenCodePromptAttachment(filename: "a.png", mimeType: "image/png", data: Data([1]))
        let file = OpenCodePromptAttachment(filename: "b.pdf", mimeType: "application/pdf", data: Data([1]))
        #expect(Self.content(text: "https://example.com/x", attachments: []).summary == "A link")
        #expect(Self.content(text: "Look", attachments: [image, image]).summary == "Text and 2 images")
        #expect(Self.content(text: "", attachments: [image, file, file]).summary == "An image and 2 files")
    }

    // MARK: Helpers

    private func temporaryInbox() throws -> BYOTShareInbox {
        let root = FileManager.default.temporaryDirectory.appending(path: "share-inbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return BYOTShareInbox(root: root)
    }

    private func cleanUp(_ inbox: BYOTShareInbox) {
        try? FileManager.default.removeItem(at: inbox.root)
    }

    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + seconds) }

    private static func content(text: String, attachments: [OpenCodePromptAttachment]) -> BYOTShareContent {
        BYOTShareContent(item: BYOTSharedItem(id: UUID(), createdAt: .now, text: text, files: [], notes: []),
                         attachments: attachments)
    }

    /// A small solid image encoded as `type`.
    private static func imageData(type: UTType) -> Data? {
        let context = CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        guard let image = context?.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
