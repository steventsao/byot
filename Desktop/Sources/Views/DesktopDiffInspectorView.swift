import SwiftUI

struct DesktopDiffInspectorView: View {
    let onClose: () -> Void

    @StateObject private var store: OpenCodeDiffReviewStore
    @State private var selectedFileID: String?

    init(client: OpenCodeClient, session: OpenCodeSession, directory: String, onClose: @escaping () -> Void) {
        self.onClose = onClose
        _store = StateObject(
            wrappedValue: OpenCodeDiffReviewStore(
                service: OpenCodeDiffReviewService(client: client, session: session, directory: directory),
                directory: directory
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(DesktopBrand.canvas)
        .task {
            await store.open(OpenCodeDiffReviewRequest(), latestTurnMessageID: nil, sessionDiffs: [])
            selectedFileID = store.files.first?.id
        }
        .onChange(of: store.files) { _, files in
            if selectedFileID == nil || !files.contains(where: { $0.id == selectedFileID }) {
                selectedFileID = files.first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Changes", systemImage: "doc.text.magnifyingglass")
                .font(.callout.weight(.semibold))

            if !store.sources.isEmpty {
                Picker("Source", selection: Binding(
                    get: { store.source ?? store.sources.first ?? .uncommitted },
                    set: { next in Task { await store.select(next) } }
                )) {
                    ForEach(store.sources) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }

            Spacer()

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh diffs")

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(DesktopBrand.surface)
    }

    @ViewBuilder
    private var content: some View {
        switch store.phase {
        case .idle, .loading:
            ProgressView("Loading changes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let reason):
            ContentUnavailableView("No Diffs", systemImage: "checkmark.circle", description: Text(reason))
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await store.refresh() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if store.files.isEmpty {
                ContentUnavailableView(
                    store.source?.emptyTitle ?? "No Changes",
                    systemImage: "checkmark.circle",
                    description: Text("Edited files will appear here as OpenCode works.")
                )
            } else {
                VStack(spacing: 0) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(store.files) { file in
                                let isSelected = file.id == selectedFileID
                                Button {
                                    selectedFileID = file.id
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: file.status.symbol)
                                            .font(.caption2)
                                        Text(file.name)
                                            .font(.caption.weight(.medium))
                                        Text("+\(file.additions)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.green)
                                        Text("-\(file.deletions)")
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(.red)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(isSelected ? DesktopBrand.selectedSurface : DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(8)
                    }
                    Divider()

                    if let file = store.files.first(where: { $0.id == selectedFileID }) ?? store.files.first {
                        patchView(for: file)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func patchView(for file: OpenCodeDiffFile) -> some View {
        if let patch = file.patch, !patch.isEmpty {
            let parsed = OpenCodeUnifiedDiff.parse(patch)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(parsed.hunks) { hunk in
                        Text(hunk.title)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(DesktopBrand.surface)

                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 8) {
                                Text(line.oldNumber.map(String.init) ?? "")
                                    .frame(width: 34, alignment: .trailing)
                                    .foregroundStyle(.tertiary)
                                Text(line.newNumber.map(String.init) ?? "")
                                    .frame(width: 34, alignment: .trailing)
                                    .foregroundStyle(.tertiary)
                                Text(prefix(for: line.kind) + line.text)
                                    .textSelection(.enabled)
                            }
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 1.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line.kind))
                        }
                    }
                }
            }
            .background(DesktopBrand.elevatedSurface)
        } else {
            ContentUnavailableView("Patch omitted", systemImage: "doc", description: Text(file.path))
        }
    }

    private func prefix(for kind: OpenCodeUnifiedDiff.Line.Kind) -> String {
        switch kind {
        case .addition: "+"
        case .deletion: "-"
        case .context: " "
        }
    }

    private func background(for kind: OpenCodeUnifiedDiff.Line.Kind) -> Color {
        switch kind {
        case .addition: DesktopBrand.additionBackground
        case .deletion: DesktopBrand.deletionBackground
        case .context: .clear
        }
    }
}
