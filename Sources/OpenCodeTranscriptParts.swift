import Foundation

// Presentation for the transcript parts that are neither prose nor tool calls:
// compaction, retry, agent and model switches, step summaries, snapshots,
// patches and inline images. The views stay thin; the wording, grouping and
// file matching live here so they can be tested without rendering.

/// One row of a message: a single part, or a run of adjacent images shown
/// together as a gallery.
enum OpenCodeTranscriptItem: Identifiable, Equatable, Sendable {
    case part(OpenCodePart)
    case images([OpenCodePart])

    var id: String {
        switch self {
        case .part(let part): part.id
        case .images(let parts): "images:" + (parts.first?.id ?? "")
        }
    }

    /// Markers that divide the conversation rather than belong to a prompt.
    var isBanner: Bool {
        guard case .part(let part) = self else { return false }
        return part.type == "compaction"
    }
}

enum OpenCodeTranscriptLayout {
    static func items(for parts: [OpenCodePart], inPrompt: Bool = false) -> [OpenCodeTranscriptItem] {
        var items: [OpenCodeTranscriptItem] = []
        for part in parts where isVisible(part, inPrompt: inPrompt) {
            if OpenCodeInlineImage.isInlineCandidate(part) {
                if case .images(let run)? = items.last {
                    items[items.count - 1] = .images(run + [part])
                } else {
                    items.append(.images([part]))
                }
            } else {
                items.append(.part(part))
            }
        }
        return items
    }

    /// Parts that would render nothing are dropped so they add no spacing.
    /// A prompt shows only what the user wrote, as upstream clients do: the
    /// synthetic text OpenCode adds for attached files and resources stays
    /// out of the pill, since the attachment itself is already shown.
    static func isVisible(_ part: OpenCodePart, inPrompt: Bool = false) -> Bool {
        switch part.type {
        case "text" where inPrompt && part.synthetic == true: false
        case "text" where part.synthetic == true: part.text?.trimmedNonEmpty != nil
        case "text", "reasoning": part.text?.isEmpty == false
        case "tool": part.state != nil
        case "patch": part.files?.isEmpty == false
        case "step-finish": OpenCodeStepSummary(part: part) != nil
        case "snapshot": part.snapshot?.trimmedNonEmpty != nil
        case "agent", "model": part.name?.trimmedNonEmpty != nil
        case "retry", "compaction", "file", "subtask": true
        default: false
        }
    }

    /// Whether a message draws anything. A step that has started with nothing
    /// to show yet takes no row, so it adds no spacing above what follows.
    static func rendersRow(_ message: OpenCodeMessageEnvelope) -> Bool {
        let inPrompt = message.info.role == "user"
        return message.parts.contains { isVisible($0, inPrompt: inPrompt) }
            || message.info.error != nil
            || OpenCodeStepSummary(reply: message) != nil
    }

    /// The least height the transcript takes: one viewport, once it has been
    /// measured. A transcript shorter than the screen then fills it from the
    /// top and leaves the scroll view no other place to rest it.
    static func minimumContentHeight(viewportHeight: CGFloat) -> CGFloat? {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return nil }
        return viewportHeight
    }
}

// MARK: - Compaction

struct OpenCodeCompactionPresentation: Equatable, Sendable {
    let title: String
    let detail: String?
    let summary: String?
    let accessibilityLabel: String

    init(part: OpenCodePart) {
        title = String(localized: "Context compacted")
        switch (part.auto, part.overflow) {
        case (true?, true?):
            detail = String(localized: "Automatic · context limit reached")
            accessibilityLabel = String(localized: "Context compacted automatically because the context limit was reached")
        case (true?, _):
            detail = String(localized: "Automatic")
            accessibilityLabel = String(localized: "Context compacted automatically")
        case (false?, _):
            detail = String(localized: "Requested")
            accessibilityLabel = String(localized: "Context compacted on request")
        default:
            detail = nil
            accessibilityLabel = String(localized: "Context compacted")
        }
        summary = part.text?.trimmedNonEmpty
    }
}

// MARK: - Synthetic context

/// Context OpenCode added for the model outside a prompt: v2 system context
/// updates and synthetic messages. It stays collapsed so it never reads as
/// something the agent said.
struct OpenCodeSyntheticContextPresentation: Equatable, Sendable {
    let title: String
    let text: String
    let accessibilityLabel: String

    /// Long context, such as a whole attached file, is cut short so the
    /// expanded row stays quick to lay out.
    static let characterLimit = 4_000

    init?(part: OpenCodePart) {
        guard part.type == "text", part.synthetic == true, let text = part.text?.trimmedNonEmpty else { return nil }
        title = String(localized: "Added context")
        self.text = text.count > Self.characterLimit ? String(text.prefix(Self.characterLimit)) + "\n…" : text
        let lines = text.split(whereSeparator: \.isNewline).count
        accessibilityLabel = lines == 1
            ? String(localized: "Context OpenCode added for the model, 1 line")
            : String(localized: "Context OpenCode added for the model, \(lines) lines")
    }
}

// MARK: - Retry

struct OpenCodeRetryPresentation: Equatable, Sendable {
    let title: String
    let detail: String?
    let accessibilityLabel: String

    init(part: OpenCodePart) {
        title = part.attempt.map { String(localized: "Retried after an error · attempt \($0)") }
            ?? String(localized: "Retried after an error")
        let status = part.error?.data?["statusCode"]?.numberValue.map { "HTTP \(Int($0))" }
        let message = part.error.map(\.displayMessage)?.trimmedNonEmpty
        detail = [status, message].compactMap { $0 }.joined(separator: " · ").trimmedNonEmpty
        accessibilityLabel = [
            part.attempt.map { String(localized: "Retried after an error, attempt \($0)") }
                ?? String(localized: "Retried after an error"),
            detail,
        ].compactMap { $0 }.joined(separator: ". ")
    }
}

// MARK: - Agent and model switches

struct OpenCodeSwitchPresentation: Equatable, Sendable {
    let symbol: String
    let title: String
    let accessibilityLabel: String

    /// In a prompt the agent part is an @mention; elsewhere it records a switch.
    init?(part: OpenCodePart, inPrompt: Bool) {
        guard let name = part.name?.trimmedNonEmpty else { return nil }
        switch part.type {
        case "agent" where inPrompt:
            symbol = "at"
            title = name
            accessibilityLabel = String(localized: "Sent to the \(name) agent")
        case "agent":
            symbol = "person.crop.circle"
            title = String(localized: "Switched to \(name)")
            accessibilityLabel = String(localized: "Switched to the \(name) agent")
        case "model":
            symbol = "cpu"
            title = String(localized: "Switched to \(name)")
            accessibilityLabel = String(localized: "Switched to model \(name)")
        default:
            return nil
        }
    }
}

// MARK: - Step summaries

/// A quiet per-step footer: tokens and cost, with the full breakdown behind
/// a disclosure. Routine finishes (stop, tool calls) are not called out.
struct OpenCodeStepSummary: Equatable, Sendable {
    struct Detail: Identifiable, Equatable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }

    let title: String
    let outcome: String?
    let details: [Detail]
    let accessibilityLabel: String

    /// `contextLimit` is the reply's model window; with it the breakdown
    /// shows how much of the window the step filled.
    init?(part: OpenCodePart, contextLimit: Int? = nil, locale: Locale = .current) {
        guard part.type == "step-finish" else { return nil }
        self.init(kind: String(localized: "Step"), tokens: part.tokens, cost: part.cost, reason: part.reason,
                  contextLimit: contextLimit, locale: locale)
    }

    /// A reply whose server recorded accounting on the message but sent no
    /// step-finish parts still gets a footer, built from the message.
    init?(reply message: OpenCodeMessageEnvelope, contextLimit: Int? = nil, locale: Locale = .current) {
        guard message.info.role == "assistant",
              !message.parts.contains(where: { $0.type == "step-finish" && Self(part: $0) != nil })
        else { return nil }
        self.init(kind: String(localized: "Reply"), tokens: message.info.tokens, cost: message.info.cost, reason: message.info.finish,
                  contextLimit: contextLimit, locale: locale)
    }

    private init?(kind: String, tokens: OpenCodeTokenUsage?, cost: Double?, reason: String?, contextLimit: Int?,
                  locale: Locale) {
        let cost = cost ?? 0
        guard (tokens?.total ?? 0) > 0 || cost > 0 else { return nil }

        var headline: [String] = []
        var spoken: [String] = []
        var details: [Detail] = []
        if let tokens, tokens.total > 0 {
            let compact = Self.compact(tokens.total, locale: locale)
            let full = Self.full(tokens.total, locale: locale)
            headline.append(String(localized: "\(compact) tokens"))
            spoken.append(String(localized: "\(full) tokens"))
            // Input and output always show; the rest only when the step used them.
            let rows: [(String, Double, Bool)] = [
                (String(localized: "Input"), tokens.input, true), (String(localized: "Output"), tokens.output, true),
                (String(localized: "Reasoning"), tokens.reasoning, false),
                (String(localized: "Cache read"), tokens.cacheRead, false),
                (String(localized: "Cache write"), tokens.cacheWrite, false),
            ]
            for (label, value, alwaysShown) in rows where value > 0 || alwaysShown {
                details.append(Detail(label: label, value: Self.full(value, locale: locale)))
            }
            if let contextLimit, contextLimit > 0, tokens.contextTokens > 0 {
                let percent = OpenCodeContextUsage.percent(tokens.contextTokens / Double(contextLimit))
                let window = Self.compact(Double(contextLimit), locale: locale)
                details.append(Detail(label: String(localized: "Context"),
                    value: String(localized: "\(percent)% of \(window)")))
            }
        }
        if cost > 0 {
            let formatted = Self.cost(cost, locale: locale)
            headline.append(formatted)
            spoken.append(String(localized: "cost \(formatted)"))
            details.append(Detail(label: String(localized: "Cost"), value: formatted))
        }
        outcome = Self.outcome(reason)
        if let outcome { details.append(Detail(label: String(localized: "Finish"), value: outcome)) }
        title = ([kind] + headline).joined(separator: " · ")
        self.details = details
        let used = spoken.joined(separator: ", ")
        accessibilityLabel = ([String(localized: "\(kind) used \(used)")] + [outcome].compactMap { $0 })
            .joined(separator: ". ")
    }

    static func outcome(_ reason: String?) -> String? {
        guard let reason = reason?.trimmedNonEmpty?.lowercased() else { return nil }
        switch reason {
        case "stop", "tool-calls", "tool_calls", "unknown", "other": return nil
        case "length", "max-tokens", "max_tokens": return String(localized: "Stopped at the output limit")
        case "content-filter", "content_filter": return String(localized: "Stopped by the content filter")
        case "error": return String(localized: "Ended with an error")
        default:
            let words = reason.replacingOccurrences(of: "[-_]+", with: " ", options: .regularExpression)
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    static func compact(_ value: Double, locale: Locale) -> String {
        guard value >= 1_000 else { return full(value, locale: locale) }
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(locale))
    }

    static func full(_ value: Double, locale: Locale) -> String {
        Int(value.rounded()).formatted(.number.locale(locale))
    }

    /// Small step costs keep enough precision to be distinguishable from zero.
    static func cost(_ value: Double, locale: Locale) -> String {
        let digits = value > 0 && value < 0.01 ? 4 : 2
        return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)).locale(locale))
    }
}

// MARK: - Snapshots

struct OpenCodeSnapshotPresentation: Equatable, Sendable {
    let title: String
    let accessibilityLabel: String

    init?(part: OpenCodePart) {
        guard let hash = part.snapshot?.trimmedNonEmpty else { return nil }
        let short = String(hash.prefix(7))
        title = String(localized: "Checkpoint · \(short)")
        accessibilityLabel = String(localized: "Workspace checkpoint \(short)")
    }
}

// MARK: - Patches

/// A file a step changed, matched to the session diff when one covers it.
struct OpenCodePatchFile: Identifiable, Equatable, Sendable {
    let path: String
    let displayPath: String
    let diffID: String?

    var id: String { path }

    var filename: String { displayPath.split(separator: "/").last.map(String.init) ?? displayPath }

    var folder: String? {
        let components = displayPath.split(separator: "/")
        guard components.count > 1 else { return nil }
        return components.dropLast().joined(separator: "/")
    }

    /// v1 patch parts list absolute paths under the worktree, which may sit
    /// above the session directory; v2 step files are relative. Session
    /// diffs are relative to the worktree, so a file matches the diff whose
    /// path it equals or ends with, and then shows that shorter path.
    static func resolve(_ files: [String], directory: String, diffs: [OpenCodeDiff]) -> [OpenCodePatchFile] {
        let root = normalize(directory).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let candidates = diffs.compactMap { diff in diff.file.map { (id: diff.id, path: normalize($0)) } }
        var seen = Set<String>()
        return files.compactMap { raw in
            let path = normalize(raw)
            guard !path.isEmpty, seen.insert(path).inserted else { return nil }
            let relative = !root.isEmpty && path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : nil
            let match = candidates.first { $0.path == relative || $0.path == path }
                ?? candidates.filter { path.hasSuffix("/" + $0.path) }.max { $0.path.count < $1.path.count }
            return OpenCodePatchFile(path: path, displayPath: relative ?? match?.path ?? path, diffID: match?.id)
        }
    }

    private static func normalize(_ path: String) -> String {
        var value = path.replacingOccurrences(of: "\\", with: "/")
        while value.hasPrefix("./") { value.removeFirst(2) }
        return value
    }
}

// MARK: - Inline images

/// Where an image part's bytes come from: inline in a data URL, or a file on
/// the server that the session's file service can read.
enum OpenCodeInlineImage: Equatable, Sendable {
    case data(Data)
    case serverFile(path: String)

    /// Raster types UIKit decodes; SVG and PDF keep the attachment row.
    static func isRasterMime(_ mime: String?) -> Bool {
        guard let mime = mime?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces),
              mime.hasPrefix("image/") else { return false }
        return !["image/svg+xml", "image/x-icon", "image/vnd.microsoft.icon"].contains(mime)
    }

    /// File parts that should render as a thumbnail rather than a file row.
    static func isInlineCandidate(_ part: OpenCodePart) -> Bool {
        guard part.type == "file", let url = part.url else { return false }
        let scheme = url.prefix(while: { $0 != ":" }).lowercased()
        if scheme == "data" { return isRasterMime(OpenCodeDataURL.mediaType(url) ?? part.mime) }
        return scheme == "file" && isRasterMime(part.mime)
    }

    static func resolve(_ part: OpenCodePart, scope: OpenCodeRemoteFileScope?) -> OpenCodeInlineImage? {
        guard isInlineCandidate(part), let url = part.url else { return nil }
        if let decoded = OpenCodeDataURL.decode(url) { return .data(decoded.data) }
        guard let scope,
              let reference = OpenCodePromptFileReference.restored(
                fromURI: url, serverID: scope.serverID, projectID: scope.projectID,
                directory: scope.directory, workspaceID: scope.workspaceID)
        else { return nil }
        return .serverFile(path: reference.path)
    }

    static func displayName(for part: OpenCodePart) -> String {
        if let filename = part.filename?.trimmedNonEmpty { return filename }
        if let url = part.url, url.lowercased().hasPrefix("file:"),
           let last = URLComponents(string: url)?.path.split(separator: "/").last {
            return String(last)
        }
        return String(localized: "Image")
    }
}

/// RFC 2397 data URLs, base64 or percent-encoded.
enum OpenCodeDataURL {
    static func mediaType(_ value: String) -> String? {
        guard value.count > 5, value.prefix(5).lowercased() == "data:",
              let comma = value.firstIndex(of: ",") else { return nil }
        let header = value[value.index(value.startIndex, offsetBy: 5)..<comma]
        let type = header.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return type.isEmpty ? "text/plain" : type.lowercased()
    }

    static func decode(_ value: String) -> (mime: String, data: Data)? {
        guard let mime = mediaType(value), let comma = value.firstIndex(of: ",") else { return nil }
        let header = value[..<comma].lowercased()
        let payload = String(value[value.index(after: comma)...])
        let data: Data?
        if header.hasSuffix(";base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data, !data.isEmpty else { return nil }
        return (mime, data)
    }
}

// MARK: - Turns

/// A prompt and the replies that answer it.
struct OpenCodeTranscriptTurn: Identifiable, Equatable, Sendable {
    let prompt: OpenCodeMessageEnvelope
    var replies: [OpenCodeMessageEnvelope] = []

    var id: String { prompt.id }
}

/// What the conversation draws: turns, shell runs, and replies whose prompt
/// is not in the transcript, as when the history starts mid-turn.
enum OpenCodeConversationRow: Identifiable, Equatable, Sendable {
    case turn(OpenCodeTranscriptTurn)
    case reply(OpenCodeMessageEnvelope)
    case shell(OpenCodeShellRun)

    var id: String {
        switch self {
        case .turn(let turn): turn.id
        case .reply(let message): message.id
        case .shell(let run): run.id
        }
    }

    /// A reply joins the prompt its `parentID` names, else the latest prompt
    /// before it, so a step that lands after a newer prompt stays in its turn.
    static func rows(_ rows: [OpenCodeTranscriptRow]) -> [OpenCodeConversationRow] {
        enum Slot { case turn(Int), reply(OpenCodeMessageEnvelope), shell(OpenCodeShellRun) }
        var slots: [Slot] = []
        var turns: [OpenCodeTranscriptTurn] = []
        var turnIndex: [String: Int] = [:]
        var latest: Int?
        for row in rows {
            switch row {
            case .shell(let run):
                slots.append(.shell(run))
                latest = nil
            case .message(let message) where message.info.role == "user":
                turnIndex[message.id] = turns.count
                latest = turns.count
                slots.append(.turn(turns.count))
                turns.append(OpenCodeTranscriptTurn(prompt: message))
            case .message(let message):
                // A named parent that is not in the transcript leaves the reply on its own.
                let target: Int? = if let parentID = message.info.parentID { turnIndex[parentID] } else { latest }
                if let target {
                    turns[target].replies.append(message)
                } else {
                    slots.append(.reply(message))
                }
            }
        }
        return slots.map { slot in
            switch slot {
            case .turn(let index): .turn(turns[index])
            case .reply(let message): .reply(message)
            case .shell(let run): .shell(run)
            }
        }
    }
}

/// The line above a turn's replies: how long OpenCode has been working, or
/// how long it worked and how the turn ended.
struct OpenCodeTurnHeader: Equatable, Sendable {
    enum Ending: Equatable, Sendable { case completed, stopped, failed }

    /// Nil while the turn runs.
    let ending: Ending?
    let startedAt: Date
    let finishedAt: Date?

    /// Nil for a finished turn with no reply to time.
    init?(turn: OpenCodeTranscriptTurn, isRunning: Bool) {
        startedAt = Date(timeIntervalSince1970: turn.prompt.info.time.created / 1_000)
        if isRunning {
            ending = nil
            finishedAt = nil
            return
        }
        guard let end = turn.replies.map({ $0.info.time.completed ?? $0.info.time.created }).max(),
              let last = turn.replies.last else { return nil }
        finishedAt = Date(timeIntervalSince1970: end / 1_000)
        ending = switch last.info.error?.name {
        case nil: .completed
        case "MessageAbortedError": .stopped
        default: .failed
        }
    }

    /// The running header counts from the prompt on this device's clock, so
    /// a server clock a day or more away shows no time rather than a wrong
    /// one; a running turn then has no header, as the activity row says it works.
    func title(now: Date = .now) -> String? {
        let elapsed = (finishedAt ?? now).timeIntervalSince(startedAt)
        guard elapsed < 86_400 else {
            return switch ending {
            case nil: nil
            case .completed: String(localized: "Done")
            case .stopped: String(localized: "Stopped")
            case .failed: String(localized: "Failed")
            }
        }
        let duration = OpenCodeSubagentCardPresentation.durationText(elapsed)
        return switch ending {
        case nil: String(localized: "Working for \(duration)")
        case .completed: String(localized: "Worked for \(duration)")
        case .stopped: String(localized: "Stopped after \(duration)")
        case .failed: String(localized: "Failed after \(duration)")
        }
    }
}

/// A reply part and the model that wrote it, so a step footer measures
/// against that model's context window.
struct OpenCodeTurnPart: Identifiable, Equatable, Sendable {
    let part: OpenCodePart
    let modelKey: String?

    var id: String { part.id }
}

/// One row under a turn's header.
enum OpenCodeTurnItem: Identifiable, Equatable, Sendable {
    case part(OpenCodeTurnPart)
    case images([OpenCodePart])
    /// Tool calls made back to back, with the reasoning and step footers between them.
    case tools([OpenCodeTurnPart])
    /// Accounting for a reply that sent no step-finish parts.
    case replySummary(OpenCodeMessageEnvelope)
    case error(messageID: String, OpenCodeMessageError)
    /// Every file a folded turn changed, in one list.
    case changes([String])

    var id: String {
        switch self {
        case .part(let entry): entry.id
        case .images(let parts): "images:" + (parts.first?.id ?? "")
        case .tools(let entries): "tools:" + (entries.first?.id ?? "")
        case .replySummary(let reply): "summary:" + reply.id
        case .error(let messageID, _): "error:" + messageID
        case .changes: "changes"
        }
    }
}

/// A turn's replies as rows, in full and folded. A finished turn opens folded,
/// as Codex does: the last stretch of prose (the answer), the files and
/// images it produced, the subagents it started, every file it changed in
/// one list, and any error. Tool calls, reasoning, narration between them and
/// step footers wait behind the header.
struct OpenCodeTurnContent: Equatable, Sendable {
    let items: [OpenCodeTurnItem]
    let folded: [OpenCodeTurnItem]
    /// Whether folding hides anything; a turn that only answered has nothing to open.
    let canFold: Bool

    init(turn: OpenCodeTranscriptTurn) {
        var flat: [OpenCodeTurnItem] = []
        for reply in turn.replies {
            let modelKey = reply.info.providerID.flatMap { provider in reply.info.modelID.map { "\(provider)/\($0)" } }
            for item in OpenCodeTranscriptLayout.items(for: reply.parts) {
                switch item {
                case .part(let part): flat.append(.part(OpenCodeTurnPart(part: part, modelKey: modelKey)))
                case .images(let parts): flat.append(.images(parts))
                }
            }
            if OpenCodeStepSummary(reply: reply) != nil { flat.append(.replySummary(reply)) }
            if let error = reply.info.error { flat.append(.error(messageID: reply.id, error)) }
        }
        items = Self.groupingTools(flat)

        var answer = Set<String>()
        scan: for item in flat.reversed() {
            switch Self.role(of: item) {
            case .prose: answer.insert(item.id)
            case .work where !answer.isEmpty: break scan
            default: continue
            }
        }
        var kept: [OpenCodeTurnItem] = []
        var errors: [OpenCodeTurnItem] = []
        var changed: [String] = []
        var hidesWork = false
        for item in flat {
            switch item {
            case .error: errors.append(item)
            case .images: kept.append(item)
            case .part(let entry) where entry.part.type == "patch":
                for file in entry.part.files ?? [] where !changed.contains(file) { changed.append(file) }
            case .part(let entry) where answer.contains(entry.id) || Self.isOutcome(entry.part):
                kept.append(item)
            default:
                hidesWork = true
            }
        }
        if !changed.isEmpty { kept.append(.changes(changed)) }
        folded = kept + errors
        canFold = hidesWork
    }

    private enum Role { case prose, work, quiet }

    /// Prose is the answer's stuff; work interrupts it; everything else (step
    /// footers, checkpoints, patches, files) can sit inside an answer.
    private static func role(of item: OpenCodeTurnItem) -> Role {
        guard case .part(let entry) = item else { return .quiet }
        return switch entry.part.type {
        case "text": .prose
        case "tool", "reasoning", "retry", "subtask": .work
        default: .quiet
        }
    }

    /// What the turn produced, kept in view when it folds. Subagent cards stay
    /// too: a background subagent can outlive the turn that started it.
    private static func isOutcome(_ part: OpenCodePart) -> Bool {
        switch part.type {
        case "file", "compaction": true
        case "tool": OpenCodeSubagentTask(part: part) != nil
        default: false
        }
    }

    /// Two or more tool calls with only reasoning, step footers and
    /// checkpoints between them become one `.tools` row.
    static func groupingTools(_ flat: [OpenCodeTurnItem]) -> [OpenCodeTurnItem] {
        func isTool(_ item: OpenCodeTurnItem) -> Bool {
            guard case .part(let entry) = item else { return false }
            return entry.part.type == "tool" && OpenCodeSubagentTask(part: entry.part) == nil
        }
        func isBetweenTools(_ item: OpenCodeTurnItem) -> Bool {
            guard case .part(let entry) = item else { return false }
            return ["reasoning", "step-finish", "snapshot"].contains(entry.part.type)
        }
        var result: [OpenCodeTurnItem] = []
        var index = flat.startIndex
        while index < flat.endIndex {
            guard isTool(flat[index]) else {
                result.append(flat[index])
                index += 1
                continue
            }
            var lastTool = index
            var probe = index + 1
            while probe < flat.endIndex, isTool(flat[probe]) || isBetweenTools(flat[probe]) {
                if isTool(flat[probe]) { lastTool = probe }
                probe += 1
            }
            let run = flat[index...lastTool]
            if run.filter(isTool).count >= 2 {
                result.append(.tools(run.compactMap { item -> OpenCodeTurnPart? in
                    guard case .part(let entry) = item else { return nil }
                    return entry
                }))
            } else {
                result.append(contentsOf: run)
            }
            index = lastTool + 1
        }
        return result
    }
}

/// The line that stands for tool calls made back to back:
/// `Read 3 files · Ran 2 commands`.
struct OpenCodeToolRunSummary: Equatable, Sendable {
    let title: String
    let isRunning: Bool
    let hasFailure: Bool

    init(tools: [OpenCodePart]) {
        var counts: [Kind: Int] = [:]
        var order: [Kind] = []
        for tool in tools {
            let kind = Kind(tool: tool.tool)
            if counts[kind] == nil { order.append(kind) }
            counts[kind, default: 0] += 1
        }
        title = order.map { $0.phrase(count: counts[$0] ?? 0) }.joined(separator: " · ")
        let statuses = tools.map { $0.state?.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        isRunning = statuses.contains { $0 == "running" || $0 == "pending" }
        hasFailure = statuses.contains("error")
    }

    var accessibilityLabel: String {
        [title, isRunning ? String(localized: "Running") : nil, hasFailure ? String(localized: "Failed") : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private enum Kind: Hashable {
        case command, read, edit, search, fetch, tasks, other

        init(tool: String?) {
            self = switch tool?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "bash", "shell": .command
            case "read": .read
            case "write", "edit", "multiedit", "apply_patch", "patch": .edit
            case "glob", "grep", "list", "codesearch": .search
            case "webfetch", "websearch": .fetch
            case "todoread", "todowrite": .tasks
            default: .other
            }
        }

        func phrase(count: Int) -> String {
            switch self {
            case .command: count == 1 ? String(localized: "Ran a command") : String(localized: "Ran \(count) commands")
            case .read: count == 1 ? String(localized: "Read a file") : String(localized: "Read \(count) files")
            case .edit: count == 1 ? String(localized: "Edited a file") : String(localized: "Edited \(count) files")
            case .search: count == 1 ? String(localized: "Searched once") : String(localized: "Searched \(count) times")
            case .fetch: count == 1 ? String(localized: "Fetched a page") : String(localized: "Fetched \(count) pages")
            case .tasks: String(localized: "Updated tasks")
            case .other: count == 1 ? String(localized: "Used a tool") : String(localized: "Used \(count) tools")
            }
        }
    }
}
