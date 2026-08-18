import Foundation

enum OpenCodeJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: OpenCodeJSONValue])
    case array([OpenCodeJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: OpenCodeJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([OpenCodeJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var compactDescription: String {
        switch self {
        case .string(let value): value
        case .number(let value):
            if let integer = Int(exactly: value) {
                String(integer)
            } else {
                String(value)
            }
        case .bool(let value): String(value)
        case .object(let value):
            value.keys.sorted().map { "\($0): \(value[$0]?.compactDescription ?? "null")" }
                .joined(separator: ", ")
        case .array(let value): value.map(\.compactDescription).joined(separator: ", ")
        case .null: "null"
        }
    }
}

struct OpenCodeProject: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let worktree: String
    let vcs: String?
    let name: String?
    let time: OpenCodeProjectTime
    let sandboxes: [String]

    var displayName: String {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty { return trimmedName }
        return URL(fileURLWithPath: worktree).lastPathComponent
    }
}

struct OpenCodeProjectTime: Codable, Equatable, Sendable {
    let created: Double
    let updated: Double
}

struct OpenCodeSession: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let slug: String
    let projectID: String
    let workspaceID: String?
    let directory: String
    let parentID: String?
    let summary: OpenCodeSessionSummary?
    let title: String
    let agent: String?
    let version: String
    let time: OpenCodeSessionTime
}

struct OpenCodeSessionSummary: Codable, Equatable, Sendable {
    let additions: Int
    let deletions: Int
    let files: Int
}

struct OpenCodeSessionTime: Codable, Equatable, Sendable {
    let created: Double
    let updated: Double
    let compacting: Double?
    let archived: Double?
}

struct OpenCodeMessageEnvelope: Codable, Identifiable, Equatable, Sendable {
    var info: OpenCodeMessageInfo
    var parts: [OpenCodePart]

    var id: String { info.id }
}

struct OpenCodeMessageInfo: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let role: String
    let time: OpenCodeMessageTime
    let agent: String?
    let modelID: String?
    let providerID: String?
    let finish: String?
    let error: OpenCodeMessageError?
}

struct OpenCodeMessageTime: Codable, Equatable, Sendable {
    let created: Double
    let completed: Double?
}

struct OpenCodeMessageError: Codable, Equatable, Sendable {
    let name: String
    let data: [String: OpenCodeJSONValue]?

    var displayMessage: String {
        data?["message"]?.stringValue ?? name
    }
}

struct OpenCodePart: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let messageID: String
    let type: String
    var text: String?
    let mime: String?
    let filename: String?
    let url: String?
    let callID: String?
    let tool: String?
    let state: OpenCodeToolState?
    let files: [String]?
    let description: String?
    let agent: String?
}

struct OpenCodeToolState: Codable, Equatable, Sendable {
    let status: String
    let input: [String: OpenCodeJSONValue]?
    let raw: String?
    let title: String?
    let output: String?
    let error: String?
    let time: OpenCodeToolTime?
}

struct OpenCodeToolTime: Codable, Equatable, Sendable {
    let start: Double
    let end: Double?
}

struct OpenCodeDiff: Codable, Identifiable, Equatable, Sendable {
    let file: String?
    let patch: String?
    let additions: Int
    let deletions: Int
    let status: String?

    var id: String { file ?? "\(additions)-\(deletions)-\(patch?.hashValue ?? 0)" }
}

enum OpenCodeActionAPIVersion: String, Codable, Equatable, Sendable {
    case legacy
    case v2
}

struct OpenCodePermissionRequest: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let permission: String
    let patterns: [String]
    let metadata: [String: OpenCodeJSONValue]
    let always: [String]
    var source: OpenCodePermissionSource? = nil
    var apiVersion: OpenCodeActionAPIVersion? = nil

    var resolvedAPIVersion: OpenCodeActionAPIVersion {
        apiVersion ?? .legacy
    }

    var presentationID: String {
        "\(resolvedAPIVersion.rawValue):\(id)"
    }

    var rememberedScopeTitle: String {
        switch resolvedAPIVersion {
        case .legacy:
            "Always allow would remember for this directory"
        case .v2:
            "Always allow would save this project permission"
        }
    }

    var rememberedScopeFooter: String {
        switch resolvedAPIVersion {
        case .legacy:
            "The rule is kept in memory while this OpenCode instance remains active and is not persisted."
        case .v2:
            "The saved rule applies across project sessions and server restarts until removed. Configured deny rules still take precedence."
        }
    }

    var alwaysAllowConfirmationMessage: String? {
        guard !always.isEmpty else { return nil }
        switch resolvedAPIVersion {
        case .legacy:
            if always == ["*"] {
                return "While this OpenCode instance remains active, this allows every \(permission) request in this directory. The rule is kept in memory and is not persisted."
            }
            return "While this OpenCode instance remains active, this allows \(permission) requests matching: \(always.joined(separator: ", ")) in this directory. The rule is kept in memory and is not persisted."
        case .v2:
            if always == ["*"] {
                return "This saves every \(permission) request in this OpenCode project. The rule applies across project sessions and server restarts until removed from saved permissions. Configured deny rules still take precedence."
            }
            return "This saves \(permission) requests matching: \(always.joined(separator: ", ")) in this OpenCode project. The rule applies across project sessions and server restarts until removed from saved permissions. Configured deny rules still take precedence."
        }
    }
}

struct OpenCodePermissionV2Request: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let action: String
    let resources: [String]
    let save: [String]?
    let metadata: [String: OpenCodeJSONValue]?
    var source: OpenCodePermissionSource? = nil

    var normalized: OpenCodePermissionRequest {
        OpenCodePermissionRequest(
            id: id,
            sessionID: sessionID,
            permission: action,
            patterns: resources,
            metadata: metadata ?? [:],
            always: save ?? [],
            source: source,
            apiVersion: .v2
        )
    }
}

struct OpenCodePermissionSource: Codable, Equatable, Sendable {
    let type: String
    let messageID: String
    let callID: String
}

enum OpenCodePermissionReply: String, Codable, Sendable {
    case once
    case always
    case reject
}

struct OpenCodeQuestionRequest: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let questions: [OpenCodeQuestion]
    var tool: OpenCodeQuestionTool? = nil
    var apiVersion: OpenCodeActionAPIVersion? = nil

    var resolvedAPIVersion: OpenCodeActionAPIVersion {
        apiVersion ?? .legacy
    }

    var presentationID: String {
        "\(resolvedAPIVersion.rawValue):\(id)"
    }
}

struct OpenCodeQuestionTool: Codable, Equatable, Sendable {
    let messageID: String
    let callID: String
}

struct OpenCodeQuestion: Codable, Equatable, Sendable {
    let question: String
    let header: String
    let options: [OpenCodeQuestionOption]
    let multiple: Bool?
    let custom: Bool?

    var allowsCustomAnswer: Bool { custom != false }
}

struct OpenCodeQuestionOption: Codable, Identifiable, Equatable, Sendable {
    let label: String
    let description: String

    var id: String { label }
}

enum OpenCodeSessionStatus: Equatable, Sendable {
    case idle
    case busy
    case retry(attempt: Int, message: String, next: Double)

    var label: String {
        switch self {
        case .idle: "Idle"
        case .busy: "Working"
        case .retry(let attempt, _, _): "Retry \(attempt)"
        }
    }

    var isActive: Bool {
        switch self {
        case .idle: false
        case .busy, .retry: true
        }
    }
}

extension OpenCodeSessionStatus: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, attempt, message, next
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "idle": self = .idle
        case "busy": self = .busy
        case "retry":
            self = .retry(
                attempt: try container.decode(Int.self, forKey: .attempt),
                message: try container.decode(String.self, forKey: .message),
                next: try container.decode(Double.self, forKey: .next)
            )
        default:
            self = .idle
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode("idle", forKey: .type)
        case .busy:
            try container.encode("busy", forKey: .type)
        case .retry(let attempt, let message, let next):
            try container.encode("retry", forKey: .type)
            try container.encode(attempt, forKey: .attempt)
            try container.encode(message, forKey: .message)
            try container.encode(next, forKey: .next)
        }
    }
}

struct OpenCodeEvent: Codable, Equatable, Sendable {
    let id: String
    let type: String
    let properties: [String: OpenCodeJSONValue]

    var sessionID: String? { properties["sessionID"]?.stringValue }
}
