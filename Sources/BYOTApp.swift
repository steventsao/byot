import SwiftUI

@main
struct BYOTApp: App {
    @UIApplicationDelegateAdaptor(BYOTPushAppDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("byot.appearance") private var appearance: BYOTAppearance = .system

    var body: some Scene {
        WindowGroup {
            appRoot
                .task(id: scenePhase) {
                    if scenePhase == .active { await BYOTPushNotifications.shared.refreshAuthorization() }
                }
                .tint(BYOTBrand.interactionTint)
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
        if ProcessInfo.processInfo.arguments.contains("--durable-queue-fixture") {
            BYOTDurableQueueHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--text-selection-fixture") {
            AgentTextSelectionHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--remote-files-fixture") {
            OpenCodeRemoteFileHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--session-browser-fixture") {
            OpenCodeSessionBrowserHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--attachment-screenshot") {
            OpenCodeAttachmentScreenshotHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--app-store-screenshots") {
            OpenCodeAppStoreScreenshotHarness()
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
    @ObservedObject private var push = BYOTPushNotifications.shared

    var body: some View {
        OpenCodeRootView(openAppNavigation: { isShowingAbout = true })
            .onChange(of: push.pendingDestination) { _, destination in
                if destination != nil { isShowingAbout = false }
            }
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
            .navigationTitle(BYOTBrand.wordmark)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) { BYOTWordmark() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
