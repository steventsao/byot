import Foundation

struct OpenCodeServerProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var baseURL: String
    var username: String
    var directory: String
    var compatibility: OpenCodeCompatibilitySummary?

    init(
        id: UUID = UUID(),
        name: String,
        baseURL: String,
        username: String = "opencode",
        directory: String = "",
        compatibility: OpenCodeCompatibilitySummary? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.username = username
        self.directory = directory
        self.compatibility = compatibility
    }

    var normalizedURL: URL? {
        guard var components = URLComponents(
            string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else { return nil }
        components.path = components.path.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return components.url
    }

    func validatedBaseURL() throws -> URL {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedURL),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false
        else {
            throw OpenCodeConnectionError.invalidProfile(
                "Enter a complete HTTPS server URL."
            )
        }
        components.path = components.path.replacingOccurrences(
            of: "/+$",
            with: "",
            options: .regularExpression
        )
        guard let url = components.url else {
            throw OpenCodeConnectionError.invalidProfile(
                "Enter a complete HTTPS server URL."
            )
        }
        return url
    }

    var normalizedDirectory: String? {
        let value = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func validate(password: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenCodeConnectionError.invalidProfile("Give this Mac a profile name.")
        }
        _ = try validatedBaseURL()
        guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenCodeConnectionError.invalidProfile("Enter the OpenCode username.")
        }
        guard !password.isEmpty else {
            throw OpenCodeConnectionError.invalidProfile("Enter the OpenCode server password.")
        }
    }
}

enum OpenCodeConnectionError: LocalizedError, Sendable {
    case invalidProfile(String)
    case invalidResponse
    case unexpectedContentType(path: String, contentType: String?)
    case unexpectedEventContentType
    case httpStatus(Int, String?)
    case emptyResponse
    case eventBufferOverflow
    case eventLineTooLong(maxBytes: Int)
    case eventRecordTooLarge(maxBytes: Int)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidProfile(let message): message
        case .invalidResponse: "The OpenCode server returned an invalid response."
        case .unexpectedContentType(let path, let contentType):
            "OpenCode returned \(contentType ?? "a non-JSON response") instead of JSON for \(path)."
        case .unexpectedEventContentType:
            "The OpenCode event endpoint did not return an event stream."
        case .httpStatus(401, _): "OpenCode rejected the username or password."
        case .httpStatus(let status, let message):
            if let message, !message.isEmpty {
                "OpenCode returned \(status): \(message)"
            } else {
                "OpenCode returned HTTP \(status)."
            }
        case .emptyResponse: "The OpenCode server returned an empty response."
        case .eventBufferOverflow:
            "The OpenCode event stream fell behind and will reconnect."
        case .eventLineTooLong(let maxBytes):
            "The OpenCode event stream sent a line larger than the \(maxBytes)-byte safety limit."
        case .eventRecordTooLarge(let maxBytes):
            "The OpenCode event stream sent a record larger than the \(maxBytes)-byte safety limit."
        case .server(let message): message
        }
    }
}

extension OpenCodeConnectionError {
    var isUnsupportedRoute: Bool {
        switch self {
        case .httpStatus(let status, _) where status == 404 || status == 405:
            true
        default:
            false
        }
    }

    var isUnsupportedV2ListRoute: Bool {
        isUnsupportedRoute
    }
}

@MainActor
final class OpenCodeProfileStore: ObservableObject {
    @Published private(set) var profiles: [OpenCodeServerProfile]
    @Published private(set) var connectionGeneration = 0
    @Published var activeProfileID: UUID? {
        didSet { persistActiveProfileID() }
    }

    private let defaults: UserDefaults
    private let profilesKey = OpenCodeProfileStore.profilesKey
    nonisolated private static let profilesKey = "byot.opencode.profiles.v1"
    private let activeProfileKey = OpenCodeProfileStore.activeProfileKey
    nonisolated private static let activeProfileKey = "byot.opencode.active-profile.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: profilesKey),
           let decoded = try? JSONDecoder().decode([OpenCodeServerProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
        activeProfileID = defaults.string(forKey: activeProfileKey).flatMap(UUID.init(uuidString:))
        if activeProfile == nil {
            activeProfileID = profiles.first?.id
        }
    }

    var activeProfile: OpenCodeServerProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }

    func password(for profile: OpenCodeServerProfile) -> String {
        KeychainStore.string(for: passwordKey(for: profile.id)) ?? ""
    }

    /// Reads one saved server without selecting it or touching the active profile,
    /// for work that runs outside the UI such as notification actions.
    static func savedServer(id: UUID) -> (profile: OpenCodeServerProfile, password: String)? {
        guard let profile = savedProfiles(defaults: .standard).first(where: { $0.id == id }) else { return nil }
        return (profile, KeychainStore.string(for: passwordKey(for: id)) ?? "")
    }

    /// Saved servers in the order the server bar shows them, read without an
    /// instance for Siri and Shortcuts.
    nonisolated static func savedProfiles(defaults: UserDefaults = .standard) -> [OpenCodeServerProfile] {
        defaults.data(forKey: profilesKey)
            .flatMap { try? JSONDecoder().decode([OpenCodeServerProfile].self, from: $0) } ?? []
    }

    /// The server byot last showed, falling back to the first saved one.
    nonisolated static func savedActiveProfileID(defaults: UserDefaults = .standard) -> UUID? {
        let profiles = savedProfiles(defaults: defaults)
        let saved = defaults.string(forKey: activeProfileKey).flatMap(UUID.init(uuidString:))
        return profiles.first { $0.id == saved }?.id ?? profiles.first?.id
    }

    nonisolated static func savedPassword(for id: UUID) -> String {
        KeychainStore.string(for: passwordKey(for: id)) ?? ""
    }

    func save(_ profile: OpenCodeServerProfile, password: String) throws {
        try profile.validate(password: password)
        try KeychainStore.set(password, for: passwordKey(for: profile.id))
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        connectionGeneration &+= 1
        activeProfileID = profile.id
        persistProfiles()
    }

    func remove(_ profile: OpenCodeServerProfile) throws {
        try KeychainStore.delete(passwordKey(for: profile.id))
        defaults.removeObject(forKey: "byot.opencode.attention.\(profile.id.uuidString)")
        profiles.removeAll { $0.id == profile.id }
        if activeProfileID == profile.id {
            activeProfileID = profiles.first?.id
        }
        persistProfiles()
    }

    func select(_ profile: OpenCodeServerProfile) {
        activeProfileID = profile.id
    }

    private func persistProfiles() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: profilesKey)
        // "Ask OpenCode on <server>" phrases name saved servers.
        if !BYOTLaunch.isAutomated { BYOTAppShortcuts.updateAppShortcutParameters() }
    }

    private func persistActiveProfileID() {
        defaults.set(activeProfileID?.uuidString, forKey: activeProfileKey)
    }

    private func passwordKey(for id: UUID) -> String {
        Self.passwordKey(for: id)
    }

    nonisolated private static func passwordKey(for id: UUID) -> String {
        "byot.opencode.password.\(id.uuidString)"
    }
}
