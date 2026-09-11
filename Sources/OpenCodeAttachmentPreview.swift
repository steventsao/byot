import ImageIO
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct OpenCodeAttachmentThumbnail: View {
    let attachment: OpenCodePromptAttachment
    @State private var thumbnail: UIImage?

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc.text")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(BYOTBrand.surface)
            }
        }
        .task(id: attachment.id) {
            // Downsample compressed images rather than decoding a full camera
            // photo for a small chip. The import limit bounds source bytes.
            guard attachment.mimeType.hasPrefix("image/"),
                  let source = CGImageSourceCreateWithData(attachment.data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 192,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return }
            thumbnail = UIImage(cgImage: image)
        }
    }
}

/// A single preview owns its temporary copy and removes it when dismissed.
struct OpenCodeAttachmentPreviewFile {
    let directory: URL
    let url: URL

    init(attachment: OpenCodePromptAttachment, root: URL = FileManager.default.temporaryDirectory) throws {
        try OpenCodePromptAttachment.validate([attachment])
        directory = root.appendingPathComponent("byot-preview-\(UUID().uuidString)", isDirectory: true)
        // Both separators are untrusted filename input, including Windows paths.
        var filename = attachment.filename.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").last.map(String.init) ?? "Attachment"
        if filename == "." || filename == ".." { filename = "Attachment" }
        if (filename as NSString).pathExtension.isEmpty,
           let ext = UTType(mimeType: attachment.mimeType)?.preferredFilenameExtension {
            filename += ".\(ext)"
        }
        url = directory.appendingPathComponent(filename, isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try attachment.data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

struct OpenCodeAttachmentPreview: View {
    let attachment: OpenCodePromptAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var file: OpenCodeAttachmentPreviewFile?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let file {
                    OpenCodeQuickLook(url: file.url)
                        .accessibilityIdentifier("attachment-preview-content")
                } else if let error {
                    ContentUnavailableView("Couldn’t preview attachment", systemImage: "doc",
                                           description: Text(error))
                } else {
                    ProgressView("Preparing preview")
                }
            }
            .navigationTitle(attachment.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            do { file = try OpenCodeAttachmentPreviewFile(attachment: attachment) }
            catch { self.error = error.localizedDescription }
        }
        .onDisappear { file?.remove(); file = nil }
    }
}

private struct OpenCodeQuickLook: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
