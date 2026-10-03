import Foundation
import Testing
@testable import byot

/// Records what would have gone to the vendor.
private final class RecordingTransport: BYOTTelemetryTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var startedWith: [UUID] = []
    private var events: [(name: String, properties: [String: Any])] = []
    private var stops = 0

    func start(installID: UUID, readInstallID: @escaping @Sendable () -> UUID?) {
        lock.withLock { startedWith.append(installID) }
    }

    func capture(_ event: String, properties: [String: Any]) {
        lock.withLock { events.append((event, properties)) }
    }

    func stop() { lock.withLock { stops += 1 } }

    var installIDs: [UUID] { lock.withLock { startedWith } }
    var names: [String] { lock.withLock { events.map(\.name) } }
    var captured: [(name: String, properties: [String: Any])] { lock.withLock { events } }
    var stopCount: Int { lock.withLock { stops } }
}

private func makeTelemetry(environment: BYOTTelemetry.Environment = .shipping,
                           consent: BYOTTelemetryConsent? = nil)
    throws -> (BYOTTelemetry, RecordingTransport, UserDefaults) {
    let defaults = try #require(UserDefaults(suiteName: "byot-telemetry-\(UUID().uuidString)"))
    if let consent { defaults.set(consent.rawValue, forKey: BYOTTelemetry.consentKey) }
    let transport = RecordingTransport()
    return (BYOTTelemetry(defaults: defaults, environment: environment, transport: transport), transport, defaults)
}

@Suite("Usage data contract")
struct BYOTTelemetrySchemaTests {
    @Test("Only the schema's keys and enum-like values pass")
    func schema() {
        #expect(BYOTTelemetry.validate(.appOpened, ["launch": "cold"]) != nil)
        #expect(BYOTTelemetry.validate(.appOpened, ["launch": "cold", "host": "mac.ts.net"]) == nil)
        #expect(BYOTTelemetry.validate(.turnRequested, ["attachment_count": 2, "variant_set": true]) != nil)
        #expect(BYOTTelemetry.validate(.turnRequested, ["model": String(repeating: "x", count: 65)]) == nil)
        #expect(BYOTTelemetry.validate(.turnRequested, ["model": ""]) == nil)
        #expect(BYOTTelemetry.validate(.turnRequested, ["model": ["a", "b"]]) == nil)
        #expect(BYOTTelemetry.validate(.turnCompleted, ["duration_ms": Double.infinity]) == nil)
    }

    @Test("A payload outside the schema is dropped whole, and counted")
    func dropsWholeEvent() throws {
        let (telemetry, transport, _) = try makeTelemetry(consent: .enabled)
        telemetry.start()
        telemetry.record(.sessionStarted, ["server_protocol": "v1", "directory": "/Users/me/repo"])
        #expect(transport.names == ["app_opened"])
        #expect(telemetry.droppedEventCount == 1)
    }

    @Test("The SDK boundary keeps schema keys and vendor context only")
    func sanitizer() {
        let kept = BYOTTelemetrySanitizer().sanitize([
            "launch": "cold", "$os_version": "26.4", "$device_name": "Steven's iPhone", "$timezone": "America/Los_Angeles",
            "server_url": "https://mac.ts.net", "$set": ["email": "x"],
        ])
        #expect(Set(kept.keys) == ["launch", "$os_version"])
    }

    @Test("Every mapping the app sends passes its own schema")
    func mappingsFitSchema() throws {
        let profile = OpenCodeServerProfile(name: "Studio", baseURL: "https://studio.tail1234.ts.net")
        let model = OpenCodeModelOption(providerID: "anthropic", providerName: "Anthropic",
                                        modelID: "claude-sonnet-4-5", modelName: "Claude Sonnet", status: nil)
        let prompt = OpenCodeQueuedPrompt(text: "fix the tests", model: model, agent: "build", variant: "high")
        let turn = BYOTTelemetryTurn(prompt: prompt, startedAt: Date(timeIntervalSinceNow: -12))
        let (telemetry, transport, _) = try makeTelemetry(consent: .enabled)
        telemetry.start()
        telemetry.recordServerConnected(profile: profile, serverProtocol: .v1)
        telemetry.record(.sessionStarted, ["server_protocol": "v2"])
        telemetry.record(.turnRequested, BYOTTelemetryOpenCode.turnRequested(prompt, delivery: .queued))
        telemetry.record(.turnRequested, BYOTTelemetryOpenCode.shellRequested())
        telemetry.record(.turnCompleted, BYOTTelemetryOpenCode.turnCompleted(turn, result: "completed", messages: [], now: .now))
        telemetry.record(.errorOccurred, BYOTTelemetryOpenCode.errorOccurred(URLError(.timedOut), surface: .sessionList))
        telemetry.record(.errorOccurred, BYOTTelemetryOpenCode.turnFailed(details: ["type": .string("APIError"), "status": .number(410)]))
        #expect(telemetry.droppedEventCount == 0)
        #expect(transport.names == ["app_opened", "server_connected", "session_started", "turn_requested",
                                    "turn_requested", "turn_completed", "error_occurred", "error_occurred"])
        let connected = try #require(transport.captured.first { $0.name == "server_connected" }).properties
        #expect(connected["host_kind"] as? String == "tailscale")
        #expect(connected["transport"] as? String == "https")
        #expect(connected["compatibility"] as? String == "unknown")
        let completed = try #require(transport.captured.first { $0.name == "turn_completed" }).properties
        #expect((completed["duration_ms"] as? Int ?? 0) >= 11_000)
        #expect(completed["model"] as? String == "claude-sonnet-4-5")
        let failed = try #require(transport.captured.last).properties
        #expect(failed["error_class"] as? String == "model_unavailable")
    }
}

@Suite("Usage data consent")
struct BYOTTelemetryConsentTests {
    @Test("Nothing leaves the device until the person opts in")
    func optIn() throws {
        let (telemetry, transport, defaults) = try makeTelemetry()
        #expect(telemetry.block == .consentPending)
        #expect(telemetry.shouldAskForConsent)
        telemetry.start()
        telemetry.record(.sessionStarted, ["server_protocol": "v1"])
        #expect(transport.names.isEmpty)
        #expect(defaults.string(forKey: BYOTTelemetry.installIDKey) == nil)

        telemetry.setConsent(true)
        #expect(telemetry.block == nil)
        #expect(telemetry.shouldAskForConsent == false)
        let installID = try #require(defaults.string(forKey: BYOTTelemetry.installIDKey).flatMap(UUID.init(uuidString:)))
        #expect(transport.installIDs == [installID])
        #expect(transport.names == ["app_opened"])
        #expect(transport.captured.first?.properties["launch"] as? String == "opt_in")
        telemetry.record(.sessionStarted, ["server_protocol": "v1"])
        #expect(transport.names == ["app_opened", "session_started"])
    }

    @Test("Opting out stops the vendor and forgets the identity; opting in again starts fresh")
    func optOut() throws {
        let (telemetry, transport, defaults) = try makeTelemetry(consent: .enabled)
        telemetry.start()
        let first = try #require(defaults.string(forKey: BYOTTelemetry.installIDKey))
        telemetry.setConsent(false)
        #expect(telemetry.block == .declined)
        #expect(transport.stopCount == 1)
        #expect(defaults.string(forKey: BYOTTelemetry.installIDKey) == nil)
        #expect(defaults.string(forKey: BYOTTelemetry.consentKey) == "disabled")
        telemetry.record(.sessionStarted, ["server_protocol": "v1"])
        #expect(transport.names == ["app_opened"])

        telemetry.setConsent(true)
        let second = try #require(defaults.string(forKey: BYOTTelemetry.installIDKey))
        #expect(first != second)
        #expect(transport.installIDs.count == 2)
    }

    @Test("Tests, the kill switch and forks never send, whatever the stored consent says")
    func environmentGates() throws {
        var environment = BYOTTelemetry.Environment.shipping
        environment.isAutomated = true
        #expect(try makeTelemetry(environment: environment, consent: .enabled).0.block == .automated)
        environment = .shipping
        environment.killSwitch = true
        let (killed, killedTransport, _) = try makeTelemetry(environment: environment, consent: .enabled)
        #expect(killed.block == .killSwitch)
        #expect(killed.shouldAskForConsent == false)
        killed.start()
        killed.setConsent(true)
        #expect(killedTransport.names.isEmpty)
        environment = .shipping
        environment.bundleIdentifier = "dev.example.byot-fork"
        #expect(try makeTelemetry(environment: environment, consent: .enabled).0.block == .foreignBuild)
    }

    @Test("A cold launch counts once; later activations are resumes; one server connects once")
    func launchesAndServers() throws {
        let (telemetry, transport, _) = try makeTelemetry(consent: .enabled)
        telemetry.start()
        telemetry.applicationDidBecomeActive()
        telemetry.applicationDidBecomeActive()
        let serverID = UUID()
        telemetry.recordServerConnected(serverID: serverID, ["transport": "https"])
        telemetry.recordServerConnected(serverID: serverID, ["transport": "https"])
        telemetry.recordServerConnected(serverID: UUID(), ["transport": "http"])
        #expect(transport.names == ["app_opened", "app_opened", "server_connected", "server_connected"])
        #expect(transport.captured.map { $0.properties["launch"] as? String } == ["cold", "resume", nil, nil])
    }
}

@Suite("Usage data vocabulary")
struct BYOTTelemetryVocabularyTests {
    @Test("Addresses become kinds, never hosts")
    func hostKinds() {
        func kind(_ url: String) -> String { BYOTTelemetryOpenCode.hostKind(of: URL(string: url)) }
        #expect(kind("https://studio.tail1234.ts.net") == "tailscale")
        #expect(kind("http://100.101.102.103:4096") == "tailscale")
        #expect(kind("http://192.168.1.20:4096") == "local_address")
        #expect(kind("https://studio.local:4096") == "local_name")
        #expect(kind("https://studio") == "local_name")
        #expect(kind("https://opencode.example.com") == "public")
        #expect(BYOTTelemetryOpenCode.hostKind(of: nil) == "unknown")
        #expect(BYOTTelemetryOpenCode.transport(of: URL(string: "http://192.168.1.20")) == "http")
        #expect(BYOTTelemetryOpenCode.serverVersion("1.18.21") == "1.18")
        #expect(BYOTTelemetryOpenCode.serverVersion("garbage") == "unknown")
        #expect(BYOTTelemetryOpenCode.serverVersion(nil) == "unknown")
    }

    @Test("Custom providers, models and agents report as other")
    func vocabulary() {
        let custom = OpenCodeModelOption(providerID: "acme-internal", providerName: "Acme",
                                         modelID: "secret-model", modelName: "Secret", status: nil)
        let known = OpenCodeModelOption(providerID: "openai", providerName: "OpenAI",
                                        modelID: "gpt-5", modelName: "GPT-5", status: nil)
        #expect(BYOTTelemetryOpenCode.provider("acme-internal") == "other")
        #expect(BYOTTelemetryOpenCode.provider("Anthropic") == "anthropic")
        #expect(BYOTTelemetryOpenCode.provider(nil) == "none")
        #expect(BYOTTelemetryOpenCode.model(custom) == "other")
        #expect(BYOTTelemetryOpenCode.model(known) == "gpt-5")
        #expect(BYOTTelemetryOpenCode.model(nil) == "none")
        #expect(BYOTTelemetryOpenCode.agent("plan") == "plan")
        #expect(BYOTTelemetryOpenCode.agent("steven-reviewer") == "other")
        #expect(BYOTTelemetryOpenCode.agent(nil) == "none")
    }

    @Test("Errors become classes without their messages")
    func errorClasses() {
        func cls(_ error: any Error) -> String { BYOTTelemetryOpenCode.errorClass(error) }
        #expect(cls(OpenCodeConnectionError.httpStatus(401, "Unauthorized for steven")) == "authentication")
        #expect(cls(OpenCodeConnectionError.httpStatus(404, nil)) == "not_found")
        #expect(cls(OpenCodeConnectionError.httpStatus(503, nil)) == "server_error")
        #expect(cls(OpenCodeConnectionError.invalidProfile("Enter a complete HTTPS server URL.")) == "invalid_profile")
        #expect(cls(OpenCodeConnectionError.emptyResponse) == "invalid_response")
        #expect(cls(OpenCodeConnectionError.server("The model claude-3 is no longer available")) == "model_unavailable")
        #expect(cls(URLError(.cannotConnectToHost)) == "unreachable")
        #expect(cls(URLError(.secureConnectionFailed)) == "tls")
        #expect(cls(CancellationError()) == "cancelled")
        #expect(BYOTTelemetryOpenCode.failureClass(OpenCodeMessageError(name: "MessageAbortedError", data: nil)) == "aborted")
        #expect(BYOTTelemetryOpenCode.failureClass(OpenCodeMessageError(name: "SomethingElse", data: nil)) == "turn_failed")
    }
}
