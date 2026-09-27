import SwiftUI

/// Lets transcript rows open the session diff at a specific file.
struct OpenCodeDiffNavigator: Sendable {
    let diffs: [OpenCodeDiff]
    let directory: String
    let open: @MainActor @Sendable (_ diffID: String) -> Void
}

private struct OpenCodeDiffNavigatorKey: EnvironmentKey {
    static let defaultValue: OpenCodeDiffNavigator? = nil
}

extension EnvironmentValues {
    var openCodeDiffNavigator: OpenCodeDiffNavigator? {
        get { self[OpenCodeDiffNavigatorKey.self] }
        set { self[OpenCodeDiffNavigatorKey.self] = newValue }
    }
}

// MARK: - Compaction

/// A full-width rule marking where earlier context was summarized.
struct OpenCodeCompactionDivider: View {
    let presentation: OpenCodeCompactionPresentation

    var body: some View {
        VStack(spacing: BYOTBrand.Space.sm) {
            HStack(spacing: 10) {
                rule
                Label(presentation.title, systemImage: "rectangle.compress.vertical")
                    .font(.cleanCaptionBold)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                rule
            }
            if let detail = presentation.detail {
                Text(detail)
                    .font(.cleanCaption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, BYOTBrand.Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("transcript-compaction")

        if let summary = presentation.summary {
            DisclosureGroup {
                AgentMarkdownText(text: summary)
                    .foregroundStyle(.secondary)
                    .padding(.top, BYOTBrand.Space.xs)
                    .textSelection(.enabled)
            } label: {
                Text("Summary")
                    .font(.cleanMono)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Compaction summary")
            }
            .disclosureGroupStyle(OpenCodeInlineDisclosureStyle())
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(BYOTBrand.hairline)
            .frame(height: 1)
            .frame(minWidth: 16)
            .accessibilityHidden(true)
    }
}

// MARK: - Retry

struct OpenCodeRetryNotice: View {
    let presentation: OpenCodeRetryPresentation
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: BYOTBrand.Space.sm) {
            Image(systemName: "arrow.clockwise")
                .font(.cleanCaptionBold)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.cleanCaptionBold)
                    .foregroundStyle(.primary)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { if presentation.detail != nil { isExpanded.toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("transcript-retry")
    }
}

// MARK: - Quiet rows

/// Agent mention inside a prompt.
struct OpenCodeAgentMentionChip: View {
    let presentation: OpenCodeSwitchPresentation

    var body: some View {
        // Reads as the mention the user typed, without the icon's gap.
        Text("@" + presentation.title)
            .font(.cleanCaptionBold)
            .foregroundStyle(BYOTBrand.accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(BYOTBrand.accentSoft, in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(presentation.accessibilityLabel)
    }
}

/// A monospace marker row aligned with the tool rows' glyph column.
struct OpenCodeTranscriptMarkerRow: View {
    let symbol: String
    let title: String
    let accessibilityLabel: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.cleanMono)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Step summary

struct OpenCodeStepSummaryView: View {
    let summary: OpenCodeStepSummary

    var body: some View {
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: BYOTBrand.Space.md, verticalSpacing: 6) {
                ForEach(summary.details) { detail in
                    GridRow {
                        Text(detail.label)
                            .foregroundStyle(.secondary)
                        Text(detail.value)
                            .foregroundStyle(.primary)
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.cleanMono)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BYOTBrand.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, BYOTBrand.Space.xs)
        } label: {
            Text([summary.title, summary.outcome].compactMap { $0 }.joined(separator: " · "))
                .font(.cleanMono)
                .foregroundStyle(summary.outcome == nil ? .tertiary : .secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(summary.accessibilityLabel)
                .accessibilityIdentifier("transcript-step-summary")
        }
        .disclosureGroupStyle(OpenCodeInlineDisclosureStyle())
    }
}

// MARK: - Patch

/// The files one step changed. Each file with a session diff opens it.
struct OpenCodePatchPartView: View {
    let files: [String]
    @Environment(\.openCodeDiffNavigator) private var navigator
    @State private var isExpanded: Bool

    init(files: [String]) {
        self.files = files
        _isExpanded = State(initialValue: files.count <= 3)
    }

    private var resolved: [OpenCodePatchFile] {
        OpenCodePatchFile.resolve(files, directory: navigator?.directory ?? "", diffs: navigator?.diffs ?? [])
    }

    var body: some View {
        let resolved = resolved
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(resolved) { file in
                    row(file)
                }
            }
            .padding(.top, 2)
        } label: {
            Text("Changed \(resolved.count) file\(resolved.count == 1 ? "" : "s")")
                .font(.cleanMono)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("transcript-patch")
        }
        .disclosureGroupStyle(OpenCodeInlineDisclosureStyle())
    }

    @ViewBuilder
    private func row(_ file: OpenCodePatchFile) -> some View {
        if let diffID = file.diffID, let navigator {
            Button {
                navigator.open(diffID)
            } label: {
                label(file, linked: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.displayPath)
            .accessibilityHint("Opens this file’s changes")
        } else {
            label(file, linked: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(file.displayPath)
        }
    }

    private func label(_ file: OpenCodePatchFile, linked: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: BYOTBrand.Space.sm) {
            Image(systemName: "doc.text")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            (Text(file.filename).foregroundStyle(linked ? BYOTBrand.accent : Color.primary)
                + Text(file.folder.map { "  " + $0 } ?? "").foregroundStyle(.tertiary))
                .font(.cleanMono)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if linked {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

// MARK: - Inline images

/// Adjacent image parts as thumbnails; tapping one opens the full-screen viewer.
/// An image that can't be loaded or decoded, for example because the server
/// can't read files, falls back to the attachment row.
struct OpenCodeInlineImageGallery: View {
    let parts: [OpenCodePart]
    @Environment(\.openCodeRemoteFiles) private var files
    @State private var selection: OpenCodeImageViewerSelection?
    @State private var failed: Set<String> = []

    private var items: [OpenCodeInlineImageItem] {
        parts.compactMap { part in
            guard !failed.contains(part.id) else { return nil }
            return OpenCodeInlineImage.resolve(part, scope: files?.scope).map {
                OpenCodeInlineImageItem(id: part.id, name: OpenCodeInlineImage.displayName(for: part), source: $0)
            }
        }
    }

    var body: some View {
        let items = items
        let fallbacks = parts.filter { part in !items.contains { $0.id == part.id } }
        VStack(alignment: .leading, spacing: BYOTBrand.Space.sm) {
            if items.count == 1, let item = items.first {
                thumbnail(item, index: 0, single: true)
            } else if !items.isEmpty {
                OpenCodeFlowLayout(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        thumbnail(item, index: index, single: false)
                    }
                }
            }
            ForEach(fallbacks) { part in
                OpenCodeRemoteFilePartView(part: part)
            }
        }
        .fullScreenCover(item: $selection) { selection in
            OpenCodeImageViewer(items: items, initialIndex: selection.index, files: files)
        }
    }

    private func thumbnail(_ item: OpenCodeInlineImageItem, index: Int, single: Bool) -> some View {
        Button {
            selection = OpenCodeImageViewerSelection(index: index)
        } label: {
            OpenCodeInlineImageThumbnail(item: item, files: files, single: single) {
                failed.insert(item.id)
            }
        }
        .buttonStyle(.agentPressFeedback)
        .accessibilityLabel("Image, \(item.name)")
        .accessibilityHint("Opens full screen")
        .accessibilityIdentifier("transcript-image")
    }
}

struct OpenCodeImageViewerSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct OpenCodeInlineImageThumbnail: View {
    let item: OpenCodeInlineImageItem
    let files: OpenCodeRemoteFileStore?
    let single: Bool
    let onFailure: () -> Void
    @State private var image: UIImage?

    private static let tile: CGFloat = 88
    private static let maximum: CGFloat = 240

    var body: some View {
        Group {
            if let image {
                if single {
                    // Small images such as icons keep their own size.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: min(Self.maximum, image.size.width),
                               maxHeight: min(Self.maximum, image.size.height))
                } else {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.tile, height: Self.tile)
                        .clipped()
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BYOTBrand.hairline, lineWidth: 1)
        }
        .task(id: item.id) {
            do {
                image = try await OpenCodeInlineImageLoader.shared.image(
                    for: item, maxPixelSize: OpenCodeInlineImageLoader.thumbnailPixels, files: files)
            } catch is CancellationError {
            } catch {
                // Scrolling away cancels the load; only a real failure falls back.
                if !Task.isCancelled { onFailure() }
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            BYOTBrand.surface
            ProgressView()
        }
        .frame(width: single ? 180 : Self.tile, height: single ? 135 : Self.tile)
    }
}

/// Wraps children onto new lines, sized to its content rather than the
/// proposal, so a short run of thumbnails stays compact inside a prompt.
struct OpenCodeFlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
