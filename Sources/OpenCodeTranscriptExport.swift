import Foundation

/// What a Markdown transcript includes beyond the conversation itself. The
/// TUI's `/export` dialog offers the same three switches.
struct OpenCodeTranscriptExportOptions: Equatable, Sendable {
    /// Reasoning parts, under "_Thinking:_".
    var thinking = false
    /// Each tool call's JSON input and its output or error.
    var toolDetails = false
    /// Agent, model and duration beside each assistant heading.
    var assistantMetadata = true

    private static let prefix = "byot.transcriptExport."

    /// The choices a viewer last made, so Copy transcript repeats them.
    init(defaults: UserDefaults) {
        thinking = defaults.object(forKey: Self.prefix + "thinking") as? Bool ?? false
        toolDetails = defaults.object(forKey: Self.prefix + "toolDetails") as? Bool ?? false
        assistantMetadata = defaults.object(forKey: Self.prefix + "assistantMetadata") as? Bool ?? true
    }

    init(thinking: Bool = false, toolDetails: Bool = false, assistantMetadata: Bool = true) {
        self.thinking = thinking
        self.toolDetails = toolDetails
        self.assistantMetadata = assistantMetadata
    }

    func save(to defaults: UserDefaults) {
        defaults.set(thinking, forKey: Self.prefix + "thinking")
        defaults.set(toolDetails, forKey: Self.prefix + "toolDetails")
        defaults.set(assistantMetadata, forKey: Self.prefix + "assistantMetadata")
    }
}

/// A conversation as Markdown, written the way OpenCode's TUI `/export` and
/// `/copy` write it (packages/tui/src/util/transcript.ts): a title block,
/// then each turn under a heading, separated by rules. Context OpenCode added
/// for the model (synthetic and ignored text) stays out, as it does there.
struct OpenCodeTranscriptExport: Sendable {
    let session: OpenCodeSession
    let messages: [OpenCodeMessageEnvelope]
    /// Display names by `provider/model`, from the server's model catalog.
    var modelNames: [String: String] = [:]
    var locale: Locale = .current
    var timeZone: TimeZone = .current

    /// Messages that put something into the transcript with these options.
    func messageCount(_ options: OpenCodeTranscriptExportOptions) -> Int {
        messages.filter { !section(for: $0, options: options).isEmpty }.count
    }

    func markdown(_ options: OpenCodeTranscriptExportOptions) -> String {
        var transcript = "# \(Self.singleLine(session.title) ?? "Untitled session")\n\n"
        transcript += "**Session ID:** \(session.id)\n"
        transcript += "**Created:** \(date(session.time.created))\n"
        transcript += "**Updated:** \(date(session.time.updated))\n\n"
        transcript += "---\n\n"
        for message in messages {
            let body = section(for: message, options: options)
            guard !body.isEmpty else { continue }
            // A v1 compaction request is a user message holding only the
            // marker; it reads as an event, not as something the user said.
            let isMarker = message.parts.allSatisfy { $0.type.lowercased() == "compaction" }
            transcript += (isMarker ? "" : heading(for: message.info, options: options)) + body + "---\n\n"
        }
        return transcript
    }

    /// The shared file's name: the conversation's title, else the TUI's
    /// `session-<id>.md`.
    var filename: String {
        let slug = session.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stem = String(slug.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (stem.isEmpty ? "session-\(session.id.prefix(8))" : stem) + ".md"
    }

    private func heading(for info: OpenCodeMessageInfo, options: OpenCodeTranscriptExportOptions) -> String {
        switch info.role {
        case "user": return "## User\n\n"
        case "assistant":
            guard options.assistantMetadata else { return "## Assistant\n\n" }
            var details: [String] = []
            if let agent = info.agent?.trimmedNonEmpty { details.append(Self.titlecase(agent)) }
            if let modelID = info.modelID?.trimmedNonEmpty {
                details.append(info.providerID.flatMap { modelNames["\($0)/\(modelID)"] } ?? modelID)
            }
            if let completed = info.time.completed, completed > info.time.created {
                details.append(String(format: "%.1fs", (completed - info.time.created) / 1_000))
            }
            return details.isEmpty ? "## Assistant\n\n" : "## Assistant (\(details.joined(separator: " · ")))\n\n"
        default:
            // v2 records shell runs and conversation markers as system messages.
            return "## \(Self.titlecase(info.role))\n\n"
        }
    }

    private func section(for message: OpenCodeMessageEnvelope, options: OpenCodeTranscriptExportOptions) -> String {
        guard !message.isSyntheticContext else { return "" }
        var body = message.parts.map { part(for: $0, options: options) }.joined()
        if message.info.role == "assistant", let error = message.info.error {
            body += "**Error:** \(error.displayMessage)\n\n"
        }
        return body
    }

    private func part(for part: OpenCodePart, options: OpenCodeTranscriptExportOptions) -> String {
        switch part.type.lowercased() {
        case "text" where part.isAuthoredText:
            guard let text = part.text?.trimmingTrailingWhitespace, !text.isEmpty else { return "" }
            return "\(text)\n\n"
        case "reasoning":
            guard options.thinking, let text = part.text?.trimmingTrailingWhitespace, !text.isEmpty else { return "" }
            return "_Thinking:_\n\n\(text)\n\n"
        case "tool":
            guard let tool = part.tool?.trimmedNonEmpty else { return "" }
            var result = "**Tool: \(tool)**\n"
            if options.toolDetails, let state = part.state {
                if let input = state.input, !input.isEmpty, let json = Self.json(.object(input)) {
                    result += "\n**Input:**\n" + Self.fenced(json, language: "json")
                }
                if state.status == "completed", let output = state.output, !output.isEmpty {
                    result += "\n**Output:**\n" + Self.fenced(output)
                }
                if state.status == "error", let error = state.error, !error.isEmpty {
                    result += "\n**Error:**\n" + Self.fenced(error)
                }
            }
            return result + "\n"
        case "file":
            guard let name = part.filename?.trimmedNonEmpty ?? part.url.flatMap({ URL(string: $0)?.lastPathComponent.trimmedNonEmpty })
            else { return "" }
            return "_Attached: \(name)_\n\n"
        case "compaction":
            return "_Conversation compacted._\n\n"
        default:
            return ""
        }
    }

    private func date(_ milliseconds: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: milliseconds / 1_000))
    }

    /// A code fence longer than any run of backticks inside, so tool output
    /// that itself holds Markdown cannot close the block early.
    static func fenced(_ text: String, language: String = "") -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return "\(fence)\(language)\n\(body)\n\(fence)\n"
    }

    static func json(_ value: OpenCodeJSONValue) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Upper-cases the first letter of each word, as the TUI's `titlecase`.
    static func titlecase(_ text: String) -> String {
        var result = ""
        var atWordStart = true
        for character in text {
            let isWord = character.isLetter || character.isNumber || character == "_"
            result += atWordStart && isWord ? character.uppercased() : String(character)
            atWordStart = !isWord
        }
        return result
    }

    private static func singleLine(_ text: String) -> String? {
        text.components(separatedBy: .newlines).joined(separator: " ").trimmedNonEmpty
    }
}

private extension String {
    var trimmingTrailingWhitespace: String {
        var text = self
        while text.last?.isWhitespace == true { text.removeLast() }
        return text
    }
}

extension OpenCodeSessionStore {
    /// The visible conversation, ready to write out. History staged for undo
    /// stays out, as it does on screen.
    var transcriptExport: OpenCodeTranscriptExport {
        let names = providerModels.flatMap(\.models).map { ($0.qualifiedID, $0.modelName) }
        return OpenCodeTranscriptExport(session: session, messages: messages,
                                        modelNames: Dictionary(names) { first, _ in first })
    }

    var transcriptUnavailableReason: String? {
        messages.isEmpty ? "Nothing to export yet." : nil
    }
}
