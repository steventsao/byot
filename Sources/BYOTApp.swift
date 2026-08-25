import SwiftUI

@main
struct BYOTApp: App {
    var body: some Scene {
        WindowGroup {
            appRoot
                .tint(BYOTBrand.accent)
                .environment(\.font, .cleanBody)
        }
    }

    @ViewBuilder
    private var appRoot: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--attachment-screenshot") {
            OpenCodeAttachmentScreenshotHarness()
        } else {
            BYOTRootView()
        }
#else
        BYOTRootView()
#endif
    }
}

private struct BYOTRootView: View {
    @State private var isShowingAbout = false

    var body: some View {
        OpenCodeRootView(openAppNavigation: { isShowingAbout = true })
            .sheet(isPresented: $isShowingAbout) {
                AboutView()
            }
    }
}

private struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Version", value: version)
                }
                Section {
                    Link("byot.app", destination: URL(string: "https://byot.app")!)
                    Link("Setup & support", destination: URL(string: "https://byot.app/support")!)
                    Link("Privacy policy", destination: URL(string: "https://byot.app/privacy")!)
                }
            }
            .navigationTitle("BYOT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
