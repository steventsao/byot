import Testing
import UIKit
@testable import byot

@Suite("Native response text selection")
@MainActor
struct AgentTextSelectionTests {
    @Test("Copy honors an arbitrary UTF-16 selection across paragraph and code boundaries")
    func copiesOnlySelectedRange() {
        let view = AgentSelectableText.makeTextView()
        view.attributedText = AgentSelectionDocument.render("Prose café 👩🏽‍💻.\n\n```swift\nlet value = 42\n    print(value)\n```")
        let chosen = "café 👩🏽‍💻.\n\nlet value = 42\n    print"
        view.selectedRange = (view.text as NSString).range(of: chosen)
        #expect(view.selectedRange.location != NSNotFound)
        view.copy(nil)
        #expect(UIPasteboard.general.string == chosen)
        #expect(!view.isEditable)
        #expect(view.isSelectable)
    }

    @Test("Code-only selection preserves whitespace and Unicode exactly")
    func codeWhitespace() {
        let text = "\tlet 名字 = \"你好\"\n    print(名字)\n"
        let view = AgentSelectableText.makeTextView()
        view.attributedText = AgentSelectionDocument.render(text, isCode: true)
        let chosen = "名字 = \"你好\"\n    print(名字)"
        view.selectedRange = (view.text as NSString).range(of: chosen)
        view.copy(nil)
        #expect(UIPasteboard.general.string == chosen)
        #expect(view.text == text)
    }

    @Test("Selection document retains visible formatting and tappable links")
    func inlineFormatting() {
        let document = AgentSelectionDocument.render("# Heading\n\nA **bold** [link](https://opencode.ai) and `code`.\n\n- first\n- second")
        #expect(document.string == "Heading\n\nA bold link and code.\n\n• first\n• second")
        let index = (document.string as NSString).range(of: "link").location
        #expect(document.attribute(.link, at: index, effectiveRange: nil) as? URL == URL(string: "https://opencode.ai"))
        let bold = (document.string as NSString).range(of: "bold").location
        let font = document.attribute(.font, at: bold, effectiveRange: nil) as? UIFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
    }
}
