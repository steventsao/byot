#if DEBUG
import SwiftUI

struct OpenCodeRemoteFileHarness: View {
    @State private var text = ""
    @State private var references: [OpenCodePromptFileReference] = []
    @StateObject private var files = OpenCodeRemoteFileStore(service: OpenCodeRemoteFileFixtureService())
    @State private var sent = ""

    var body: some View {
        NavigationStack {
            VStack {
                Text(sent).accessibilityIdentifier("remote-file-sent")
                Spacer()
                OpenCodeRemoteContextView(text: $text, references: $references, files: files)
                TextField("Message", text: $text).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("remote-file-draft")
                Button("Send fixture context") {
                    sent = references.map(\.fileURL).joined(separator: "\n")
                    references = []; text = ""
                }
                .disabled(references.isEmpty)
                .accessibilityIdentifier("remote-file-send")
            }
            .padding().navigationTitle("Server file acceptance")
        }
    }
}

private struct OpenCodeRemoteFileFixtureService: OpenCodeRemoteFileServicing {
    let scope = OpenCodeRemoteFileScope(serverID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        serverName: "Mac mini", projectID: "pro_fixture", directory: "/repo/byot", workspaceID: "wrk_fixture")
    func capabilities() async throws -> OpenCodeRemoteFileCapabilities {
        .init(search: true, browse: true, read: true, changes: true, context: true)
    }
    func search(query: String) async throws -> [OpenCodeRemoteFileEntry] {
        [.init(path: "Sources/App.swift", type: "file")].filter { query.isEmpty || $0.path.localizedCaseInsensitiveContains(query) }
    }
    func list(path: String) async throws -> [OpenCodeRemoteFileEntry] {
        path.isEmpty ? [.init(path: "Sources", type: "directory")] : [.init(path: "Sources/App.swift", type: "file")]
    }
    func changes() async throws -> [OpenCodeRemoteFileChange] {
        [.init(file: "Sources/App.swift", additions: 2, deletions: 1, status: "modified"),
         .init(file: "removed.txt", additions: 0, deletions: 4, status: "deleted")]
    }
    func read(path: String) async throws -> OpenCodeRemoteFileContent {
        .init(path: path, text: "import SwiftUI\nstruct Demo {\n    let title = \"BYOT\"\n}", mimeType: "text/plain", byteCount: 60)
    }
}
#endif
