import SwiftUI
import UIKit

/// The Markdown file the share sheet offers. Each export owns its temporary
/// copy and removes it when the sheet closes or the options change.
struct OpenCodeTranscriptFile: Equatable {
    let directory: URL
    let url: URL

    init(markdown: String, filename: String, root: URL = FileManager.default.temporaryDirectory) throws {
        directory = root.appendingPathComponent("byot-transcript-\(UUID().uuidString)", isDirectory: true)
        // The name is a title slug, but never let it leave the directory.
        let name = filename.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        url = directory.appendingPathComponent(name.hasPrefix(".") ? "transcript.md" : name, isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try Data(markdown.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

enum OpenCodeTranscriptClipboard {
    /// Copies the conversation with the viewer's last export choices, like
    /// the TUI's `/copy`.
    @MainActor
    static func copy(_ export: OpenCodeTranscriptExport, defaults: UserDefaults = .standard) {
        UIPasteboard.general.string = export.markdown(OpenCodeTranscriptExportOptions(defaults: defaults))
        AgentHaptics.send()
        AccessibilityNotification.Announcement("Transcript copied").post()
    }
}

/// Export as Markdown: choose what to include, preview it, then share the
/// file or copy the text. The TUI's `/export` dialog, for a phone.
struct OpenCodeTranscriptExportView: View {
    /// The conversation as it stood when the sheet opened. Replies that keep
    /// streaming in would otherwise change the summary and title while the
    /// preview and the shared file still held the earlier text.
    @State private var export: OpenCodeTranscriptExport
    private let defaults: UserDefaults
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var options: OpenCodeTranscriptExportOptions
    @State private var markdown = ""
    @State private var preview = ""
    @State private var isPreviewTruncated = false
    @State private var messageCount = 0
    @State private var file: OpenCodeTranscriptFile?
    @State private var fileError: String?
    @State private var copies = 0
    @State private var showsCopied = false
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 40

    /// Long transcripts preview their opening; the file holds all of it.
    private static let previewLimit = 6_000

    init(export: OpenCodeTranscriptExport, defaults: UserDefaults = .standard) {
        _export = State(initialValue: export)
        self.defaults = defaults
        _options = State(initialValue: OpenCodeTranscriptExportOptions(defaults: defaults))
    }

    var body: some View {
        NavigationStack {
            List {
                Section { summary }
                Section {
                    optionToggle("Thinking", detail: "The model’s reasoning before each reply",
                                 isOn: $options.thinking, id: "thinking")
                    optionToggle("Tool details", detail: "Each tool call’s input and output",
                                 isOn: $options.toolDetails, id: "tool-details")
                    optionToggle("Reply details", detail: "Agent, model and duration beside each reply",
                                 isOn: $options.assistantMetadata, id: "assistant-metadata")
                } header: {
                    Text("Include")
                }
                Section {
                    Text(preview)
                        .font(.cleanMono)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("transcript-export-preview")
                } header: {
                    Text("Preview")
                } footer: {
                    if isPreviewTruncated {
                        Text("Showing the beginning. The file and the copy include the whole conversation.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationTitle("Export transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: options) { prepare() }
        .task(id: copies) {
            guard copies > 0 else { return }
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            showsCopied = false
        }
        .onDisappear { file?.remove() }
    }

    private var summary: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            Image(systemName: "doc.richtext")
                .font(.cleanBodySemibold)
                .foregroundStyle(BYOTBrand.accent)
                // The glyph scales with text; its tile stops growing at a thumbnail.
                .frame(width: min(iconSize, 64), height: min(iconSize, 64))
                .background(BYOTBrand.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(export.filename)
                    .font(.cleanBodySemibold)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(detail)
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcript-export-summary")
    }

    private var detail: String {
        let messages = messageCount == 1 ? "1 message" : "\(messageCount.formatted()) messages"
        let size = ByteCountFormatter.string(fromByteCount: Int64(markdown.utf8.count), countStyle: .file)
        return "Markdown · \(messages) · \(size)"
    }

    private func optionToggle(_ title: String, detail: String, isOn: Binding<Bool>, id: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.cleanBody)
                Text(detail).font(.cleanCaption).foregroundStyle(.secondary)
            }
        }
        .tint(BYOTBrand.accent)
        .frame(minHeight: 44)
        .accessibilityIdentifier("transcript-export-\(id)")
    }

    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        return VStack(spacing: 8) {
            if let fileError {
                Text(fileError)
                    .font(.cleanCaption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            layout {
                Button(action: copy) {
                    Label(showsCopied ? "Copied" : "Copy", systemImage: showsCopied ? "checkmark" : "doc.on.doc")
                        .font(.cleanBodySemibold)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .tint(BYOTBrand.primaryAction)
                .disabled(markdown.isEmpty)
                .accessibilityLabel(showsCopied ? "Copied" : "Copy Markdown")
                .accessibilityIdentifier("transcript-export-copy")

                Group {
                    if let file {
                        ShareLink(item: file.url,
                                  preview: SharePreview(export.filename, image: Image(systemName: "doc.richtext"))) {
                            shareLabel
                        }
                    } else {
                        Button {} label: { shareLabel }.disabled(true)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(BYOTBrand.primaryAction)
                .foregroundStyle(BYOTBrand.primaryActionInk)
                .accessibilityLabel("Share Markdown file")
                .accessibilityIdentifier("transcript-export-share")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var shareLabel: some View {
        Label("Share", systemImage: "square.and.arrow.up")
            .font(.cleanBodySemibold)
            .frame(maxWidth: .infinity, minHeight: 36)
    }

    private func prepare() {
        options.save(to: defaults)
        markdown = export.markdown(options)
        // Counted once here rather than on every render of a long transcript.
        messageCount = export.messageCount(options)
        isPreviewTruncated = markdown.count > Self.previewLimit
        preview = isPreviewTruncated ? String(markdown.prefix(Self.previewLimit)) + "\n…" : markdown
        file?.remove()
        do {
            file = try OpenCodeTranscriptFile(markdown: markdown, filename: export.filename)
            fileError = nil
        } catch {
            file = nil
            fileError = "Couldn’t prepare the file to share. You can still copy the transcript."
        }
    }

    private func copy() {
        UIPasteboard.general.string = markdown
        AgentHaptics.send()
        AccessibilityNotification.Announcement("Transcript copied").post()
        showsCopied = true
        copies += 1
    }
}
