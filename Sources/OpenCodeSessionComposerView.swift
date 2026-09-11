import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct OpenCodeSessionComposerView: View {
    @ObservedObject var store: OpenCodeSessionStore
    private let screenshotAttachment: OpenCodePromptAttachment?
    @State private var text = ""
    @State private var attachments: [OpenCodePromptAttachment] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isShowingPhotoPicker = false
    @State private var isShowingFileImporter = false
    @State private var isImportingAttachment = false
    @State private var attachmentErrorMessage: String?
    @State private var isShowingModelPicker = false
    @State private var previewAttachment: OpenCodePromptAttachment?
    @FocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        store: OpenCodeSessionStore,
        screenshotAttachment: OpenCodePromptAttachment? = nil
    ) {
        self.store = store
        self.screenshotAttachment = screenshotAttachment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                ScrollView(dynamicTypeSize.isAccessibilitySize ? .vertical : .horizontal,
                           showsIndicators: dynamicTypeSize.isAccessibilitySize) {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 8) {
                            ForEach(attachments) { attachmentChip($0) }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachmentChip($0) }
                        }
                    }
                }
                .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 132 : 80)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Attachments")
            }

            TextField("Message", text: $text, axis: .vertical)
                .focused($isFocused)
                .lineLimit(1...(dynamicTypeSize.isAccessibilitySize ? 2 : 6))
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .accessibilityIdentifier("opencode-composer-message")
                .submitLabel(.send)
                .onSubmit(send)

            if dynamicTypeSize.isAccessibilitySize {
                modelButton
                HStack(spacing: 8) {
                    attachmentButton
                    Spacer(minLength: 8)
                    sessionProgress
                    submitButton
                }
            } else {
                HStack(spacing: 4) {
                    attachmentButton
                    modelButton
                    Spacer(minLength: 4)
                    sessionProgress
                    submitButton
                }
            }
        }
        .padding(10)
        .background(BYOTBrand.controlSurface, in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .strokeBorder(BYOTBrand.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(BYOTBrand.canvas)
        .sheet(item: $previewAttachment) { attachment in
            OpenCodeAttachmentPreview(attachment: attachment)
        }
        .sheet(isPresented: $isShowingModelPicker) {
            OpenCodeModelPickerView(store: store)
        }
        .photosPicker(
            isPresented: $isShowingPhotoPicker,
            selection: $selectedPhotos,
            maxSelectionCount: max(
                1,
                OpenCodePromptAttachment.maximumCount - attachments.count
            ),
            matching: .images,
            preferredItemEncoding: .current
        )
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            importPhotos(items)
        }
        .onChange(of: store.modelFailure) { _, failure in
            if failure != nil { isFocused = false }
        }
        .alert(
            "Couldn’t Add Attachment",
            isPresented: Binding(
                get: { attachmentErrorMessage != nil },
                set: { if !$0 { attachmentErrorMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) { attachmentErrorMessage = nil }
            },
            message: {
                Text(attachmentErrorMessage ?? "The attachment couldn’t be read.")
            }
        )
    }

    private var hasSendableContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    private var modelButton: some View {
        Button(action: showModelPicker) {
            HStack(spacing: 6) {
                Text(store.selectedModel?.modelName ?? "Automatic")
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
            .font(.cleanCaptionBold)
            .padding(.horizontal, 8)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose model")
        .accessibilityValue(store.selectedModel.map {
            "\($0.modelName), \($0.providerName)"
        } ?? "Automatic")
    }

    private var attachmentButton: some View {
        Menu {
            Button("Choose Photo", systemImage: "photo") {
                isShowingPhotoPicker = true
            }
            Button("Choose File", systemImage: "doc") {
                isShowingFileImporter = true
            }
#if DEBUG
            if let screenshotAttachment {
                Button("Add Screenshot Fixture", systemImage: "sparkles") {
                    do { try appendAttachments([screenshotAttachment]) }
                    catch { attachmentErrorMessage = error.localizedDescription }
                }
                Button("Add Text Fixture", systemImage: "doc.text") {
                    do {
                        try appendAttachments([OpenCodePromptAttachment(
                            filename: "review-notes.txt", mimeType: "text/plain",
                            data: Data("Review the attachment preview and composer layout.".utf8)
                        )])
                    } catch { attachmentErrorMessage = error.localizedDescription }
                }
            }
#endif
        } label: {
            Group {
                if isImportingAttachment { ProgressView() }
                else { Image(systemName: "plus").font(.cleanControlIcon) }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary)
        .accessibilityLabel("Add attachment")
        .disabled(isImportingAttachment || attachments.count >= OpenCodePromptAttachment.maximumCount)
    }

    @ViewBuilder
    private var sessionProgress: some View {
        if !store.canSubmitPrompt {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Checking session status")
        }
    }

    private var submitButton: some View {
        Button {
            if showsStopControl { stopTurn() }
            else { send() }
        } label: {
            Image(systemName: showsStopControl ? "stop.fill" : "arrow.up")
                .font(.cleanControlIcon)
                .foregroundStyle(BYOTBrand.primaryActionInk)
                .frame(width: 44, height: 44)
                .background(BYOTBrand.primaryAction, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showsStopControl ? "Stop the current turn" :
            (store.willQueueNextPrompt ? "Queue message" : "Send message"))
        .accessibilityIdentifier(showsStopControl ? "opencode-composer-stop" : "opencode-composer-send")
        .disabled(!showsStopControl && (!hasSendableContent || !store.canSubmitPrompt))
    }

    private func attachmentChip(_ attachment: OpenCodePromptAttachment) -> some View {
        HStack(spacing: 2) {
            Button {
                isFocused = false
                previewAttachment = attachment
            } label: {
                HStack(spacing: 8) {
                    OpenCodeAttachmentThumbnail(attachment: attachment)
                        .frame(width: 48, height: 48)
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
                            .lineLimit(1)
                    }
                    .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 160,
                           alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(attachment.filename)")
            Button {
                attachments.removeAll { $0.id == attachment.id }
            } label: {
                Image(systemName: "xmark")
                    .font(.cleanCaptionBold)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.filename)")
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .padding(6)
        .background(BYOTBrand.canvas, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }

    private var showsStopControl: Bool {
        Self.showsStopControl(canStop: store.canStopTurn, text: text, hasAttachments: !attachments.isEmpty)
    }

    // The stop control takes the send slot only while the composer is empty;
    // typed text switches back to send/queue so a steering message is never
    // blocked by the stop affordance.
    nonisolated static func showsStopControl(canStop: Bool, text: String, hasAttachments: Bool = false) -> Bool {
        canStop && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasAttachments
    }

    private func showModelPicker() {
        isFocused = false
        isShowingModelPicker = true
    }

    private func stopTurn() {
        Task { await store.stopTurn() }
    }

    private func send() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!prompt.isEmpty || !attachments.isEmpty), store.canSubmitPrompt else { return }
        let promptAttachments = attachments
        text = ""
        attachments = []
        if store.send(prompt, attachments: promptAttachments) == false,
           text.isEmpty,
           attachments.isEmpty {
            text = prompt
            attachments = promptAttachments
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        isImportingAttachment = true
        Task { @MainActor in
            defer {
                selectedPhotos = []
                isImportingAttachment = false
            }
            do {
                var imported: [OpenCodePromptAttachment] = []
                for (index, item) in items.enumerated() {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw OpenCodeAttachmentImportError.unreadable("Photo \(index + 1)")
                    }
                    let type = item.supportedContentTypes.first(where: {
                        $0.preferredMIMEType != nil
                    }) ?? .jpeg
                    let fileExtension = type.preferredFilenameExtension ?? "jpg"
                    imported.append(
                        OpenCodePromptAttachment(
                            filename: "Photo \(attachments.count + imported.count + 1).\(fileExtension)",
                            mimeType: type.preferredMIMEType ?? "image/jpeg",
                            data: data
                        )
                    )
                }
                try appendAttachments(imported)
            } catch {
                attachmentErrorMessage = error.localizedDescription
            }
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentErrorMessage = error.localizedDescription
        case .success(let urls):
            isImportingAttachment = true
            Task { @MainActor in
                defer { isImportingAttachment = false }
                do {
                    var imported: [OpenCodePromptAttachment] = []
                    for url in urls {
                        imported.append(try await Self.loadAttachment(from: url))
                    }
                    try appendAttachments(imported)
                } catch {
                    attachmentErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func appendAttachments(_ imported: [OpenCodePromptAttachment]) throws {
        let updated = attachments + imported
        try OpenCodePromptAttachment.validate(updated)
        attachments = updated
    }

    private static func loadAttachment(from url: URL) async throws -> OpenCodePromptAttachment {
        try await Task.detached(priority: .userInitiated) {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else {
                throw OpenCodeAttachmentImportError.unreadable(url.lastPathComponent)
            }
            if let size = values.fileSize,
               size > OpenCodePromptAttachment.maximumFileBytes {
                throw OpenCodePromptAttachmentError.fileTooLarge(
                    filename: url.lastPathComponent,
                    maximumBytes: OpenCodePromptAttachment.maximumFileBytes
                )
            }
            let type = UTType(filenameExtension: url.pathExtension)
            return OpenCodePromptAttachment(
                filename: url.lastPathComponent,
                mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                data: try Data(contentsOf: url)
            )
        }.value
    }
}

private enum OpenCodeAttachmentImportError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let filename):
            "\(filename) couldn’t be read as a file."
        }
    }
}
