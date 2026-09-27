import Foundation

/// One command typed in the composer's shell mode. It runs on the server in the
/// session's directory and is never sent to the model as a prompt.
struct OpenCodeShellCommand: Equatable, Sendable {
    let command: String
    /// v1 records the user turn under a primary agent; the route requires one.
    let agent: String?
    let model: OpenCodeModelOption?
}

/// Composer-side rules shared by the `!` shortcut, the mode toggle and submit.
enum OpenCodeShellInput {
    /// OpenCode's composers enter shell mode when `!` is typed into an empty
    /// prompt, and the `!` itself is consumed. Pasted or restored text that
    /// merely starts with `!` stays an ordinary message.
    static func entersShellMode(from old: String, to new: String) -> Bool {
        old.isEmpty && new == "!"
    }

    /// iOS keyboards substitute typographic quotes and dashes by default, which
    /// a shell reads as different characters. Undo those substitutions so
    /// `echo "hi"` and `ls --all` run as typed on a desktop keyboard.
    static func normalized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}": result.append("\"")
            case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}": result.append("'")
            case "\u{2014}": result.append("--")
            default: result.append(character)
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Exact per-protocol shell operations, verified against OpenCode:
/// - v1 `POST /session/{sessionID}/shell` with `{agent, model?, command}`. It
///   answers after the command exits; output streams as a `bash` tool part.
/// - v2 `POST /api/session/{sessionID}/shell` with `{command}`, only when the
///   server's schema lists it. Output arrives as `session.shell.*` events.
struct OpenCodeShellDispatch: Sendable {
    static let v2Path = "/api/session/{sessionID}/shell"
    /// A shell run holds the v1 request open until the command exits.
    static let requestTimeout: TimeInterval = 600

    let context: OpenCodeFeatureContext

    static func isSupported(_ context: OpenCodeFeatureContext) -> Bool {
        if context.serverProtocol == .v1 { return true }
        return context.supports(v2Path, method: "post")
            && context.composerSchemaProperties(v2Path)["command"] != nil
    }

    func body(_ shell: OpenCodeShellCommand) throws -> OpenCodeJSONValue {
        guard Self.isSupported(context) else { throw OpenCodeShellError.unsupported }
        guard !shell.command.isEmpty else { throw OpenCodeShellError.emptyCommand }
        var body: [String: OpenCodeJSONValue] = ["command": .string(shell.command)]
        if context.serverProtocol == .v1 {
            guard let agent = shell.agent?.trimmedNonEmpty else { throw OpenCodeShellError.agentRequired }
            body["agent"] = .string(agent)
            if let model = shell.model {
                body["model"] = .object(["providerID": .string(model.providerID), "modelID": .string(model.modelID)])
            }
        }
        // v2 accepts an optional `evt_` admission id. BYOT never retries a shell
        // run automatically, so it lets the server assign one rather than
        // fabricating an id outside OpenCode's ascending format.
        return .object(body)
    }

    func run(sessionID: String, directory: String, workspace: String?, shell: OpenCodeShellCommand) async throws {
        let data = try JSONEncoder().encode(try body(shell))
        let isV2 = context.serverProtocol == .v2
        var request = try context.transport.makeRequest(
            path: (isV2 ? ["api"] : []) + ["session", sessionID, "shell"],
            query: isV2 ? [] : context.composerQuery(directory: directory, workspace: workspace),
            method: "POST", body: data)
        request.timeoutInterval = Self.requestTimeout
        // The transcript renders the run from events and the next refresh;
        // v1's echoed message body is not needed here.
        try await context.transport.performExpectingEmptyResponse(request)
    }
}

enum OpenCodeShellError: LocalizedError, Equatable {
    case unsupported
    case emptyCommand
    case agentRequired

    var errorDescription: String? {
        switch self {
        case .unsupported: "This OpenCode server doesn’t support shell commands."
        case .emptyCommand: "Enter a command to run."
        case .agentRequired: "OpenCode hasn’t listed its agents yet. Reload commands, then run this again."
        }
    }

    /// True when OpenCode certainly did not run the command: it was never
    /// sent, or the server rejected it. Anything else may have executed.
    static func certainlyDidNotRun(_ error: Error) -> Bool {
        if error is OpenCodeShellError { return true }
        if case .httpStatus(let status, _) = error as? OpenCodeConnectionError { return (400..<500).contains(status) }
        return false
    }

    /// Explains a failed run without hiding whether it may still have executed.
    static func failureMessage(for error: Error) -> String {
        if let shellError = error as? OpenCodeShellError { return shellError.localizedDescription }
        if case .httpStatus(409, _) = error as? OpenCodeConnectionError {
            return "OpenCode was busy with another turn. Run the command again when the session is idle."
        }
        if certainlyDidNotRun(error) { return error.localizedDescription }
        return "The connection ended before OpenCode confirmed the result, so the command may have run. "
            + "Check the conversation before running it again. " + error.localizedDescription
    }
}

/// Stores reach shell runs through this seam so tests can script outcomes.
protocol OpenCodeShellServicing: Sendable {
    func runShell(sessionID: String, directory: String, workspace: String?, shell: OpenCodeShellCommand) async throws
}

extension OpenCodeClient: OpenCodeShellServicing {
    func runShell(sessionID: String, directory: String, workspace: String?, shell: OpenCodeShellCommand) async throws {
        let context = try await featureContext()
        try await OpenCodeShellDispatch(context: context).run(sessionID: sessionID, directory: directory, workspace: workspace, shell: shell)
    }
}
