import Foundation

enum OpenCodeProviderAuthMethodKind: String, Codable, Equatable, Sendable {
    case key
    case oauth
}

enum OpenCodeProviderAuthPromptKind: String, Codable, Equatable, Sendable {
    case text
    case select
}

enum OpenCodeProviderAuthPromptConditionOperation: String, Codable, Equatable, Sendable {
    case equal = "eq"
    case notEqual = "neq"
}

struct OpenCodeProviderAuthPromptCondition: Codable, Equatable, Sendable {
    let key: String
    let operation: OpenCodeProviderAuthPromptConditionOperation
    let value: String

    private enum CodingKeys: String, CodingKey {
        case key
        case operation = "op"
        case value
    }

    func matches(inputs: [String: String]) -> Bool {
        guard let actual = inputs[key] else { return false }
        switch operation {
        case .equal: return actual == value
        case .notEqual: return actual != value
        }
    }
}

struct OpenCodeProviderAuthPromptOption: Codable, Identifiable, Equatable, Sendable {
    let label: String
    let value: String
    let hint: String?

    init(label: String, value: String, hint: String? = nil) {
        self.label = label
        self.value = value
        self.hint = hint
    }

    var id: String { value }
}

struct OpenCodeProviderAuthPrompt: Codable, Identifiable, Equatable, Sendable {
    let kind: OpenCodeProviderAuthPromptKind
    let key: String
    let message: String
    let placeholder: String?
    let options: [OpenCodeProviderAuthPromptOption]
    let condition: OpenCodeProviderAuthPromptCondition?

    init(
        kind: OpenCodeProviderAuthPromptKind,
        key: String,
        message: String,
        placeholder: String? = nil,
        options: [OpenCodeProviderAuthPromptOption] = [],
        condition: OpenCodeProviderAuthPromptCondition? = nil
    ) {
        self.kind = kind
        self.key = key
        self.message = message
        self.placeholder = placeholder
        self.options = options
        self.condition = condition
    }

    private enum CodingKeys: String, CodingKey {
        case kind = "type"
        case key
        case message
        case placeholder
        case options
        case condition = "when"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(OpenCodeProviderAuthPromptKind.self, forKey: .kind)
        key = try container.decode(String.self, forKey: .key)
        message = try container.decode(String.self, forKey: .message)
        placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
        options = try container.decodeIfPresent(
            [OpenCodeProviderAuthPromptOption].self,
            forKey: .options
        ) ?? []
        condition = try container.decodeIfPresent(
            OpenCodeProviderAuthPromptCondition.self,
            forKey: .condition
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(key, forKey: .key)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(placeholder, forKey: .placeholder)
        if !options.isEmpty { try container.encode(options, forKey: .options) }
        try container.encodeIfPresent(condition, forKey: .condition)
    }

    var id: String { key }

    func isVisible(inputs: [String: String]) -> Bool {
        condition?.matches(inputs: inputs) ?? true
    }
}

struct OpenCodeProviderAuthMethod: Identifiable, Equatable, Sendable {
    let id: String
    let kind: OpenCodeProviderAuthMethodKind
    let label: String
    let prompts: [OpenCodeProviderAuthPrompt]

    init(
        id: String,
        kind: OpenCodeProviderAuthMethodKind,
        label: String,
        prompts: [OpenCodeProviderAuthPrompt] = []
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.prompts = prompts
    }

    func visiblePrompts(inputs: [String: String]) -> [OpenCodeProviderAuthPrompt] {
        prompts.filter { $0.isVisible(inputs: inputs) }
    }

    func missingRequiredInput(inputs: [String: String]) -> String? {
        visiblePrompts(inputs: inputs).first { prompt in
            inputs[prompt.key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }?.key
    }
}

struct OpenCodeProviderConnection: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isConnected: Bool
    let methods: [OpenCodeProviderAuthMethod]

    func markingConnected() -> Self {
        Self(id: id, name: name, isConnected: true, methods: methods)
    }
}

enum OpenCodeProviderCatalogEmptyState: Equatable, Sendable {
    case none
    case catalog
    case search
}

struct OpenCodeProviderCatalogPresentation: Equatable, Sendable {
    let providers: [OpenCodeProviderConnection]
    let query: String
    let errorMessage: String?

    var filteredProviders: [OpenCodeProviderConnection] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return providers }
        return providers.filter {
            $0.name.localizedStandardContains(query)
                || $0.id.localizedStandardContains(query)
        }
    }

    var emptyState: OpenCodeProviderCatalogEmptyState {
        guard filteredProviders.isEmpty else { return .none }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .catalog
            : .search
    }

    var refreshErrorMessage: String? {
        providers.isEmpty ? nil : errorMessage
    }
}

enum OpenCodeProviderOAuthMode: Equatable, Sendable {
    case code
    case automatic
}

struct OpenCodeProviderOAuthAuthorization: Equatable, Sendable {
    let attemptID: String
    let url: URL
    let instructions: String
    let mode: OpenCodeProviderOAuthMode
    let createdAt: Double
    let expiresAt: Double
}

enum OpenCodeProviderOAuthStatus: Equatable, Sendable {
    case pending
    case complete
    case failed(message: String)
    case expired
}

enum OpenCodeProviderConnectionError: LocalizedError, Equatable, Sendable {
    case invalidMethod
    case missingInput(String)
    case missingKey
    case missingCode
    case invalidAuthorizationURL

    var errorDescription: String? {
        switch self {
        case .invalidMethod: "OpenCode returned an invalid provider authentication method."
        case .missingInput(let key): "Enter a value for \(key) to continue."
        case .missingKey: "Enter an API key to continue."
        case .missingCode: "Enter the authorization code to continue."
        case .invalidAuthorizationURL: "OpenCode returned an invalid authorization URL."
        }
    }
}
