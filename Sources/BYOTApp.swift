import AppIntents
import SwiftUI

@main
struct BYOTApp: App {
    @UIApplicationDelegateAdaptor(BYOTPushAppDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("byot.appearance") private var appearance: BYOTAppearance = .system

    init() {
        // Sends nothing until the person opts in; see docs/features/telemetry.md.
        BYOTTelemetry.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            appRoot
                .task(id: scenePhase) {
                    if scenePhase == .active {
                        BYOTTelemetry.shared.applicationDidBecomeActive()
                        await BYOTPushNotifications.shared.refreshAuthorization()
                    }
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
        if ProcessInfo.processInfo.arguments.contains("--polish-ui-tests") {
            OpenCodePolishUITestHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--durable-queue-fixture") {
            BYOTDurableQueueHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--text-selection-fixture") {
            AgentTextSelectionHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--remote-files-fixture") {
            OpenCodeRemoteFileHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--session-browser-fixture") {
            OpenCodeSessionBrowserHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--terminal-fixture") {
            OpenCodeTerminalHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--project-status-fixture") {
            OpenCodeProjectStatusHarness()
        } else if ProcessInfo.processInfo.arguments.contains("--worktrees-fixture") {
            OpenCodeWorktreesHarness()
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
    @State private var isAskingForUsageData = false
    @State private var pairingLink: URL?
    @ObservedObject private var push = BYOTPushNotifications.shared
    @ObservedObject private var shares = BYOTShareCenter.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        OpenCodeRootView(openAppNavigation: { isShowingAbout = true }, pairingLink: $pairingLink,
                         isCovered: isShowingAbout)
            .onChange(of: push.pendingDestination) { _, destination in
                if destination != nil { isShowingAbout = false }
            }
            .onChange(of: shares.incoming?.id) { _, id in
                if id != nil { isShowingAbout = false }
            }
            .onOpenURL { url in
                // A pairing code scanned with the Camera app.
                if url.scheme?.lowercased() == OpenCodePairingPayload.scheme {
                    isShowingAbout = false
                    pairingLink = url
                    return
                }
                // Widget and Live Activity taps. The plain "open" link only
                // brings byot forward.
                if let destination = BYOTPushDestination(widgetURL: url) { push.pendingDestination = destination }
                // The share extension names the share it just saved.
                if let link = BYOTShareLink(url: url), !BYOTLaunch.isAutomated { shares.refresh(preferring: link.shareID) }
            }
            .task(id: scenePhase) {
                // A share saved while byot couldn't be opened waits in the inbox.
                if scenePhase == .active, !BYOTLaunch.isAutomated { shares.refresh() }
                await askForUsageDataIfNeeded()
            }
            .sheet(isPresented: $isShowingAbout) {
                AboutView(appearance: $appearance)
            }
            .background {
                // Its own presenter, so it never competes with the About sheet.
                Color.clear.sheet(isPresented: $isAskingForUsageData) { BYOTTelemetryConsentSheet() }
            }
            .task {
                // Server names in "Ask OpenCode on <server>" phrases.
                if !BYOTLaunch.isAutomated { BYOTAppShortcuts.updateAppShortcutParameters() }
            }
    }

    /// Asks once, after the first server exists and the screen is free. A
    /// person who has nothing to connect to has no usage to share yet.
    private func askForUsageDataIfNeeded() async {
        guard scenePhase == .active, BYOTTelemetry.shared.shouldAskForConsent,
              !OpenCodeProfileStore.savedProfiles().isEmpty else { return }
        try? await Task.sleep(for: .seconds(1.5))
        guard scenePhase == .active, BYOTTelemetry.shared.shouldAskForConsent, !isShowingAbout,
              pairingLink == nil, push.pendingDestination == nil, shares.incoming == nil else { return }
        isAskingForUsageData = true
    }
}

private struct AboutView: View {
    @Binding var appearance: BYOTAppearance
    @Environment(\.dismiss) private var dismiss
    @AppStorage(BYOTLiveActivityController.enabledKey) private var showsLiveActivities = true

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
                if BYOTLiveActivityController.isWidgetExtensionEmbedded {
                    Section {
                        Toggle("Live Activities", isOn: $showsLiveActivities)
                            .accessibilityIdentifier("live-activities-toggle")
                            .onChange(of: showsLiveActivities) { _, isOn in
                                BYOTLiveActivityController.shared.isEnabled = isOn
                            }
                    } footer: {
                        Text("Follow a running turn on the Lock Screen and in the Dynamic Island, including when it needs your approval. Add the byot widget to your Home Screen to see active sessions at a glance.")
                    }
                }
                Section {
                    ShortcutsLink()
                        .shortcutsLinkStyle(.automaticOutline)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("shortcuts-link")
                } header: {
                    Text("Siri & Shortcuts")
                } footer: {
                    Text("Say “Ask OpenCode in byot” to start a session, or “What needs me in byot” to hear which sessions are waiting on you. byot’s actions are also in the Shortcuts app.")
                }
                BYOTTelemetryPrivacySection()
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
