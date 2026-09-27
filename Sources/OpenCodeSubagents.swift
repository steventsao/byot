import Foundation

/// A `task` tool call: the parent's handle on the subagent session it spawned.
/// OpenCode records the child's ID in the call's metadata (`sessionId`) as soon
/// as the child exists, and repeats it in the result's `<task id="…">` wrapper.
/// v2 projects the same record as the tool's `structured` state.
struct OpenCodeSubagentTask: Equatable, Sendable {
    /// The tool part's ID.
    let id: String
    let description: String?
    /// The subagent type the model asked for, such as `explore`.
    let agent: String?
    let sessionID: String?
    let isBackground: Bool
    /// `pending`, `running`, `completed`, or `error`.
    let status: String
    /// The subagent's final answer, without OpenCode's wrapper tags.
    let result: String?
    let error: String?
    /// Seconds from the call starting to its result, when both are known.
    let duration: TimeInterval?

    init?(part: OpenCodePart) {
        guard part.type == "tool", part.tool?.lowercased() == "task", let state = part.state else { return nil }
        let input = state.input
        id = part.id
        description = input?["description"]?.stringValue?.trimmedNonEmpty
        agent = input?["subagent_type"]?.stringValue?.trimmedNonEmpty
        let output = state.output?.trimmedNonEmpty
        sessionID = Self.childSessionID(metadata: state.metadata, output: output)
        isBackground = state.metadata?["background"] == .bool(true) || input?["background"] == .bool(true)
        status = state.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        result = output.flatMap(Self.resultText)
        error = state.error?.trimmedNonEmpty
        if let time = state.time, let end = time.end, end >= time.start, time.start > 0 {
            duration = (end - time.start) / 1_000
        } else {
            duration = nil
        }
    }

    /// The title OpenCode gives the child it creates for this call, used to
    /// find the child when a server leaves the ID out of the call's metadata.
    var expectedChildTitle: String? {
        guard let description, let agent else { return nil }
        return "\(description) (@\(agent) subagent)"
    }

    func isChild(_ session: OpenCodeSession) -> Bool {
        if let sessionID { return session.id == sessionID }
        return expectedChildTitle == session.title
    }

    static func childSessionID(metadata: [String: OpenCodeJSONValue]?, output: String?) -> String? {
        for key in ["sessionId", "sessionID", "session_id"] {
            if let id = metadata?[key]?.stringValue?.trimmedNonEmpty { return id }
        }
        guard let output else { return nil }
        // Current: `<task id="ses_…" state="…">`. Earlier: `task_id: ses_… (for resuming …)`.
        for prefix in ["<task id=\"", "task_id: "] {
            guard let start = output.range(of: prefix)?.upperBound else { continue }
            let id = output[start...].prefix { !$0.isWhitespace && $0 != "\"" && $0 != "(" }
            if id.hasPrefix("ses") { return String(id) }
        }
        return nil
    }

    /// The text inside `<task_result>` (or `<task_error>`). Output without the
    /// wrapper is returned whole, less a leading `task_id:` line.
    static func resultText(_ output: String) -> String? {
        for tag in ["task_result", "task_error"] {
            guard let open = output.range(of: "<\(tag)>") else { continue }
            let close = output.range(of: "</\(tag)>", range: open.upperBound..<output.endIndex)
            return String(output[open.upperBound..<(close?.lowerBound ?? output.endIndex)]).trimmedNonEmpty
        }
        let lines = output.components(separatedBy: "\n")
        let body = lines.first?.hasPrefix("task_id:") == true ? lines.dropFirst() : lines[...]
        return body.joined(separator: "\n").trimmedNonEmpty
    }

    /// Child session IDs named by task calls in a transcript, in order. It
    /// runs on every streamed token, so it reads only the ID.
    static func sessionIDs(in messages: [OpenCodeMessageEnvelope]) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        for message in messages {
            for part in message.parts where part.type == "tool" && part.tool?.lowercased() == "task" {
                guard let state = part.state,
                      let id = childSessionID(metadata: state.metadata, output: state.output),
                      seen.insert(id).inserted else { continue }
                ids.append(id)
            }
        }
        return ids
    }

    static func containsTask(in messages: [OpenCodeMessageEnvelope]) -> Bool {
        messages.contains { $0.parts.contains { $0.type == "tool" && $0.tool?.lowercased() == "task" } }
    }
}

/// OpenCode titles a subagent session `<task> (@<agent> subagent)`. Screens
/// show the task and name the agent separately, as OpenCode's app does.
enum OpenCodeSubagentTitle {
    static func parse(_ title: String) -> (task: String, agent: String?) {
        let suffix = " subagent)"
        guard title.hasSuffix(suffix), let open = title.range(of: " (@", options: .backwards) else {
            return (title, nil)
        }
        let agent = title[open.upperBound..<title.index(title.endIndex, offsetBy: -suffix.count)]
        guard !agent.isEmpty, !agent.contains(")") else { return (title, nil) }
        let task = String(title[..<open.lowerBound]).trimmedNonEmpty ?? title
        return (task, String(agent))
    }

    static func displayTitle(of session: OpenCodeSession) -> String {
        session.parentID == nil ? session.title : parse(session.title).task
    }

    static func agent(of session: OpenCodeSession) -> String? {
        session.agent?.trimmedNonEmpty ?? parse(session.title).agent
    }

    /// `explore` → `Explore`, `code-reviewer` → `Code Reviewer`.
    static func agentLabel(_ agent: String?) -> String {
        agent?.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .capitalized.trimmedNonEmpty ?? "Subagent"
    }
}

/// What the parent has seen of one child session since it opened: the
/// child's status, its tool calls, and requests waiting on the user.
struct OpenCodeSubagentActivity: Equatable, Sendable {
    /// nil until the server reports one; v1 reports only non-idle sessions.
    var status: OpenCodeSessionStatus?
    var toolCallIDs: Set<String> = []
    /// The latest tool call, as its transcript row reads.
    var latestTool: String?
    var pendingRequestIDs: Set<String> = []

    var toolCount: Int { toolCallIDs.count }
    var needsResponse: Bool { !pendingRequestIDs.isEmpty }
}

/// Follows the child sessions a parent knows about through the parent's own
/// event stream, which already carries every session in the directory.
struct OpenCodeSubagentTracker: Equatable, Sendable {
    private(set) var activity: [String: OpenCodeSubagentActivity] = [:]

    func isTracking(_ sessionID: String) -> Bool { activity[sessionID] != nil }

    /// Starts following these sessions. Returns true when any is new.
    @discardableResult
    mutating func track<IDs: Sequence>(_ ids: IDs) -> Bool where IDs.Element == String {
        var added = false
        for id in ids where activity[id] == nil {
            activity[id] = OpenCodeSubagentActivity()
            added = true
        }
        return added
    }

    /// Applies an authoritative status snapshot. Sessions it leaves out are idle.
    mutating func applyStatuses(_ statuses: [String: OpenCodeSessionStatus]) {
        for id in activity.keys {
            activity[id]?.status = statuses[id] ?? .idle
        }
    }

    /// Replaces the pending requests of every followed session with a
    /// directory-wide snapshot of `(sessionID, requestID)` pairs.
    mutating func applyPendingRequests(_ requests: [(sessionID: String, id: String)]) {
        var pending: [String: Set<String>] = [:]
        for request in requests where activity[request.sessionID] != nil {
            pending[request.sessionID, default: []].insert(request.id)
        }
        for id in activity.keys {
            activity[id]?.pendingRequestIDs = pending[id] ?? []
        }
    }

    /// Returns true when the event changed a followed session's activity.
    @discardableResult
    mutating func apply(_ event: OpenCodeEvent) -> Bool {
        let data = event.properties
        // Older servers name the session only inside the part.
        guard let sessionID = event.sessionID ?? data["part"]?.objectValue?["sessionID"]?.stringValue,
              var entry = activity[sessionID] else { return false }
        switch OpenCodeV2EventReducer.canonicalType(event.type) {
        case "session.status":
            guard let status = Self.status(data["status"]) else { return false }
            entry.status = status
        case "session.idle", "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted":
            entry.status = .idle
        case "session.execution.started", "session.step.started":
            entry.status = .busy
        case "session.retry.scheduled", "session.retried":
            entry.status = .retry(attempt: Int(data["attempt"]?.numberValue ?? 1),
                                  message: data["error"]?.objectValue?["message"]?.stringValue ?? "Retrying",
                                  next: data["at"]?.numberValue ?? 0)
        case "message.part.updated":
            guard let part = data["part"]?.objectValue, part["type"]?.stringValue == "tool",
                  let id = part["id"]?.stringValue, let name = part["tool"]?.stringValue,
                  let state = part["state"].flatMap(Self.toolState) else { return false }
            entry.toolCallIDs.insert(id)
            entry.latestTool = Self.toolLine(name: name, state: state)
        case "session.tool.called":
            guard let id = data["callID"]?.stringValue ?? data["id"]?.stringValue,
                  let name = data["tool"]?.stringValue ?? data["name"]?.stringValue else { return false }
            entry.toolCallIDs.insert(id)
            let state = OpenCodeToolState(status: "running", input: data["input"]?.objectValue, raw: nil,
                                          title: nil, output: nil, error: nil, time: nil)
            entry.latestTool = Self.toolLine(name: name, state: state)
        case "permission.asked", "permission.v2.asked", "question.asked", "question.v2.asked", "form.created":
            guard let id = data["id"]?.stringValue ?? data["form"]?.objectValue?["id"]?.stringValue else { return false }
            entry.pendingRequestIDs.insert(id)
        case "permission.replied", "permission.v2.replied", "question.replied", "question.v2.replied",
             "question.rejected", "question.v2.rejected", "form.replied", "form.cancelled":
            guard let id = data["requestID"]?.stringValue ?? data["id"]?.stringValue
                    ?? data["form"]?.objectValue?["id"]?.stringValue else { return false }
            entry.pendingRequestIDs.remove(id)
        default:
            return false
        }
        guard entry != activity[sessionID] else { return false }
        activity[sessionID] = entry
        return true
    }

    private static func status(_ value: OpenCodeJSONValue?) -> OpenCodeSessionStatus? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(OpenCodeSessionStatus.self, from: data)
    }

    private static func toolState(_ value: OpenCodeJSONValue) -> OpenCodeToolState? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(OpenCodeToolState.self, from: data)
    }

    private static func toolLine(name: String, state: OpenCodeToolState) -> String {
        let presentation = OpenCodeToolPresentation(name: name, state: state)
        return [presentation.title, presentation.summary].compactMap { $0 }.joined(separator: " · ")
    }
}

/// A subagent session among its siblings: the children of one parent in the
/// order they were created, as OpenCode's TUI steps through them.
struct OpenCodeSubagentFamily: Equatable, Sendable {
    let parentID: String
    let parent: OpenCodeSession?
    let siblings: [OpenCodeSession]
    let currentID: String

    init?(session: OpenCodeSession, parent: OpenCodeSession?, siblings: [OpenCodeSession]) {
        guard let parentID = session.parentID else { return nil }
        self.parentID = parentID
        self.parent = parent?.id == parentID ? parent : nil
        var family = siblings.filter { $0.parentID == parentID && $0.id != session.id && $0.time.archived == nil }
        family.append(session)
        self.siblings = Self.ordered(family)
        currentID = session.id
    }

    static func ordered(_ sessions: [OpenCodeSession]) -> [OpenCodeSession] {
        sessions.sorted { ($0.time.created, $0.id) < ($1.time.created, $1.id) }
    }

    private var index: Int? { siblings.firstIndex { $0.id == currentID } }
    /// One-based position among the siblings.
    var position: Int? { index.map { $0 + 1 } }
    var count: Int { siblings.count }
    var previous: OpenCodeSession? { index.flatMap { $0 > 0 ? siblings[$0 - 1] : nil } }
    var next: OpenCodeSession? { index.flatMap { $0 + 1 < siblings.count ? siblings[$0 + 1] : nil } }
    var parentTitle: String? { parent.map(OpenCodeSubagentTitle.displayTitle) }
}

/// How a task card reads: the subagent, what it was asked to do, and where it is.
struct OpenCodeSubagentCardPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case starting, running, retrying, needsResponse, background, completed, failed
    }

    let phase: Phase
    let agentLabel: String
    let title: String
    let statusLabel: String
    /// A secondary line: the current tool, or the finished run's size.
    let detail: String?
    let isLinked: Bool

    init(task: OpenCodeSubagentTask, activity: OpenCodeSubagentActivity?, isLinked: Bool) {
        let childActive = activity?.status?.isActive == true
        let phase: Phase
        if task.status == "error" {
            phase = .failed
        } else if activity?.needsResponse == true, task.status != "completed" || task.isBackground {
            phase = .needsResponse
        } else if case .retry? = activity?.status, task.status == "running" || task.isBackground {
            phase = .retrying
        } else if task.status == "running" || (task.isBackground && childActive) {
            phase = .running
        } else if task.status == "completed" {
            // A background call completes as soon as it launches; its child
            // is done only once the server reports it idle.
            phase = task.isBackground && activity?.status == nil ? .background : .completed
        } else {
            phase = .starting
        }
        self.phase = phase
        let agent = OpenCodeSubagentTitle.agentLabel(task.agent)
        agentLabel = task.isBackground ? "\(agent) · Background" : agent
        title = task.description ?? "Subagent task"
        self.isLinked = isLinked

        switch phase {
        case .starting: statusLabel = "Starting"
        case .running: statusLabel = "Running"
        case .retrying: statusLabel = "Retrying"
        case .needsResponse: statusLabel = "Needs your response"
        case .background: statusLabel = "In background"
        case .completed: statusLabel = "Done"
        case .failed: statusLabel = "Failed"
        }

        let toolCount = activity?.toolCount ?? 0
        let calls = toolCount > 0 ? "\(toolCount) tool call\(toolCount == 1 ? "" : "s")" : nil
        switch phase {
        case .running:
            detail = activity?.latestTool ?? calls
        case .retrying:
            if case .retry(let attempt, let message, _)? = activity?.status {
                detail = "Attempt \(attempt) · \(message)"
            } else {
                detail = nil
            }
        case .needsResponse:
            detail = "Open to answer"
        case .completed, .failed:
            let parts = [calls, task.duration.map(Self.durationText)].compactMap { $0 }
            detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .starting, .background:
            detail = nil
        }
    }

    var isActive: Bool { phase == .running || phase == .retrying || phase == .starting }

    var accessibilityLabel: String {
        ["\(agentLabel) subagent", title, statusLabel, detail].compactMap { $0 }.joined(separator: ", ")
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(total, 0))s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h \((total % 3_600) / 60)m"
    }
}
