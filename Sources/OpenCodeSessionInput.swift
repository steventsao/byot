import Foundation

struct OpenCodeCommandOption: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let description: String?
    let template: String
    let source: String?
    let agent: String?
    let subtask: Bool?
    let hints: [String]

    var id: String { name }

    init(
        name: String,
        description: String?,
        template: String,
        source: String?,
        agent: String?,
        subtask: Bool?,
        hints: [String]
    ) {
        self.name = name
        self.description = description
        self.template = template
        self.source = source
        self.agent = agent
        self.subtask = subtask
        self.hints = hints
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case description
        case template
        case source
        case agent
        case subtask
        case hints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        template = try container.decode(String.self, forKey: .template)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        subtask = try container.decodeIfPresent(Bool.self, forKey: .subtask)
        hints = try container.decodeIfPresent([String].self, forKey: .hints) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(template, forKey: .template)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(subtask, forKey: .subtask)
        try container.encode(hints, forKey: .hints)
    }
}

struct OpenCodeAgentOption: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let description: String?
    let mode: String
    let hidden: Bool

    init(id: String, description: String?, mode: String, hidden: Bool) {
        self.id = id
        self.description = description
        self.mode = mode
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case mode
        case hidden
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(String.self, forKey: .id) {
            self.id = id
        } else {
            id = try container.decode(String.self, forKey: .name)
        }
        description = try container.decodeIfPresent(String.self, forKey: .description)
        mode = try container.decode(String.self, forKey: .mode)
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(mode, forKey: .mode)
        try container.encode(hidden, forKey: .hidden)
    }
}

enum OpenCodeSessionInputMode: Equatable, Sendable {
    case normal
    case shell
}

enum OpenCodeSessionInputIntent: Equatable, Sendable {
    case prompt(String)
    case command(name: String, arguments: String)
    case shell(String)

    var text: String {
        switch self {
        case .prompt(let text), .shell(let text):
            return text
        case .command(let name, let arguments):
            return arguments.isEmpty ? "/\(name)" : "/\(name) \(arguments)"
        }
    }
}

enum OpenCodeSessionInputParser {
    static func intent(
        text: String,
        mode: OpenCodeSessionInputMode,
        commands: [OpenCodeCommandOption]
    ) -> OpenCodeSessionInputIntent {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .shell { return .shell(text) }
        let components = text.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: \Character.isWhitespace
        )
        guard let head = components.first,
              head.hasPrefix("/"),
              head.count > 1
        else { return .prompt(text) }
        let name = String(head.dropFirst())
        guard commands.contains(where: { $0.name == name }) else {
            return .prompt(text)
        }
        let arguments = components.count > 1 ? String(components[1]) : ""
        return .command(name: name, arguments: arguments)
    }
}

enum OpenCodeSessionInputAgentResolver {
    static func agentID(
        for intent: OpenCodeSessionInputIntent,
        selectedAgentID: String?,
        commands: [OpenCodeCommandOption]
    ) -> String? {
        guard case .command(let name, _) = intent else {
            return selectedAgentID
        }
        return commands.first(where: { $0.name == name })?.agent
            ?? selectedAgentID
    }
}

enum OpenCodeSessionInputAgentCatalog {
    static func submissionAgentID(
        selectedAgentID: String?,
        agents: [OpenCodeAgentOption]
    ) -> String? {
        guard let selectedAgentID else { return nil }
        return agents.first(where: { $0.id == selectedAgentID })?.id
    }
}

enum OpenCodeSessionAttachmentPolicy {
    static func appending(
        _ imported: [OpenCodePromptAttachment],
        to current: [OpenCodePromptAttachment],
        mode: OpenCodeSessionInputMode
    ) throws -> [OpenCodePromptAttachment] {
        guard mode != .shell else {
            throw OpenCodeSessionInputError.shellAttachmentsUnavailable
        }
        let updated = current + imported
        try OpenCodePromptAttachment.validate(updated)
        return updated
    }
}

struct OpenCodeSessionInputPolicy: Equatable, Sendable {
    let canListCommands: Bool
    let canExecuteCommands: Bool
    let canRunShell: Bool
    let canListAgents: Bool
    let canSelectAgent: Bool
    let commandUnavailableReason: String?
    let shellUnavailableReason: String?

    init(capabilities: OpenCodeProtocolCapabilities) {
        canListCommands = capabilities.commandCatalog.isSupported
        canExecuteCommands = capabilities.commandExecution.isSupported
        canRunShell = capabilities.shellExecution.isSupported
        canListAgents = capabilities.agentCatalog.isSupported
        canSelectAgent = capabilities.agentSelection.isSupported
        commandUnavailableReason = capabilities.commandExecution.unavailableReason
        shellUnavailableReason = capabilities.shellExecution.unavailableReason
    }

    func supports(_ intent: OpenCodeSessionInputIntent) -> Bool {
        switch intent {
        case .prompt:
            return true
        case .command:
            return canExecuteCommands
        case .shell:
            return canRunShell
        }
    }
}

enum OpenCodeSessionInputError: LocalizedError, Equatable, Sendable {
    case shellAgentRequired
    case shellAttachmentsUnavailable

    var errorDescription: String? {
        switch self {
        case .shellAgentRequired:
            return "Choose an agent before running a shell command."
        case .shellAttachmentsUnavailable:
            return "Attachments are unavailable in shell mode."
        }
    }
}
