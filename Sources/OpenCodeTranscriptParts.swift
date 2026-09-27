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
}

// MARK: - Compaction

struct OpenCodeCompactionPresentation: Equatable, Sendable {
    let title: String
    let detail: String?
    let summary: String?
    let accessibilityLabel: String

    init(part: OpenCodePart) {
        title = "Context compacted"
        switch (part.auto, part.overflow) {
        case (true?, true?):
            detail = "Automatic · context limit reached"
            accessibilityLabel = "Context compacted automatically because the context limit was reached"
        case (true?, _):
            detail = "Automatic"
            accessibilityLabel = "Context compacted automatically"
        case (false?, _):
            detail = "Requested"
            accessibilityLabel = "Context compacted on request"
        default:
            detail = nil
            accessibilityLabel = "Context compacted"
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
        title = "Added context"
        self.text = text.count > Self.characterLimit ? String(text.prefix(Self.characterLimit)) + "\n…" : text
        let lines = text.split(whereSeparator: \.isNewline).count
        accessibilityLabel = "Context OpenCode added for the model, \(lines) line\(lines == 1 ? "" : "s")"
    }
}

// MARK: - Retry

struct OpenCodeRetryPresentation: Equatable, Sendable {
    let title: String
    let detail: String?
    let accessibilityLabel: String

    init(part: OpenCodePart) {
        let attempt = part.attempt.map { " · attempt \($0)" } ?? ""
        title = "Retried after an error" + attempt
        let status = part.error?.data?["statusCode"]?.numberValue.map { "HTTP \(Int($0))" }
        let message = part.error.map(\.displayMessage)?.trimmedNonEmpty
        detail = [status, message].compactMap { $0 }.joined(separator: " · ").trimmedNonEmpty
        accessibilityLabel = [
            part.attempt.map { "Retried after an error, attempt \($0)" } ?? "Retried after an error",
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
            accessibilityLabel = "Sent to the \(name) agent"
        case "agent":
            symbol = "person.crop.circle"
            title = "Switched to \(name)"
            accessibilityLabel = "Switched to the \(name) agent"
        case "model":
            symbol = "cpu"
            title = "Switched to \(name)"
            accessibilityLabel = "Switched to model \(name)"
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
        self.init(kind: "Step", tokens: part.tokens, cost: part.cost, reason: part.reason,
                  contextLimit: contextLimit, locale: locale)
    }

    /// A reply whose server recorded accounting on the message but sent no
    /// step-finish parts still gets a footer, built from the message.
    init?(reply message: OpenCodeMessageEnvelope, contextLimit: Int? = nil, locale: Locale = .current) {
        guard message.info.role == "assistant",
              !message.parts.contains(where: { $0.type == "step-finish" && Self(part: $0) != nil })
        else { return nil }
        self.init(kind: "Reply", tokens: message.info.tokens, cost: message.info.cost, reason: message.info.finish,
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
            headline.append("\(Self.compact(tokens.total, locale: locale)) tokens")
            spoken.append("\(Self.full(tokens.total, locale: locale)) tokens")
            let rows: [(String, Double)] = [
                ("Input", tokens.input), ("Output", tokens.output), ("Reasoning", tokens.reasoning),
                ("Cache read", tokens.cacheRead), ("Cache write", tokens.cacheWrite),
            ]
            for (label, value) in rows where value > 0 || label == "Input" || label == "Output" {
                details.append(Detail(label: label, value: Self.full(value, locale: locale)))
            }
            if let contextLimit, contextLimit > 0, tokens.contextTokens > 0 {
                let percent = OpenCodeContextUsage.percent(tokens.contextTokens / Double(contextLimit))
                details.append(Detail(label: "Context",
                    value: "\(percent)% of \(Self.compact(Double(contextLimit), locale: locale))"))
            }
        }
        if cost > 0 {
            let formatted = Self.cost(cost, locale: locale)
            headline.append(formatted)
            spoken.append("cost \(formatted)")
            details.append(Detail(label: "Cost", value: formatted))
        }
        outcome = Self.outcome(reason)
        if let outcome { details.append(Detail(label: "Finish", value: outcome)) }
        title = ([kind] + headline).joined(separator: " · ")
        self.details = details
        accessibilityLabel = (["\(kind) used " + spoken.joined(separator: ", ")] + [outcome].compactMap { $0 })
            .joined(separator: ". ")
    }

    static func outcome(_ reason: String?) -> String? {
        guard let reason = reason?.trimmedNonEmpty?.lowercased() else { return nil }
        switch reason {
        case "stop", "tool-calls", "tool_calls", "unknown", "other": return nil
        case "length", "max-tokens", "max_tokens": return "Stopped at the output limit"
        case "content-filter", "content_filter": return "Stopped by the content filter"
        case "error": return "Ended with an error"
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
        title = "Checkpoint · \(short)"
        accessibilityLabel = "Workspace checkpoint \(short)"
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
        return "Image"
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
