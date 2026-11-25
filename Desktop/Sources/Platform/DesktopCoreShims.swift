import Combine
import Foundation

// Minimal macOS shims for the three iOS-only hooks referenced inside BYOT's
// shared core files (`OpenCodeConnection.swift`, `BYOTTelemetry.swift`,
// `BYOTDurableQueue.swift`, `BYOTNudge.swift`). Keeping these shims inside
// `Desktop/` lets us compile the shared core untouched while keeping iPhone
// completely stable.

enum BYOTLaunch {
    static let isAutomated: Bool = {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()
}

enum BYOTAppShortcuts {
    static func updateAppShortcutParameters() {}
}

@MainActor
final class BYOTPushNotifications: ObservableObject {
    static let shared = BYOTPushNotifications()

    @Published private(set) var preferences: [UUID: BYOTPushPreferences] = [:]
    @Published private(set) var credentials: [UUID: BYOTPushCredential] = [:]

    func refresh(_ serverID: UUID) async throws {}
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
