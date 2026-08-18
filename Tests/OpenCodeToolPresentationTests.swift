import Testing
@testable import byot

struct OpenCodeToolPresentationTests {
    @Test("Long shell commands become compact leading summaries")
    func shellCommandSummary() {
        let command = """
        ls /home/opencode/dev/okra/apps/okra-computer/src; echo ---; \
        rg -il --glob '!node_modules' macos /home/opencode/dev/okra/scratch
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
                == "ls /home/opencode/dev/okra/apps/okra-computer/src; echo ---; rg -il --glob '!node_modules' macos /home/opencode/dev/okra/scratch"
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
