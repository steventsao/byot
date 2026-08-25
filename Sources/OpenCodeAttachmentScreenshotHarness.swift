#if DEBUG
import SwiftUI

struct OpenCodeAttachmentScreenshotHarness: View {
    @StateObject private var store: OpenCodeSessionStore

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
        _store = StateObject(
            wrappedValue: OpenCodeSessionStore(
                client: OpenCodeClient(profile: profile, password: "screenshot"),
                session: session,
                directory: session.directory
            )
        )
    }

    var body: some View {
        NavigationStack {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(BYOTBrand.canvas)
                .navigationTitle(store.session.title)
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                OpenCodeSessionComposerView(
                    store: store,
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
