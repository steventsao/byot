import SwiftUI

struct OpenCodeFileBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: OpenCodeFileBrowserStore
    private let client: OpenCodeClient

    init(
        client: OpenCodeClient,
        directory: String,
        workspace: String?
    ) {
        self.client = client
        _store = StateObject(
            wrappedValue: OpenCodeFileBrowserStore(
                client: client,
                directory: directory,
                workspace: workspace
            )
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading && store.entries.isEmpty {
                    BYOTActivityView(
                        .loading,
                        title: "Loading project files",
                        detail: "Reading the OpenCode workspace.",
                        layout: .blocking
                    )
                } else if shouldPromptForSearch {
                    ContentUnavailableView(
                        "Search project files",
                        systemImage: "magnifyingglass",
                        description: Text(
                            store.policy?.searchOnlyDescription
                                ?? "Enter a filename to search this project."
                        )
                    )
                } else {
                    fileList
                }
            }
            .navigationTitle(OpenCodeFileBrowserPath.title(for: store.currentPath))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $store.query, prompt: "Find files")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if store.policy?.canListChanges == true,
                       store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Picker("File view", selection: $store.mode) {
                            ForEach(OpenCodeFileBrowserMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.start() }
            .task(id: store.query) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                    try Task.checkCancellation()
                } catch {
                    return
                }
                await store.search()
            }
        }
    }

    private var shouldPromptForSearch: Bool {
        store.policy?.canBrowseTree == false
            && store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var fileList: some View {
        List {
            if let errorMessage = store.errorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                        .listRowInsets(EdgeInsets())
                }
            }
            if store.mode == .browse,
               store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !store.currentPath.isEmpty {
                Button {
                    Task { await store.goUp() }
                } label: {
                    Label("Parent folder", systemImage: "arrow.up.left")
                }
            }
            Section(sectionTitle) {
                if store.visibleEntries.isEmpty, !store.isSearching {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.visibleEntries) { entry in
                    entryRow(entry)
                }
            }
        }
        .overlay {
            if store.isSearching {
                ProgressView("Searching")
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: OpenCodeFileEntry) -> some View {
        if entry.isDirectory {
            Button {
                Task { await store.open(entry) }
            } label: {
                OpenCodeFileEntryLabel(entry: entry, status: nil)
            }
            .buttonStyle(.plain)
            .disabled(store.policy?.canBrowseTree != true)
        } else {
            NavigationLink {
                OpenCodeFileReaderView(
                    client: client,
                    directory: store.directory,
                    workspace: store.workspace,
                    path: entry.path
                )
            } label: {
                OpenCodeFileEntryLabel(
                    entry: entry,
                    status: store.statusByPath[entry.path]
                )
            }
        }
    }

    private var sectionTitle: String {
        if !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Search results"
        }
        return store.mode == .changes ? "Changed files" : "Files"
    }

    private var emptyMessage: String {
        if !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No matching files"
        }
        return store.mode == .changes ? "No changed files" : "This folder is empty"
    }
}

private struct OpenCodeFileEntryLabel: View {
    let entry: OpenCodeFileEntry
    let status: OpenCodeFileStatus?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(entry.isDirectory ? BYOTBrand.accent : .secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.cleanBody)
                    .foregroundStyle(entry.ignored ? .secondary : .primary)
                if entry.path != entry.name {
                    Text(entry.path)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let status {
                Text("+\(status.additions) −\(status.deletions)")
                    .font(.cleanCaptionBold)
                    .foregroundStyle(BYOTBrand.accent)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(entry.ignored ? "Ignored" : "")
    }
}

private struct OpenCodeFileReaderView: View {
    @StateObject private var store: OpenCodeFileReaderStore

    init(
        client: OpenCodeClient,
        directory: String,
        workspace: String?,
        path: String
    ) {
        _store = StateObject(
            wrappedValue: OpenCodeFileReaderStore(
                client: client,
                directory: directory,
                workspace: workspace,
                path: path
            )
        )
    }

    var body: some View {
        Group {
            if store.isLoading {
                BYOTActivityView(
                    .loading,
                    title: "Reading file",
                    detail: store.path,
                    layout: .blocking
                )
            } else if let errorMessage = store.errorMessage {
                ContentUnavailableView(
                    "Couldn’t read file",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage.agentDisplayErrorText)
                )
            } else if let reason = store.presentation.unavailableReason {
                ContentUnavailableView(
                    "File reading unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(reason)
                )
            } else if let description = store.presentation.binaryDescription {
                ContentUnavailableView(
                    "Binary file",
                    systemImage: "doc.badge.ellipsis",
                    description: Text(description)
                )
            } else {
                codeView
            }
        }
        .navigationTitle(OpenCodeFileBrowserPath.title(for: store.path))
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .accessibilityLabel(store.presentation.accessibilitySummary)
    }

    private var codeView: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(store.presentation.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(String(line.number))
                            .foregroundStyle(.tertiary)
                            .frame(width: 42, alignment: .trailing)
                            .accessibilityHidden(true)
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(.primary)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 19)
                }
            }
            .padding(.vertical, 14)
            .padding(.trailing, 16)
        }
        .background(BYOTBrand.canvas)
        .textSelection(.enabled)
    }
}
