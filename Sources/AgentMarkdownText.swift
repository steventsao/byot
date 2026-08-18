import SwiftUI
import UIKit

/// One parsed block in an agent reply. The parser intentionally covers only the
/// shapes agents actually emit (prose, headings, lists, quotes, fenced code)
/// so rendering stays fast and deterministic.
enum AgentMarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case list(items: [String], ordered: Bool)
    case quote(String)
    case codeBlock(language: String?, code: String)
    case divider
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

        for line in lines {
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
/// `AttributedString` so styled segments wrap naturally mid-sentence, matching
/// the inline code chips modern agent apps use for file and symbol references.
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
            attributed[run.range].font = .system(size: 15, design: .monospaced)
            attributed[run.range].backgroundColor = UIColor(
                red: 0.54, green: 0.88, blue: 0.70, alpha: 0.12
            )
        }
        return attributed
    }
}

struct AgentMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                AgentMarkdownBlockView(block: block)
            }
        }
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(ordered ? .cleanBody : .cleanBodyBold)
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

        case .divider:
            Divider()
                .overlay(BYOTBrand.hairline)
                .padding(.vertical, 2)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:
            Font.custom("OpenRunde-Bold", size: 22, relativeTo: .title3)
        case 2:
            Font.custom("OpenRunde-Bold", size: 19, relativeTo: .headline)
        default:
            .cleanBodySemibold
        }
    }
}

private struct AgentCodeBlockView: View {
    let language: String?
    let code: String
    @State private var showsCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(language?.lowercased() ?? "code")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(showsCopied ? "Copied" : "Copy", systemImage: showsCopied ? "checkmark" : "doc.on.doc") {
                    copy()
                }
                .labelStyle(.iconOnly)
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
                Text(code)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.primary)
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
