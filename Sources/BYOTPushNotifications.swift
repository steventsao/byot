import SwiftUI
import UserNotifications

@MainActor
final class BYOTPushNotifications: ObservableObject {
    static let shared = BYOTPushNotifications()
    @Published private(set) var preferences: [UUID: BYOTPushPreferences] = [:]
    @Published private(set) var credentials: [UUID: BYOTPushCredential] = [:]
    @Published var pendingDestination: BYOTPushDestination?
    @Published var routingError: String?
    @Published var registrationError: String?
    @Published private(set) var deviceToken: String?
    var activeRoute: BYOTPushRoute?
    private let client = BYOTPushClient()
    private let credentialKey = "byot.push.credentials.v1"
    /// Injected by tests; the app reads the saved profile and its Keychain password.
    var resolveServer: @MainActor (UUID) -> (profile: OpenCodeServerProfile, password: String)? = OpenCodeProfileStore.savedServer
    var makeActionService: @MainActor (OpenCodeServerProfile, String) -> any BYOTPushActionService = {
        OpenCodeClient(profile: $0, password: $1)
    }
    var deliverFollowUp: @MainActor (UNNotificationRequest) async -> Void = { request in
        try? await UNUserNotificationCenter.current().add(request)
    }

    init(credentials initial: [BYOTPushCredential]? = nil) {
        if let initial {
            credentials = Dictionary(uniqueKeysWithValues: initial.map { ($0.serverID, $0) })
            return
        }
        if let text = KeychainStore.string(for: credentialKey), let data = text.data(using: .utf8),
           let saved = try? JSONDecoder().decode([BYOTPushCredential].self, from: data) {
            credentials = Dictionary(uniqueKeysWithValues: saved.map { ($0.serverID, $0) })
        }
        // A cached token is never used until this launch's APNs registration succeeds.
    }

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func registered(_ data: Data) async {
        deviceToken = data.map { String(format: "%02x", $0) }.joined()
        registrationError = nil
        for credential in credentials.values {
            do { try await register(credential) } catch { registrationError = error.localizedDescription }
        }
    }

    func setup(_ profile: OpenCodeServerProfile) async throws -> (String, Date) {
        let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        guard allowed else { throw BYOTPushError.denied }
        UIApplication.shared.registerForRemoteNotifications()
        // Registration is asynchronous; wait briefly without blocking the main actor.
        for _ in 0..<50 {
            if deviceToken != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard deviceToken != nil else { throw BYOTPushError.unavailable(registrationError ?? BYOTPushError.registering.localizedDescription) }
        if let old = credentials[profile.id], old.fingerprint != BYOTPushCredential.fingerprint(profile) {
            try await remove(profile.id)
        }
        let credential = credentials[profile.id] ?? BYOTPushCredential.make(profile)
        // Persist the owner key before registration, so interrupted setup is recoverable.
        credentials[profile.id] = credential
        try saveCredentials()
        try await register(credential)
        var enabled = preferences[profile.id] ?? BYOTPushPreferences()
        enabled.enabled = true
        try await update(profile.id, enabled)
        struct Pair: Encodable { let routeKey: String }
        struct Result: Decodable { let code: String; let expiresAt: Double }
        let response = try await client.request("POST", credential: credential, action: "pair", body: JSONEncoder().encode(Pair(routeKey: credential.routeKey)))
        let result = try JSONDecoder().decode(Result.self, from: response)
        return (result.code, Date(timeIntervalSince1970: result.expiresAt / 1000))
    }

    private func register(_ credential: BYOTPushCredential) async throws {
        guard let deviceToken else { return }
        struct Registration: Encodable { let deviceToken: String; let environment: String; let serverID: String }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let data = try await client.request("PUT", credential: credential,
            body: JSONEncoder().encode(Registration(deviceToken: deviceToken, environment: environment, serverID: credential.serverID.uuidString.lowercased())))
        preferences[credential.serverID] = try JSONDecoder().decode(BYOTPushPreferences.self, from: data)
    }

    func refresh(_ id: UUID) async throws {
        guard let credential = credentials[id] else { return }
        let data = try await client.request("GET", credential: credential)
        preferences[id] = try JSONDecoder().decode(BYOTPushPreferences.self, from: data)
    }

    func update(_ id: UUID, _ value: BYOTPushPreferences) async throws {
        guard let credential = credentials[id] else { return }
        _ = try await client.request("PATCH", credential: credential, body: JSONEncoder().encode(value))
        preferences[id] = value
    }

    func remove(_ id: UUID) async throws {
        guard let credential = credentials[id] else { return }
        _ = try await client.request("DELETE", credential: credential)
        credentials[id] = nil
        preferences[id] = nil
        try saveCredentials()
    }

    func test(_ profile: OpenCodeServerProfile) async throws {
        guard let credential = credentials[profile.id] else { return }
        let route = BYOTPushRoute(serverID: profile.id, sessionID: "", directory: "", workspace: nil)
        struct Event: Encodable { let eventID: String; let kind: String; let route: String; let thread: String; let createdAt: Double }
        let event = Event(eventID: UUID().uuidString, kind: "test", route: try route.encrypted(key: credential.routeKey),
                          thread: credential.thread("test"), createdAt: Date().timeIntervalSince1970 * 1000)
        _ = try await client.request("POST", credential: credential, action: "test", body: JSONEncoder().encode(event))
    }

    func isMuted(serverID: UUID, sessionID: String) -> Bool {
        guard let credential = credentials[serverID] else { return false }
        return preferences[serverID]?.mutedThreads.contains(credential.thread(sessionID)) ?? false
    }
    func toggleMute(serverID: UUID, sessionID: String) async throws {
        guard let credential = credentials[serverID] else { return }
        try await refresh(serverID)
        var value = preferences[serverID] ?? BYOTPushPreferences()
        let thread = credential.thread(sessionID)
        if value.mutedThreads.contains(thread) { value.mutedThreads.removeAll { $0 == thread } }
        else {
            guard value.mutedThreads.count < 100 else { throw BYOTPushError.unavailable("You can mute up to 100 sessions. Unmute an older session first.") }
            value.mutedThreads.append(thread)
        }
        try await update(serverID, value)
    }

    func decode(_ data: Data) throws -> BYOTPushRoute { try decodeNotification(data).route }

    /// Authenticates the envelope: only a known subscription's route key can produce
    /// a route, and a request ID is only meaningful on the kinds that carry one.
    func decodeNotification(_ data: Data) throws -> (route: BYOTPushRoute, kind: BYOTPushKind?) {
        struct Envelope: Decodable { struct Content: Decodable { let version: Int; let subscriptionID: UUID; let kind: String; let route: String }; let byot: Content }
        let content = try JSONDecoder().decode(Envelope.self, from: data).byot
        let kind = BYOTPushKind(rawValue: content.kind)
        guard content.version == 1, kind != nil || content.kind == "test",
              let credential = credentials.values.first(where: { $0.subscriptionID == content.subscriptionID }) else { throw BYOTPushError.invalidNotification }
        let route = try BYOTPushRoute.decrypt(content.route, key: credential.routeKey)
        guard route.serverID == credential.serverID, (content.kind == "test") == route.sessionID.isEmpty,
              route.requestID == nil || kind == .permission || kind == .question else { throw BYOTPushError.invalidNotification }
        return (route, kind)
    }

    /// Answers a permission or question from a notification action. The device was
    /// unlocked by iOS before this runs; the reply goes straight to the saved server
    /// with its saved password, after confirming the request is still pending there.
    @discardableResult
    func respond(to action: BYOTPushAction, notification data: Data, threadIdentifier: String = "") async -> BYOTPushActionOutcome {
        let outcome: BYOTPushActionOutcome
        var decoded: BYOTPushRoute?
        if let notification = try? decodeNotification(data), notification.kind == action.kind {
            decoded = notification.route
            if let server = resolveServer(notification.route.serverID),
               let credential = credentials[server.profile.id],
               credential.fingerprint == BYOTPushCredential.fingerprint(server.profile) {
                outcome = await BYOTPushActionResponder.perform(
                    action, route: notification.route, service: makeActionService(server.profile, server.password))
            } else {
                outcome = .serverChanged
            }
        } else {
            outcome = .needsReview
        }
        if let followUp = outcome.followUp {
            await deliverFollowUp(Self.followUpRequest(followUp, notification: data, route: decoded, thread: threadIdentifier))
        }
        return outcome
    }

    static func followUpRequest(_ text: (title: String, body: String), notification data: Data, route: BYOTPushRoute?,
                                thread: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.threadIdentifier = thread
        content.interruptionLevel = .active
        // Keep only the authenticated envelope so tapping the follow-up opens the same session.
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let envelope = object["byot"] {
            content.userInfo = ["byot": envelope]
        }
        let key = route.map { "\($0.serverID.uuidString):\($0.sessionID):\($0.requestID ?? "")" } ?? UUID().uuidString
        return UNNotificationRequest(identifier: "byot.follow-up." + BYOTPushCredential.digest(key), content: content, trigger: nil)
    }
    func receive(_ data: Data) {
        do { pendingDestination = BYOTPushDestination(route: try decode(data)) }
        catch { routingError = BYOTPushError.invalidNotification.localizedDescription }
    }
    func shouldPresent(_ data: Data) -> Bool {
        guard let route = try? decode(data) else { return false }
        return route.sessionID.isEmpty || activeRoute?.serverID != route.serverID || activeRoute?.sessionID != route.sessionID
    }
    private func saveCredentials() throws {
        let data = try JSONEncoder().encode(Array(credentials.values))
        try KeychainStore.set(String(decoding: data, as: UTF8.self), for: credentialKey)
    }
}

final class BYOTPushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories(BYOTPushCategory.all)
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await BYOTPushNotifications.shared.registered(deviceToken) }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in BYOTPushNotifications.shared.registrationError = "Apple couldn’t register notifications. Check your connection and try again." }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let data = try? JSONSerialization.data(withJSONObject: notification.request.content.userInfo)
        return await MainActor.run {
            data.map { BYOTPushNotifications.shared.shouldPresent($0) } == true ? [.banner, .list, .sound] : []
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let data = try? JSONSerialization.data(withJSONObject: response.notification.request.content.userInfo)
        let identifier = response.actionIdentifier
        let thread = response.notification.request.content.threadIdentifier
        guard let data, identifier != UNNotificationDismissActionIdentifier else { return }
        guard let action = BYOTPushAction(identifier: identifier, text: (response as? UNTextInputNotificationResponse)?.userText) else {
            // The default tap and "Review in byot" only open the session; they never answer it.
            await MainActor.run { BYOTPushNotifications.shared.receive(data) }
            return
        }
        // iOS keeps a background launch alive until this method returns; the task
        // assertion also covers a response that arrives while the app is suspending.
        let assertion = await BYOTBackgroundAssertion(name: "byot.notification-action")
        await BYOTPushNotifications.shared.respond(to: action, notification: data, threadIdentifier: thread)
        await assertion.end()
    }
}

@MainActor
private final class BYOTBackgroundAssertion {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
