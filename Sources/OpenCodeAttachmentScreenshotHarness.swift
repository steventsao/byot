#if DEBUG
import SwiftUI

struct OpenCodeAttachmentScreenshotHarness: View {
    @StateObject private var store: OpenCodeSessionStore

    init() {
        let profile = OpenCodeServerProfile(
            id: ProcessInfo.processInfo.arguments.contains("--persist-composer-draft")
                ? UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")! : UUID(),
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
                        data: Self.previewImage
                    )
                )
            }
        }
        .frame(maxWidth: Self.screenWidth)
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            store.prepareForAttachmentScreenshot(
                withCatalog: arguments.contains("--composer-catalog"),
                crowded: arguments.contains("--composer-crowded"))
        }
    }

    /// `-BYOTScreenWidth 393` lays the screen out as a narrower phone would.
    private static var screenWidth: CGFloat? {
        let width = UserDefaults.standard.double(forKey: "BYOTScreenWidth")
        return width > 0 ? width : nil
    }

    private static var previewImage: Data {
        UIGraphicsImageRenderer(size: CGSize(width: 480, height: 320)).pngData { context in
            UIColor(red: 0.12, green: 0.38, blue: 0.26, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 320))
            ("byot" as NSString).draw(at: CGPoint(x: 32, y: 60), withAttributes: [
                .font: UIFont(name: "OpenRunde-Bold", size: 80)!,
                .foregroundColor: UIColor.white
            ])
            ("Design review" as NSString).draw(at: CGPoint(x: 32, y: 200), withAttributes: [
                .font: UIFont(name: "OpenRunde-Regular", size: 28)!,
                .foregroundColor: UIColor.white
            ])
        }
    }
}
#endif
