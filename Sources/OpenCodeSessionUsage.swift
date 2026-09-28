import Foundation

// Context and spend accounting, derived from the transcript the way OpenCode's
// TUI sidebar and web context panel derive it (packages/app/src/components/
// session/session-context-metrics.ts): the context in use is the latest reply's
// full token footprint against its model's window, and spend is the sum of
// every reply's cost. Deriving it from the transcript keeps the meter live
// while a turn streams, on v1 and v2 alike.

/// One assistant reply's accounting, from its step-finish parts and, where the
/// server records it, the message itself.
struct OpenCodeReplyUsage: Equatable, Sendable {
    let cost: Double
    /// Every step added together: what the reply spent.
    let tokens: OpenCodeTokenUsage
    /// The last step's tokens: what the context window held when it ended.
    let context: OpenCodeTokenUsage?

    init?(_ message: OpenCodeMessageEnvelope) {
        guard message.info.role == "assistant" else { return nil }
        let steps = message.parts.filter { $0.type == "step-finish" }
        let stepCost = steps.reduce(0) { $0 + max($1.cost ?? 0, 0) }
        let stepTokens = steps.compactMap(\.tokens).reduce(.zero, +)
        let messageTokens = message.info.tokens.flatMap { $0.contextTokens > 0 ? $0 : nil }
        // v1 also sums the reply's cost onto the message. The two arrive in
        // separate events, so the larger one has caught up with the stream.
        cost = max(stepCost, message.info.cost ?? 0)
        tokens = stepTokens.contextTokens > 0 ? stepTokens : messageTokens ?? .zero
        context = steps.last(where: { ($0.tokens?.contextTokens ?? 0) > 0 })?.tokens ?? messageTokens
        guard cost > 0 || context != nil else { return nil }
    }
}

/// How full the model's context window was after the latest reply.
struct OpenCodeContextUsage: Equatable, Sendable {
    enum Level: Equatable, Sendable {
        case normal, high, critical
    }

    let messageID: String
    let tokens: OpenCodeTokenUsage
    let providerID: String?
    let modelID: String?
    let modelName: String?
    /// The model's window in tokens; nil when the catalog does not list the model.
    let limit: Int?

    var used: Double { tokens.contextTokens }

    /// Share of the window in use. Not capped: a stale catalog limit can be exceeded.
    var fraction: Double? {
        guard let limit, limit > 0 else { return nil }
        return used / Double(limit)
    }

    var percent: Int? { fraction.map(Self.percent) }

    /// OpenCode compacts automatically as a conversation nears the window, so
    /// the meter warns ahead of it rather than at the edge.
    var level: Level {
        guard let fraction else { return .normal }
        if fraction >= 0.9 { return .critical }
        if fraction >= 0.7 { return .high }
        return .normal
    }

    var modelLabel: String? { modelName ?? modelID }

    /// Rounded like OpenCode's panels, but a sliver of use never reads as 0%.
    static func percent(_ fraction: Double) -> Int {
        guard fraction > 0 else { return 0 }
        return max(1, Int((fraction * 100).rounded()))
    }
}

struct OpenCodeSessionUsage: Equatable, Sendable {
    /// The latest reply's window, unless the conversation has been compacted since.
    private(set) var context: OpenCodeContextUsage?
    /// Compacted after the latest reply that reported usage; the next reply
    /// reports the smaller context.
    private(set) var isCompacted = false
    private(set) var cost: Double = 0
    private(set) var tokens: OpenCodeTokenUsage = .zero
    /// Replies that reported any accounting.
    private(set) var replies = 0
    /// Prompts and replies since the last compaction, which is what the model
    /// still reads. A server that reports its active context replaces this.
    private(set) var activeMessages = 0

    var hasUsage: Bool { replies > 0 }

    init() {}

    /// `session` supplies the server's stored totals, which also cover history
    /// older than the loaded transcript page; the larger figure wins, since
    /// the transcript runs ahead of the stored session while a turn streams.
    init(messages: [OpenCodeMessageEnvelope], models: [OpenCodeModelOption], session: OpenCodeSession? = nil) {
        let compaction = Self.lastCompaction(in: messages)
        var latest: (index: Int, message: OpenCodeMessageEnvelope, tokens: OpenCodeTokenUsage)?
        for (index, message) in messages.enumerated() {
            guard let usage = OpenCodeReplyUsage(message) else { continue }
            replies += 1
            cost += usage.cost
            tokens = tokens + usage.tokens
            // A v1 compaction summary reply read the whole old context; the
            // window after compaction is what later replies report.
            if let context = usage.context, message.info.summary != true {
                latest = (index, message, context)
            }
        }
        if let stored = session?.cost, stored > cost { cost = stored }
        if let stored = session?.tokens, stored.total > tokens.total { tokens = stored }
        var active = messages[((compaction?.index).map { $0 + 1 } ?? 0)...].filter(Self.isConversationMessage)
        if let compaction, let tail = compaction.tailStartID,
           let start = messages.firstIndex(where: { $0.info.id == tail }), start < compaction.index {
            active += messages[start..<compaction.index].filter(Self.isConversationMessage)
        }
        activeMessages = active.count
        guard let latest else { return }
        if let compaction, compaction.index > latest.index {
            isCompacted = true
            return
        }
        let info = latest.message.info
        let model = models.first { $0.providerID == info.providerID && $0.modelID == info.modelID }
        context = OpenCodeContextUsage(
            messageID: info.id, tokens: latest.tokens, providerID: info.providerID, modelID: info.modelID,
            modelName: model?.modelName, limit: model?.contextLimit)
    }

    /// The latest compaction that took effect. v2 writes its compaction
    /// message once the summary has ended. v1 marks a user message first, and
    /// OpenCode only honors it once the summary reply after it finishes
    /// without error (filterCompacted); a v1 compaction may also keep a tail
    /// of recent messages in context.
    private static func lastCompaction(in messages: [OpenCodeMessageEnvelope]) -> (index: Int, tailStartID: String?)? {
        for index in messages.indices.reversed() {
            guard let part = messages[index].parts.last(where: { $0.type == "compaction" }) else { continue }
            if messages[index].info.role == "user" {
                let summary = messages[(index + 1)...].first { $0.info.role == "assistant" && $0.info.summary == true }
                guard let summary, summary.info.finish != nil, summary.info.error == nil else { continue }
            }
            return (index, part.tailStartID)
        }
        return nil
    }

    /// Adopts the message count of the server's own view of the active context.
    func reconciled(activeContext messages: [OpenCodeMessageEnvelope]) -> Self {
        var copy = self
        copy.activeMessages = messages.filter(Self.isConversationMessage).count
        return copy
    }

    private static func isConversationMessage(_ message: OpenCodeMessageEnvelope) -> Bool {
        (message.info.role == "user" || message.info.role == "assistant") && message.info.summary != true
    }
}

// MARK: - Presentation

/// The session header's compact gauge. Hidden until a reply reports usage.
struct OpenCodeContextMeterPresentation: Equatable, Sendable {
    let label: String
    /// Ring fill, 0...1.
    let fill: Double
    let level: OpenCodeContextUsage.Level
    let accessibilityValue: String

    init?(usage: OpenCodeSessionUsage, locale: Locale = .current) {
        if let context = usage.context {
            let used = OpenCodeStepSummary.full(context.used, locale: locale)
            if let percent = context.percent, let limit = context.limit {
                label = "\(percent)%"
                fill = min(max(context.fraction ?? 0, 0), 1)
                let total = OpenCodeStepSummary.full(Double(limit), locale: locale)
                accessibilityValue = String(localized: "\(percent) percent used, \(used) of \(total) tokens")
            } else {
                label = OpenCodeStepSummary.compact(context.used, locale: locale)
                fill = 0
                accessibilityValue = String(localized: "\(used) tokens. The model's context size is unknown")
            }
            level = context.level
        } else if usage.isCompacted {
            label = String(localized: "Compacted")
            fill = 0
            level = .normal
            accessibilityValue = String(localized: "Compacted. Usage updates after the next reply")
        } else {
            return nil
        }
    }
}

/// Rows for the usage breakdown in session details.
struct OpenCodeUsageRow: Identifiable, Equatable, Sendable {
    let label: String
    let value: String
    var id: String { label }

    /// Input and output always appear; the rest only when a model used them.
    static func breakdown(_ tokens: OpenCodeTokenUsage, locale: Locale = .current) -> [OpenCodeUsageRow] {
        let rows: [(String, Double, Bool)] = [
            (String(localized: "Input"), tokens.input, true), (String(localized: "Output"), tokens.output, true),
            (String(localized: "Reasoning"), tokens.reasoning, false), (String(localized: "Cache read"), tokens.cacheRead, false),
            (String(localized: "Cache write"), tokens.cacheWrite, false),
        ]
        return rows.filter { $0.2 || $0.1 > 0 }.map {
            OpenCodeUsageRow(label: $0.0, value: OpenCodeStepSummary.full($0.1, locale: locale))
        }
    }
}
