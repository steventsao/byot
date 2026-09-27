import Foundation

/// Code shown in a tool's disclosure with syntax color: a shell command, the
/// content a write produced, an edit as a diff, or the file a read returned.
struct OpenCodeToolCode: Equatable, Sendable {
    let title: String
    let text: String
    let language: BYOTSyntaxLanguage?
    /// Draws a line-number gutter starting here when set.
    var firstLineNumber: Int? = nil
    var footnote: String? = nil
}

struct OpenCodeToolPresentation: Equatable, Sendable {
    let title: String
    let summary: String?
    let statusLabel: String
    /// Remaining input fields, one `key: value` per line, after any field
    /// promoted to `inputCode`.
    let input: String?
    let inputCode: OpenCodeToolCode?
    let output: String?
    /// The output as code when the tool returned a file (the `read` tool).
    let outputCode: OpenCodeToolCode?
    let error: String?

    init(name: String, state: OpenCodeToolState) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        title = Self.displayTitle(for: normalizedName)
        statusLabel = Self.statusLabel(for: state.status)
        let promoted = Self.inputCode(toolName: normalizedName, input: state.input)
        inputCode = promoted?.code
        input = Self.inputText(from: state, excluding: promoted?.keys ?? [])
        output = state.output?.trimmedNonEmpty
        outputCode = Self.outputCode(toolName: normalizedName, input: state.input, output: output)
        error = state.error?.trimmedNonEmpty
        summary = Self.summary(
            toolName: normalizedName,
            displayTitle: title,
            stateTitle: state.title,
            input: state.input,
            raw: state.raw
        )
    }

    private static func displayTitle(for name: String) -> String {
        switch name.lowercased() {
        case "bash", "shell": String(localized: "Shell command")
        case "read": String(localized: "Read file")
        case "write": String(localized: "Write file")
        case "edit": String(localized: "Edit file")
        case "glob": String(localized: "Find files")
        case "grep": String(localized: "Search files")
        case "list": String(localized: "List files")
        case "task": String(localized: "Subtask")
        case "webfetch": String(localized: "Fetch webpage")
        case "todoread": String(localized: "Read tasks")
        case "todowrite": String(localized: "Update tasks")
        case "question": String(localized: "Question")
        case "lsp": String(localized: "Code intelligence")
        default:
            name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
                .trimmedNonEmpty ?? String(localized: "Tool")
        }
    }

    private static func statusLabel(for status: String) -> String {
        switch status.lowercased() {
        case "pending": String(localized: "Queued")
        case "running": String(localized: "Running")
        case "completed": String(localized: "Completed")
        case "error": String(localized: "Failed")
        default: status.capitalized
        }
    }

    private static func summary(
        toolName: String,
        displayTitle: String,
        stateTitle: String?,
        input: [String: OpenCodeJSONValue]?,
        raw: String?
    ) -> String? {
        if let preferredInput = preferredSummary(toolName: toolName, input: input) {
            return preferredInput.singleLine
        }

        if let stateTitle = stateTitle?.trimmedNonEmpty,
           !stateTitle.caseInsensitiveEquals(toolName),
           !stateTitle.caseInsensitiveEquals(displayTitle) {
            return stateTitle.singleLine
        }

        return raw?.trimmedNonEmpty?.singleLine
    }

    private static func preferredSummary(
        toolName: String,
        input: [String: OpenCodeJSONValue]?
    ) -> String? {
        guard let input else { return nil }

        let preferredKeys: [String]
        switch toolName.lowercased() {
        case "bash", "shell":
            preferredKeys = ["command"]
        case "read", "write", "edit", "list":
            preferredKeys = ["path", "filePath", "file"]
        case "glob":
            preferredKeys = ["pattern", "path"]
        case "grep":
            preferredKeys = ["pattern", "query", "path"]
        case "webfetch":
            preferredKeys = ["url"]
        case "task":
            preferredKeys = ["description", "prompt"]
        default:
            preferredKeys = []
        }

        return preferredKeys.lazy.compactMap { input[$0]?.stringValue?.trimmedNonEmpty }.first
    }

    private static func inputText(from state: OpenCodeToolState, excluding promoted: Set<String>) -> String? {
        if let input = state.input, !input.isEmpty {
            let keys = input.keys.filter { !promoted.contains($0) }.sorted()
            guard !keys.isEmpty else { return nil }
            return keys.map { key in
                "\(key): \(input[key]?.compactDescription ?? "null")"
            }
            .joined(separator: "\n")
        }
        return state.raw?.trimmedNonEmpty
    }

    private static let pathKeys = ["filePath", "path", "file"]

    private static func filePath(in input: [String: OpenCodeJSONValue]?) -> String? {
        guard let input else { return nil }
        return pathKeys.lazy.compactMap { input[$0]?.stringValue?.trimmedNonEmpty }.first
    }

    /// Promotes the input field that is really code out of the `key: value`
    /// list so it can render with syntax color.
    private static func inputCode(
        toolName: String,
        input: [String: OpenCodeJSONValue]?
    ) -> (code: OpenCodeToolCode, keys: Set<String>)? {
        guard let input else { return nil }
        switch toolName.lowercased() {
        case "bash", "shell":
            guard let command = input["command"]?.stringValue?.trimmedNonEmpty else { return nil }
            return (OpenCodeToolCode(title: String(localized: "Command"), text: command, language: .shell), ["command"])
        case "write":
            guard let content = input["content"]?.stringValue, !content.isEmpty else { return nil }
            let code = OpenCodeToolCode(
                title: String(localized: "Content"),
                text: content,
                language: BYOTSyntaxLanguage(path: filePath(in: input)),
                firstLineNumber: 1
            )
            return (code, ["content"])
        case "edit":
            guard let old = input["oldString"]?.stringValue, let new = input["newString"]?.stringValue,
                  !(old.isEmpty && new.isEmpty) else { return nil }
            let replacesAll = input["replaceAll"] == .bool(true)
            let code = OpenCodeToolCode(
                title: String(localized: "Change"),
                text: editDiff(old: old, new: new),
                language: .diff,
                footnote: replacesAll ? String(localized: "Replaces every occurrence") : nil
            )
            return (code, ["oldString", "newString", "replaceAll"])
        case "apply_patch", "patch":
            guard let patch = (input["patchText"] ?? input["patch"])?.stringValue?.trimmedNonEmpty else {
                return nil
            }
            return (OpenCodeToolCode(title: String(localized: "Patch"), text: patch, language: .diff), ["patchText", "patch"])
        default:
            return nil
        }
    }

    private static func editDiff(old: String, new: String) -> String {
        func lines(_ text: String, prefix: String) -> [String] {
            guard !text.isEmpty else { return [] }
            return text.components(separatedBy: "\n").map { prefix + $0 }
        }
        return (lines(old, prefix: "-") + lines(new, prefix: "+")).joined(separator: "\n")
    }

    private static func outputCode(
        toolName: String,
        input: [String: OpenCodeJSONValue]?,
        output: String?
    ) -> OpenCodeToolCode? {
        guard toolName.lowercased() == "read", let output,
              let file = OpenCodeReadToolOutput(output) else { return nil }
        return OpenCodeToolCode(
            title: String(localized: "Output"),
            text: file.text,
            language: BYOTSyntaxLanguage(path: filePath(in: input) ?? file.path),
            firstLineNumber: file.firstLineNumber,
            footnote: file.footnote
        )
    }
}

/// The file body inside a `read` tool result. OpenCode wraps it as
/// `<path>…</path><type>file</type><content>` with `12: text` lines; older
/// servers used `<file>` and `00012| text`. Anything else is left as output.
struct OpenCodeReadToolOutput: Equatable, Sendable {
    let path: String?
    let firstLineNumber: Int
    let text: String
    let footnote: String?

    init?(_ output: String) {
        let lines = output.components(separatedBy: "\n")
        var index = 0
        var path: String?
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if Self.numberedLine(lines[index]) != nil { break }
            if line == "<type>directory</type>" { return nil }
            if line.hasPrefix("<path>"), line.hasSuffix("</path>") {
                path = String(line.dropFirst("<path>".count).dropLast("</path>".count))
            } else if !line.isEmpty, !line.hasPrefix("<") {
                return nil
            }
            index += 1
        }
        guard index < lines.count, let first = Self.numberedLine(lines[index]) else { return nil }

        var body: [String] = []
        var expected = first.number
        while index < lines.count, let line = Self.numberedLine(lines[index]), line.number == expected {
            body.append(line.text)
            expected += 1
            index += 1
        }
        // The numbered run must end cleanly (a blank line, the closing tag, or
        // the end); anything else is an unfamiliar shape, so the whole output
        // stays visible as plain text rather than losing lines.
        if index < lines.count {
            let next = lines[index].trimmingCharacters(in: .whitespaces)
            guard next.isEmpty || next.hasPrefix("<") else { return nil }
        }

        var footnote: String?
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            if line.isEmpty { continue }
            if line.hasPrefix("("), line.hasSuffix(")") { footnote = String(line.dropFirst().dropLast()) }
            break
        }

        self.path = path?.trimmedNonEmpty
        firstLineNumber = first.number
        text = body.joined(separator: "\n")
        self.footnote = footnote
    }

    /// `12: text`, `12:` (an empty line), or legacy `00012| text`.
    private static func numberedLine(_ line: String) -> (number: Int, text: String)? {
        let digits = line.prefix(while: \.isASCIIDigitCharacter)
        guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
        let rest = line[digits.endIndex...]
        for separator in [": ", "| "] where rest.hasPrefix(separator) {
            return (number, String(rest.dropFirst(separator.count)))
        }
        if rest == ":" || rest == "|" { return (number, "") }
        return nil
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}

private extension String {
    var singleLine: String {
        split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    func caseInsensitiveEquals(_ other: String) -> Bool {
        compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
