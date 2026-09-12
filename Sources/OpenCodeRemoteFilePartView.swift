import SwiftUI

private struct OpenCodeRemoteFilesEnvironmentKey: EnvironmentKey {
    static let defaultValue: OpenCodeRemoteFileStore? = nil
}

extension EnvironmentValues {
    var openCodeRemoteFiles: OpenCodeRemoteFileStore? {
        get { self[OpenCodeRemoteFilesEnvironmentKey.self] }
        set { self[OpenCodeRemoteFilesEnvironmentKey.self] = newValue }
    }
}

/// Opens a server reference from an earlier message using the session's connection.
/// Ordinary uploaded attachments retain their existing transcript label.
struct OpenCodeRemoteFilePartView: View {
    let part: OpenCodePart
    @Environment(\.openCodeRemoteFiles) private var files
    @State private var showingReader = false

    private var reference: OpenCodePromptFileReference? {
        guard let files, let uri = part.url else { return nil }
        return .restored(fromURI: uri, serverID: files.scope.serverID, projectID: files.scope.projectID,
                         directory: files.scope.directory, workspaceID: files.scope.workspaceID)
    }

    var body: some View {
        if let reference, let files {
            Button { showingReader = true } label: {
                Label(reference.displayName, systemImage: "doc.text.magnifyingglass")
                    .font(.cleanCaption).lineLimit(2).truncationMode(.middle)
                    .frame(minHeight: 44)
            }
            .accessibilityLabel("Open server file \(reference.displayName)")
            .sheet(isPresented: $showingReader) {
                NavigationStack {
                    OpenCodeRemoteFileReader(files: files, path: reference.path, existingSelection: reference.selection) { selected in
                        files.contextToAdd = selected
                        showingReader = false
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingReader = false } } }
                }
            }
        } else {
            Label(part.filename ?? part.mime ?? "Attachment", systemImage: "paperclip").font(.cleanCaption)
        }
    }
}
