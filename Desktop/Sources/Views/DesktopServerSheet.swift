import SwiftUI

struct DesktopServerSheet: View {
    @ObservedObject var appState: DesktopAppState
    let editing: OpenCodeServerProfile?
    let initialPairingURL: URL?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var discovery = OpenCodeDiscoveryStore()

    @State private var name = ""
    @State private var baseURL = ""
    @State private var username = "opencode"
    @State private var password = ""
    @State private var directory = ""
    @State private var allowsLocalHTTP = false
    @State private var pairingInput = ""
    @State private var isTesting = false
    @State private var isRedeeming = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing == nil ? "Add Server" : "Edit Server")
                    .font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if editing == nil {
                        quickConnectSection
                        pairingSection
                    }
                    manualFormSection

                    if let statusMessage {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Button {
                    Task { await testConnection() }
                } label: {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test Connection")
                    }
                }
                .disabled(isTesting || baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button("Save & Connect") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
        }
        .frame(width: 520, height: 560)
        .onAppear {
            seedInitialValues()
            if editing == nil { discovery.start() }
        }
        .onDisappear {
            discovery.stop()
        }
    }

    @ViewBuilder
    private var quickConnectSection: some View {
        if let local = appState.localProbe {
            VStack(alignment: .leading, spacing: 6) {
                Text("This Mac")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Local OpenCode")
                            .font(.callout.weight(.semibold))
                        Text(local.baseURL + (local.version.map { " · v\($0)" } ?? ""))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Use Local") {
                        name = Host.current().localizedName ?? "This Mac"
                        baseURL = local.baseURL
                        username = "opencode"
                        allowsLocalHTTP = true
                        statusMessage = local.requiresAuth
                            ? "Local server uses Basic auth — enter your server password below."
                            : "Local server selected."
                        errorMessage = nil
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(DesktopBrand.hairline))
            }
        }

        if !discovery.servers.isEmpty || discovery.isSearching {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Nearby on Network (Bonjour)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if discovery.isSearching {
                        ProgressView().controlSize(.mini)
                    }
                }

                ForEach(discovery.servers) { server in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.title)
                                .font(.callout.weight(.medium))
                            Text(server.address)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Select") {
                            applyPayload(server.pairingPayload)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(DesktopBrand.surface, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Pairing Link or Code")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Paste byot://pair or opencode pair link…", text: $pairingInput)
                    .textFieldStyle(.roundedBorder)
                Button {
                    Task { await parseOrRedeemPairing() }
                } label: {
                    if isRedeeming {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Apply")
                    }
                }
                .disabled(isRedeeming || pairingInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var manualFormSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Server Details")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Name")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .trailing)
                    TextField("Mac Studio / Local", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Server URL")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .trailing)
                    TextField("https://my-mac.ts.net or http://127.0.0.1:4096", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: baseURL) { _, next in
                            if let host = URLComponents(string: next.trimmingCharacters(in: .whitespacesAndNewlines))?.host,
                               next.lowercased().hasPrefix("http://"),
                               OpenCodeLocalEndpointPolicy.isLocalHost(host) {
                                allowsLocalHTTP = true
                            }
                        }
                }
                GridRow {
                    Text("Username")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .trailing)
                    TextField("opencode", text: $username)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Password")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .trailing)
                    SecureField("OPENCODE_SERVER_PASSWORD", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Directory")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .trailing)
                    TextField("Optional default working directory", text: $directory)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func seedInitialValues() {
        if let editing {
            name = editing.name
            baseURL = editing.baseURL
            username = editing.username
            password = appState.profileStore.password(for: editing)
            directory = editing.directory
            allowsLocalHTTP = editing.allowsLocalHTTP
        } else if let url = initialPairingURL {
            pairingInput = url.absoluteString
            Task { await parseOrRedeemPairing() }
        }
    }

    private func applyPayload(_ payload: OpenCodePairingPayload) {
        baseURL = payload.baseURL.absoluteString
        allowsLocalHTTP = payload.allowsLocalHTTP
        if let n = payload.name, !n.isEmpty { name = n }
        if let u = payload.username, !u.isEmpty { username = u }
        if let p = payload.password, !p.isEmpty { password = p }
        if let d = payload.directory, !d.isEmpty { directory = d }
        statusMessage = "Pairing details applied."
        errorMessage = nil
    }

    private func parseOrRedeemPairing() async {
        let raw = pairingInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        errorMessage = nil
        statusMessage = nil

        do {
            if let oneTime = try OpenCodeOneTimePairing.parse(raw, allowsLoopback: true) {
                isRedeeming = true
                defer { isRedeeming = false }
                let result = await OpenCodePairingRedeemer().redeem(oneTime)
                switch result {
                case .paired:
                    if let payload = result.payload {
                        applyPayload(payload)
                        statusMessage = "Paired with OpenCode 2 token."
                    }
                case .expired:
                    errorMessage = "That one-time pairing code has already been used or expired."
                case .unreachable:
                    errorMessage = "Could not reach any address in that pairing code."
                }
                return
            }

            let payload = try OpenCodePairingPayload(code: raw)
            applyPayload(payload)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func buildProfile() -> OpenCodeServerProfile {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = URLComponents(string: trimmedURL)?.host ?? "OpenCode"
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenCodeServerProfile(
            id: editing?.id ?? UUID(),
            name: trimmedName.isEmpty ? defaultName : trimmedName,
            baseURL: trimmedURL,
            username: username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "opencode" : username.trimmingCharacters(in: .whitespacesAndNewlines),
            directory: directory.trimmingCharacters(in: .whitespacesAndNewlines),
            allowsLocalHTTP: allowsLocalHTTP
        )
    }

    private func testConnection() async {
        isTesting = true
        errorMessage = nil
        statusMessage = nil
        defer { isTesting = false }

        let profile = buildProfile()
        do {
            try profile.validate(password: password)
            let client = OpenCodeClient(profile: profile, password: password)
            let summary = try await client.probeCompatibility()
            let version = summary.serverVersion ?? "server"
            statusMessage = "Connected to OpenCode \(version)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveAndDismiss() {
        errorMessage = nil
        let profile = buildProfile()
        do {
            try appState.saveServer(profile, password: password)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
