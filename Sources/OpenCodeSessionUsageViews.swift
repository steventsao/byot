import SwiftUI

/// Lets transcript rows look up a reply's model window by `provider/model`.
private struct OpenCodeContextLimitsKey: EnvironmentKey {
    static let defaultValue: [String: Int] = [:]
}

extension EnvironmentValues {
    var openCodeContextLimits: [String: Int] {
        get { self[OpenCodeContextLimitsKey.self] }
        set { self[OpenCodeContextLimitsKey.self] = newValue }
    }
}

extension OpenCodeContextUsage.Level {
    /// Only the ring carries the warning color; labels stay in readable ink.
    var tint: Color {
        switch self {
        case .normal: BYOTBrand.accent
        case .high: .orange
        case .critical: .red
        }
    }
}

/// A thin progress ring for the share of the context window in use.
struct OpenCodeContextRing: View {
    let fill: Double
    let level: OpenCodeContextUsage.Level
    var lineWidth: CGFloat = 2.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(BYOTBrand.strongHairline, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(level.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(lineWidth / 2)
        .animation(reduceMotion ? nil : .easeOut(duration: BYOTBrand.Motion.quick), value: fill)
        .accessibilityHidden(true)
    }
}

/// The session header's gauge: how full the model's context is. Opens the
/// usage details.
struct OpenCodeContextMeter: View {
    let presentation: OpenCodeContextMeterPresentation
    let action: () -> Void
    @ScaledMetric(relativeTo: .footnote) private var ringSize: CGFloat = 13

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                OpenCodeContextRing(fill: presentation.fill, level: presentation.level, lineWidth: max(2, ringSize * 0.18))
                    .frame(width: ringSize, height: ringSize)
                Text(presentation.label)
                    .font(.cleanCaptionBold)
                    .monospacedDigit()
                    .foregroundStyle(presentation.level == .critical ? .primary : .secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(BYOTBrand.surface, in: Capsule())
            // The capsule stays compact in the header; the tap target reaches 44pt.
            .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context")
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint("Shows token use and cost for this session")
        .accessibilityIdentifier("session-context-meter")
    }
}

/// Context and spend sections, shared by the usage sheet and session details.
struct OpenCodeSessionUsageSections: View {
    let usage: OpenCodeSessionUsage
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title) private var ringSize: CGFloat = 40

    var body: some View {
        if usage.context != nil || usage.isCompacted {
            Section {
                contextSummary
                if let model = usage.context?.modelLabel {
                    LabeledContent("Model", value: model)
                }
                LabeledContent("Messages in context") {
                    Text(usage.activeMessages.formatted()).monospacedDigit()
                }
                .accessibilityIdentifier("usage-active-messages")
            } header: {
                Text("Context")
            } footer: {
                Text(contextFooter)
            }
        }
        Section {
            if usage.hasUsage {
                LabeledContent("Cost") {
                    Text(OpenCodeStepSummary.cost(usage.cost, locale: .current)).monospacedDigit()
                }
                .accessibilityIdentifier("usage-total-cost")
                LabeledContent("Tokens") {
                    Text(OpenCodeStepSummary.full(usage.tokens.total, locale: .current)).monospacedDigit()
                }
                ForEach(OpenCodeUsageRow.breakdown(usage.tokens)) { row in
                    LabeledContent {
                        Text(row.value).monospacedDigit()
                    } label: {
                        Text(row.label).padding(.leading, BYOTBrand.Space.md)
                    }
                    .foregroundStyle(.secondary)
                }
                LabeledContent("Replies") {
                    Text(usage.replies.formatted()).monospacedDigit()
                }
            } else {
                Text("Token counts and cost appear after the first reply.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Session totals")
        } footer: {
            if usage.hasUsage {
                Text("Totals for this conversation's replies. Subagent sessions keep their own totals.")
            }
        }
    }

    private var contextSummary: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
        let meter = OpenCodeContextMeterPresentation(usage: usage)
        return layout {
            OpenCodeContextRing(fill: meter?.fill ?? 0, level: meter?.level ?? .normal, lineWidth: 5)
                .frame(width: ringSize, height: ringSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(contextHeadline)
                    .font(.cleanBodySemibold)
                if let detail = contextDetail {
                    Text(detail)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage-context-summary")
    }

    private var contextHeadline: String {
        guard let context = usage.context else { return String(localized: "Context compacted") }
        if let percent = context.percent { return String(localized: "\(percent)% of context used") }
        return String(localized: "\(OpenCodeStepSummary.full(context.used, locale: .current)) tokens in context")
    }

    private var contextDetail: String? {
        guard let context = usage.context else { return String(localized: "Usage updates after the next reply.") }
        guard let limit = context.limit else { return nil }
        let used = OpenCodeStepSummary.full(context.used, locale: .current)
        let total = OpenCodeStepSummary.full(Double(limit), locale: .current)
        return String(localized: "\(used) of \(total) tokens")
    }

    private var contextFooter: String {
        guard let context = usage.context else {
            return String(localized: "Earlier messages were summarized to free the context window.")
        }
        if context.limit == nil {
            return String(localized: "The server's model catalog doesn't list a context size for this model.")
        }
        if context.level != .normal {
            return String(localized: "OpenCode compacts the conversation automatically when the context is nearly full. You can also compact it yourself from the actions menu.")
        }
        return String(localized: "The latest reply's input, output, reasoning and cached tokens, measured against the model's context window.")
    }
}

/// The meter's destination: context and spend for this session.
struct OpenCodeSessionUsageView: View {
    @ObservedObject var store: OpenCodeSessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            List {
                OpenCodeSessionUsageSections(usage: store.usage)
            }
            .navigationTitle("Context and usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // Re-read the server's active context when a new reply lands.
            .task(id: store.usage.context?.messageID) { await store.refreshContextWindow() }
        }
        // Half height cannot show a single row at accessibility sizes.
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }
}
