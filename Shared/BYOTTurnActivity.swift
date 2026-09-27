import ActivityKit
import SwiftUI

/// A running OpenCode turn as the Live Activity and Dynamic Island show it.
/// The app starts, updates, and ends it; the widget extension only renders.
/// The payload is visible on the Lock Screen, so it carries labels and file
/// names only, never prompt text, shell commands, or file contents.
struct BYOTTurnActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: BYOTTurnPhase
        /// What the agent is waiting on when `phase` is `.needsResponse`.
        var response: BYOTTurnResponseKind?
        /// A display-ready tool label such as "Edit file".
        var tool: String?
        /// A short target for the tool, such as a file name.
        var detail: String?
        var pendingCount = 0
        var startedAt: Date
        var endedAt: Date?

        var headline: String {
            switch phase {
            case .thinking: "Thinking"
            case .working: tool ?? "Writing a reply"
            case .needsResponse:
                switch response {
                case .approval: "Approval needed"
                case .answer: "Question for you"
                case nil: "Response needed"
                }
            case .retrying: "Retrying"
            case .completed: "Turn complete"
            case .failed: "Turn failed"
            case .stopped: "Turn stopped"
            }
        }

        /// The secondary clause after the headline, if any.
        var subheadline: String? {
            switch phase {
            case .working: tool == nil ? nil : detail
            case .needsResponse:
                if pendingCount > 1 { "\(pendingCount) waiting" } else { tool ?? detail }
            case .retrying: detail
            default: nil
            }
        }

        var statusLine: String {
            [headline, subheadline].compactMap { $0?.trimmedWidgetText }.joined(separator: " · ")
        }

        /// Elapsed time for an ended turn; running turns use a live timer.
        var duration: TimeInterval? {
            endedAt.map { max(0, $0.timeIntervalSince(startedAt)) }
        }
    }

    let serverID: UUID
    let serverName: String
    let sessionID: String
    let sessionTitle: String
    let projectName: String
    let directory: String
    let workspace: String?

    var link: URL {
        BYOTWidgetLink(serverID: serverID, sessionID: sessionID, directory: directory, workspace: workspace).url
    }

    var key: String { BYOTTurnActivityAttributes.key(serverID: serverID, sessionID: sessionID) }

    static func key(serverID: UUID, sessionID: String) -> String {
        "\(serverID.uuidString):\(sessionID)"
    }
}

enum BYOTTurnPhase: String, Codable, Hashable, Sendable, CaseIterable {
    case thinking
    case working
    case needsResponse
    case retrying
    case completed
    case failed
    case stopped

    var isActive: Bool {
        switch self {
        case .thinking, .working, .needsResponse, .retrying: true
        case .completed, .failed, .stopped: false
        }
    }

    var symbol: String {
        switch self {
        case .thinking: "sparkles"
        case .working: "gearshape.2.fill"
        case .needsResponse: "hand.raised.fill"
        case .retrying: "arrow.clockwise"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .thinking, .working: BYOTBrand.accent
        case .needsResponse, .retrying: .orange
        case .completed: .green
        case .failed: .red
        case .stopped: .secondary
        }
    }
}

enum BYOTTurnResponseKind: String, Codable, Hashable, Sendable {
    case approval
    case answer
}

extension String {
    /// Collapses whitespace and bounds length for glanceable widget text.
    var trimmedWidgetText: String? {
        let collapsed = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > 60 ? String(collapsed.prefix(59)) + "…" : collapsed
    }
}
