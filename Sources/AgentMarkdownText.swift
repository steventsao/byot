import SwiftUI
import UIKit

/// One parsed block in an agent reply. The parser intentionally covers only the
/// shapes agents actually emit (prose, headings, lists, quotes, fenced code,
/// tables) so rendering stays fast and deterministic.
enum AgentMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(items: [String], ordered: Bool)
    case quote(String)
    case codeBlock(language: String?, code: String)
    case table(AgentMarkdownTable)
    case divider
}

/// A GitHub-style pipe table. Rows are padded or cut to the header's width.
struct AgentMarkdownTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    let header: [String]
    let alignments: [Alignment]
    let rows: [[String]]
}

enum AgentMarkdownParser {
    static func parse(_ text: String) -> [AgentMarkdownBlock] {
        let source = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = source.components(separatedBy: "\n")
        var blocks: [AgentMarkdownBlock] = []
        var paragraphLines: [String] = []
        var listItems: [String] = []
        var listIsOrdered = false
        var quoteLines: [String] = []
        var codeLines: [String]?
        var codeLanguage: String?

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            blocks.append(.paragraph(paragraphLines.joined(separator: "\n")))
            paragraphLines = []
        }

        func flushList() {
            guard !listItems.isEmpty else { return }
            blocks.append(.list(items: listItems, ordered: listIsOrdered))
            listItems = []
            listIsOrdered = false
        }

        func flushQuote() {
            guard !quoteLines.isEmpty else { return }
            blocks.append(.quote(quoteLines.joined(separator: "\n")))
            quoteLines = []
        }

        func flushProse() {
            flushParagraph()
            flushList()
            flushQuote()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if codeLines != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.codeBlock(
                        language: codeLanguage,
                        code: (codeLines ?? []).joined(separator: "\n")
                    ))
                    codeLines = nil
                    codeLanguage = nil
                } else {
                    codeLines?.append(line)
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                flushProse()
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                codeLanguage = language.isEmpty ? nil : language
                codeLines = []
                continue
            }

            if trimmed.isEmpty {
                flushProse()
                continue
            }

            // A header row followed by a `|---|---|` delimiter row starts a table;
            // agents summarize with them often, and raw pipes are hard to read.
            if index < lines.count,
               let header = tableCells(trimmed),
               let alignments = tableAlignments(lines[index].trimmingCharacters(in: .whitespaces)),
               alignments.count == header.count {
                flushProse()
                index += 1
                var rows: [[String]] = []
                while index < lines.count,
                      let cells = tableCells(lines[index].trimmingCharacters(in: .whitespaces)) {
                    rows.append(Array((cells + Array(repeating: "", count: header.count)).prefix(header.count)))
                    index += 1
                }
                blocks.append(.table(AgentMarkdownTable(header: header, alignments: alignments, rows: rows)))
                continue
            }

            if isDivider(trimmed) {
                flushProse()
                blocks.append(.divider)
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushProse()
                blocks.append(heading)
                continue
            }

            if let item = parseUnorderedItem(trimmed) {
                flushParagraph()
                flushQuote()
                if listIsOrdered { flushList() }
                listItems.append(item)
                continue
            }

            if let item = parseOrderedItem(trimmed) {
                flushParagraph()
                flushQuote()
                if !listIsOrdered, !listItems.isEmpty { flushList() }
                listIsOrdered = true
                listItems.append(item)
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quoteLines.append(
                    String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                )
                continue
            }

            flushList()
            flushQuote()
            paragraphLines.append(trimmed)
        }

        // An unterminated fence still renders as code — this is the common
        // streaming case where the closing ``` has not arrived yet.
        if let codeLines {
            blocks.append(.codeBlock(
                language: codeLanguage,
                code: codeLines.joined(separator: "\n")
            ))
        }
        flushProse()

        return blocks
    }

    /// The cells of a pipe-table row, or nil when the line isn't one. Escaped
    /// pipes (`\|`) and pipes inside inline code stay in their cell.
    static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for character in line {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                current.append(character)
            } else if character == "|", !inCode {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)
        if line.hasPrefix("|") { cells.removeFirst() }
        if line.hasSuffix("|"), !line.hasSuffix("\\|"), !cells.isEmpty { cells.removeLast() }
        let trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        // A lone pipe in prose isn't a table row.
        guard trimmed.count > 1 || line.hasPrefix("|") else { return nil }
        return trimmed
    }

    private static func tableAlignments(_ line: String) -> [AgentMarkdownTable.Alignment]? {
        guard let cells = tableCells(line), !cells.isEmpty else { return nil }
        var alignments: [AgentMarkdownTable.Alignment] = []
        for cell in cells {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    private static func isDivider(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let markers: Set<Character> = ["-", "*", "_"]
        return line.allSatisfy { markers.contains($0) || $0 == " " }
            && line.contains(where: { markers.contains($0) })
    }

    private static func parseHeading(_ line: String) -> AgentMarkdownBlock? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: level, text: text)
    }

    private static func parseUnorderedItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] {
            if line.hasPrefix(marker) {
                let item = String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                return item.isEmpty ? nil : item
            }
        }
        return nil
    }

    private static func parseOrderedItem(_ line: String) -> String? {
        var index = line.startIndex
        while index < line.endIndex, line[index].isNumber {
            index = line.index(after: index)
        }
        guard index > line.startIndex,
              index < line.endIndex,
              line[index] == "."
        else { return nil }
        let afterDot = line.index(after: index)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let item = String(line[afterDot...]).trimmingCharacters(in: .whitespaces)
        return item.isEmpty ? nil : item
    }
}

/// Renders inline markdown (bold, italic, inline code, links) as a single
/// `AttributedString` so styled segments wrap naturally mid-sentence. Inline
/// code renders as dim monospace without a chip, as in OpenCode's transcript.
enum AgentInlineMarkdown {
    static func attributedString(from source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        var attributed = (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
        attributed.font = Font.cleanBody
        for run in attributed.runs {
            guard run.inlinePresentationIntent?.contains(.code) == true else { continue }
            attributed[run.range].font = Font.cleanMono
            attributed[run.range].foregroundColor = Color.secondary
        }
        return attributed
    }
}

struct AgentMarkdownText: View {
    let text: String
    @State private var selection: AgentTextSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                AgentMarkdownBlockView(block: block)
            }
        }
        .lineSpacing(2)
        .contextMenu {
            Button("Select text", systemImage: "text.cursor") {
                selection = AgentTextSelection(text: text)
            }
            Button("Copy response", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = text
            }
        }
        .accessibilityAction(named: "Select text") {
            selection = AgentTextSelection(text: text)
        }
        .sheet(item: $selection) { AgentTextSelectionSheet(selection: $0) }
    }

    private var blocks: [AgentMarkdownBlock] {
        AgentMarkdownParser.parse(text)
    }
}

private struct AgentMarkdownBlockView: View {
    let block: AgentMarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let text):
            Text(AgentInlineMarkdown.attributedString(from: text))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            Text(AgentInlineMarkdown.attributedString(from: text))
                .font(headingFont(for: level))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 4 : 2)

        case .list(let items, let ordered):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.cleanBody)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(AgentInlineMarkdown.attributedString(from: item))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(BYOTBrand.accent.opacity(0.55))
                    .frame(width: 3)
                Text(AgentInlineMarkdown.attributedString(from: text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .codeBlock(let language, let code):
            AgentCodeBlockView(language: language, code: code)

        case .table(let table):
            AgentMarkdownTableView(table: table)

        case .divider:
            Divider()
                .overlay(BYOTBrand.hairline)
                .padding(.vertical, 2)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            Font.system(.title3, weight: .semibold)
        case 2:
            Font.system(.headline)
        default:
            .cleanBodySemibold
        }
    }
}

/// A pipe table as a grid that scrolls sideways when it's wider than the
/// reply. At accessibility sizes each row becomes a stacked card of
/// “column: value” lines, since the columns can't sit side by side.
private struct AgentMarkdownTableView: View {
    let table: AgentMarkdownTable
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                ScrollView(.horizontal) {
                    grid
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
        .background(BYOTBrand.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(BYOTBrand.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table")
    }

    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    cell(table.header[column], column: column, isHeader: true)
                }
            }
            // The semibold header over a stronger rule; per-cell fills drew
            // as separate tiles rather than one band.
            Rectangle().fill(BYOTBrand.strongHairline).frame(height: 1).gridCellUnsizedAxes(.horizontal)
            ForEach(table.rows.indices, id: \.self) { row in
                if row > 0 { Divider().overlay(BYOTBrand.hairline).gridCellUnsizedAxes(.horizontal) }
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.rows[row][column], column: column, isHeader: false)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func cell(_ text: String, column: Int, isHeader: Bool) -> some View {
        Text(AgentInlineMarkdown.attributedString(from: text))
            .font(isHeader ? .cleanBodySemibold : nil)
            .multilineTextAlignment(textAlignment(column))
            .frame(maxWidth: 260, alignment: frameAlignment(column))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .gridColumnAlignment(horizontalAlignment(column))
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(table.rows.indices, id: \.self) { row in
                if row > 0 { Divider().overlay(BYOTBrand.hairline) }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(table.header.indices, id: \.self) { column in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(AgentInlineMarkdown.attributedString(from: table.header[column]))
                                .font(.cleanCaptionBold)
                                .foregroundStyle(.secondary)
                            Text(AgentInlineMarkdown.attributedString(from: table.rows[row][column]))
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func alignment(_ column: Int) -> AgentMarkdownTable.Alignment {
        column < table.alignments.count ? table.alignments[column] : .leading
    }

    private func horizontalAlignment(_ column: Int) -> HorizontalAlignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignment(column) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct AgentCodeBlockView: View {
    let language: String?
    let code: String
    @State private var showsCopied = false
    @State private var selection: AgentTextSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language?.lowercased() ?? String(localized: "code"))
                    .font(.cleanMono)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    selection = AgentTextSelection(text: code, isCode: true, language: syntaxLanguage)
                } label: {
                    Label("Select code", systemImage: "text.cursor")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.cleanCaptionBold)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
                .accessibilityLabel("Select code")
                Button {
                    copy()
                } label: {
                    Label(showsCopied ? "Copied" : "Copy", systemImage: showsCopied ? "checkmark" : "doc.on.doc")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .font(.cleanCaptionBold)
                .foregroundStyle(showsCopied ? BYOTBrand.accent : Color.secondary)
                .buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(BYOTBrand.hairline)
                    .frame(height: 1)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                BYOTCodeText(code: code, language: syntaxLanguage)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(BYOTBrand.canvas, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(BYOTBrand.hairline, lineWidth: 1)
        }
        .sheet(item: $selection) { AgentTextSelectionSheet(selection: $0) }
    }

    private var syntaxLanguage: BYOTSyntaxLanguage? {
        BYOTSyntaxLanguage(fenceLabel: language)
    }

    private func copy() {
        UIPasteboard.general.string = code
        AgentHaptics.send()
        showsCopied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            showsCopied = false
        }
    }
}
