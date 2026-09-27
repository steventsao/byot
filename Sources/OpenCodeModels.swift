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
    // Fork lineage differs from a subagent's parentID. Forks remain roots.
    var forkSourceID: String? = nil
    // The server's running spend for the session, summed over every step it
    // has stored, including history older than the transcript page loaded.
    var cost: Double? = nil
    var tokens: OpenCodeTokenUsage? = nil
    /// Present while the session is published on the web; absent when private.
    var share: OpenCodeSessionShare? = nil
}

extension OpenCodeSession {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decode(String.self, forKey: .slug)
        projectID = try c.decode(String.self, forKey: .projectID)
        workspaceID = try c.decodeIfPresent(String.self, forKey: .workspaceID)
        directory = try c.decode(String.self, forKey: .directory)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        summary = try c.decodeIfPresent(OpenCodeSessionSummary.self, forKey: .summary)
        title = try c.decode(String.self, forKey: .title)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        version = try c.decode(String.self, forKey: .version)
        time = try c.decode(OpenCodeSessionTime.self, forKey: .time)
        forkSourceID = try c.decodeIfPresent(String.self, forKey: .forkSourceID)
        // Older servers omit usage; an unexpected shape must not drop the session.
        cost = try? c.decodeIfPresent(Double.self, forKey: .cost)
        tokens = try? c.decodeIfPresent(OpenCodeTokenUsage.self, forKey: .tokens)
        share = try? c.decodeIfPresent(OpenCodeSessionShare.self, forKey: .share)
    }
}

/// A published session's public page. Only the server-returned URL is used;
/// BYOT never builds share links itself.
struct OpenCodeSessionShare: Codable, Equatable, Sendable {
    let url: String

    /// Nil unless the server returned an absolute web link. A server with
    /// sharing turned off by environment answers with an empty URL.
    var link: URL? {
        guard let components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host?.isEmpty == false
        else { return nil }
        return components.url
    }
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

    /// A v2 system or synthetic message: context OpenCode added for the
    /// model. It is not a reply, so it never counts as the turn answering.
    var isSyntheticContext: Bool {
        !parts.isEmpty && parts.allSatisfy { $0.type.lowercased() == "text" && $0.synthetic == true }
    }
}

struct OpenCodeMessageInfo: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let role: String
    var time: OpenCodeMessageTime
    let agent: String?
    let modelID: String?
    let providerID: String?
    let finish: String?
    let error: OpenCodeMessageError?
    var variant: String? = nil
    // Assistant accounting: v1 keeps the reply's summed `cost` and its last
    // step's `tokens`; v2 assistant messages are one step each. `summary`
    // marks the v1 reply that wrote a compaction summary.
    var cost: Double? = nil
    var tokens: OpenCodeTokenUsage? = nil
    var summary: Bool? = nil
    /// The prompt an assistant reply answers; its turn's diff is keyed by this id.
    var parentID: String? = nil
}

struct OpenCodeMessageTime: Codable, Equatable, Sendable {
    let created: Double
    let completed: Double?
}

struct OpenCodeMessageError: Codable, Equatable, Sendable {
    let name: String
    let data: [String: OpenCodeJSONValue]?

    var displayMessage: String {
        failure.message
    }

    var failure: OpenCodeFailure { OpenCodeFailure(message: name, details: data) }
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
    // Fields of the remaining v1 part types (packages/schema/src/v1/session.ts):
    // agent `name`; compaction `auto`/`overflow`; retry `attempt`/`error`;
    // step-finish `reason`/`cost`/`tokens`; snapshot and step `snapshot`;
    // patch `hash`; text `synthetic`/`ignored`, which mark context OpenCode
    // added for the model rather than words the user typed. They decode
    // leniently so an unfamiliar shape never drops the part, and default to
    // nil so memberwise construction stays compact.
    var name: String? = nil
    var auto: Bool? = nil
    var overflow: Bool? = nil
    var attempt: Int? = nil
    var error: OpenCodeMessageError? = nil
    var reason: String? = nil
    var cost: Double? = nil
    var tokens: OpenCodeTokenUsage? = nil
    var snapshot: String? = nil
    var hash: String? = nil
    var synthetic: Bool? = nil
    var ignored: Bool? = nil
    /// A v1 compaction's retained tail: the first message the model still
    /// reads verbatim after the summary.
    var tailStartID: String? = nil

    /// Text the user actually wrote, as upstream clients restore and resend
    /// it: synthetic context (attached file contents, MCP resources,
    /// reminders) and ignored text are left out.
    var isAuthoredText: Bool {
        type.lowercased() == "text" && synthetic != true && ignored != true
    }
}

extension OpenCodePart {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        messageID = try c.decode(String.self, forKey: .messageID)
        type = try c.decode(String.self, forKey: .type)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        mime = try c.decodeIfPresent(String.self, forKey: .mime)
        filename = try c.decodeIfPresent(String.self, forKey: .filename)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        callID = try c.decodeIfPresent(String.self, forKey: .callID)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        state = try c.decodeIfPresent(OpenCodeToolState.self, forKey: .state)
        files = try c.decodeIfPresent([String].self, forKey: .files)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        auto = try? c.decodeIfPresent(Bool.self, forKey: .auto)
        overflow = try? c.decodeIfPresent(Bool.self, forKey: .overflow)
        attempt = (try? c.decodeIfPresent(Double.self, forKey: .attempt)).map { Int($0) }
        error = try? c.decodeIfPresent(OpenCodeMessageError.self, forKey: .error)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        cost = try? c.decodeIfPresent(Double.self, forKey: .cost)
        tokens = try? c.decodeIfPresent(OpenCodeTokenUsage.self, forKey: .tokens)
        snapshot = try? c.decodeIfPresent(String.self, forKey: .snapshot)
        hash = try? c.decodeIfPresent(String.self, forKey: .hash)
        synthetic = try? c.decodeIfPresent(Bool.self, forKey: .synthetic)
        ignored = try? c.decodeIfPresent(Bool.self, forKey: .ignored)
        if type == "compaction" {
            let wire = try? decoder.container(keyedBy: WireKeys.self)
            tailStartID = (try? wire?.decodeIfPresent(String.self, forKey: .tailStartID))
                ?? (try? c.decodeIfPresent(String.self, forKey: .tailStartID))
        }
    }

    private enum WireKeys: String, CodingKey { case tailStartID = "tail_start_id" }
}

/// Token accounting for one model step. v1 step-finish parts and v2
/// step.ended events share this shape; `total` is optional upstream.
struct OpenCodeTokenUsage: Codable, Equatable, Sendable {
    var input: Double
    var output: Double
    var reasoning: Double
    var cacheRead: Double
    var cacheWrite: Double
    var reportedTotal: Double?

    init(input: Double, output: Double, reasoning: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0,
         reportedTotal: Double? = nil) {
        self.input = input; self.output = output; self.reasoning = reasoning
        self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.reportedTotal = reportedTotal
    }

    init?(_ value: OpenCodeJSONValue?) {
        guard let object = value?.objectValue else { return nil }
        let cache = object["cache"]?.objectValue
        self.init(input: object["input"]?.numberValue ?? 0, output: object["output"]?.numberValue ?? 0,
                  reasoning: object["reasoning"]?.numberValue ?? 0, cacheRead: cache?["read"]?.numberValue ?? 0,
                  cacheWrite: cache?["write"]?.numberValue ?? 0, reportedTotal: object["total"]?.numberValue)
    }

    /// Every token the step consumed or produced, as OpenCode counts context usage.
    var total: Double { reportedTotal ?? contextTokens }

    /// The step's footprint in the context window, summed from its parts the
    /// way OpenCode's sidebar and context panel count it.
    var contextTokens: Double { input + output + reasoning + cacheRead + cacheWrite }

    static let zero = OpenCodeTokenUsage(input: 0, output: 0)

    /// Session totals add steps part by part; a reported total survives only
    /// when a step supplied one.
    static func + (lhs: OpenCodeTokenUsage, rhs: OpenCodeTokenUsage) -> OpenCodeTokenUsage {
        OpenCodeTokenUsage(
            input: lhs.input + rhs.input, output: lhs.output + rhs.output,
            reasoning: lhs.reasoning + rhs.reasoning, cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reportedTotal: lhs.reportedTotal == nil && rhs.reportedTotal == nil ? nil : lhs.total + rhs.total)
    }

    private enum CodingKeys: String, CodingKey { case input, output, reasoning, cache, total }
    private enum CacheKeys: String, CodingKey { case read, write }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let cache = try? c.nestedContainer(keyedBy: CacheKeys.self, forKey: .cache)
        input = (try? c.decodeIfPresent(Double.self, forKey: .input)) ?? 0
        output = (try? c.decodeIfPresent(Double.self, forKey: .output)) ?? 0
        reasoning = (try? c.decodeIfPresent(Double.self, forKey: .reasoning)) ?? 0
        cacheRead = (try? cache?.decodeIfPresent(Double.self, forKey: .read)) ?? 0
        cacheWrite = (try? cache?.decodeIfPresent(Double.self, forKey: .write)) ?? 0
        reportedTotal = try? c.decodeIfPresent(Double.self, forKey: .total)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(input, forKey: .input)
        try c.encode(output, forKey: .output)
        try c.encode(reasoning, forKey: .reasoning)
        var cache = c.nestedContainer(keyedBy: CacheKeys.self, forKey: .cache)
        try cache.encode(cacheRead, forKey: .read)
        try cache.encode(cacheWrite, forKey: .write)
        try c.encodeIfPresent(reportedTotal, forKey: .total)
    }
}

struct OpenCodeToolState: Codable, Equatable, Sendable {
    let status: String
    let input: [String: OpenCodeJSONValue]?
    let raw: String?
    let title: String?
    let output: String?
    let error: String?
    let time: OpenCodeToolTime?
    /// What the tool recorded about itself (v1 `metadata`, v2 `structured`),
    /// cut down to the fields BYOT reads: a `task` call's subagent session
    /// and whether it runs in the background, and a shell run's streamed
    /// output, exit code and truncation. Other tools record whole files here
    /// (an edit's before and after), which a transcript need not hold.
    var metadata: [String: OpenCodeJSONValue]? = nil

    static let retainedMetadataKeys: Set<String> = [
        "sessionId", "sessionID", "session_id", "background", "output", "exit", "truncated",
    ]

    static func retainedMetadata(_ metadata: [String: OpenCodeJSONValue]?) -> [String: OpenCodeJSONValue]? {
        guard let kept = metadata?.filter({ retainedMetadataKeys.contains($0.key) }), !kept.isEmpty else { return nil }
        return kept
    }
}

extension OpenCodeToolState {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        input = try c.decodeIfPresent([String: OpenCodeJSONValue].self, forKey: .input)
        raw = try c.decodeIfPresent(String.self, forKey: .raw)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        output = try c.decodeIfPresent(String.self, forKey: .output)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        time = try c.decodeIfPresent(OpenCodeToolTime.self, forKey: .time)
        // Metadata is a tool's own record; an odd shape never drops the part.
        metadata = Self.retainedMetadata(try? c.decodeIfPresent([String: OpenCodeJSONValue].self, forKey: .metadata))
    }
}

/// A shell run's metadata as the shell cards read it. v1 streams a running
/// shell's output here before `output` is final. A field of an unexpected
/// type reads as absent.
struct OpenCodeToolMetadata: Equatable, Sendable {
    var output: String?
    var exit: Double?
    var truncated: Bool?

    init(output: String? = nil, exit: Double? = nil, truncated: Bool? = nil) {
        self.output = output
        self.exit = exit
        self.truncated = truncated
    }

    init(_ metadata: [String: OpenCodeJSONValue]?) {
        output = metadata?["output"]?.stringValue
        exit = metadata?["exit"]?.numberValue
        truncated = if case .bool(let value)? = metadata?["truncated"] { value } else { nil }
    }

    /// The retained metadata fields for a shell run.
    var fields: [String: OpenCodeJSONValue]? {
        var fields: [String: OpenCodeJSONValue] = [:]
        if let output { fields["output"] = .string(output) }
        if let exit { fields["exit"] = .number(exit) }
        if let truncated { fields["truncated"] = .bool(truncated) }
        return fields.isEmpty ? nil : fields
    }
}

extension OpenCodeToolState {
    var shellMetadata: OpenCodeToolMetadata { OpenCodeToolMetadata(metadata) }
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
            String(localized: "Always allow would remember for this directory")
        case .v2:
            String(localized: "Always allow would save this project permission")
        }
    }

    var rememberedScopeFooter: String {
        switch resolvedAPIVersion {
        case .legacy:
            String(localized: "The rule is kept in memory while this OpenCode instance remains active and is not persisted.")
        case .v2:
            String(localized: "The saved rule applies across project sessions and server restarts until removed. Configured deny rules still take precedence.")
        }
    }

    var alwaysAllowConfirmationMessage: String? {
        guard !always.isEmpty else { return nil }
        switch resolvedAPIVersion {
        case .legacy:
            if always == ["*"] {
                return String(localized: "While this OpenCode instance remains active, this allows every \(permission) request in this directory. The rule is kept in memory and is not persisted.")
            }
            let patterns = always.joined(separator: ", ")
            return String(localized: "While this OpenCode instance remains active, this allows \(permission) requests matching: \(patterns) in this directory. The rule is kept in memory and is not persisted.")
        case .v2:
            if always == ["*"] {
                return String(localized: "This saves every \(permission) request in this OpenCode project. The rule applies across project sessions and server restarts until removed from saved permissions. Configured deny rules still take precedence.")
            }
            let patterns = always.joined(separator: ", ")
            return String(localized: "This saves \(permission) requests matching: \(patterns) in this OpenCode project. The rule applies across project sessions and server restarts until removed from saved permissions. Configured deny rules still take precedence.")
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

    init(type: String, messageID: String, callID: String) {
        self.type = type; self.messageID = messageID; self.callID = callID
    }
    private enum CodingKeys: String, CodingKey { case type, messageID, callID, id }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        type = try values.decode(String.self, forKey: .type)
        messageID = try values.decode(String.self, forKey: .messageID)
        callID = try values.decodeIfPresent(String.self, forKey: .callID) ?? values.decode(String.self, forKey: .id)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(type, forKey: .type)
        try values.encode(messageID, forKey: .messageID)
        try values.encode(callID, forKey: .callID)
    }
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
    var form: OpenCodeForm? = nil

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

    var wireValue: String? = nil

    var id: String { wireValue ?? label }
}

enum OpenCodeSessionStatus: Equatable, Sendable {
    case idle
    case busy
    case retry(attempt: Int, message: String, next: Double)

    var label: String {
        switch self {
        case .idle: String(localized: "Idle")
        case .busy: String(localized: "Working")
        case .retry(let attempt, _, _): String(localized: "Retry \(attempt)")
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

    var created: Double? = nil
    var isV2: Bool = false
    // Current v2 envelopes carry prompt metadata (for example displayText)
    // beside `data`; the message projection copies it onto the message.
    var metadata: [String: OpenCodeJSONValue]? = nil
    /// v2's `location` envelope. `/api/event` streams every project's events, so
    /// project-level events (not tied to a session) must be matched against it.
    var location: Location? = nil

    struct Location: Codable, Equatable, Sendable {
        let directory: String
        var workspaceID: String?
    }

    /// The instance directory a server-wide stream attributes this event to:
    /// v1 `/global/event` wraps each payload with it, v2 events carry a location.
    var directory: String? { location?.directory }

    var sessionID: String? {
        properties["sessionID"]?.stringValue ?? properties["form"]?.objectValue?["sessionID"]?.stringValue
    }

    private enum CodingKeys: String, CodingKey { case id, type, properties, data, created, metadata, location, payload, directory }
    init(
        id: String, type: String, properties: [String: OpenCodeJSONValue], created: Double? = nil, isV2: Bool = false,
        metadata: [String: OpenCodeJSONValue]? = nil, location: Location? = nil
    ) {
        self.id = id; self.type = type; self.properties = properties; self.created = created; self.isV2 = isV2
        self.metadata = metadata
        self.location = location
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // v1 `/global/event` wraps every project's events as `{directory, project, payload}`.
        // Some payloads (`sync`) carry neither an ID nor properties; "global" is no location.
        if container.contains(.payload) {
            let payload = try container.nestedContainer(keyedBy: CodingKeys.self, forKey: .payload)
            id = try payload.decodeIfPresent(String.self, forKey: .id) ?? ""
            type = try payload.decode(String.self, forKey: .type)
            properties = (try? payload.decodeIfPresent([String: OpenCodeJSONValue].self, forKey: .properties)) ?? [:]
            let directory = try? container.decodeIfPresent(String.self, forKey: .directory)
            location = directory.flatMap { $0 == "global" ? nil : Location(directory: $0) }
            return
        }
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        created = try container.decodeIfPresent(Double.self, forKey: .created)
        isV2 = container.contains(.data)
        properties = try container.decodeIfPresent([String: OpenCodeJSONValue].self, forKey: isV2 ? .data : .properties) ?? [:]
        metadata = isV2 ? try? container.decodeIfPresent([String: OpenCodeJSONValue].self, forKey: .metadata) : nil
        location = try? container.decodeIfPresent(Location.self, forKey: .location)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let directory, !isV2 {
            try container.encode(directory, forKey: .directory)
            var payload = container.nestedContainer(keyedBy: CodingKeys.self, forKey: .payload)
            try payload.encode(id, forKey: .id)
            try payload.encode(type, forKey: .type)
            try payload.encode(properties, forKey: .properties)
            return
        }
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(created, forKey: .created)
        try container.encode(properties, forKey: isV2 ? .data : .properties)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(location, forKey: .location)
    }
}

// v1 user messages carry model identity in `model`; assistant messages flatten it.
extension OpenCodeMessageInfo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        role = try c.decode(String.self, forKey: .role)
        time = try c.decode(OpenCodeMessageTime.self, forKey: .time)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        finish = try c.decodeIfPresent(String.self, forKey: .finish)
        error = try c.decodeIfPresent(OpenCodeMessageError.self, forKey: .error)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        let raw = try OpenCodeJSONValue(from: decoder).objectValue
        let model = raw?["model"]?.objectValue
        variant = try c.decodeIfPresent(String.self, forKey: .variant) ?? model?["variant"]?.stringValue
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? model?["modelID"]?.stringValue
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID) ?? model?["providerID"]?.stringValue
        // User messages reuse `summary` for an object; only the assistant flag matters here.
        cost = try? c.decodeIfPresent(Double.self, forKey: .cost)
        tokens = try? c.decodeIfPresent(OpenCodeTokenUsage.self, forKey: .tokens)
        summary = try? c.decodeIfPresent(Bool.self, forKey: .summary)
    }
}
