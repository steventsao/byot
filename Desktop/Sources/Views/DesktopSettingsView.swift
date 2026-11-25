import SwiftUI

struct DesktopSettingsView: View {
    @ObservedObject var appState: DesktopAppState
    @Binding var appearance: DesktopAppearance
    @State private var telemetryEnabled = BYOTTelemetry.shared.consent == .enabled

    private var versionText: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        TabView {
            Form {
                Picker("Appearance", selection: $appearance) {
                    ForEach(DesktopAppearance.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Share anonymous usage events", isOn: $telemetryEnabled)
                    .onChange(of: telemetryEnabled) { _, enabled in
                        BYOTTelemetry.shared.setConsent(enabled)
                    }

                Text("Off by default. Prompts, code, server addresses, and project names are never collected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            VStack(alignment: .leading, spacing: 12) {
                List {
                    ForEach(appState.profileStore.profiles) { profile in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).font(.headline)
                                Text(profile.baseURL).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") {
                                appState.editingProfile = profile
                                appState.showServerSheet = true
                            }
                            Button("Remove", role: .destructive) {
                                appState.removeServer(profile)
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Add Server…", systemImage: "plus") {
                        appState.editingProfile = nil
                        appState.showServerSheet = true
                    }
                }
            }
            .padding()
            .tabItem { Label("Servers", systemImage: "server.rack") }

            VStack(spacing: 10) {
                DesktopWordmark(size: 28)
                Text("Version \(versionText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 16) {
                    Link("byot.app", destination: URL(string: "https://byot.app")!)
                    Link("Privacy", destination: URL(string: "https://byot.app/privacy")!)
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 300)
    }
}
