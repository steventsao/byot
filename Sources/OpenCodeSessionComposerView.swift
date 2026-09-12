import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct OpenCodeSessionComposerView: View {
    @ObservedObject var store: OpenCodeSessionStore
    private let onNewSession: (() -> Void)?
    private let sessionActions: [OpenCodeComposerAction]
    private let restoredMessage: OpenCodeMessageEnvelope?
    private let onRestoreConsumed: (() -> Void)?
    private let screenshotAttachment: OpenCodePromptAttachment?
    @State private var text = ""
    @State private var remoteReferences: [OpenCodePromptFileReference] = []
    @State private var isShowingAgentPicker = false
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
        screenshotAttachment: OpenCodePromptAttachment? = nil,
        onNewSession: (() -> Void)? = nil,
        sessionActions: [OpenCodeComposerAction] = [],
        restoredMessage: OpenCodeMessageEnvelope? = nil,
        onRestoreConsumed: (() -> Void)? = nil
    ) {
        self.store = store
        self.screenshotAttachment = screenshotAttachment
        self.onNewSession = onNewSession
        self.sessionActions = sessionActions
        self.restoredMessage = restoredMessage
        self.onRestoreConsumed = onRestoreConsumed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            slashSuggestions
            if let files = store.remoteFiles {
                OpenCodeRemoteContextView(text: $text, references: $remoteReferences, files: files)
            }
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

            if !store.composerCatalog.agents.isEmpty || !store.availableVariants.isEmpty {
                HStack(spacing: 8) {
                    if !store.composerCatalog.agents.isEmpty { agentButton }
                    if !store.availableVariants.isEmpty { variantMenu }
                    Spacer(minLength: 0)
                }
            }

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
        .sheet(isPresented: $isShowingAgentPicker) {
            OpenCodeAgentPickerView(store: store)
        }
        .onChange(of: restoredMessage) { _, message in
            guard let message else { return }
            restore(message)
            onRestoreConsumed?()
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
            || !attachments.isEmpty || !remoteReferences.isEmpty
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
        Self.showsStopControl(canStop: store.canStopTurn, text: text,
                              hasAttachments: !attachments.isEmpty || !remoteReferences.isEmpty)
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
        if attachments.isEmpty, remoteReferences.isEmpty,
           !store.composerCatalog.commands.contains(where: { "/" + $0.name == prompt }),
           runBuiltin(prompt) { return }
        guard (!prompt.isEmpty || !attachments.isEmpty || !remoteReferences.isEmpty), store.canSubmitPrompt else { return }
        let promptAttachments = attachments
        let promptReferences = remoteReferences
        text = ""
        attachments = []
        remoteReferences = []
        if store.send(prompt, attachments: promptAttachments, remoteReferences: promptReferences) == false,
           text.isEmpty, attachments.isEmpty, remoteReferences.isEmpty {
            text = prompt
            attachments = promptAttachments
            remoteReferences = promptReferences
        }
    }

    private var agentButton: some View {
        Button {
            isFocused = false
            isShowingAgentPicker = true
        } label: {
            Label(store.selectedAgentName, systemImage: "person.crop.circle")
                .font(.cleanCaptionBold)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose agent")
        .accessibilityValue(store.selectedAgentName)
        .accessibilityIdentifier("opencode-agent-picker")
    }

    private var variantMenu: some View {
        Menu {
            Button { store.selectVariant(nil) } label: {
                Label("Default", systemImage: store.selectedVariant == nil ? "checkmark" : "circle")
            }
            ForEach(store.availableVariants, id: \.self) { variant in
                Button { store.selectVariant(variant) } label: {
                    Label(variant, systemImage: store.selectedVariant == variant ? "checkmark" : "circle")
                }
            }
        } label: {
            Label(store.variantLabel, systemImage: "slider.horizontal.3")
                .font(.cleanCaptionBold)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minHeight: 44)
        }
        .accessibilityLabel("Model variant")
        .accessibilityValue(store.variantLabel)
        .accessibilityIdentifier("opencode-variant-picker")
    }

    private var builtinActions: [OpenCodeComposerAction] {
        var actions = [OpenCodeComposerAction(name: "model", title: "Choose model", unavailableReason: nil, run: showModelPicker)]
        if let onNewSession {
            actions.append(OpenCodeComposerAction(name: "new", title: "New session", unavailableReason: nil, run: onNewSession))
        }
        return actions + sessionActions
    }

    @ViewBuilder
    private var slashSuggestions: some View {
        if text.hasPrefix("/") {
            let token = String(text.dropFirst().prefix(while: { !$0.isWhitespace }))
            let isChoosing = !text.dropFirst().contains(where: \.isWhitespace)
            if isChoosing {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(builtinActions.filter { token.isEmpty || $0.name.localizedCaseInsensitiveContains(token) }, id: \.name) { action in
                            Button {
                                guard action.unavailableReason == nil else { return }
                                text = ""
                                isFocused = false
                                action.run()
                            } label: {
                                commandRow(name: action.name, detail: action.unavailableReason ?? action.title, kind: "App action")
                            }
                            .buttonStyle(.plain)
                            .disabled(action.unavailableReason != nil)
                            .accessibilityIdentifier("opencode-command-app-\(action.name)")
                        }
                        ForEach(store.composerCatalog.commands.filter { token.isEmpty || $0.name.localizedCaseInsensitiveContains(token) }) { command in
                            Button {
                                text = "/\(command.name) "
                                isFocused = true
                            } label: {
                                commandRow(name: command.name, detail: command.description ?? "Add arguments, then send",
                                           kind: command.kind == .command ? "Server command" : "Server skill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("opencode-command-\(command.id)")
                        }
                        if let error = store.composerErrorMessage {
                            Text(error).font(.cleanCaption).foregroundStyle(.secondary)
                            Button("Reload commands") { Task { await store.reloadComposerCatalog() } }
                                .font(.cleanCaptionBold)
                                .frame(minHeight: 44)
                        }
                    }
                }
                .frame(maxHeight: dynamicTypeSize.isAccessibilitySize ? 180 : 220)
                .accessibilityIdentifier("opencode-slash-suggestions")
            } else if let invocation = OpenCodeCommandInvocation.parse(text, catalog: store.composerCatalog.commands) {
                Text("/\(invocation.name) · \(invocation.kind == .command ? "Server command" : "Server skill") · Add arguments below")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("opencode-command-arguments")
            }
        }
    }

    private func commandRow(name: String, detail: String, kind: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("/\(name) · \(kind)").font(.cleanCaptionBold)
            Text(detail).font(.cleanCaption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func runBuiltin(_ prompt: String) -> Bool {
        guard let action = builtinActions.first(where: { "/" + $0.name == prompt }) else { return false }
        guard action.unavailableReason == nil else {
            store.errorMessage = action.unavailableReason
            return true
        }
        text = ""
        isFocused = false
        action.run()
        return true
    }

    private func restore(_ message: OpenCodeMessageEnvelope) {
        text = message.parts.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n\n")
        attachments = message.parts.compactMap { part in
            guard part.type == "file", let url = part.url, url.hasPrefix("data:"),
                  let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
            return OpenCodePromptAttachment(filename: part.filename ?? "Attachment",
                                            mimeType: part.mime ?? "application/octet-stream", data: data)
        }
        remoteReferences = OpenCodePromptFileReference.restored(from: message, serverID: store.serverID,
            projectID: store.session.projectID, directory: store.directory, workspaceID: store.session.workspaceID)
        if let providerID = message.info.providerID, let modelID = message.info.modelID,
           let model = store.providerModels.flatMap(\.models).first(where: { $0.providerID == providerID && $0.modelID == modelID }) {
            store.selectModel(model)
            store.selectVariant(message.info.variant)
        }
        if let agent = message.info.agent { store.selectAgent(agent) }
        isFocused = true
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
