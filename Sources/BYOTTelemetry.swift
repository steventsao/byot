import Foundation
import PostHog

/// Anonymous, opt-in product usage events: seven names, fixed property keys,
/// enum-like values. docs/features/telemetry.md is the public contract; keep
/// the two in step. Nothing here may carry prompts, code, server addresses,
/// directories, project or session names, or any free text a person typed.
enum BYOTTelemetryEvent: String, CaseIterable, Sendable {
    case appOpened = "app_opened"
    case serverConnected = "server_connected"
    case sessionStarted = "session_started"
    case turnRequested = "turn_requested"
    case turnCompleted = "turn_completed"
    case errorOccurred = "error_occurred"
    case nudgeOutcome = "nudge_outcome"

    /// The only property keys this event may carry. A payload with any other
    /// key is dropped whole, so a new field needs a schema change here and a
    /// line in the docs, never a quiet addition at a call site.
    var allowedProperties: Set<String> {
        switch self {
        case .appOpened: ["launch"]
        case .serverConnected: ["transport", "host_kind", "server_protocol", "server_version", "compatibility"]
        case .sessionStarted: ["server_protocol"]
        case .turnRequested:
            ["kind", "delivery", "agent", "provider", "model", "variant_set", "attachment_count",
             "file_reference_count", "server_protocol"]
        case .turnCompleted:
            ["result", "duration_ms", "agent", "provider", "model", "input_tokens", "output_tokens",
             "reasoning_tokens", "reply_count", "server_protocol"]
        case .errorOccurred: ["error_class", "surface", "server_protocol"]
        case .nudgeOutcome: ["kind", "outcome", "completed_turns", "threshold"]
        }
    }

    static let allAllowedProperties = Set(allCases.flatMap(\.allowedProperties))
}

enum BYOTTelemetryConsent: String, Sendable {
    /// Nothing is sent, and the app may still ask once.
    case undecided
    case enabled
    case disabled
}

/// Where the events go. The app uses PostHog; tests record in memory.
protocol BYOTTelemetryTransport: Sendable {
    /// Called once events may flow. `installID` is the only identity the
    /// vendor ever sees; `readInstallID` re-reads it after a reset.
    func start(installID: UUID, readInstallID: @escaping @Sendable () -> UUID?)
    func capture(_ event: String, properties: [String: Any])
    /// Opt-out: stop sending, forget the identity, drop anything queued.
    func stop()
}

final class BYOTTelemetry: @unchecked Sendable {
    typealias Properties = [String: any Sendable]

    /// Why events stay on the device. `nil` means they may leave.
    enum Block: Equatable, Sendable {
        /// Unit tests and UI fixtures.
        case automated
        /// `--telemetry-disabled` or `BYOT_TELEMETRY_DISABLED=1`.
        case killSwitch
        /// A build with another bundle identifier, such as a fork.
        case foreignBuild
        case consentPending
        case declined
    }

    /// What the process says about itself, so tests can pretend to be the
    /// shipping app.
    struct Environment: Sendable {
        var isAutomated: Bool
        var killSwitch: Bool
        var bundleIdentifier: String

        static let current = Environment(
            isAutomated: BYOTLaunch.isAutomated,
            killSwitch: ProcessInfo.processInfo.arguments.contains(BYOTTelemetry.disableArgument)
                || ProcessInfo.processInfo.environment[BYOTTelemetry.disableEnvironment] == "1",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "")

        static let shipping = Environment(isAutomated: false, killSwitch: false,
                                          bundleIdentifier: BYOTTelemetry.shippingBundleIdentifier)
    }

    static let shared = BYOTTelemetry()

    static let consentKey = "byot.telemetry.consent"
    static let installIDKey = "byot.telemetry.install-id"
    static let disableArgument = "--telemetry-disabled"
    static let disableEnvironment = "BYOT_TELEMETRY_DISABLED"
    static let shippingBundleIdentifier = "com.steventsao.byot"
    /// A PostHog project token only accepts writes; it is public by design.
    static let projectToken = "phc_o7tybZgZzgjjVQE8b54kSRqEW2Q2g6yLznpbk6SyKvw5"
    static let host = "https://us.i.posthog.com"
    /// Longer strings are free text by definition and drop the event.
    static let maximumStringLength = 64

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let environment: Environment
    private let transport: any BYOTTelemetryTransport
    private var consentValue: BYOTTelemetryConsent
    private var isTransportRunning = false
    private var skipsNextActivation = false
    private var connectedServers: Set<UUID> = []
    private var droppedCount = 0

    init(defaults: UserDefaults = .standard, environment: Environment = .current,
         transport: any BYOTTelemetryTransport = BYOTPostHogTransport()) {
        self.defaults = defaults
        self.environment = environment
        self.transport = transport
        consentValue = defaults.string(forKey: Self.consentKey).flatMap(BYOTTelemetryConsent.init) ?? .undecided
    }

    var consent: BYOTTelemetryConsent { lock.withLock { consentValue } }

    var block: Block? { lock.withLock { currentBlock } }

    /// Events dropped by the schema check since launch; a non-zero count in
    /// tests means a call site sends something the contract does not allow.
    var droppedEventCount: Int { lock.withLock { droppedCount } }

    /// True once the app may show the one-time question.
    var shouldAskForConsent: Bool {
        lock.withLock { consentValue == .undecided && environment.isAutomated == false && environment.killSwitch == false }
    }

    private var currentBlock: Block? {
        if environment.isAutomated { return .automated }
        if environment.killSwitch { return .killSwitch }
        if environment.bundleIdentifier != Self.shippingBundleIdentifier { return .foreignBuild }
        switch consentValue {
        case .undecided: return .consentPending
        case .disabled: return .declined
        case .enabled: return nil
        }
    }

    /// Call once at launch. Starts the vendor only when consent was given
    /// earlier, and records the cold launch.
    func start() {
        let started: Bool = lock.withLock {
            guard currentBlock == nil, isTransportRunning == false else { return false }
            startTransportLocked()
            return true
        }
        if started { recordLaunch("cold") }
    }

    /// The app returned to the foreground. The first activation after a cold
    /// launch is part of that launch, not a resume.
    func applicationDidBecomeActive() {
        let isResume: Bool = lock.withLock {
            guard skipsNextActivation else { return true }
            skipsNextActivation = false
            return false
        }
        if isResume { record(.appOpened, ["launch": "resume"]) }
    }

    func setConsent(_ enabled: Bool) {
        let startedNow: Bool = lock.withLock {
            consentValue = enabled ? .enabled : .disabled
            defaults.set(consentValue.rawValue, forKey: Self.consentKey)
            if enabled {
                guard currentBlock == nil, isTransportRunning == false else { return false }
                startTransportLocked()
                return true
            }
            if isTransportRunning {
                transport.stop()
                isTransportRunning = false
            }
            // Opting out forgets the identity; a later opt-in starts a new one.
            defaults.removeObject(forKey: Self.installIDKey)
            connectedServers = []
            return false
        }
        if startedNow { recordLaunch("opt_in") }
    }

    /// Validates against the event's schema and sends when allowed. Any key
    /// outside the schema, any empty or long string, or any other value type
    /// drops the whole event: a payload that fails the contract is a bug, not
    /// something to trim.
    func record(_ event: BYOTTelemetryEvent, _ properties: Properties = [:]) {
        guard let validated = Self.validate(event, properties) else {
            lock.withLock { droppedCount += 1 }
            #if DEBUG
            print("BYOTTelemetry dropped \(event.rawValue): \(properties.keys.sorted())")
            #endif
            return
        }
        let mayTransmit: Bool = lock.withLock { currentBlock == nil && isTransportRunning }
        guard mayTransmit else { return }
        transport.capture(event.rawValue, properties: validated)
    }

    /// `server_connected` once per saved server and launch, however many
    /// screens negotiate the same connection.
    func recordServerConnected(serverID: UUID, _ properties: Properties) {
        let isFirst: Bool = lock.withLock { connectedServers.insert(serverID).inserted }
        if isFirst { record(.serverConnected, properties) }
    }

    static func validate(_ event: BYOTTelemetryEvent, _ properties: Properties) -> [String: Any]? {
        var result: [String: Any] = [:]
        for (key, value) in properties {
            guard event.allowedProperties.contains(key) else { return nil }
            switch value {
            case let bool as Bool: result[key] = bool
            case let int as Int: result[key] = int
            case let double as Double:
                guard double.isFinite else { return nil }
                result[key] = double
            case let string as String:
                guard !string.isEmpty, string.count <= maximumStringLength else { return nil }
                result[key] = string
            default: return nil
            }
        }
        return result
    }

    private func startTransportLocked() {
        let installID: UUID
        if let saved = defaults.string(forKey: Self.installIDKey).flatMap(UUID.init(uuidString:)) {
            installID = saved
        } else {
            installID = UUID()
            defaults.set(installID.uuidString, forKey: Self.installIDKey)
        }
        let reader = InstallIDReader(defaults: defaults)
        transport.start(installID: installID) { reader() }
        isTransportRunning = true
    }

    /// UserDefaults is thread-safe but not marked Sendable; the SDK reads the
    /// id from its own queue.
    private struct InstallIDReader: @unchecked Sendable {
        let defaults: UserDefaults
        func callAsFunction() -> UUID? {
            defaults.string(forKey: BYOTTelemetry.installIDKey).flatMap(UUID.init(uuidString:))
        }
    }

    private func recordLaunch(_ launch: String) {
        if launch == "cold" { lock.withLock { skipsNextActivation = true } }
        record(.appOpened, ["launch": launch])
    }
}

/// The PostHog SDK, set up once per process with everything automatic
/// turned off: no lifecycle or screen events, no person profiles, no feature
/// flags, no replay, no exception capture.
struct BYOTPostHogTransport: BYOTTelemetryTransport {
    private static let state = State()

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var isSetUp = false
    }

    func start(installID: UUID, readInstallID: @escaping @Sendable () -> UUID?) {
        let needsSetup: Bool = Self.state.lock.withLock {
            defer { Self.state.isSetUp = true }
            return Self.state.isSetUp == false
        }
        if needsSetup {
            let config = PostHogConfig(apiKey: BYOTTelemetry.projectToken, host: BYOTTelemetry.host)
            config.captureApplicationLifecycleEvents = false
            config.captureScreenViews = false
            config.enableSwizzling = false
            config.preloadFeatureFlags = false
            config.remoteConfig = false
            config.sendFeatureFlagEvent = false
            config.personProfiles = .never
            config.setDefaultPersonProperties = false
            config.errorTrackingConfig.autoCapture = false
            config.sessionReplay = false
            config.surveys = false
            config.flushAt = 10
            config.propertiesSanitizer = BYOTTelemetrySanitizer()
            // The install id is the distinct id. Read it each time so a reset
            // after opt-out and a fresh id after opt-in both take effect.
            config.getAnonymousId = { generated in readInstallID() ?? generated }
            PostHogSDK.shared.setup(config)
        } else {
            // Opt-in after an opt-out in the same launch: take the new id.
            PostHogSDK.shared.reset()
        }
        PostHogSDK.shared.optIn()
    }

    func capture(_ event: String, properties: [String: Any]) {
        PostHogSDK.shared.capture(event, properties: properties)
    }

    func stop() {
        PostHogSDK.shared.optOut()
        PostHogSDK.shared.reset()
    }
}

/// Last line of defence at the SDK boundary: only the schema's keys and the
/// SDK's own `$` context survive, minus the device's user-visible name and
/// the time zone, which say more than the product needs.
final class BYOTTelemetrySanitizer: NSObject, PostHogPropertiesSanitizer {
    static let droppedContextKeys: Set<String> = ["$device_name", "$timezone", "$set", "$set_once"]

    func sanitize(_ properties: [String: Any]) -> [String: Any] {
        properties.filter { key, _ in
            guard Self.droppedContextKeys.contains(key) == false else { return false }
            return key.hasPrefix("$") || BYOTTelemetryEvent.allAllowedProperties.contains(key)
        }
    }
}
