import Foundation
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
        #expect(
            OpenCodeFileBrowserPath.normalize(#"\Sources\\UI\App.swift\"#)
                == "Sources/UI/App.swift"
        )
        #expect(OpenCodeFileBrowserPath.join("", "Sources") == "Sources")
        #expect(OpenCodeFileBrowserPath.join(#"Sources\UI"#, "App.swift") == "Sources/UI/App.swift")
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

@MainActor
@Suite(.serialized)
struct OpenCodeFileBrowserStoreTests {
    @Test("v1 startup loads a sorted visible tree and changed-file status")
    func v1Startup() async {
        let service = MockFileBrowserService(
            capabilities: .v1,
            entries: [
                OpenCodeFileEntry(name: "Z.swift", path: "Z.swift", type: "file"),
                OpenCodeFileEntry(name: "Sources", path: "Sources", type: "directory"),
                OpenCodeFileEntry(
                    name: ".build",
                    path: ".build",
                    type: "directory",
                    ignored: true
                ),
            ],
            statuses: [
                OpenCodeFileStatus(
                    path: "Z.swift",
                    added: 3,
                    removed: 1,
                    status: "modified"
                ),
            ]
        )
        let store = OpenCodeFileBrowserStore(
            service: service,
            directory: "/repo",
            workspace: "wrk_1"
        )

        await store.start()

        #expect(service.steps == [.capabilities, .list(path: ""), .statuses])
        #expect(store.entries.map(\.path) == [".build", "Sources", "Z.swift"])
        #expect(store.entries.first?.ignored == true)
        #expect(store.statuses.map(\.path) == ["Z.swift"])
        #expect(store.errorMessage == nil)
    }

    @Test("v2 startup gates missing file routes and search uses its supported service")
    func v2SearchOnly() async {
        let service = MockFileBrowserService(
            capabilities: .v2,
            searchResults: [
                OpenCodeFileEntry(
                    name: "App.swift",
                    path: "Sources/App.swift",
                    type: "file"
                ),
            ]
        )
        let store = OpenCodeFileBrowserStore(
            service: service,
            directory: "/repo",
            workspace: "wrk_1"
        )

        await store.start()
        store.query = " App "
        await store.search()

        #expect(service.steps == [.capabilities, .search(query: "App")])
        #expect(store.policy?.canBrowseTree == false)
        #expect(store.searchResults.map(\.path) == ["Sources/App.swift"])
        #expect(store.errorMessage == nil)
    }

    @Test("reader checks capabilities before attempting a read")
    func readerCapabilityGate() async {
        let service = MockFileBrowserService(capabilities: .v2)
        let store = OpenCodeFileReaderStore(
            service: service,
            directory: "/repo",
            workspace: nil,
            path: "README.md"
        )

        await store.load()

        #expect(service.steps == [.capabilities])
        #expect(store.content == nil)
        #expect(store.presentation.unavailableReason != nil)
    }
}

private final class MockFileBrowserService: OpenCodeFileBrowserServicing, @unchecked Sendable {
    enum Step: Equatable {
        case capabilities
        case list(path: String)
        case statuses
        case search(query: String)
        case read(path: String)
    }

    private let lock = NSLock()
    nonisolated(unsafe) private var recordedSteps: [Step] = []
    private let capabilities: OpenCodeProtocolCapabilities
    private let entries: [OpenCodeFileEntry]
    private let statuses: [OpenCodeFileStatus]
    private let searchResults: [OpenCodeFileEntry]
    private let content: OpenCodeFileContent

    init(
        capabilities: OpenCodeProtocolCapabilities,
        entries: [OpenCodeFileEntry] = [],
        statuses: [OpenCodeFileStatus] = [],
        searchResults: [OpenCodeFileEntry] = [],
        content: OpenCodeFileContent = OpenCodeFileContent(
            type: "text",
            content: "",
            diff: nil,
            encoding: nil,
            mimeType: "text/plain"
        )
    ) {
        self.capabilities = capabilities
        self.entries = entries
        self.statuses = statuses
        self.searchResults = searchResults
        self.content = content
    }

    var steps: [Step] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSteps
    }

    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities {
        record(.capabilities)
        return capabilities
    }

    func listFiles(
        directory: String,
        workspace: String?,
        path: String
    ) async throws -> [OpenCodeFileEntry] {
        record(.list(path: path))
        return entries
    }

    func readFile(
        directory: String,
        workspace: String?,
        path: String
    ) async throws -> OpenCodeFileContent {
        record(.read(path: path))
        return content
    }

    func fileStatuses(
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeFileStatus] {
        record(.statuses)
        return statuses
    }

    func findFiles(
        directory: String,
        workspace: String?,
        query: String
    ) async throws -> [OpenCodeFileEntry] {
        record(.search(query: query))
        return searchResults
    }

    private func record(_ step: Step) {
        lock.lock()
        recordedSteps.append(step)
        lock.unlock()
    }
}
