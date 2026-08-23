import Foundation

typealias OpenCodeConfiguration = [String: OpenCodeJSONValue]

struct OpenCodeVCSInfo: Codable, Equatable, Sendable {
    let branch: String?
    let defaultBranch: String?

    enum CodingKeys: String, CodingKey {
        case branch
        case defaultBranch = "default_branch"
    }
}

struct OpenCodeServerPaths: Codable, Equatable, Sendable {
    let home: String?
    let state: String?
    let config: String?
    let worktree: String?
    let directory: String
    let workspaceID: String?
    let projectID: String?
}

struct OpenCodeMCPStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case connected
        case disabled
        case failed
        case needsAuth = "needs_auth"
        case needsClientRegistration = "needs_client_registration"
    }

    let status: State
    let error: String?
}

struct OpenCodeLSPStatus: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case connected
        case error
    }

    let id: String
    let name: String
    let root: String
    let status: State
}

struct OpenCodeFormatterStatus: Codable, Equatable, Identifiable, Sendable {
    let name: String
    let extensions: [String]
    let enabled: Bool

    var id: String { name }
}

enum OpenCodeConfigurationDocument {
    static func string(from configuration: OpenCodeConfiguration) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(configuration), as: UTF8.self)
    }

    static func configuration(from text: String) throws -> OpenCodeConfiguration {
        try JSONDecoder().decode(
            OpenCodeConfiguration.self,
            from: Data(text.utf8)
        )
    }
}

enum OpenCodeServerContextSection<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case available(Value)
    case unavailable(reason: String)
    case failed(message: String)

    var value: Value? {
        guard case .available(let value) = self else { return nil }
        return value
    }

    var unavailableReason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }

}
