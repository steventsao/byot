import Foundation

/// A shell command the user ran from the composer, as the transcript shows it.
struct OpenCodeShellRun: Identifiable, Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case running
        /// v1 does not report exit codes; v2 does.
        case exited(code: Int?)
        case timedOut
        case stopped
        /// OpenCode refused or never received it.
        case notRun(String)
        /// The connection ended before OpenCode confirmed the result.
        case unconfirmed(String)
    }

    /// The transcript row identity: the message that owns the run, so undo,
    /// fork and scroll anchors keep working.
    let id: String
    let command: String
    let output: String
    let status: Status
    let isTruncated: Bool

    var isRunning: Bool { status == .running }

    var statusLabel: String {
        switch status {
        case .running: String(localized: "Running")
        case .exited(let code?): code == 0 ? String(localized: "Exit 0") : String(localized: "Exit \(code)")
        case .exited(nil): String(localized: "Done")
        case .timedOut: String(localized: "Timed out")
        case .stopped: String(localized: "Stopped")
        case .notRun: String(localized: "Didn’t run")
        case .unconfirmed: String(localized: "Unconfirmed")
        }
    }

    var isFailure: Bool {
        switch status {
        case .exited(let code?): code != 0
        case .timedOut, .notRun, .unconfirmed: true
        case .running, .exited(nil), .stopped: false
        }
    }
}

/// Rows the conversation renders. User shell runs collapse their protocol
/// messages into one terminal card; everything else stays a message.
enum OpenCodeTranscriptRow: Identifiable, Equatable, Sendable {
    case message(OpenCodeMessageEnvelope)
    case shell(OpenCodeShellRun)

    var id: String {
        switch self {
        case .message(let message): message.id
        case .shell(let run): run.id
        }
    }
}

/// A command sent from this device, shown until the server's own record of
/// the run reaches the transcript, or kept when OpenCode did not run it.
struct OpenCodeLocalShell: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case sending
        case failed(String)
        case unconfirmed(String)
    }

    let id: UUID
    let command: String
    /// Messages that existed at send time; the run is new work beyond them.
    let baselineMessageIDs: Set<String>
    var phase: Phase = .sending

    var isSending: Bool { phase == .sending }

    var run: OpenCodeShellRun {
        let status: OpenCodeShellRun.Status = switch phase {
        case .sending: .running
        case .failed(let message): .notRun(message)
        case .unconfirmed(let message): .unconfirmed(message)
        }
        return OpenCodeShellRun(id: "shell-local-\(id.uuidString)", command: command, output: "",
                                status: status, isTruncated: false)
    }
}

enum OpenCodeShellTranscript {
    /// Upstream `SessionPrompt.shellImpl` writes this synthetic user text ahead
    /// of the `bash` tool part that holds the command and its output.
    static let v1MarkerText = "The following tool was executed by the user"
    /// Appended by upstream v1 when the run is aborted.
    static let v1AbortNotice = "<metadata>\nUser aborted the command\n</metadata>"

    static func rows(
        for messages: [OpenCodeMessageEnvelope],
        local: OpenCodeLocalShell? = nil
    ) -> [OpenCodeTranscriptRow] {
        var rows: [OpenCodeTranscriptRow] = []
        rows.reserveCapacity(messages.count + 1)
        var localShown = false
        var index = messages.startIndex
        while index < messages.endIndex {
            let message = messages[index]
            if let run = v2Run(message) {
                rows.append(.shell(run))
                if let local, isRun(run, local: local) { localShown = true }
            } else if isV1Marker(message) {
                let next = messages.index(after: index)
                if next < messages.endIndex, let run = v1Run(user: message, assistant: messages[next]) {
                    rows.append(.shell(run))
                    if let local, isRun(run, local: local) { localShown = true }
                    index = next
                }
                // A marker whose tool part has not arrived renders nothing:
                // it is server bookkeeping, never something the user typed.
            } else {
                rows.append(.message(message))
            }
            index = messages.index(after: index)
        }
        // The server's record replaces the local card once it arrives, even
        // when the request itself failed after the command ran.
        if let local, !localShown { rows.append(.shell(local.run)) }
        return rows
    }

    /// The command behind a v1 shell marker, so undoing that turn restores it.
    static func command(forMarker messageID: String, in messages: [OpenCodeMessageEnvelope]) -> String? {
        guard let index = messages.firstIndex(where: { $0.id == messageID }), isV1Marker(messages[index]) else {
            return nil
        }
        let next = messages.index(after: index)
        guard next < messages.endIndex else { return nil }
        return v1Run(user: messages[index], assistant: messages[next])?.command
    }

    static func isV1Marker(_ message: OpenCodeMessageEnvelope) -> Bool {
        guard message.info.role == "user", !message.parts.isEmpty,
              message.parts.allSatisfy({ $0.type == "text" && $0.synthetic == true }) else { return false }
        return message.parts.compactMap(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            == v1MarkerText
    }

    private static func isRun(_ run: OpenCodeShellRun, local: OpenCodeLocalShell) -> Bool {
        !local.baselineMessageIDs.contains(run.id) && run.command == local.command
    }

    private static func v1Run(user: OpenCodeMessageEnvelope, assistant: OpenCodeMessageEnvelope) -> OpenCodeShellRun? {
        guard assistant.info.role == "assistant",
              !assistant.parts.contains(where: { $0.type == "text" || $0.type == "reasoning" }) else { return nil }
        let tools = assistant.parts.filter { $0.type == "tool" }
        guard tools.count == 1, let tool = tools.first, tool.tool == "bash", let state = tool.state,
              let command = state.input?["command"]?.stringValue else { return nil }
        var output = state.output ?? state.shellMetadata.output ?? ""
        let status: OpenCodeShellRun.Status
        switch state.status {
        case "pending", "running":
            status = .running
        case "error":
            status = .notRun(state.error?.trimmedNonEmpty ?? String(localized: "OpenCode couldn’t run the command."))
        default:
            if let range = output.range(of: v1AbortNotice, options: .backwards) {
                output.removeSubrange(range)
                status = .stopped
            } else {
                status = .exited(code: nil)
            }
        }
        return OpenCodeShellRun(id: user.id, command: command, output: trimmedOutput(output),
                                status: status, isTruncated: false)
    }

    private static func v2Run(_ message: OpenCodeMessageEnvelope) -> OpenCodeShellRun? {
        guard let part = message.parts.first(where: { $0.type == "shell" }), let state = part.state else { return nil }
        let exit = state.shellMetadata.exit.flatMap { Int(exactly: $0) }
        let status: OpenCodeShellRun.Status = switch state.status {
        case "running": .running
        case "timeout": .timedOut
        case "killed": .stopped
        default: .exited(code: exit)
        }
        return OpenCodeShellRun(id: message.id, command: state.input?["command"]?.stringValue ?? "",
                                output: trimmedOutput(state.output ?? ""), status: status,
                                isTruncated: state.shellMetadata.truncated == true)
    }

    /// Keeps leading indentation but drops the blank lines shells often end with.
    private static func trimmedOutput(_ output: String) -> String {
        var result = Substring(output)
        while let last = result.last, last.isWhitespace { result.removeLast() }
        while result.first == "\n" || result.first == "\r" { result.removeFirst() }
        return String(result)
    }
}
