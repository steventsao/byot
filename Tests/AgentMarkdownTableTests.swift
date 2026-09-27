import Testing
@testable import byot

@Suite("Markdown tables in agent replies")
struct AgentMarkdownTableTests {
    @Test("A header and delimiter row start a table that ends at the first line without pipes")
    func parsesReplyTable() {
        let reply = """
        Both functions are called in the block.

        | Function | Signature | Returns |
        |---|:---:|---:|
        | `greet` | `greet(name: str) -> str` | `"Hello, {name}!"` |
        | `farewell` | `farewell(name: str) -> str` | `"Goodbye, {name}!"` |
        Done.
        """
        let blocks = AgentMarkdownParser.parse(reply)
        #expect(blocks.count == 3)
        #expect(blocks.first == .paragraph("Both functions are called in the block."))
        #expect(blocks[1] == .table(AgentMarkdownTable(
            header: ["Function", "Signature", "Returns"],
            alignments: [.leading, .center, .trailing],
            rows: [["`greet`", "`greet(name: str) -> str`", "`\"Hello, {name}!\"`"],
                   ["`farewell`", "`farewell(name: str) -> str`", "`\"Goodbye, {name}!\"`"]]
        )))
        #expect(blocks.last == .paragraph("Done."))
    }

    @Test("Pipes inside inline code or escaped with a backslash stay in their cell")
    func keepsEscapedPipes() {
        #expect(AgentMarkdownParser.tableCells("| `a | b` | c \\| d |") == ["`a | b`", "c | d"])
        #expect(AgentMarkdownParser.tableCells("a | b") == ["a", "b"])
        #expect(AgentMarkdownParser.tableCells("no pipes here") == nil)
    }

    @Test("Short rows are padded and long rows cut to the header's width")
    func normalizesRowWidth() {
        let blocks = AgentMarkdownParser.parse("| A | B |\n| - | - |\n| 1 |\n| 1 | 2 | 3 |")
        #expect(blocks == [.table(AgentMarkdownTable(
            header: ["A", "B"], alignments: [.leading, .leading], rows: [["1", ""], ["1", "2"]]
        ))])
    }

    @Test("A pipe in prose without a delimiter row stays a paragraph")
    func leavesProseAlone() {
        #expect(AgentMarkdownParser.parse("Use a | b to pipe output.\nThen continue.")
            == [.paragraph("Use a | b to pipe output.\nThen continue.")])
        // A delimiter row whose column count differs from the header's isn't a table.
        #expect(AgentMarkdownParser.parse("| A | B |\n| --- |").count == 1)
    }

    @Test("Selecting a table copies tab-separated rows")
    @MainActor
    func selectionCopiesRows() {
        let document = AgentSelectionDocument.render("| A | B |\n|---|---|\n| 1 | 2 |")
        #expect(document.string == "A\tB\n1\t2")
    }
}
