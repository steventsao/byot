import AppKit
import SwiftUI

@main
struct BYOTDesktopApp: App {
    @StateObject private var appState = DesktopAppState()
    @AppStorage("byot.desktop.appearance") private var appearance: DesktopAppearance = .system
    @Environment(\.openWindow) private var openWindow

    init() {
        BYOTTelemetry.shared.start()
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            DesktopRootView(appState: appState)
                .frame(minWidth: 920, minHeight: 620)
                .onAppear {
                    appearance.apply()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .onChange(of: appearance) { _, next in
                    next.apply()
                }
                .onOpenURL { url in
                    appState.handleIncomingURL(url)
                }
        }
        .defaultSize(width: 1200, height: 780)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    if let project = appState.workspaceStore?.projects.first {
                        appState.createSession(in: project)
                    } else {
                        appState.showServerSheet = true
                    }
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Add Server…") {
                    appState.editingProfile = nil
                    appState.showServerSheet = true
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Pair iPhone…") {
                    appState.openPairPhone()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu("Workspace") {
                Button("Refresh") {
                    appState.refreshActiveServer()
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Toggle("Changes", isOn: $appState.showDiffInspector)
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                Toggle("Terminal", isOn: $appState.showTerminalDrawer)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }

        // Persistent menu bar presence so 1-click iPhone pairing is always one click away
        // as long as byot is running on your Mac.
        MenuBarExtra {
            DesktopMenuBarView(appState: appState) {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            Image(systemName: appState.pairing.localOpenCode.isReachable ? "terminal.fill" : "terminal")
        }

        Settings {
            DesktopSettingsView(appState: appState, appearance: $appearance)
        }
    }
}

private struct DesktopMenuBarView: View {
    @ObservedObject var appState: DesktopAppState
    let openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            if appState.pairing.localOpenCode.isReachable {
                Text("OpenCode :\(appState.pairing.localPort) · Running")
            } else {
                Text("OpenCode :\(appState.pairing.localPort) · Stopped")
            }

            if let url = appState.pairing.tailscale?.serveURL {
                Text("Tailscale · \(url.replacingOccurrences(of: "https://", with: ""))")
            } else if let tunnel = appState.pairing.quickTunnelURL {
                Text("Tunnel · \(tunnel.replacingOccurrences(of: "https://", with: ""))")
            }

            Divider()

            Button("Pair iPhone (QR)…") {
                openMainWindow()
                appState.openPairPhone()
            }

            if !appState.pairing.localOpenCode.isReachable, appState.pairing.hasOpenCodeBinary {
                Button("Start OpenCode Server") {
                    Task { _ = await appState.pairing.startManagedOpenCode(bindLAN: true) }
                }
            }

            if let ts = appState.pairing.tailscale, ts.isOnline, ts.serveURL == nil {
                Button("Enable Tailscale HTTPS") {
                    Task { await appState.pairing.enableTailscaleServe() }
                }
            }

            if appState.pairing.isQuickTunnelRunning {
                Button("Stop Anywhere Tunnel") {
                    appState.pairing.stopQuickTunnel()
                }
            } else if appState.pairing.hasCloudflaredBinary {
                Button("Start Anywhere Tunnel") {
                    appState.pairing.startQuickTunnel()
                }
            }

            Divider()

            Button("Open byot") {
                openMainWindow()
            }

            Button("Quit byot") {
                appState.pairing.shutdownManagedProcesses()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
