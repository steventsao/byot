import Foundation
import CryptoKit

enum BYOTPushKind: String, Codable, CaseIterable, Sendable {
    case permission, question, complete, error
    var title: String {
        switch self {
        case .permission: "Approval requests"
        case .question: "Questions"
        case .complete: "Finished turns"
        case .error: "Errors"
        }
    }
}

struct BYOTPushRoute: Codable, Equatable, Sendable {
    let serverID: UUID
    let sessionID: String
    let directory: String
    let workspace: String?

    var isValid: Bool {
        sessionID.utf8.count <= 200 && (sessionID.isEmpty || sessionID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
        && directory.utf8.count <= 1_024 && !directory.contains("\0")
        && (workspace?.utf8.count ?? 0) <= 200
    }

    func encrypted(key: String) throws -> String {
        guard let data = Data(base64Encoded: key), data.count == 32, isValid else { throw BYOTPushError.invalidNotification }
        let sealed = try AES.GCM.seal(JSONEncoder().encode(self), using: SymmetricKey(data: data))
        return sealed.combined!.base64EncodedString()
    }

    static func decrypt(_ text: String, key: String) throws -> Self {
        guard text.utf8.count <= 2_800, let combined = Data(base64Encoded: text),
              let key = Data(base64Encoded: key), key.count == 32 else { throw BYOTPushError.invalidNotification }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key))
        let route = try JSONDecoder().decode(Self.self, from: clear)
        guard route.isValid else { throw BYOTPushError.invalidNotification }
        return route
    }
}

struct BYOTPushCredential: Codable, Sendable {
    let subscriptionID: UUID
    let serverID: UUID
    let fingerprint: String
    let ownerKey: String
    let routeKey: String

    static func fingerprint(_ profile: OpenCodeServerProfile) -> String {
        digest([profile.baseURL, profile.username, profile.directory].joined(separator: "\n"))
    }
    static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    func thread(_ sessionID: String) -> String { Self.digest(subscriptionID.uuidString.lowercased() + ":" + sessionID) }
    static func make(_ profile: OpenCodeServerProfile) -> Self {
        let owner = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        return Self(subscriptionID: UUID(), serverID: profile.id, fingerprint: fingerprint(profile), ownerKey: owner, routeKey: key)
    }
}

struct BYOTPushPreferences: Codable, Equatable, Sendable {
    var enabled = true
    var kinds = BYOTPushKind.allCases.map(\.rawValue)
    var mutedThreads: [String] = []
    var paired = false
    var lastSeen: Double?
    var queueVersion: Int?
}

struct BYOTPushDestination: Identifiable, Equatable, Sendable {
    let id = UUID()
    let route: BYOTPushRoute
}

enum BYOTPushError: LocalizedError {
    case invalidNotification, denied, registering, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .invalidNotification: "This notification can’t be opened. Open the session from your server instead."
        case .denied: "Notifications are disabled for byot. Enable them in iOS Settings, then try again."
        case .registering: "Waiting for Apple to register this device. Try again in a moment."
        case .unavailable(let message): message
        }
    }
}
