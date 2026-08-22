import Foundation

struct OpenCodeToolPresentation: Equatable, Sendable {
    let title: String
    let summary: String?
    let statusLabel: String
    let input: String?
    let output: String?
    let error: String?

    init(name: String, state: OpenCodeToolState) {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        title = Self.displayTitle(for: normalizedName)
        statusLabel = Self.statusLabel(for: state.status)
        input = Self.inputText(from: state)
        output = state.output?.trimmedNonEmpty
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
        case "bash", "shell": "Shell command"
        case "read": "Read file"
        case "write": "Write file"
        case "edit": "Edit file"
        case "glob": "Find files"
        case "grep": "Search files"
        case "list": "List files"
        case "task": "Subtask"
        case "webfetch": "Fetch webpage"
        case "todoread": "Read tasks"
        case "todowrite": "Update tasks"
        case "question": "Question"
        case "lsp": "Code intelligence"
        default:
            name
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
                .capitalized
                .trimmedNonEmpty ?? "Tool"
        }
    }

    private static func statusLabel(for status: String) -> String {
        switch status.lowercased() {
        case "pending": "Queued"
        case "running": "Running"
        case "completed": "Completed"
        case "error": "Failed"
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

    private static func inputText(from state: OpenCodeToolState) -> String? {
        if let input = state.input, !input.isEmpty {
            return input.keys.sorted().map { key in
                "\(key): \(input[key]?.compactDescription ?? "null")"
            }
            .joined(separator: "\n")
        }
        return state.raw?.trimmedNonEmpty
    }
}

private extension String {
    var singleLine: String {
        split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    func caseInsensitiveEquals(_ other: String) -> Bool {
        compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}
