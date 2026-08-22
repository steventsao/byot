import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct OpenCodeSessionComposerView: View {
    @ObservedObject var store: OpenCodeSessionStore
    @ObservedObject var inputStore: OpenCodeSessionInputStore
    private let screenshotAttachment: OpenCodePromptAttachment?
    @State private var text = ""
    @State private var attachments: [OpenCodePromptAttachment] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isShowingPhotoPicker = false
    @State private var isShowingFileImporter = false
    @State private var isImportingAttachment = false
    @State private var attachmentErrorMessage: String?
    @State private var isShowingModelPicker = false
    @State private var isShowingAgentPicker = false
    @State private var isShowingCommandPicker = false
    @State private var mode = OpenCodeSessionInputMode.normal
    @FocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        store: OpenCodeSessionStore,
        inputStore: OpenCodeSessionInputStore,
        screenshotAttachment: OpenCodePromptAttachment? = nil
    ) {
        self.store = store
        self.inputStore = inputStore
        self.screenshotAttachment = screenshotAttachment
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        modelButton
                        agentButton
                        Button("Commands", systemImage: "slash.circle") {
                            isShowingCommandPicker = true
                        }
                        .disabled(inputStore.commands.isEmpty)
                        inputModeButton
                    }
                }
                .scrollIndicators(.hidden)
                .buttonStyle(.bordered)

                if let inputError = inputStore.errorMessage {
                    Label(inputError.agentDisplayErrorText, systemImage: "exclamationmark.triangle")
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if store.canSubmitPrompt == false {
                    Label("Checking session status", systemImage: "arrow.triangle.2.circlepath")
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.willQueueNextPrompt {
                    Label(
                        "Next message will be queued",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(attachments) { attachment in
                                attachmentChip(attachment)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .accessibilityLabel("Attachments")
                }

                HStack(alignment: .bottom, spacing: 10) {
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
                                do {
                                    try appendAttachments([screenshotAttachment])
                                } catch {
                                    attachmentErrorMessage = error.localizedDescription
                                }
                            }
                        }
#endif
                    } label: {
                        Group {
                            if isImportingAttachment {
                                ProgressView()
                            } else {
                                Image(systemName: "paperclip")
                                    .font(.cleanControlIcon)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background(
                            BYOTBrand.controlSurface,
                            in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                        )
                    }
                    .accessibilityLabel("Add attachment")
                    .disabled(
                        mode == .shell
                            || isImportingAttachment
                            || attachments.count >= OpenCodePromptAttachment.maximumCount
                    )

                    TextField(inputPlaceholder, text: $text, axis: .vertical)
                        .focused($isFocused)
                        .lineLimit(1...8)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            BYOTBrand.controlSurface,
                            in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                        )
                        .submitLabel(.send)
                        .onSubmit(send)

                    if store.status.isActive,
                       store.lifecyclePolicy?.canAbort == true {
                        Button {
                            Task { await store.abortSession() }
                        } label: {
                            if store.isAborting {
                                ProgressView()
                                    .tint(.primary)
                            } else {
                                Image(systemName: "stop.fill")
                                    .font(.cleanControlIcon)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .background(
                            BYOTBrand.controlSurface,
                            in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                        )
                        .accessibilityLabel("Stop OpenCode")
                        .disabled(!store.canAbortSession)
                    }

                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.cleanControlIcon)
                        .foregroundStyle(BYOTBrand.primaryActionInk)
                        .frame(width: 44, height: 44)
                        .background(
                            BYOTBrand.primaryAction,
                            in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                        )
                    }
                    .accessibilityLabel(
                        store.willQueueNextPrompt ? "Queue message" : "Send message"
                    )
                    .disabled(!hasSendableContent || store.canSubmitPrompt == false)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
        .sheet(isPresented: $isShowingModelPicker) {
            OpenCodeModelPickerView(store: store)
        }
        .sheet(isPresented: $isShowingAgentPicker) {
            OpenCodeAgentPickerView(store: inputStore)
        }
        .sheet(isPresented: $isShowingCommandPicker) {
            OpenCodeCommandPickerView(store: inputStore) { command in
                guard attachments.isEmpty else {
                    attachmentErrorMessage = "Remove attachments before running a command."
                    return
                }
                mode = .normal
                text = "/\(command.name) "
                isFocused = true
            }
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
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return mode == .shell ? hasText : hasText || !attachments.isEmpty
    }

    private var modelButton: some View {
        Button(action: showModelPicker) {
            Label(
                store.selectedModel?.modelName ?? "Automatic model",
                systemImage: "cpu"
            )
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
        }
        .accessibilityLabel("Choose model")
        .accessibilityValue(
            store.selectedModel.map {
                "\($0.modelName), \($0.providerName)"
            } ?? "Automatic"
        )
    }

    private var agentButton: some View {
        Button {
            isShowingAgentPicker = true
        } label: {
            Label(inputStore.selectedAgent?.id ?? "Automatic agent", systemImage: "person.crop.circle")
                .lineLimit(1)
        }
        .disabled(inputStore.selectableAgents.isEmpty)
        .accessibilityLabel("Choose agent")
        .accessibilityValue(inputStore.selectedAgent?.id ?? "Automatic")
    }

    private var inputModeButton: some View {
        Button {
            if mode == .shell {
                mode = .normal
            } else {
                guard attachments.isEmpty else {
                    attachmentErrorMessage = "Remove attachments before entering shell mode."
                    return
                }
                guard inputStore.prepareShellMode() else { return }
                mode = .shell
            }
            isFocused = true
        } label: {
            Label(
                mode == .shell ? "Exit shell" : "Shell",
                systemImage: mode == .shell ? "text.bubble" : "terminal"
            )
        }
        .accessibilityValue(mode == .shell ? "On" : "Off")
        .accessibilityHint(
            inputStore.policy?.shellUnavailableReason
                ?? "Switch between messages and shell commands"
        )
    }

    private var inputPlaceholder: String {
        mode == .shell ? "Run a shell command" : "Message OpenCode"
    }

    private func attachmentChip(_ attachment: OpenCodePromptAttachment) -> some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.mimeType.hasPrefix("image/") ? "photo" : "doc")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.filename)
                    .font(.cleanCaptionBold)
                    .lineLimit(1)
                Text(attachment.formattedByteCount)
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
            }
            Button("Remove \(attachment.filename)", systemImage: "xmark.circle.fill") {
                attachments.removeAll { $0.id == attachment.id }
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)
            .frame(minWidth: 32, minHeight: 32)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(BYOTBrand.controlSurface, in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private func showModelPicker() {
        isShowingModelPicker = true
    }

    private func send() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!prompt.isEmpty || !attachments.isEmpty), store.canSubmitPrompt else { return }
        let intent = OpenCodeSessionInputParser.intent(
            text: prompt,
            mode: mode,
            commands: inputStore.commands
        )
        guard inputStore.validate(intent) else { return }
        if case .prompt = intent {
            // Prompt attachments remain valid for an empty text part.
        } else if !attachments.isEmpty {
            attachmentErrorMessage = "Remove attachments before running a command."
            return
        }
        let promptAttachments = attachments
        text = ""
        attachments = []
        if store.send(
            intent,
            agent: inputStore.selectedAgent?.id,
            attachments: promptAttachments
        ) == false,
           text.isEmpty,
           attachments.isEmpty {
            text = prompt
            attachments = promptAttachments
        } else if mode == .shell {
            mode = .normal
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
