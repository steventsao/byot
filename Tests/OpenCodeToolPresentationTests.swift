import Testing
@testable import byot

struct OpenCodeToolPresentationTests {
    @Test("Long shell commands become compact leading summaries")
    func shellCommandSummary() {
        let command = """
        ls /workspace/acme-api/src; echo ---; \
        rg -il --glob '!node_modules' macos /workspace/acme-api/scratch
        """
        let presentation = OpenCodeToolPresentation(
            name: "bash",
            state: makeState(
                input: ["command": .string(command)],
                title: command
            )
        )

        #expect(presentation.title == "Shell command")
        #expect(
            presentation.summary
                == "ls /workspace/acme-api/src; echo ---; rg -il --glob '!node_modules' macos /workspace/acme-api/scratch"
        )
        #expect(presentation.statusLabel == "Completed")
    }

    @Test(
        "Common tools use readable titles",
        arguments: [
            ("read", "Read file"),
            ("write", "Write file"),
            ("edit", "Edit file"),
            ("glob", "Find files"),
            ("grep", "Search files"),
            ("list", "List files")
        ]
    )
    func readableToolTitle(name: String, expectedTitle: String) {
        let presentation = OpenCodeToolPresentation(name: name, state: makeState())

        #expect(presentation.title == expectedTitle)
    }

    @Test("File tools prefer the path over a verbose server title")
    func filePathSummary() {
        let presentation = OpenCodeToolPresentation(
            name: "read",
            state: makeState(
                input: ["path": .string("Sources/OpenCodeSessionView.swift")],
                title: "Read Sources/OpenCodeSessionView.swift from the project"
            )
        )

        #expect(presentation.summary == "Sources/OpenCodeSessionView.swift")
    }

    @Test("A redundant server title does not create a second row")
    func redundantTitleIsOmitted() {
        let presentation = OpenCodeToolPresentation(
            name: "grep",
            state: makeState(title: "Search files")
        )

        #expect(presentation.summary == nil)
    }

    @Test("Shell commands render as highlighted code apart from the other input")
    func shellCommandIsPromoted() {
        let presentation = OpenCodeToolPresentation(
            name: "bash",
            state: makeState(input: [
                "command": .string("git status --short"),
                "description": .string("Shows changes"),
            ])
        )

        #expect(presentation.inputCode == OpenCodeToolCode(title: "Command", text: "git status --short", language: .shell))
        #expect(presentation.input == "description: Shows changes")
    }

    @Test("Written files render in their language with line numbers")
    func writeContentIsPromoted() {
        let presentation = OpenCodeToolPresentation(
            name: "write",
            state: makeState(input: [
                "filePath": .string("/repo/Sources/App.swift"),
                "content": .string("import SwiftUI\n"),
            ])
        )

        #expect(presentation.inputCode?.language == .swift)
        #expect(presentation.inputCode?.text == "import SwiftUI\n")
        #expect(presentation.inputCode?.firstLineNumber == 1)
        #expect(presentation.input == "filePath: /repo/Sources/App.swift")
    }

    @Test("Edits render as a diff of the replaced text")
    func editIsDiff() {
        let presentation = OpenCodeToolPresentation(
            name: "edit",
            state: makeState(input: [
                "filePath": .string("a.ts"),
                "oldString": .string("let a = 1\nlet b = 2"),
                "newString": .string("let a = 3"),
                "replaceAll": .bool(true),
            ])
        )

        #expect(presentation.inputCode?.language == .diff)
        #expect(presentation.inputCode?.text == "-let a = 1\n-let b = 2\n+let a = 3")
        #expect(presentation.inputCode?.footnote == "Replaces every occurrence")
        #expect(presentation.input == "filePath: a.ts")
    }

    @Test("A read result renders as the file, with its first line number and note")
    func readOutputIsFile() {
        let output = """
        <path>/repo/main.py</path>
        <type>file</type>
        <content>
        40: def main():
        41:
        42:     return 0

        (Showing lines 40-42 of 90. Use offset=43 to continue.)
        </content>

        <system-reminder>
        Follow the repo's AGENTS.md.
        </system-reminder>
        """
        let presentation = OpenCodeToolPresentation(
            name: "read",
            state: makeState(input: ["filePath": .string("/repo/main.py")], output: output)
        )

        let code = presentation.outputCode
        #expect(code?.language == .python)
        #expect(code?.firstLineNumber == 40)
        #expect(code?.text == "def main():\n\n    return 0")
        #expect(code?.footnote == "Showing lines 40-42 of 90. Use offset=43 to continue.")
        #expect(presentation.output == output)
    }

    @Test("Legacy read results with padded line numbers still parse")
    func legacyReadOutput() {
        let file = OpenCodeReadToolOutput("<file>\n00001| {\n00002|   \"a\": 1\n00003| }\n\n(End of file - total 3 lines)\n</file>")

        #expect(file?.firstLineNumber == 1)
        #expect(file?.text == "{\n  \"a\": 1\n}")
        #expect(file?.footnote == "End of file - total 3 lines")
        #expect(file?.path == nil)
    }

    @Test("Directory reads, prose, and other tools keep plain output")
    func nonFileOutputsStayPlain() {
        #expect(OpenCodeReadToolOutput("<path>/repo</path>\n<type>directory</type>\n<entries>\n1: a\n</entries>") == nil)
        #expect(OpenCodeReadToolOutput("File not found: /repo/x") == nil)
        #expect(OpenCodeReadToolOutput("<path>/repo/x</path>\n<content>\n</content>") == nil)

        let grep = OpenCodeToolPresentation(name: "grep", state: makeState(output: "12: match"))
        #expect(grep.outputCode == nil)
        #expect(grep.output == "12: match")
    }

    @Test("A read result with an unfamiliar body stays plain instead of dropping lines")
    func unfamiliarReadOutputStaysPlain() {
        #expect(OpenCodeReadToolOutput("<path>/r/a.py</path>\n<content>\n1: a\n3: c\n</content>") == nil)
        #expect(OpenCodeReadToolOutput("<path>/r/a.py</path>\n<content>\n1: a\nnot numbered\n</content>") == nil)
        #expect(OpenCodeReadToolOutput("<path>/r/a.py</path>\n<content>\n1: a\n</content>")?.text == "a")
    }

    @Test("Read output falls back to the path the server echoed")
    func readLanguageFromOutputPath() {
        let presentation = OpenCodeToolPresentation(
            name: "read",
            state: makeState(output: "<path>/repo/Dockerfile</path>\n<type>file</type>\n<content>\n1: FROM swift:6\n</content>")
        )

        #expect(presentation.outputCode?.language == .dockerfile)
        #expect(presentation.outputCode?.text == "FROM swift:6")
    }

    private func makeState(
        input: [String: OpenCodeJSONValue]? = nil,
        raw: String? = nil,
        title: String? = nil,
        output: String? = nil,
        error: String? = nil,
        status: String = "completed"
    ) -> OpenCodeToolState {
        OpenCodeToolState(
            status: status,
            input: input,
            raw: raw,
            title: title,
            output: output,
            error: error,
            time: nil
        )
    }
}
