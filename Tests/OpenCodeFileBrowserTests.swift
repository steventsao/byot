import Testing
@testable import byot

struct OpenCodeFileBrowserTests {
    @Test("File browser policy exposes only detected protocol surfaces")
    func policy() {
        let v1 = OpenCodeFileBrowserPolicy(capabilities: .v1)
        let v2 = OpenCodeFileBrowserPolicy(capabilities: .v2)

        #expect(v1.canBrowseTree)
        #expect(v1.canReadFiles)
        #expect(v1.canListChanges)
        #expect(v1.canSearch)
        #expect(!v2.canBrowseTree)
        #expect(!v2.canReadFiles)
        #expect(!v2.canListChanges)
        #expect(v2.canSearch)
    }

    @Test("Relative path navigation joins and walks parents deterministically")
    func paths() {
        #expect(OpenCodeFileBrowserPath.join("", "Sources") == "Sources")
        #expect(OpenCodeFileBrowserPath.join("Sources", "App.swift") == "Sources/App.swift")
        #expect(OpenCodeFileBrowserPath.parent(of: "Sources/UI/App.swift") == "Sources/UI")
        #expect(OpenCodeFileBrowserPath.parent(of: "Sources") == "")
        #expect(OpenCodeFileBrowserPath.title(for: "") == "Project files")
        #expect(OpenCodeFileBrowserPath.title(for: "Sources/UI") == "UI")
    }

    @Test("Text content preserves empty and trailing lines for code reading")
    func textPresentation() {
        let presentation = OpenCodeFileContentPresentation(
            path: "Sources/App.swift",
            content: OpenCodeFileContent(
                type: "text",
                content: "first\n\nthird\n",
                diff: nil,
                encoding: nil,
                mimeType: "text/x-swift"
            ),
            support: .supported
        )

        #expect(presentation.lines.map(\.number) == [1, 2, 3, 4])
        #expect(presentation.lines.map(\.text) == ["first", "", "third", ""])
        #expect(presentation.canDisplayText)
        #expect(presentation.accessibilitySummary == "App.swift, 4 lines")
    }

    @Test("Unavailable and binary content remain explicit")
    func unavailablePresentation() {
        let support = OpenCodeV2Adapter().capabilities.fileRead
        let unavailable = OpenCodeFileContentPresentation(
            path: "README.md",
            content: nil,
            support: support
        )
        let binary = OpenCodeFileContentPresentation(
            path: "image.png",
            content: OpenCodeFileContent(
                type: "binary",
                content: "AA==",
                diff: nil,
                encoding: "base64",
                mimeType: "image/png"
            ),
            support: .supported
        )

        #expect(unavailable.unavailableReason == support.unavailableReason)
        #expect(!unavailable.canDisplayText)
        #expect(binary.binaryDescription == "Binary file · image/png")
        #expect(!binary.canDisplayText)
    }

    @Test("A newer browser request rejects an older response")
    func requestVersion() {
        var version = OpenCodeFileBrowserRequestVersion()
        let stale = version.begin()
        let current = version.begin()

        #expect(!version.accepts(stale))
        #expect(version.accepts(current))
    }
}
