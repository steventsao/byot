import SwiftUI

@main
struct BYOTApp: App {
    @AppStorage("byot.appearance") private var appearance: BYOTAppearance = .system

    var body: some Scene {
        WindowGroup {
            appRoot
                .tint(BYOTBrand.accent)
                .environment(\.font, .cleanBody)
                .background {
                    BYOTAppearanceOverride(appearance: appearance)
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
        }
    }

    @ViewBuilder
    private var appRoot: some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--session-browser-fixture") {
            OpenCodeSessionBrowserHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--attachment-screenshot") {
            OpenCodeAttachmentScreenshotHarness()
        } else {
            BYOTRootView(appearance: $appearance)
        }
#else
        BYOTRootView(appearance: $appearance)
#endif
    }
}

private struct BYOTRootView: View {
    @Binding var appearance: BYOTAppearance
    @State private var isShowingAbout = false

    var body: some View {
        OpenCodeRootView(openAppNavigation: { isShowingAbout = true })
            .sheet(isPresented: $isShowingAbout) {
                AboutView(appearance: $appearance)
            }
    }
}

private struct AboutView: View {
    @Binding var appearance: BYOTAppearance
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
                    Picker("Appearance", selection: $appearance) {
                        ForEach(BYOTAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("appearance-picker")
                } footer: {
                    Text("System follows your iPhone’s Light or Dark Mode setting.")
                }
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
