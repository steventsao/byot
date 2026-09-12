import SwiftUI
import UIKit

/// Capture the response on opening so streaming cannot move an active selection.
struct AgentTextSelection: Identifiable {
    let id = UUID()
    let text: String
    var isCode = false
}

struct AgentTextSelectionSheet: View {
    let selection: AgentTextSelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AgentSelectableText(text: selection.text, isCode: selection.isCode)
                .navigationTitle(selection.isCode ? "Select code" : "Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Copy all", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = selection.text
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

struct AgentSelectableText: UIViewRepresentable {
    let text: String
    var isCode = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> UITextView {
        Self.makeTextView()
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let content = AgentSelectionDocument.render(text, isCode: isCode)
        guard !view.attributedText.isEqual(to: content) else { return }
        let selectedRange = view.selectedRange
        let offset = view.contentOffset
        view.attributedText = content
        if NSMaxRange(selectedRange) <= content.length { view.selectedRange = selectedRange }
        view.setContentOffset(offset, animated: false)
    }

    static func makeTextView() -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.alwaysBounceVertical = true
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .systemBackground
        view.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 24, right: 16)
        view.accessibilityIdentifier = "response-selection-text"
        view.accessibilityLabel = "Response text"
        view.accessibilityHint = "Touch and hold a word, then adjust the selection handles to copy part of the response."
        return view
    }
}

/// One text storage preserves native selections across prose, links, and code.
enum AgentSelectionDocument {
    static func render(_ text: String, isCode: Bool = false) -> NSAttributedString {
        if isCode { return code(text) }
        let result = NSMutableAttributedString()
        for block in AgentMarkdownParser.parse(text) {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            switch block {
            case .paragraph(let text), .quote(let text): result.append(inline(text))
            case .heading(let level, let text):
                result.append(inline(text, style: level == 1 ? .title2 : .headline))
            case .list(let items, let ordered):
                for (index, item) in items.enumerated() {
                    if index > 0 { result.append(NSAttributedString(string: "\n")) }
                    result.append(inline("\(ordered ? "\(index + 1)." : "•") \(item)"))
                }
            case .codeBlock(_, let text): result.append(code(text))
            case .divider: result.append(inline("———"))
            }
        }
        return result
    }

    private static func code(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular)),
            .foregroundColor: UIColor.label,
            .backgroundColor: UIColor.secondarySystemBackground
        ])
    }

    private static func inline(_ source: String, style: UIFont.TextStyle = .body) -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = UIFont.preferredFont(forTextStyle: style)
            if intent.contains(.code) {
                font = UIFontMetrics(forTextStyle: style).scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
            }
            var traits = font.fontDescriptor.symbolicTraits
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            if let url = run.link { attributes[.link] = url }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}

#if DEBUG
struct AgentTextSelectionHarness: View {
    static let response = """
    A **precise selection** keeps café 👩🏽‍💻 text intact.

    Read [OpenCode](https://opencode.ai) and select across paragraphs.

    ```swift
    let greeting = "Hello, 世界"
        print(greeting)
    ```
    """
    @State private var clipboard = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                AgentMarkdownText(text: Self.response).padding()
            }
            .navigationTitle("Selection fixture")
            .toolbar {
                Button("Read clipboard") { clipboard = UIPasteboard.general.string ?? "" }
            }
            Text(clipboard).accessibilityIdentifier("selection-clipboard")
        }
    }
}
#endif
