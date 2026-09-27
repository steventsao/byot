import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Turns what another app shared into a composer message. Text and web links
/// become the message; images and files become attachments within the
/// composer's limits, and anything left out gets a plain-language note.
/// Compiled into the share extension and the app, so the app's tests cover it.
enum BYOTShareImport {
    struct Result: Equatable, Sendable {
        var text = ""
        var attachments: [OpenCodePromptAttachment] = []
        var notes: [String] = []

        var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
    }

    /// How one shared item is read.
    enum Kind: Equatable, Sendable {
        /// A web page link; it goes into the message as text.
        case webURL
        /// A file offered only by its location, such as a text file from Files.
        case fileURL
        /// A text snippet, or a text file whose name decides which it is.
        case text(String)
        case image(UTType)
        case file(UTType)

        /// Images and files always need an attachment slot.
        var isAttachment: Bool {
            switch self {
            case .image, .file: true
            case .webURL, .fileURL, .text: false
            }
        }
    }

    enum Loaded: Equatable, Sendable {
        case text(String)
        case attachment(OpenCodePromptAttachment)
        case skipped(String)
    }

    /// Longer text is attached as a file instead, so the composer stays usable.
    static let longTextLimit = 12_000
    static let longTextFilename = "Shared text.txt"
    /// Formats every model provider accepts go through unchanged. Anything
    /// else (HEIC, TIFF, RAW) is re-encoded as JPEG, which also drops location
    /// metadata.
    static let passthroughImageTypes: [UTType] = [.png, .jpeg, .gif, .webP]
    static let maximumImagePixelSize = 4_096

    // MARK: Loading

    @MainActor
    static func load(_ items: [NSExtensionItem]) async -> Result {
        let text = items.compactMap { $0.attributedContentText?.string }
        return await load(texts: text, providers: items.flatMap { $0.attachments ?? [] })
    }

    @MainActor
    static func load(texts: [String] = [], providers: [NSItemProvider]) async -> Result {
        var collector = Collector(texts: texts)
        for (index, provider) in providers.enumerated() {
            guard let kind = kind(of: provider.registeredTypeIdentifiers) else { continue }
            if kind.isAttachment, collector.isFull {
                collector.overflow += 1
                continue
            }
            let naming = Naming(suggested: provider.suggestedName, index: index + 1, kind: kind)
            let budget = collector.budget
            switch kind {
            case .webURL, .fileURL: collector.add(await loadURL(provider, naming: naming, budget: budget))
            case .text(let identifier):
                collector.add(await loadText(provider, identifier: identifier, naming: naming, budget: budget))
            case .image(let type): collector.add(await loadImage(provider, type: type, naming: naming, budget: budget))
            case .file(let type): collector.add(await loadFile(provider, type: type, naming: naming, budget: budget))
            }
        }
        return collector.result()
    }

    /// Picks how to read an item from the types it offers, most specific first.
    /// A file that names its type (a PDF from Files) is copied by that type;
    /// text files and files of unknown type are read from their location, so
    /// they keep their names. Folders and undeclared types are passed over.
    static func kind(of identifiers: [String]) -> Kind? {
        let types = identifiers.compactMap { UTType($0) }
        if let image = types.first(where: { $0.conforms(to: .image) }) { return .image(image) }
        let isContent = { (type: UTType) in
            type.isDeclared && type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
                && type != .data
        }
        if let file = types.first(where: isContent) { return .file(file) }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return .fileURL }
        if types.contains(where: { $0.conforms(to: .url) }) { return .webURL }
        if let text = types.first(where: { $0.conforms(to: .text) }) { return .text(text.identifier) }
        return types.first { $0.conforms(to: .data) }.map(Kind.file)
    }

    /// A link becomes text; a file location becomes an attachment.
    @MainActor
    private static func loadURL(_ provider: NSItemProvider, type: UTType? = nil, naming: Naming,
                                budget: Budget) async -> Loaded {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { @Sendable url, _ in
                let loaded: Loaded = switch url {
                case let url? where url.isFileURL: file(at: url, type: type, naming: naming, budget: budget)
                case let url?: .text(url.absoluteString)
                case nil: .skipped(unreadable(naming.name()))
                }
                continuation.resume(returning: loaded)
            }
        }
    }

    @MainActor
    private static func loadText(_ provider: NSItemProvider, identifier: String, naming: Naming,
                                 budget: Budget) async -> Loaded {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { @Sendable item, _ in
                let type = UTType(identifier)
                let loaded: Loaded = switch item {
                case let string as String: .text(string)
                case let string as NSAttributedString: .text(string.string)
                case let url as URL where url.isFileURL: file(at: url, type: nil, naming: naming, budget: budget)
                case let data as Data:
                    // Unnamed plain text is a snippet (Notes); named data is a file.
                    if naming.suggested == nil, type?.conforms(to: .plainText) == true,
                       let text = String(data: data, encoding: .utf8) { .text(text) }
                    else { attachment(data, type: type, name: naming.name(), budget: budget) }
                default: .skipped(unreadable(naming.name()))
                }
                continuation.resume(returning: loaded)
            }
        }
    }

    @MainActor
    private static func loadFile(_ provider: NSItemProvider, type: UTType, naming: Naming,
                                 budget: Budget) async -> Loaded {
        // The file's own location keeps its name; a copy by type may arrive
        // with a generic one ("PDF document.pdf").
        if naming.suggested == nil, provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let original = await loadURL(provider, type: type, naming: naming, budget: budget)
            if case .attachment = original { return original }
        }
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { @Sendable url, _ in
                // The file is deleted when this handler returns, so read it here.
                let loaded = url.map { file(at: $0, type: type, naming: naming, budget: budget) }
                continuation.resume(returning: loaded ?? .skipped(unreadable(naming.name())))
            }
        }
    }

    @MainActor
    private static func loadImage(_ provider: NSItemProvider, type: UTType, naming: Naming,
                                  budget: Budget) async -> Loaded {
        let fromFile: Loaded = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { @Sendable url, _ in
                let loaded = url.map { image(at: $0, type: type, name: naming.name(), budget: budget) }
                continuation.resume(returning: loaded ?? .skipped(unreadable(naming.name())))
            }
        }
        guard case .skipped = fromFile, provider.canLoadObject(ofClass: UIImage.self) else { return fromFile }
        // Screenshots shared straight from markup can arrive as an image object only.
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { @Sendable object, _ in
                guard let data = (object as? UIImage)?.pngData() else {
                    continuation.resume(returning: fromFile)
                    return
                }
                continuation.resume(returning: image(data, type: .png, name: naming.name(), budget: budget))
            }
        }
    }

    // MARK: Files and images

    /// Room left for attachments, passed into the loaders so an oversized
    /// file is skipped before it is read.
    struct Budget: Equatable, Sendable {
        var bytes: Int
        var fileBytes: Int { min(bytes, OpenCodePromptAttachment.maximumFileBytes) }
    }

    /// How an item is named: the sender's suggestion without any path, else
    /// the file's own name, else "Image 2" or "File 3".
    struct Naming: Equatable, Sendable {
        let suggested: String?
        let fallback: String

        init(suggested: String?, index: Int, kind: Kind) {
            let base = suggested?.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            self.suggested = base.isEmpty || base == "." || base == ".." ? nil : base
            fallback = switch kind {
            case .image: String(localized: "Image \(index)")
            case .webURL: String(localized: "Link \(index)")
            case .fileURL, .text, .file: String(localized: "File \(index)")
            }
        }

        func name(for url: URL? = nil) -> String {
            suggested ?? url.map(\.lastPathComponent).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        }
    }

    static func file(at url: URL, type: UTType?, naming: Naming, budget: Budget) -> Loaded {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = filename(naming.name(for: url), type: UTType(filenameExtension: url.pathExtension))
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile != false else { return .skipped(unreadable(name)) }
        if let size = values?.fileSize, let note = limitNote(size, name: name, budget: budget) { return .skipped(note) }
        guard let data = try? Data(contentsOf: url) else { return .skipped(unreadable(name)) }
        let specific = type.flatMap { $0 == .data || $0 == .item ? nil : $0 }
        return attachment(data, type: specific ?? UTType(filenameExtension: url.pathExtension), name: name,
                          budget: budget)
    }

    static func attachment(_ data: Data, type: UTType?, name: String, budget: Budget) -> Loaded {
        let name = filename(name, type: type)
        guard !data.isEmpty else { return .skipped(String(localized: "\(name) is empty, so it wasn’t added.")) }
        if let note = limitNote(data.count, name: name, budget: budget) { return .skipped(note) }
        return .attachment(OpenCodePromptAttachment(filename: name,
                                                    mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                                                    data: data))
    }

    static func image(at url: URL, type: UTType, name: String, budget: Budget) -> Loaded {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? Int.max
        if passthroughImageTypes.contains(type), size <= budget.fileBytes, let data = try? Data(contentsOf: url) {
            return attachment(data, type: type, name: name, budget: budget)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .skipped(unreadable(name)) }
        return reencoded(source, name: name, budget: budget)
    }

    static func image(_ data: Data, type: UTType, name: String, budget: Budget) -> Loaded {
        if passthroughImageTypes.contains(type), data.count <= budget.fileBytes {
            return attachment(data, type: type, name: name, budget: budget)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .skipped(unreadable(name)) }
        return reencoded(source, name: name, budget: budget)
    }

    /// Re-encodes as JPEG, shrinking a very large image until it fits.
    private static func reencoded(_ source: CGImageSource, name: String, budget: Budget) -> Loaded {
        let name = (name as NSString).deletingPathExtension + ".jpg"
        var size = 0
        for pixels in [maximumImagePixelSize, maximumImagePixelSize / 2] {
            guard let data = jpeg(source, maximumPixelSize: pixels) else { return .skipped(unreadable(name)) }
            if data.count <= budget.fileBytes { return attachment(data, type: .jpeg, name: name, budget: budget) }
            size = data.count
        }
        return .skipped(limitNote(size, name: name, budget: budget) ?? unreadable(name))
    }

    static func jpeg(_ source: CGImageSource, maximumPixelSize: Int) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// Why a file of this size can't join the message, if it can't.
    static func limitNote(_ size: Int, name: String, budget: Budget) -> String? {
        let limit = ByteCountFormatter.string(fromByteCount: Int64(OpenCodePromptAttachment.maximumFileBytes),
                                              countStyle: .file)
        if size > OpenCodePromptAttachment.maximumFileBytes {
            return String(localized: "\(name) is larger than \(limit), so it wasn’t added.")
        }
        if size > budget.bytes {
            return String(localized: "\(name) wasn’t added: attachments can total up to \(limit) per message.")
        }
        return nil
    }

    // MARK: Names and text

    /// Adds the type's usual extension when the name has none.
    static func filename(_ name: String, type: UTType?) -> String {
        guard (name as NSString).pathExtension.isEmpty,
              let ext = type?.preferredFilenameExtension else { return name }
        return "\(name).\(ext)"
    }

    /// Joins shared text into one message, dropping blanks, repeats, and links
    /// already quoted in other text (Safari often sends both).
    static func message(_ parts: [String]) -> String {
        var kept: [String] = []
        for part in parts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !part.isEmpty {
            if kept.contains(where: { $0 == part || $0.contains(part) }) { continue }
            kept.removeAll { part.contains($0) }
            kept.append(part)
        }
        return kept.joined(separator: "\n\n")
    }

    private static func unreadable(_ name: String) -> String {
        String(localized: "\(name) couldn’t be read, so it wasn’t added.")
    }

    // MARK: Limits

    struct Collector {
        var texts: [String]
        var attachments: [OpenCodePromptAttachment] = []
        var notes: [String] = []
        /// Files left out because the message already carries the most it can.
        var overflow = 0

        var isFull: Bool { attachments.count >= OpenCodePromptAttachment.maximumCount }

        var budget: Budget {
            Budget(bytes: OpenCodePromptAttachment.maximumTotalBytes - attachments.reduce(0) { $0 + $1.byteCount })
        }

        mutating func add(_ loaded: Loaded) {
            switch loaded {
            case .text(let text): texts.append(text)
            case .skipped(let note): notes.append(note)
            case .attachment(let attachment):
                if isFull { overflow += 1 }
                else if let note = BYOTShareImport.limitNote(attachment.byteCount, name: attachment.filename,
                                                             budget: budget) { notes.append(note) }
                else { attachments.append(attachment) }
            }
        }

        func result() -> Result {
            var result = Result(text: BYOTShareImport.message(texts), attachments: attachments, notes: notes)
            if result.text.count > BYOTShareImport.longTextLimit {
                var collector = self
                collector.texts = []
                collector.add(.attachment(OpenCodePromptAttachment(
                    filename: BYOTShareImport.longTextFilename, mimeType: "text/plain", data: Data(result.text.utf8))))
                if collector.attachments.count > attachments.count {
                    result.text = ""
                    result.attachments = collector.attachments
                }
            }
            if overflow > 0 {
                let maximum = OpenCodePromptAttachment.maximumCount
                result.notes.append(overflow == 1
                    ? String(localized: "A message can carry \(maximum) files, so 1 more wasn’t added.")
                    : String(localized: "A message can carry \(maximum) files, so \(overflow) more weren’t added."))
            }
            return result
        }
    }
}
