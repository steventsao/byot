import AVFoundation
import PhotosUI
import SwiftUI

/// Pages pushed inside the server form that fill it in for the person.
enum OpenCodeServerSetupRoute: Hashable {
    case scan
    case nearby
}

enum OpenCodeServerSetupCommand {
    /// Prints a pairing QR code in the terminal of the computer running OpenCode.
    static let pairing = "curl -fsSL https://raw.githubusercontent.com/steventsao/byot/main/scripts/byot-pair-qr.sh | bash -s -- https://your-mac.example.ts.net"
    /// Advertises OpenCode on the local network for Find nearby.
    static let nearby = "OPENCODE_SERVER_PASSWORD=your-password opencode serve --mdns"
}

// MARK: - Scan

struct OpenCodePairingScannerView: View {
    let onPayload: (OpenCodePairingPayload) -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var access = OpenCodeCameraAccess.current
    @State private var cameraFailed = false
    @State private var gate = OpenCodePairingScanGate()
    @State private var message: String?
    @State private var photo: PhotosPickerItem?
    @State private var isReadingPhoto = false
    @State private var successes = 0
    @State private var copies = 0

    var body: some View {
        Form {
            Section {
                camera
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            } footer: {
                Text(isCameraLive
                    ? "Point the camera at the pairing code shown on your computer. byot fills in the address and sign-in; nothing is saved until you tap Save."
                    : "byot fills in the address and sign-in from the code; nothing is saved until you tap Save.")
            }

            if let message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.cleanCaption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("pairing-error")
                }
            }

            Section("Other ways") {
                PhotosPicker(selection: $photo, matching: .images) {
                    HStack {
                        Label("Choose from Photos", systemImage: "photo.on.rectangle")
                        Spacer()
                        if isReadingPhoto { ProgressView().accessibilityLabel("Reading photo") }
                    }
                }
                .disabled(isReadingPhoto)
                PasteButton(payloadType: String.self) { strings in
                    let code = strings.first ?? ""
                    Task { @MainActor in handle(code, fromCamera: false) }
                }
                .labelStyle(.titleAndIcon)
                .accessibilityHint("Pastes a byot pairing link or server address")
            }

            Section {
                Text(OpenCodeServerSetupCommand.pairing)
                    .font(.cleanMono)
                    .textSelection(.enabled)
                Button("Copy command", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = OpenCodeServerSetupCommand.pairing
                    copies += 1
                }
                .sensoryFeedback(.success, trigger: copies)
            } header: {
                Text("Make a pairing code")
            } footer: {
                Text("Run it on the computer with your OpenCode server, using the address your iPhone reaches. It reads OPENCODE_SERVER_PASSWORD, and the code contains that password, so don’t share it.")
            }
        }
        .navigationTitle("Scan pairing code")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: successes)
        .task {
            guard access == .notDetermined else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            access = granted ? .authorized : OpenCodeCameraAccess.current
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from Settings may have changed camera access.
            if phase == .active, access != .notDetermined { access = OpenCodeCameraAccess.current }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            readPhoto(item)
        }
    }

    private var isCameraLive: Bool { access == .authorized && !cameraFailed }

    @ViewBuilder
    private var camera: some View {
        switch access {
        case .authorized where !cameraFailed:
            OpenCodeQRCameraView(
                onCode: { handle($0, fromCamera: true) },
                onFailure: { cameraFailed = true }
            )
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: 420)
            .clipShape(RoundedRectangle(cornerRadius: BYOTBrand.panelRadius, style: .continuous))
            .overlay {
                OpenCodeViewfinder()
                    .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .padding(48)
                    .shadow(color: BYOTBrand.shadow, radius: 4)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("pairing-camera")
        case .notDetermined:
            cameraPanel(
                systemImage: "camera",
                title: "Allow camera access",
                detail: "byot uses the camera only to read the pairing code."
            )
        case .denied:
            cameraPanel(
                systemImage: "camera.fill",
                title: "Camera access is off",
                detail: "Allow camera access in Settings, or choose a photo of the code below.",
                opensSettings: true
            )
        case .restricted:
            cameraPanel(
                systemImage: "camera.fill",
                title: "Camera is restricted",
                detail: "Choose a photo of the code or paste the pairing link below."
            )
        case .unavailable, .authorized:
            cameraPanel(
                systemImage: "camera",
                title: "No camera available",
                detail: "Choose a photo of the code or paste the pairing link below."
            )
        }
    }

    private func cameraPanel(
        systemImage: String,
        title: String,
        detail: String,
        opensSettings: Bool = false
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        } actions: {
            if opensSettings {
                Button("Open Settings", systemImage: "gear") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .background(BYOTBrand.surface, in: RoundedRectangle(cornerRadius: BYOTBrand.panelRadius, style: .continuous))
    }

    private func readPhoto(_ item: PhotosPickerItem) {
        isReadingPhoto = true
        message = nil
        Task {
            defer {
                isReadingPhoto = false
                photo = nil
            }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                show("That photo couldn’t be opened. Try another one.")
                return
            }
            let codes = await Task.detached(priority: .userInitiated) {
                OpenCodeQRCode.messages(inImageData: data)
            }.value
            guard !codes.isEmpty else {
                show("No QR code found in that photo. Crop it to the code and try again.")
                return
            }
            let code = codes.first { (try? OpenCodePairingPayload(code: $0)) != nil } ?? codes[0]
            handle(code, fromCamera: false)
        }
    }

    private func handle(_ code: String, fromCamera: Bool) {
        if fromCamera {
            guard gate.shouldHandle(code) else { return }
        } else {
            guard !gate.isFinished else { return }
        }
        do {
            let payload = try OpenCodePairingPayload(code: code)
            gate.finish()
            message = nil
            successes += 1
            onPayload(payload)
        } catch {
            show(error.localizedDescription)
        }
    }

    private func show(_ text: String) {
        message = text
        AccessibilityNotification.Announcement(text).post()
    }
}

/// Four rounded corner brackets framing the scan area.
private struct OpenCodeViewfinder: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.18
        var path = Path()
        for (corner, dx, dy) in [
            (CGPoint(x: rect.minX, y: rect.minY), 1.0, 1.0),
            (CGPoint(x: rect.maxX, y: rect.minY), -1.0, 1.0),
            (CGPoint(x: rect.minX, y: rect.maxY), 1.0, -1.0),
            (CGPoint(x: rect.maxX, y: rect.maxY), -1.0, -1.0),
        ] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * length))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * length, y: corner.y))
        }
        return path
    }
}

// MARK: - Find nearby

struct OpenCodeDiscoveryView: View {
    @StateObject private var store: OpenCodeDiscoveryStore
    @Environment(\.openURL) private var openURL
    @State private var copies = 0
    let select: (OpenCodeDiscoveredServer) -> Void

    init(
        browser: @autoclosure @escaping () -> any OpenCodeBonjourBrowsing = OpenCodeBonjourBrowser(),
        select: @escaping (OpenCodeDiscoveredServer) -> Void
    ) {
        _store = StateObject(wrappedValue: OpenCodeDiscoveryStore(browser: browser()))
        self.select = select
    }

    var body: some View {
        List {
            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "wifi.exclamationmark")
                        .font(.cleanCaption)
                        .foregroundStyle(.red)
                    Button("Open Settings", systemImage: "gear") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    Button("Try again", systemImage: "arrow.clockwise") { store.start() }
                }
            }

            if !store.servers.isEmpty {
                Section {
                    ForEach(store.servers) { server in
                        Button { select(server) } label: {
                            HStack(spacing: BYOTBrand.Space.md) {
                                Image(systemName: "desktopcomputer")
                                    .font(.cleanControlIcon)
                                    .foregroundStyle(BYOTBrand.accent)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
                                    Text(server.title)
                                        .font(.cleanBodySemibold)
                                        .foregroundStyle(BYOTBrand.ink)
                                    Text(server.address)
                                        .font(.cleanMono)
                                        .foregroundStyle(BYOTBrand.mutedInk)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.forward")
                                    .font(.cleanCaptionBold)
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(server.title), \(server.address)")
                        .accessibilityHint("Fills in this server’s address")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityIdentifier("nearby-server")
                    }
                } header: {
                    Text("On this network")
                } footer: {
                    Text("Nearby servers connect over plain HTTP on this network, so anyone on it could read the traffic. Use HTTPS on shared Wi-Fi. You’ll still enter the server password.")
                }
            }
        }
        .overlay {
            if store.errorMessage == nil, store.servers.isEmpty {
                if store.isSearching {
                    BYOTActivityView(
                        .loading,
                        title: "Looking nearby",
                        detail: "Searching this network for OpenCode servers.",
                        layout: .blocking
                    )
                } else {
                    emptyState
                }
            }
        }
        .navigationTitle("Find nearby")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Search again", systemImage: "arrow.clockwise") { store.start() }
                    .disabled(store.isSearching)
            }
        }
        .task { store.start() }
        .onDisappear { store.stop() }
    }

    private var emptyState: some View {
        ScrollView {
            ContentUnavailableView {
                Label("No servers found yet", systemImage: "wifi")
            } description: {
                VStack(spacing: BYOTBrand.Space.sm) {
                    Text("On a computer on this Wi-Fi network, start OpenCode with --mdns. byot keeps looking while this page is open. If nothing appears, check that Local Network is on for byot in Settings.")
                    Text(OpenCodeServerSetupCommand.nearby)
                        .font(.cleanMono)
                        .textSelection(.enabled)
                        .padding(BYOTBrand.Space.sm)
                        .background(BYOTBrand.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            } actions: {
                Button("Copy command", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = OpenCodeServerSetupCommand.nearby
                    copies += 1
                }
                .buttonStyle(.bordered)
                .sensoryFeedback(.success, trigger: copies)
            }
        }
    }
}
