import SwiftUI

struct OpenCodeRemoteContextView: View {
    @Binding var text: String
    @Binding var references: [OpenCodePromptFileReference]
    @ObservedObject var files: OpenCodeRemoteFileStore
    @State private var showingPicker = false
    @State private var preview: OpenCodePromptFileReference?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !references.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(references) { reference in
                            HStack(spacing: 0) {
                                Button { preview = reference } label: {
                                    Label(reference.displayName, systemImage: "doc.text")
                                        .lineLimit(2).truncationMode(.middle)
                                        .frame(maxWidth: 230, minHeight: 44)
                                }
                                .accessibilityLabel("Preview server file \(reference.displayName)")
                                Button { references.removeAll { $0.id == reference.id } } label: {
                                    Image(systemName: "xmark").frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("Remove server file \(reference.displayName)")
                            }
                            .font(.cleanCaption).buttonStyle(.plain).padding(.leading, 10)
                            .background(BYOTBrand.canvas, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                .accessibilityIdentifier("remote-file-context")
            }
            Button { showingPicker = true } label: {
                Label("Server files", systemImage: "at")
                    .font(.cleanCaptionBold).frame(minHeight: 44)
            }
            .accessibilityIdentifier("remote-file-picker")
            if OpenCodeFileMention.query(in: text) != nil {
                if let error = files.suggestionErrorMessage {
                    Text(error).font(.cleanCaption).foregroundStyle(.secondary)
                }
                ForEach(Array(files.suggestions.prefix(4))) { entry in
                    Button { add(files.reference(path: entry.path)) } label: {
                        Label(entry.path, systemImage: "doc.text")
                            .font(.cleanCaption).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("remote-file-suggestion-\(entry.path)")
                    .disabled(files.capabilities?.context != true)
                }
            }
        }
        .onChange(of: files.contextToAdd) { _, reference in
            guard let reference else { return }
            add(reference)
            files.contextToAdd = nil
        }
        .task { await files.loadCapabilities() }
        .task(id: OpenCodeFileMention.query(in: text)) { await files.suggest(query: OpenCodeFileMention.query(in: text)) }
        .sheet(isPresented: $showingPicker) {
            OpenCodeRemoteFilePicker(files: files, initialQuery: OpenCodeFileMention.query(in: text) ?? "", add: add)
        }
        .sheet(item: $preview) { reference in
            NavigationStack {
                OpenCodeRemoteFileReader(files: files, path: reference.path, existingSelection: reference.selection) { updated in
                    references.removeAll { $0.id == reference.id }
                    add(updated)
                    preview = nil
                }
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { preview = nil } } }
            }
        }
    }

    private func add(_ reference: OpenCodePromptFileReference) {
        if !references.contains(where: { $0.fileURL == reference.fileURL && $0.serverID == reference.serverID && $0.workspaceID == reference.workspaceID }) {
            references.append(reference)
        }
        text = OpenCodeFileMention.removingQuery(from: text)
    }
}

struct OpenCodeRemoteFilePicker: View {
    @ObservedObject var files: OpenCodeRemoteFileStore
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var directory = ""
    @State private var showChanges = false
    let add: (OpenCodePromptFileReference) -> Void

    init(files: OpenCodeRemoteFileStore, initialQuery: String = "", add: @escaping (OpenCodePromptFileReference) -> Void) {
        self.files = files
        self.add = add
        _query = State(initialValue: initialQuery)
    }

    private var requestID: String { "\(directory)|\(query)|\(showChanges)" }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(files.scope.serverName).font(.cleanBodySemibold)
                    Text(files.scope.directory).font(.cleanCaption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: { Text("Selected project") }
                Section {
                    Picker("Files", selection: $showChanges) {
                        Text("Browse").tag(false)
                        Text("Changed").tag(true).disabled(files.capabilities?.changes == false)
                    }.pickerStyle(.segmented)
                    if !showChanges, !directory.isEmpty, query.isEmpty {
                        Button("Up one folder", systemImage: "arrow.turn.up.left") {
                            directory = directory.split(separator: "/").dropLast().joined(separator: "/")
                        }
                        Text(directory).font(.cleanCaption).foregroundStyle(.secondary)
                    }
                    if files.isLoading { ProgressView("Loading files") }
                    if let error = files.errorMessage {
                        Text(error).foregroundStyle(.secondary)
                        Button("Retry") { Task { await reload() } }
                    } else if !files.isLoading {
                        if showChanges { changedRows }
                        else { fileRows }
                    }
                } footer: {
                    if files.capabilities?.context == false { Text("This server does not accept file references in prompts.") }
                    if files.capabilities?.changes == false { Text("Changed-file status is unavailable on this server.") }
                }
            }
            .searchable(text: $query, prompt: "Search project files")
            .navigationTitle("Server files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: requestID) {
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(220)) }
                if !Task.isCancelled { await reload() }
            }
            .refreshable { await reload() }
        }
    }

    @ViewBuilder private var fileRows: some View {
        if files.entries.isEmpty {
            ContentUnavailableView(query.isEmpty ? "No files" : "No matches", systemImage: "doc.text.magnifyingglass")
        }
        ForEach(files.entries) { entry in
            if entry.isDirectory {
                Button { directory = entry.path; query = "" } label: { Label(entry.name, systemImage: "folder") }
            } else {
                fileRow(path: entry.path)
            }
        }
    }

    @ViewBuilder private var changedRows: some View {
        if files.changedFiles.isEmpty {
            ContentUnavailableView("No changed files", systemImage: "checkmark.circle")
        }
        ForEach(files.changedFiles.filter { query.isEmpty || $0.file.localizedCaseInsensitiveContains(query) }) { change in
            if change.status == "deleted" {
                VStack(alignment: .leading) {
                    Label(change.file, systemImage: "doc.badge.minus")
                    Text("Deleted · −\(change.deletions)").font(.cleanCaption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    fileRow(path: change.file)
                    Text("\(change.status.capitalized) · +\(change.additions) −\(change.deletions)")
                        .font(.cleanCaption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func fileRow(path: String) -> some View {
        HStack {
            NavigationLink {
                OpenCodeRemoteFileReader(files: files, path: path) { reference in add(reference); dismiss() }
            } label: {
                Label(path, systemImage: "doc.text").lineLimit(2).truncationMode(.middle)
            }
            .accessibilityIdentifier("remote-file-open-\(path)")
            Button { add(files.reference(path: path)); dismiss() } label: {
                Image(systemName: "plus.circle").frame(width: 44, height: 44)
            }.buttonStyle(.borderless)
                .accessibilityLabel("Add \(path) as context")
                .disabled(files.capabilities?.context != true)
        }
    }

    private func reload() async { await files.load(path: directory, query: showChanges ? nil : query, changes: showChanges) }
}

struct OpenCodeRemoteFileReader: View {
    @ObservedObject var files: OpenCodeRemoteFileStore
    let path: String
    let add: (OpenCodePromptFileReference) -> Void
    @State private var firstLine: Int?
    @State private var lastLine: Int?

    init(files: OpenCodeRemoteFileStore, path: String, existingSelection: OpenCodeFileLineRange? = nil,
         add: @escaping (OpenCodePromptFileReference) -> Void) {
        self.files = files; self.path = path; self.add = add
        _firstLine = State(initialValue: existingSelection?.startLine)
        _lastLine = State(initialValue: existingSelection?.endLine)
    }

    private var selection: OpenCodeFileLineRange? {
        guard let firstLine else { return nil }
        return .init(startLine: min(firstLine, lastLine ?? firstLine), endLine: max(firstLine, lastLine ?? firstLine))
    }

    var body: some View {
        VStack(spacing: 0) {
            previewContent
            contextButtons
        }
        .navigationTitle(path.split(separator: "/").last.map(String.init) ?? path)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: path) {
            if files.capabilities == nil { await files.loadCapabilities() }
            await files.read(path: path)
        }
    }

    @ViewBuilder private var previewContent: some View {
        if files.isReading { ProgressView("Reading file").frame(maxHeight: .infinity) }
        else if let error = files.readErrorMessage {
            ContentUnavailableView { Label("Preview unavailable", systemImage: "doc") }
                description: { Text(error) }
                actions: { Button("Retry") { Task { await files.read(path: path) } } }
        } else if let content = files.content, content.path == path {
            if content.text != nil { textPreview(content) }
            else {
                ContentUnavailableView("Binary file", systemImage: "doc", description:
                    Text("\(content.mimeType) · \(ByteCountFormatter.string(fromByteCount: Int64(content.byteCount), countStyle: .file))"))
            }
        }
    }

    private func textPreview(_ content: OpenCodeRemoteFileContent) -> some View {
        VStack(spacing: 0) {
            Text(files.capabilities?.lineSelection == true
                 ? "Tap a line, then another line to select a range."
                 : "This server provides a trimmed preview. Add the whole file as context.")
                .font(.cleanCaption).foregroundStyle(.secondary).padding(10)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(content.lines.enumerated()), id: \.offset) { index, line in
                        lineRow(number: index + 1, text: line)
                    }
                }
            }
            .accessibilityIdentifier("remote-file-reader")
        }
    }

    private func lineRow(number: Int, text: String) -> some View {
        Button { select(line: number) } label: {
            HStack(alignment: .top, spacing: 12) {
                if files.capabilities?.lineSelection == true {
                    Text("\(number)").foregroundStyle(.secondary).frame(minWidth: 40, alignment: .trailing)
                }
                Text(text.isEmpty ? " " : text).foregroundStyle(.primary)
            }
            .font(.system(.footnote, design: .monospaced))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected(number) ? BYOTBrand.accent.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(files.capabilities?.lineSelection != true)
        .accessibilityLabel(files.capabilities?.lineSelection == true ? "Line \(number): \(text)" : text)
        .accessibilityIdentifier("remote-file-line-\(number)")
        .accessibilityAddTraits(isSelected(number) ? [.isSelected] : [])
    }

    private var contextButtons: some View {
        VStack(spacing: 8) {
            if let selection, files.capabilities?.lineSelection == true {
                HStack {
                    Text("Lines \(selection.startLine)–\(selection.endLine)").font(.cleanCaption)
                    Spacer()
                    Button("Clear") { firstLine = nil; lastLine = nil }
                }
                Button("Add selected lines as context") { add(files.reference(path: path, selection: selection)) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("remote-file-add-lines")
            }
            Button("Add whole file as context", systemImage: "plus") { add(files.reference(path: path)) }
                .buttonStyle(.bordered).accessibilityIdentifier("remote-file-add-whole")
        }
        .padding().frame(maxWidth: .infinity)
        .disabled(files.capabilities?.context != true)
    }

    private func select(line: Int) {
        if firstLine == nil || lastLine != nil { firstLine = line; lastLine = nil }
        else { lastLine = line }
    }
    private func isSelected(_ line: Int) -> Bool {
        guard files.capabilities?.lineSelection == true, let selection else { return false }
        return line >= selection.startLine && line <= selection.endLine
    }
}
