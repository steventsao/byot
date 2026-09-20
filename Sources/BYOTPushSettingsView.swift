import SwiftUI

struct BYOTPushSettingsView: View {
    let profile: OpenCodeServerProfile
    @ObservedObject private var push = BYOTPushNotifications.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var pairing: String?
    @State private var expiry: Date?
    private var prefs: BYOTPushPreferences? { push.preferences[profile.id] }
    private let command = "curl -fsS https://byot-push.steventsao.workers.dev/byot-notify.mjs -o /tmp/byot-notify.mjs && node /tmp/byot-notify.mjs setup"

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(profile.name, systemImage: "server.rack")
                    Text("Get notified when OpenCode needs approval, asks a question, finishes, or encounters an error—even when byot is closed.")
                }
                if push.credentials[profile.id] != nil, let prefs {
                    Section {
                        Toggle("Notifications", isOn: Binding(get: { prefs.enabled }, set: { enabled in
                            var value = prefs; value.enabled = enabled; perform { try await push.update(profile.id, value) }
                        })).accessibilityIdentifier("push-enabled")
                        ForEach(BYOTPushKind.allCases, id: \.self) { kind in
                            Toggle(kind.title, isOn: Binding(get: { prefs.kinds.contains(kind.rawValue) }, set: { enabled in
                                var value = prefs; value.kinds.removeAll { $0 == kind.rawValue }
                                if enabled { value.kinds.append(kind.rawValue) }
                                perform { try await push.update(profile.id, value) }
                            })).disabled(!prefs.enabled)
                        }
                        if prefs.paired {
                            Label("Computer paired", systemImage: "checkmark.circle")
                            if let seen = prefs.lastSeen {
                                LabeledContent("Last connected") { Text(Date(timeIntervalSince1970: seen / 1000), style: .relative) }
                            } else { Text("Waiting for the notification companion to connect.").foregroundStyle(.secondary) }
                        }
                    } header: { Text("Alerts") } footer: {
                        Text("Notifications use private, generic text. Your prompts, code, server password, and session titles are never included.")
                    }
                    if prefs.enabled {
                        Button("Send test notification", systemImage: "bell.badge") {
                            perform { try await push.test(profile); message = "Test notification sent to Apple." }
                        }.accessibilityIdentifier("push-test")
                    }
                }
                Section {
                    Button(prefs?.paired == true ? "Pair another companion" : "Set up notifications", systemImage: "bell") {
                        perform { let result = try await push.setup(profile); pairing = result.0; expiry = result.1 }
                    }.accessibilityIdentifier("push-setup")
                    if let pairing {
                        Text("1. Run this command on the computer running your OpenCode server. Node.js 22 or later is required.")
                        Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        Button("Copy setup command", systemImage: "doc.on.doc") { UIPasteboard.general.string = command }
                        Text("2. Enter this pairing code when asked, then enter the OpenCode server address and password on that computer.")
                        Text(pairing).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("push-pairing-code")
                        if let expiry { Text("Code expires \(expiry.formatted(date: .omitted, time: .shortened)).").font(.cleanCaption).foregroundStyle(.secondary) }
                        Text("The companion must keep running on your computer. Setup can install a background service on macOS.")
                        Button("Check connection", systemImage: "arrow.clockwise") { perform { try await push.refresh(profile.id) } }
                    }
                } header: { Text("Connect your computer") } footer: {
                    Text("Pairing replaces the previous companion for this server on this iPhone. Other iPhones can pair separately.")
                }
                if let message {
                    Section { Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle").foregroundStyle(isError ? Color.red : .secondary) }
                }
                Section {
                    Button("Open iOS notification settings", systemImage: "gearshape") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    if push.credentials[profile.id] != nil {
                        Button("Disconnect notifications", role: .destructive) {
                            perform { try await push.remove(profile.id); pairing = nil; message = "Notification companion disconnected." }
                        }
                    }
                }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await push.refreshAuthorization()
                do { try await push.refresh(profile.id) } catch { message = error.localizedDescription; isError = true }
            }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; message = nil; isError = false
        Task { do { try await action() } catch { message = error.localizedDescription; isError = true }; busy = false }
    }
}
