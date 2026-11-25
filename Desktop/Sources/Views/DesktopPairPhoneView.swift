import AppKit
import SwiftUI

/// One-click mobile pairing sheet: detects local OpenCode + Tailscale HTTPS (or
/// starts a zero-account Quick Tunnel) and renders a scannable `byot://pair` QR.
struct DesktopPairPhoneView: View {
    @ObservedObject var appState: DesktopAppState
    @ObservedObject var pairing: DesktopPairingManager
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var username = "opencode"
    @State private var serverName = Host.current().localizedName ?? "My Mac"
    @State private var includePassword = true
    @State private var isVerifyingPassword = false
    @State private var verificationMessage: String?
    @State private var verificationFailed = false
    @State private var copiedFeedback = false

    private var availablePaths: [DesktopPairingManager.ConnectionPath] {
        var paths: [DesktopPairingManager.ConnectionPath] = [.tailscale, .quickTunnel, .lan]
        if let active = appState.activeProfile,
           active.baseURL.lowercased().hasPrefix("https://"),
           active.baseURL != pairing.tailscale?.serveURL {
            paths.append(.activeProfile)
        }
        return paths
    }

    private var activePairingURL: URL? {
        pairing.pairingURL(for: pairing.selectedPath, activeProfile: appState.activeProfile)
    }

    private var resolvedPassword: String {
        if !password.isEmpty { return password }
        if let managed = pairing.managedPassword, !managed.isEmpty { return managed }
        if let saved = savedMatchingProfile() {
            return appState.profileStore.password(for: saved)
        }
        return ""
    }

    private var pairingLink: URL? {
        guard let url = activePairingURL else { return nil }
        return pairing.buildPairingLink(
            url: url,
            username: username,
            password: resolvedPassword,
            name: serverName,
            includePassword: includePassword
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            HStack(alignment: .top, spacing: 0) {
                leftColumn
                    .frame(width: 316)
                Divider()
                rightQRColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 680, height: 500)
        .background(DesktopBrand.canvas)
        .task {
            await pairing.refreshAll(activeProfile: appState.activeProfile)
            hydrateSavedCredentials()
        }
        .onChange(of: pairing.selectedPath) { _, _ in
            hydrateSavedCredentials()
        }
        .onChange(of: pairing.tailscale) { _, _ in
            hydrateSavedCredentials()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Pair iPhone")
                    .font(.headline)
                Text("Scan with your iPhone Camera or BYOT.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                Task { await pairing.refreshAll(activeProfile: appState.activeProfile) }
            } label: {
                if pairing.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh status")

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(DesktopBrand.surface)
    }

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                localHostCard

                VStack(alignment: .leading, spacing: 8) {
                    Text("ROUTE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)

                    ForEach(availablePaths) { path in
                        pathCard(path)
                    }
                }

                credentialsSection

                if let error = pairing.actionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(16)
        }
    }

    private var localHostCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(pairing.localOpenCode.isReachable ? DesktopBrand.statusLive : Color.orange)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(pairing.localOpenCode.isReachable ? "OpenCode running" : "OpenCode stopped")
                    .font(.callout.weight(.medium))
                Text(localHostSubtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !pairing.localOpenCode.isReachable {
                Button {
                    Task {
                        if let generated = await pairing.startManagedOpenCode(bindLAN: true) {
                            password = generated
                            saveCurrentRouteToDesktop(passwordToSave: generated)
                        }
                    }
                } label: {
                    if pairing.isStartingOpenCode {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Start")
                    }
                }
                .buttonStyle(DesktopPrimaryButtonStyle(compact: true))
                .disabled(pairing.isStartingOpenCode || !pairing.hasOpenCodeBinary)
            } else if pairing.localOpenCode.isManagedByDesktop {
                Button("Stop") {
                    pairing.stopManagedOpenCode()
                }
                .buttonStyle(DesktopSecondaryButtonStyle(compact: true))
            }
        }
        .padding(10)
        .background(DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(DesktopBrand.hairline))
    }

    private var localHostSubtitle: String {
        if pairing.localOpenCode.isReachable {
            let ver = pairing.localOpenCode.version.map { "v\($0) · " } ?? ""
            return "\(ver)127.0.0.1:\(pairing.localPort)" + (pairing.localOpenCode.isManagedByDesktop ? " · managed" : "")
        }
        return pairing.hasOpenCodeBinary ? "Start local server on :\(pairing.localPort)" : "opencode binary not found"
    }

    private func pathCard(_ path: DesktopPairingManager.ConnectionPath) -> some View {
        let isSelected = pairing.selectedPath == path
        let status = pathStatus(path)

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: path.symbol)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .frame(width: 14)
                Text(path.title)
                    .font(.callout.weight(.medium))
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(status.color).frame(width: 6, height: 6)
                    Text(status.label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(status.detail)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)

            pathActionButton(path)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? DesktopBrand.selectedSurface : DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(isSelected ? Color.primary.opacity(0.45) : DesktopBrand.hairline, lineWidth: isSelected ? 1.2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture {
            pairing.selectedPath = path
        }
    }

    @ViewBuilder
    private func pathActionButton(_ path: DesktopPairingManager.ConnectionPath) -> some View {
        switch path {
        case .tailscale:
            if let ts = pairing.tailscale, ts.isOnline, ts.serveURL == nil {
                Button {
                    Task { await pairing.enableTailscaleServe() }
                } label: {
                    if pairing.isEnablingTailscale {
                        ProgressView().controlSize(.mini)
                    } else {
                        Text("Enable Tailscale HTTPS")
                    }
                }
                .buttonStyle(DesktopPrimaryButtonStyle(compact: true))
                .padding(.top, 3)
            }
        case .quickTunnel:
            if pairing.isQuickTunnelRunning {
                Button("Stop Tunnel") {
                    pairing.stopQuickTunnel()
                }
                .buttonStyle(DesktopSecondaryButtonStyle(compact: true))
                .padding(.top, 3)
            } else {
                Button {
                    pairing.startQuickTunnel()
                } label: {
                    if pairing.isStartingTunnel {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Starting…")
                        }
                    } else {
                        Text("Start Tunnel")
                    }
                }
                .buttonStyle(DesktopPrimaryButtonStyle(compact: true))
                .disabled(pairing.isStartingTunnel || !pairing.hasCloudflaredBinary)
                .padding(.top, 3)
            }
        case .lan, .activeProfile:
            EmptyView()
        }
    }

    private func pathStatus(_ path: DesktopPairingManager.ConnectionPath) -> (label: String, detail: String, color: Color) {
        switch path {
        case .tailscale:
            if let url = pairing.tailscale?.serveURL {
                return ("Ready", url, DesktopBrand.statusLive)
            } else if let ts = pairing.tailscale, ts.isOnline {
                return ("Available", ts.dnsName ?? "tailnet online", .orange)
            } else {
                return ("Offline", "Sign into Tailscale.app", .secondary)
            }
        case .quickTunnel:
            if let url = pairing.quickTunnelURL {
                return ("Live", url, DesktopBrand.statusLive)
            } else if pairing.hasCloudflaredBinary {
                return ("Ready", "Works over 5G via cloudflared", .secondary)
            } else {
                return ("Unavailable", "brew install cloudflared", .secondary)
            }
        case .lan:
            if let ip = pairing.lanIP {
                if pairing.localOpenCode.listensOnLAN {
                    return ("Ready", "http://\(ip):\(pairing.localPort)", DesktopBrand.statusLive)
                }
                return ("Loopback", "http://\(ip):\(pairing.localPort) · needs --mdns", .orange)
            }
            return ("Offline", "No local Wi-Fi address", .secondary)
        case .activeProfile:
            if let active = appState.activeProfile {
                return ("Ready", active.baseURL, DesktopBrand.statusLive)
            }
            return ("None", "No saved server", .secondary)
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CREDENTIALS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Toggle("Embed password in QR", isOn: $includePassword)
                .font(.caption)

            if includePassword {
                HStack(spacing: 6) {
                    SecureField("OPENCODE_SERVER_PASSWORD", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button {
                        Task { await verifyAndSaveCredentials() }
                    } label: {
                        if isVerifyingPassword {
                            ProgressView().controlSize(.mini)
                        } else {
                            Text("Verify")
                        }
                    }
                    .buttonStyle(DesktopSecondaryButtonStyle(compact: true))
                    .disabled(isVerifyingPassword || resolvedPassword.isEmpty || activePairingURL == nil)
                }

                if let msg = verificationMessage {
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(verificationFailed ? .red : DesktopBrand.statusLive)
                } else if resolvedPassword.isEmpty && pairing.localOpenCode.requiresAuth {
                    Text("Saved to Keychain after verify so future pairing is one click.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var rightQRColumn: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 4)

            if let link = pairingLink, let qrImage = DesktopQRCodeGenerator.image(for: link.absoluteString, dimension: 232) {
                VStack(spacing: 14) {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 214, height: 214)
                        .padding(14)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.black.opacity(0.08)))

                    VStack(spacing: 4) {
                        Text(activePairingURL?.absoluteString ?? "")
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(includePassword && !resolvedPassword.isEmpty
                             ? "Includes password · keep private"
                             : "Phone will ask for password")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button {
                            DesktopBrand.copyToClipboard(link.absoluteString)
                            copiedFeedback = true
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                copiedFeedback = false
                            }
                        } label: {
                            Label(copiedFeedback ? "Copied" : "Copy Link", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(DesktopSecondaryButtonStyle(compact: true))

                        if appState.activeProfile == nil, !resolvedPassword.isEmpty {
                            Button("Connect Desktop") {
                                saveCurrentRouteToDesktop(passwordToSave: resolvedPassword)
                            }
                            .buttonStyle(DesktopPrimaryButtonStyle(compact: true))
                        }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text(emptyQRHint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)

                    if pairing.selectedPath == .tailscale, pairing.tailscale?.isOnline == true {
                        Button("Enable Tailscale HTTPS") {
                            Task { await pairing.enableTailscaleServe() }
                        }
                        .buttonStyle(DesktopPrimaryButtonStyle(compact: true))
                    } else if pairing.selectedPath == .quickTunnel, pairing.hasCloudflaredBinary {
                        Button("Start Tunnel") {
                            pairing.startQuickTunnel()
                        }
                        .buttonStyle(DesktopPrimaryButtonStyle(compact: true))
                    }
                }
            }

            Spacer(minLength: 4)
        }
        .padding(20)
    }

    private var emptyQRHint: String {
        switch pairing.selectedPath {
        case .tailscale: "Enable Tailscale HTTPS to generate your pairing QR."
        case .quickTunnel: "Start a tunnel to generate a temporary HTTPS QR."
        case .lan: "Connect to Wi-Fi for a local address."
        case .activeProfile: "Save a server first."
        }
    }

    private func savedMatchingProfile() -> OpenCodeServerProfile? {
        if let activeURL = activePairingURL?.absoluteString.lowercased() {
            if let exact = appState.profileStore.profiles.first(where: { $0.baseURL.lowercased() == activeURL }) {
                return exact
            }
        }
        if let local = appState.profileStore.profiles.first(where: { $0.baseURL.contains("127.0.0.1:\(pairing.localPort)") }) {
            return local
        }
        return appState.activeProfile
    }

    private func hydrateSavedCredentials() {
        if let managed = pairing.managedPassword, !managed.isEmpty {
            password = managed
            return
        }
        if let match = savedMatchingProfile() {
            let saved = appState.profileStore.password(for: match)
            if !saved.isEmpty {
                password = saved
                username = match.username
                serverName = match.name
            }
        }
    }

    private func verifyAndSaveCredentials() async {
        guard let url = activePairingURL else { return }
        let pw = resolvedPassword
        guard !pw.isEmpty else { return }

        isVerifyingPassword = true
        verificationMessage = nil
        verificationFailed = false
        defer { isVerifyingPassword = false }

        let profile = OpenCodeServerProfile(
            id: savedMatchingProfile()?.id ?? UUID(),
            name: serverName.trimmedNonEmpty ?? (Host.current().localizedName ?? "My Mac"),
            baseURL: url.absoluteString,
            username: username.trimmedNonEmpty ?? "opencode",
            allowsLocalHTTP: url.scheme?.lowercased() == "http"
        )
        do {
            let client = OpenCodeClient(profile: profile, password: pw)
            let summary = try await client.probeCompatibility()
            try appState.saveServer(profile, password: pw)
            verificationMessage = "Verified (\(summary.serverVersion ?? "ready")) & saved."
            verificationFailed = false
        } catch {
            verificationMessage = error.localizedDescription
            verificationFailed = true
        }
    }

    private func saveCurrentRouteToDesktop(passwordToSave: String) {
        guard let url = activePairingURL else { return }
        let profile = OpenCodeServerProfile(
            id: savedMatchingProfile()?.id ?? UUID(),
            name: serverName.trimmedNonEmpty ?? (Host.current().localizedName ?? "My Mac"),
            baseURL: url.absoluteString,
            username: username.trimmedNonEmpty ?? "opencode",
            allowsLocalHTTP: url.scheme?.lowercased() == "http"
        )
        try? appState.saveServer(profile, password: passwordToSave)
    }
}
