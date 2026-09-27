import SwiftUI
import UIKit

/// Opens the reviewer from transcript rows without threading the session store through them.
struct OpenCodeReviewChangesAction: Sendable {
    let run: @MainActor @Sendable (OpenCodeDiffReviewRequest) -> Void

    @MainActor func callAsFunction(_ request: OpenCodeDiffReviewRequest) { run(request) }
}

private struct OpenCodeReviewChangesKey: EnvironmentKey {
    static var defaultValue: OpenCodeReviewChangesAction? { nil }
}

extension EnvironmentValues {
    var openCodeReviewChanges: OpenCodeReviewChangesAction? {
        get { self[OpenCodeReviewChangesKey.self] }
        set { self[OpenCodeReviewChangesKey.self] = newValue }
    }
}

extension BYOTBrand {
    /// Diff ink: the brand green for additions and a matched red for deletions,
    /// both legible on the canvas in light and dark appearance.
    static var diffAddition: Color { accent }
    static var diffDeletion: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 1.00, green: 0.56, blue: 0.53, alpha: 1)
                : UIColor(red: 0.70, green: 0.13, blue: 0.11, alpha: 1)
        })
    }

    static func diffFill(_ kind: OpenCodeUnifiedDiff.Line.Kind, contrast: ColorSchemeContrast) -> Color {
        let strength = contrast == .increased ? 0.24 : 0.13
        switch kind {
        case .addition: return diffAddition.opacity(strength)
        case .deletion: return diffDeletion.opacity(strength)
        case .context: return .clear
        }
    }

    static func diffInk(_ status: OpenCodeDiffFileStatus) -> Color {
        switch status {
        case .added: diffAddition
        case .deleted: diffDeletion
        case .modified: mutedInk
        }
    }
}

// MARK: - File list

struct OpenCodeDiffReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: OpenCodeDiffReviewStore
    let request: OpenCodeDiffReviewRequest
    let latestTurnMessageID: String?
    let sessionDiffs: [OpenCodeDiff]
    @State private var path: [String] = []
    @State private var didOpenRequestedFile = false
    /// Keeps state overlays below the source picker; the menu picker grows with Dynamic Type.
    @ScaledMetric(relativeTo: .body) private var pickerClearance: CGFloat = 72

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if store.sources.count > 1 {
                    Section { sourcePicker }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                if !store.files.isEmpty {
                    Section {
                        ForEach(store.files) { file in
                            NavigationLink(value: file.id) { OpenCodeDiffFileRow(file: file) }
                                .accessibilityLabel(file.accessibilitySummary)
                                .accessibilityHint("Shows this file’s changes")
                                .accessibilityIdentifier("diff-file-\(file.path)")
                        }
                    } header: {
                        summary
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            if let caption { Text(caption) }
                            // A failed pull to refresh keeps the last list; say it may be stale.
                            if case .failed(let message) = store.phase {
                                Label("Couldn’t refresh. \(message.agentDisplayErrorText)",
                                      systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(BYOTBrand.diffDeletion)
                            }
                        }
                        .font(.cleanCaption)
                    }
                }
            }
            .overlay {
                stateOverlay.padding(.top, store.sources.count > 1 ? pickerClearance : 0)
            }
            .refreshable { await store.refresh(latestTurnMessageID: latestTurnMessageID) }
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: String.self) { fileID in
                OpenCodeDiffFileView(store: store, initialFileID: fileID)
            }
        }
        .task {
            await store.open(request, latestTurnMessageID: latestTurnMessageID, sessionDiffs: sessionDiffs)
            openRequestedFile()
        }
        .onChange(of: sessionDiffs) { _, diffs in store.updateSessionDiffs(diffs) }
        .accessibilityIdentifier("diff-review")
    }

    /// Segments truncate at accessibility sizes; a menu keeps every title whole.
    @ViewBuilder private var sourcePicker: some View {
        if dynamicTypeSize.isAccessibilitySize {
            sourcePicker(.menu)
        } else {
            sourcePicker(.segmented)
        }
    }

    private func sourcePicker(_ style: some PickerStyle) -> some View {
        Picker("Compare", selection: Binding(
            get: { store.source ?? store.sources.first ?? .turn },
            set: { value in Task { await store.select(value) } }
        )) {
            ForEach(store.sources) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(style)
        .accessibilityIdentifier("diff-source")
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Text(store.files.count == 1 ? "1 file" : "\(store.files.count) files")
            Spacer(minLength: 8)
            OpenCodeDiffCounts(additions: store.additions, deletions: store.deletions)
        }
        .font(.cleanCaptionBold)
        .textCase(nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(store.files.count == 1
            ? "1 changed file, \(store.additions) additions, \(store.deletions) deletions"
            : "\(store.files.count) changed files, \(store.additions) additions, \(store.deletions) deletions")
    }

    private var caption: String? {
        switch store.source {
        case .turn:
            store.isPinnedTurn ? String(localized: "Files changed by the selected prompt.") : String(localized: "Files changed by your latest prompt.")
        case .session:
            String(localized: "Files changed during this session.")
        case .uncommitted:
            store.branch?.current.map { String(localized: "Uncommitted changes on \($0).") } ?? String(localized: "Uncommitted changes in the working tree.")
        case .branch:
            if let current = store.branch?.current, let base = store.branch?.defaultBranch {
                String(localized: "\(current) compared with \(base).")
            } else { nil }
        case nil:
            nil
        }
    }

    @ViewBuilder private var stateOverlay: some View {
        switch store.phase {
        case .idle, .loading:
            if store.files.isEmpty {
                BYOTActivityView(.loading, title: String(localized: "Loading changes"), layout: .blocking)
            }
        case .failed(let message) where store.files.isEmpty:
            ContentUnavailableView {
                Label("Couldn’t load changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message.agentDisplayErrorText)
            } actions: {
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { await store.refresh(latestTurnMessageID: latestTurnMessageID) }
                }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(BYOTBrand.accentInk)
            }
        case .unavailable(let reason):
            ContentUnavailableView("Changes unavailable", systemImage: "plusminus", description: Text(reason))
        case .loaded where store.files.isEmpty:
            ContentUnavailableView {
                Label(store.source?.emptyTitle ?? String(localized: "No changes"), systemImage: "checkmark.circle")
            } description: {
                if let caption { Text(caption) }
            }
        default:
            EmptyView()
        }
    }

    /// A transcript patch row naming one file opens straight into that file.
    private func openRequestedFile() {
        guard !didOpenRequestedFile else { return }
        didOpenRequestedFile = true
        guard request.files.count == 1, let requested = request.files.first else { return }
        let match = store.files.first { $0.path == requested || requested.hasSuffix("/" + $0.path) }
        if let match { path = [match.id] }
    }
}

private struct OpenCodeDiffFileRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let file: OpenCodeDiffFile

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                // At accessibility sizes the icon moves beside the counts so the
                // name keeps the row's full width instead of breaking mid-word.
                if !dynamicTypeSize.isAccessibilitySize { statusIcon }
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.cleanBodySemibold)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let folder = file.folder {
                        Text(folder)
                            .font(.cleanCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                            .truncationMode(.head)
                    }
                }
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if dynamicTypeSize.isAccessibilitySize { statusIcon }
                OpenCodeDiffCounts(additions: file.additions, deletions: file.deletions, showsBar: true)
                    .font(.cleanCaptionBold)
            }
        }
        .frame(minHeight: 44)
    }

    private var statusIcon: some View {
        Image(systemName: file.status.symbol)
            .foregroundStyle(BYOTBrand.diffInk(file.status))
            .accessibilityHidden(true)
    }
}

/// `+12 −3` with GitHub's five-block proportion bar.
struct OpenCodeDiffCounts: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let additions: Int
    let deletions: Int
    var showsBar = false

    var body: some View {
        HStack(spacing: 6) {
            // Zero counts recede so the side that changed reads first.
            Text("+\(additions)").foregroundStyle(additions > 0 ? BYOTBrand.diffAddition : BYOTBrand.mutedInk)
            Text("−\(deletions)").foregroundStyle(deletions > 0 ? BYOTBrand.diffDeletion : BYOTBrand.mutedInk)
            if showsBar && !dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: 2) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 7, height: 7)
                    }
                }
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) additions, \(deletions) deletions")
    }

    private var blocks: [Color] {
        let total = additions + deletions
        guard total > 0 else { return Array(repeating: BYOTBrand.hairline, count: 5) }
        var added = Int((Double(additions) / Double(total) * 5).rounded())
        if additions > 0 { added = max(added, 1) }
        if deletions > 0 { added = min(added, 4) }
        return (0..<5).map { $0 < added ? BYOTBrand.diffAddition : BYOTBrand.diffDeletion }
    }
}

// MARK: - File diff

private enum OpenCodeDiffMetrics {
    /// Advance of one SF Mono column at the footnote style's default 13pt size.
    static let columnWidth: CGFloat = ("0" as NSString)
        .size(withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).width
}

struct OpenCodeDiffFileView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @ObservedObject var store: OpenCodeDiffReviewStore
    @State private var fileID: String
    @State private var parsed: OpenCodeUnifiedDiff?
    @State private var rows: [OpenCodeDiffRow] = []
    @State private var columns = 0
    @State private var expandedGaps: Set<String> = []
    @AppStorage("byot.diff.wrap-lines") private var wrapsLines = false
    @ScaledMetric(relativeTo: .footnote) private var columnWidth = OpenCodeDiffMetrics.columnWidth

    init(store: OpenCodeDiffReviewStore, initialFileID: String) {
        self.store = store
        _fileID = State(initialValue: initialFileID)
    }

    private var file: OpenCodeDiffFile? { store.files.first { $0.id == fileID } }
    private var index: Int? { store.index(of: fileID) }

    var body: some View {
        Group {
            if let file {
                VStack(spacing: 0) {
                    header(file)
                    Divider()
                    content(file)
                }
            } else {
                ContentUnavailableView("File no longer changed", systemImage: "doc",
                                       description: Text("Refresh the list to see the current changes."))
            }
        }
        .background(BYOTBrand.canvas)
        .navigationTitle(file?.name ?? String(localized: "Changes"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            ForEach(store.files) { item in
                Button { show(item.id) } label: {
                    Label(item.path, systemImage: item.id == fileID ? "checkmark" : item.status.symbol)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $wrapsLines) { Label("Wrap lines", systemImage: "text.word.spacing") }
                    if let patch = file?.patch, !patch.isEmpty {
                        Button("Copy patch", systemImage: "doc.on.doc") { UIPasteboard.general.string = patch }
                    }
                    if hasCollapsedGaps || !expandedGaps.isEmpty {
                        Button(hasCollapsedGaps ? "Show all lines" : "Collapse unchanged lines",
                               systemImage: hasCollapsedGaps ? "arrow.up.and.down" : "arrow.down.right.and.arrow.up.left") {
                            toggleAllGaps()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(BYOTBrand.chromeTint)
                .accessibilityLabel("File options")
                .accessibilityIdentifier("diff-file-options")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button { step(-1) } label: { Label("Previous file", systemImage: "chevron.up") }
                    .disabled((index ?? 0) == 0)
                    .accessibilityIdentifier("diff-previous-file")
                Spacer()
                if let index {
                    Text("\(index + 1) of \(store.files.count)")
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        // The bar would otherwise cut it to "1…" at accessibility sizes.
                        .fixedSize()
                        .accessibilityLabel("File \(index + 1) of \(store.files.count)")
                }
                Spacer()
                Button { step(1) } label: { Label("Next file", systemImage: "chevron.down") }
                    .disabled((index ?? store.files.count) >= store.files.count - 1)
                    .accessibilityIdentifier("diff-next-file")
            }
        }
        // Keyed by the whole file so a refresh that edits a patch in place reparses it.
        .task(id: file) { await parse() }
    }

    private func header(_ file: OpenCodeDiffFile) -> some View {
        // At accessibility sizes the path takes its own lines above the counts.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(file.status.title, systemImage: file.status.symbol)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(BYOTBrand.diffInk(file.status))
                Text(file.path)
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            OpenCodeDiffCounts(additions: file.additions, deletions: file.deletions)
                .font(.cleanCaptionBold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.path), \(file.status.title), \(file.additions) additions, \(file.deletions) deletions")
    }

    @ViewBuilder private func content(_ file: OpenCodeDiffFile) -> some View {
        if let parsed {
            if parsed.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc.zipper",
                                       description: Text("OpenCode reports this file changed, but it can’t be shown as text."))
            } else if parsed.hunks.isEmpty {
                ContentUnavailableView("No line changes", systemImage: "doc.text",
                                       description: Text(file.patch?.isEmpty == false
                                           ? "Only file metadata changed."
                                           : "OpenCode didn’t include a patch for this file."))
            } else {
                lines
            }
        } else {
            BYOTActivityView(.loading, title: String(localized: "Preparing diff"), layout: .blocking)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var gutterDigits: Int { max(String(parsed?.maximumLineNumber ?? 0).count, 2) }

    private var lines: some View {
        GeometryReader { proxy in
            // The gutter holds two line-number columns, a sign column and padding.
            let gutter = CGFloat(gutterDigits * 2 + 4) * columnWidth + 24
            let contentWidth = wrapsLines ? proxy.size.width
                : max(proxy.size.width, gutter + CGFloat(columns + 1) * columnWidth + 16)
            ScrollView(wrapsLines ? .vertical : [.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row, viewportWidth: proxy.size.width)
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(.bottom, 16)
                // Short patches start at the top instead of centering in the viewport.
                .frame(minHeight: proxy.size.height, alignment: .top)
            }
            .id("\(fileID)|\(wrapsLines)")
            .accessibilityIdentifier("diff-lines")
        }
    }

    @ViewBuilder private func rowView(_ row: OpenCodeDiffRow, viewportWidth: CGFloat) -> some View {
        switch row {
        case .hunk(_, let title):
            Text(title)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(wrapsLines ? nil : 1)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BYOTBrand.surface)
                .accessibilityLabel(hunkLabel(title))
                .accessibilityAddTraits(.isHeader)
        case .gap(let id, let hidden):
            Button { expand(id) } label: {
                Label(hidden == 1 ? "Show 1 unchanged line" : "Show \(hidden) unchanged lines", systemImage: "arrow.up.and.down")
                    .font(.cleanCaption)
                    .foregroundStyle(BYOTBrand.interactionTint)
                    .padding(.horizontal, 12)
                    .frame(width: viewportWidth, alignment: .leading)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BYOTBrand.surface.opacity(0.6))
            .accessibilityIdentifier("diff-gap-\(id)")
        case .line(_, let line):
            OpenCodeDiffLineRow(line: line, digits: gutterDigits, wraps: wrapsLines, contrast: contrast)
        }
    }

    private var hasCollapsedGaps: Bool { rows.contains { if case .gap = $0 { true } else { false } } }

    private func hunkLabel(_ title: String) -> String {
        guard let hunk = parsed?.hunks.first(where: { title.hasPrefix($0.header) }) else { return title }
        let start = hunk.newCount > 0 ? hunk.newStart : hunk.oldStart
        return [String(localized: "Change at line \(String(start))"), hunk.section].compactMap { $0 }.joined(separator: ", ")
    }

    private func parse() async {
        guard let patch = file?.patch else {
            parsed = OpenCodeUnifiedDiff()
            rows = []
            columns = 0
            return
        }
        expandedGaps = []
        // Width covers every line, collapsed or not, so expanding a gap never re-lays the page.
        let (result, width) = await Task.detached(priority: .userInitiated) {
            let diff = OpenCodeUnifiedDiff.parse(patch)
            return (diff, OpenCodeDiffRow.columns(in: diff))
        }.value
        guard !Task.isCancelled else { return }
        parsed = result
        columns = width
        rebuildRows()
    }

    private func rebuildRows() {
        guard let parsed else { rows = []; return }
        rows = OpenCodeDiffRow.rows(for: parsed, expandedGaps: expandedGaps)
    }

    private func expand(_ id: String) {
        expandedGaps.insert(id)
        withAnimation(reduceMotion ? nil : .easeOut(duration: BYOTBrand.Motion.quick)) { rebuildRows() }
    }

    private func toggleAllGaps() {
        guard let parsed else { return }
        if hasCollapsedGaps {
            // Every gap id is stable, so expanding them all reveals the full patch.
            let everything = OpenCodeDiffRow.rows(for: parsed, expandedGaps: [])
            expandedGaps.formUnion(everything.compactMap { if case .gap(let id, _) = $0 { id } else { nil } })
        } else {
            expandedGaps = []
        }
        rebuildRows()
    }

    private func show(_ id: String) {
        guard id != fileID else { return }
        parsed = nil
        rows = []
        fileID = id
    }

    private func step(_ offset: Int) {
        guard let index else { return }
        let next = index + offset
        guard store.files.indices.contains(next) else { return }
        show(store.files[next].id)
        UIAccessibility.post(notification: .screenChanged, argument: store.files[next].path)
    }
}

private struct OpenCodeDiffLineRow: View {
    let line: OpenCodeUnifiedDiff.Line
    let digits: Int
    let wraps: Bool
    let contrast: ColorSchemeContrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(number(line.oldNumber) + " " + number(line.newNumber))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
            Text(sign)
                .foregroundStyle(signInk)
                .padding(.horizontal, 6)
                .fontWeight(.semibold)
            Text(text)
                .foregroundStyle(.primary)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: true)
                .padding(.trailing, 12)
        }
        .font(.system(.footnote, design: .monospaced))
        .padding(.vertical, 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BYOTBrand.diffFill(line.kind, contrast: contrast))
        .contextMenu {
            Button("Copy line", systemImage: "doc.on.doc") { UIPasteboard.general.string = line.text }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAction(named: "Copy line") { UIPasteboard.general.string = line.text }
    }

    private var text: String {
        let value = OpenCodeDiffRow.displayText(line.text)
        return value.isEmpty ? " " : value
    }

    private var sign: String {
        switch line.kind {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        }
    }

    private var signInk: Color {
        switch line.kind {
        case .addition: BYOTBrand.diffAddition
        case .deletion: BYOTBrand.diffDeletion
        case .context: .secondary
        }
    }

    private func number(_ value: Int?) -> String {
        let text = value.map(String.init) ?? ""
        return String(repeating: " ", count: max(digits - text.count, 0)) + text
    }

    private var accessibilityLabel: String {
        let content = line.text.trimmingCharacters(in: .whitespaces).isEmpty ? String(localized: "blank") : line.text
        let suffix = line.missingNewline ? String(localized: ", no newline at end of file") : ""
        switch line.kind {
        case .addition: return String(localized: "Added line \(String(line.newNumber ?? 0)): \(content)\(suffix)")
        case .deletion: return String(localized: "Removed line \(String(line.oldNumber ?? 0)): \(content)\(suffix)")
        case .context: return String(localized: "Line \(String(line.newNumber ?? 0)): \(content)\(suffix)")
        }
    }
}
