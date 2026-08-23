#if DEBUG
import SwiftUI

struct OpenCodeAttachmentScreenshotHarness: View {
    @StateObject private var store: OpenCodeSessionStore
    @StateObject private var inputStore: OpenCodeSessionInputStore

    init() {
        let profile = OpenCodeServerProfile(
            name: "Screenshot",
            baseURL: "https://screenshot.invalid",
            username: "opencode",
            directory: "/Users/demo/byot"
        )
        let session = OpenCodeSession(
            id: "ses_screenshot",
            slug: "attachment-demo",
            projectID: "pro_screenshot",
            workspaceID: nil,
            directory: "/Users/demo/byot",
            parentID: nil,
            summary: nil,
            title: "Attachment support",
            agent: nil,
            version: "1.18.10",
            time: OpenCodeSessionTime(
                created: Date.now.timeIntervalSince1970 * 1_000,
                updated: Date.now.timeIntervalSince1970 * 1_000,
                compacting: nil,
                archived: nil
            )
        )
        let client = OpenCodeClient(profile: profile, password: "screenshot")
        _store = StateObject(
            wrappedValue: OpenCodeSessionStore(
                client: client,
                session: session,
                directory: session.directory
            )
        )
        _inputStore = StateObject(
            wrappedValue: OpenCodeSessionInputStore(
                client: client,
                directory: session.directory,
                workspace: session.workspaceID,
                initialAgentID: session.agent
            )
        )
    }

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Ready for a prompt",
                systemImage: "terminal",
                description: Text("Attach a screenshot, document, or text file for OpenCode to inspect.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BYOTBrand.canvas)
            .navigationTitle(store.session.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                OpenCodeSessionComposerView(
                    store: store,
                    inputStore: inputStore,
                    screenshotAttachment: OpenCodePromptAttachment(
                        filename: "byot-design.png",
                        mimeType: "image/png",
                        data: Data("simulator-screenshot-fixture".utf8)
                    )
                )
            }
        }
        .onAppear { store.prepareForAttachmentScreenshot() }
    }
}
#endif
