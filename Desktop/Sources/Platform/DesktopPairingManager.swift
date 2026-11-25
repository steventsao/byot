import AppKit
import Combine
import CoreImage
import Darwin
import Foundation
import Security

/// Generates razor-sharp, nearest-neighbor scaled QR `NSImage`s for `byot://pair` URLs.
enum DesktopQRCodeGenerator {
    static func image(for string: String, dimension: CGFloat = 240) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scale = max(1, floor(dimension / extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }

        let finalSize = NSSize(width: scaled.extent.width, height: scaled.extent.height)
        let image = NSImage(size: finalSize)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSGraphicsContext.current?.cgContext.draw(cgImage, in: NSRect(origin: .zero, size: finalSize))
        image.unlockFocus()
        return image
    }
}

/// Manages local host ergonomics for 1-click mobile pairing (modeled on Orca + T3 Code):
/// - Detects local `opencode serve` (or spawns a managed one with an auto-generated password)
/// - Detects Tailscale HTTPS (`tailscale serve`) and offers 1-click enablement
/// - Detects `cloudflared` for zero-account "Anywhere" HTTPS quick tunnels
/// - Detects this Mac's LAN IPv4 address for same-Wi-Fi fallback
@MainActor
final class DesktopPairingManager: ObservableObject {
    enum ConnectionPath: String, CaseIterable, Identifiable {
        case tailscale
        case quickTunnel
        case lan
        case activeProfile

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tailscale: "Tailscale HTTPS"
            case .quickTunnel: "Anywhere Tunnel"
            case .lan: "Same Wi-Fi (LAN)"
            case .activeProfile: "Current Server"
            }
        }

        var subtitle: String {
            switch self {
            case .tailscale: "Private encrypted HTTPS across your tailnet"
            case .quickTunnel: "Works over 5G with zero account via cloudflared"
            case .lan: "Fast direct local IP on the same Wi-Fi"
            case .activeProfile: "Share the currently selected server profile"
            }
        }

        var symbol: String {
            switch self {
            case .tailscale: "lock.shield.fill"
            case .quickTunnel: "globe"
            case .lan: "wifi"
            case .activeProfile: "server.rack"
            }
        }
    }

    struct TailscaleInfo: Equatable {
        let cliPath: String
        let isOnline: Bool
        let dnsName: String?
        let serveURL: String?
        let proxiesLocalPort: Bool
    }

    struct LocalOpenCodeInfo: Equatable {
        let port: Int
        let isReachable: Bool
        let requiresAuth: Bool
        let version: String?
        let isManagedByDesktop: Bool
        let listensOnLAN: Bool
    }

    @Published var selectedPath: ConnectionPath = .tailscale
    @Published private(set) var tailscale: TailscaleInfo?
    @Published private(set) var localOpenCode = LocalOpenCodeInfo(
        port: 4096, isReachable: false, requiresAuth: false, version: nil, isManagedByDesktop: false, listensOnLAN: false
    )
    @Published private(set) var lanIP: String?
    @Published private(set) var quickTunnelURL: String?
    @Published private(set) var isStartingTunnel = false
    @Published private(set) var isEnablingTailscale = false
    @Published private(set) var isStartingOpenCode = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var managedPassword: String?
    @Published var actionError: String?

    let localPort: Int = 4096
    private var managedOpenCodeProcess: Process?
    private var tunnelProcess: Process?
    private var tunnelPipe: Pipe?
    private var terminateObserver: Any?

    init() {
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdownManagedProcesses()
            }
        }
    }

    var hasOpenCodeBinary: Bool { findOpenCodeBinary() != nil }
    var hasCloudflaredBinary: Bool { findCloudflaredBinary() != nil }

    var isQuickTunnelRunning: Bool {
        tunnelProcess?.isRunning == true && quickTunnelURL != nil
    }

    func refreshAll(activeProfile: OpenCodeServerProfile? = nil) async {
        isRefreshing = true
        defer { isRefreshing = false }

        lanIP = Self.detectPrimaryLANIPv4()
        async let localTask = probeLocalOpenCode()
        async let tsTask = probeTailscale()
        let (local, ts) = await (localTask, tsTask)

        localOpenCode = local
        tailscale = ts

        // Pick the smartest default route automatically.
        if selectedPath == .tailscale, ts?.serveURL == nil {
            if quickTunnelURL != nil {
                selectedPath = .quickTunnel
            } else if let activeProfile, activeProfile.baseURL.lowercased().hasPrefix("https://") {
                selectedPath = .activeProfile
            } else if ts?.isOnline == true {
                selectedPath = .tailscale
            } else if lanIP != nil {
                selectedPath = .lan
            }
        }
    }

    /// Resolves the URL that will be embedded in the `byot://pair` QR code for the selected path.
    func pairingURL(for path: ConnectionPath, activeProfile: OpenCodeServerProfile?) -> URL? {
        switch path {
        case .tailscale:
            guard let raw = tailscale?.serveURL else { return nil }
            return URL(string: raw)
        case .quickTunnel:
            guard let raw = quickTunnelURL else { return nil }
            return URL(string: raw)
        case .lan:
            guard let ip = lanIP else { return nil }
            return URL(string: "http://\(ip):\(localPort)")
        case .activeProfile:
            guard let raw = activeProfile?.baseURL else { return nil }
            return URL(string: raw)
        }
    }

    func buildPairingLink(
        url: URL,
        username: String,
        password: String?,
        name: String,
        directory: String? = nil,
        includePassword: Bool
    ) -> URL {
        let payload = OpenCodePairingPayload(
            baseURL: url,
            username: username.trimmedNonEmpty ?? "opencode",
            password: includePassword ? password?.trimmedNonEmpty : nil,
            directory: directory?.trimmedNonEmpty,
            name: name.trimmedNonEmpty ?? (Host.current().localizedName ?? "My Mac")
        )
        return payload.link
    }

    // MARK: - 1-Click Actions

    /// Enables `tailscale serve --bg http://127.0.0.1:4096` so the Mac's Tailscale
    /// MagicDNS HTTPS URL immediately proxies OpenCode without opening Terminal.
    func enableTailscaleServe() async {
        guard let cli = tailscale?.cliPath ?? findTailscaleBinary() else {
            actionError = "Tailscale CLI was not found. Install or open Tailscale.app first."
            return
        }
        isEnablingTailscale = true
        actionError = nil
        defer { isEnablingTailscale = false }

        let result = await runProcess(
            executable: cli,
            arguments: ["serve", "--bg", "http://127.0.0.1:\(localPort)"]
        )
        if result.exitCode != 0 {
            let detail = result.stderr.trimmedNonEmpty ?? result.stdout.trimmedNonEmpty ?? "Tailscale Serve failed (exit \(result.exitCode))."
            actionError = detail
        }
        tailscale = await probeTailscale()
        if tailscale?.serveURL != nil {
            selectedPath = .tailscale
        }
    }

    /// Starts a zero-account ephemeral HTTPS tunnel (`cloudflared tunnel --url http://127.0.0.1:4096`)
    /// so your iPhone can reach this Mac over 5G even without Tailscale.
    func startQuickTunnel() {
        guard !isStartingTunnel else { return }
        guard let binary = findCloudflaredBinary() else {
            actionError = "Install cloudflared (`brew install cloudflared`) to use Anywhere Quick Tunnels."
            return
        }
        stopQuickTunnel()
        actionError = nil
        isStartingTunnel = true

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["tunnel", "--url", "http://127.0.0.1:\(localPort)", "--no-autoupdate"]

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        tunnelPipe = pipe
        tunnelProcess = process

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            if let match = Self.extractTryCloudflareURL(from: chunk) {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.quickTunnelURL = match
                    self.isStartingTunnel = false
                    self.selectedPath = .quickTunnel
                }
            }
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.tunnelPipe?.fileHandleForReading.readabilityHandler = nil
                self.tunnelPipe = nil
                if self.tunnelProcess === proc {
                    self.tunnelProcess = nil
                    self.quickTunnelURL = nil
                    self.isStartingTunnel = false
                }
            }
        }

        do {
            try process.run()
            // Timeout guard so the spinner never sticks forever if network is offline.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard let self, self.isStartingTunnel, self.quickTunnelURL == nil else { return }
                self.isStartingTunnel = false
                self.actionError = "Timed out waiting for Cloudflare Quick Tunnel URL."
                self.stopQuickTunnel()
            }
        } catch {
            isStartingTunnel = false
            actionError = "Couldn’t start cloudflared: \(error.localizedDescription)"
        }
    }

    func stopQuickTunnel() {
        tunnelPipe?.fileHandleForReading.readabilityHandler = nil
        tunnelPipe = nil
        if let proc = tunnelProcess, proc.isRunning {
            proc.terminate()
        }
        tunnelProcess = nil
        quickTunnelURL = nil
        isStartingTunnel = false
    }

    /// Launches a BYOT-managed local `opencode serve` with an auto-generated password
    /// if no OpenCode server is running on this Mac yet.
    func startManagedOpenCode(bindLAN: Bool = true) async -> String? {
        guard let binary = findOpenCodeBinary() else {
            actionError = "Couldn’t find the `opencode` binary on this Mac."
            return nil
        }
        isStartingOpenCode = true
        actionError = nil
        defer { isStartingOpenCode = false }

        let password = managedPassword ?? Self.generateSecurePassword()
        managedPassword = password

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        var args = ["serve", "--port", String(localPort)]
        if bindLAN {
            args += ["--hostname", "0.0.0.0", "--mdns"]
        } else {
            args += ["--hostname", "127.0.0.1"]
        }
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["OPENCODE_SERVER_PASSWORD"] = password
        env["OPENCODE_SERVER_USERNAME"] = "opencode"
        process.environment = env

        let devNull = FileHandle.nullDevice
        process.standardOutput = devNull
        process.standardError = devNull

        do {
            try process.run()
            managedOpenCodeProcess = process
            // Wait up to 4 seconds for /global/health to respond.
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(250))
                let probe = await probeLocalOpenCode()
                if probe.isReachable {
                    localOpenCode = probe
                    return password
                }
            }
            localOpenCode = await probeLocalOpenCode()
            if !localOpenCode.isReachable {
                actionError = "Started `opencode serve`, but port \(localPort) didn’t answer yet."
            }
            return password
        } catch {
            actionError = "Couldn’t start OpenCode: \(error.localizedDescription)"
            return nil
        }
    }

    func stopManagedOpenCode() {
        if let proc = managedOpenCodeProcess, proc.isRunning {
            proc.terminate()
        }
        managedOpenCodeProcess = nil
        Task { localOpenCode = await probeLocalOpenCode() }
    }

    func shutdownManagedProcesses() {
        stopQuickTunnel()
        if let proc = managedOpenCodeProcess, proc.isRunning {
            proc.terminate()
        }
        managedOpenCodeProcess = nil
    }

    // MARK: - Probes

    private func probeLocalOpenCode() async -> LocalOpenCodeInfo {
        let managed = managedOpenCodeProcess?.isRunning == true
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/global/health") else {
            return LocalOpenCodeInfo(port: localPort, isReachable: false, requiresAuth: false, version: nil, isManagedByDesktop: managed, listensOnLAN: false)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return LocalOpenCodeInfo(port: localPort, isReachable: false, requiresAuth: false, version: nil, isManagedByDesktop: managed, listensOnLAN: false)
            }
            let reachable = http.statusCode == 401 || (200..<300).contains(http.statusCode)
            let version = (200..<300).contains(http.statusCode)
                ? (try? JSONDecoder().decode(OpenCodeHealth.self, from: data))?.version
                : nil
            let lanReachable = reachable ? await isLANPortReachable() : false
            return LocalOpenCodeInfo(
                port: localPort,
                isReachable: reachable,
                requiresAuth: http.statusCode == 401,
                version: version,
                isManagedByDesktop: managed,
                listensOnLAN: lanReachable
            )
        } catch {
            return LocalOpenCodeInfo(port: localPort, isReachable: false, requiresAuth: false, version: nil, isManagedByDesktop: managed, listensOnLAN: false)
        }
    }

    private func isLANPortReachable() async -> Bool {
        guard let ip = lanIP, let url = URL(string: "http://\(ip):\(localPort)/global/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return http.statusCode == 401 || (200..<300).contains(http.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    private func probeTailscale() async -> TailscaleInfo? {
        guard let cli = findTailscaleBinary() else { return nil }
        let status = await runProcess(executable: cli, arguments: ["status", "--json"])
        guard status.exitCode == 0,
              let data = status.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = json["Self"] as? [String: Any]
        else {
            return TailscaleInfo(cliPath: cli, isOnline: false, dnsName: nil, serveURL: nil, proxiesLocalPort: false)
        }

        let online = (selfNode["Online"] as? Bool) ?? false
        var dns = (selfNode["DNSName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        while dns?.hasSuffix(".") == true { dns?.removeLast() }

        let serve = await runProcess(executable: cli, arguments: ["serve", "status"])
        let parsedServe = Self.parseTailscaleServeStatus(serve.stdout, expectedPort: localPort)

        return TailscaleInfo(
            cliPath: cli,
            isOnline: online,
            dnsName: dns?.trimmedNonEmpty,
            serveURL: parsedServe.url,
            proxiesLocalPort: parsedServe.proxiesPort
        )
    }

    private static func parseTailscaleServeStatus(_ output: String, expectedPort: Int) -> (url: String?, proxiesPort: Bool) {
        var foundURL: String?
        var proxiesPort = false
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("https://"), let first = line.split(separator: " ").first {
                foundURL = String(first).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            if line.contains("127.0.0.1:\(expectedPort)") || line.contains("localhost:\(expectedPort)") {
                proxiesPort = true
            }
        }
        return (proxiesPort ? foundURL : nil, proxiesPort)
    }

    private nonisolated static func extractTryCloudflareURL(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"https://[a-zA-Z0-9-]+\.trycloudflare\.com"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private func findOpenCodeBinary() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.opencode/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func findTailscaleBinary() -> String? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func findCloudflaredBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private struct ProcessOutput: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    private func runProcess(executable: String, arguments: [String]) async -> ProcessOutput {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = arguments
                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe
                do {
                    try proc.run()
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    proc.waitUntilExit()
                    continuation.resume(returning: ProcessOutput(
                        exitCode: proc.terminationStatus,
                        stdout: String(data: outData, encoding: .utf8) ?? "",
                        stderr: String(data: errData, encoding: .utf8) ?? ""
                    ))
                } catch {
                    continuation.resume(returning: ProcessOutput(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                }
            }
        }
    }

    /// Reads the Mac's primary non-loopback IPv4 LAN address directly via `getifaddrs`.
    private static func detectPrimaryLANIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var preferred: [String: String] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: current.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostBuffer)
                if OpenCodeLocalEndpointPolicy.isLocalHost(ip), !ip.hasPrefix("169.254.") {
                    preferred[name] = ip
                }
            }
        }
        for iface in ["en0", "en1", "en2", "en3"] {
            if let ip = preferred[iface] { return ip }
        }
        return preferred.values.first
    }

    private static func generateSecurePassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
