import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner and Dynamic Island for a running OpenCode turn.
struct BYOTTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BYOTTurnActivityAttributes.self) { context in
            BYOTTurnLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activitySystemActionForegroundColor(BYOTBrand.accent)
                .widgetURL(context.attributes.link)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BYOTWidgetBadge(symbol: state.phase.symbol, tint: state.phase.tint, size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BYOTTurnElapsed(state: state)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.sessionTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("\(context.attributes.projectName) · \(context.attributes.serverName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        Text(state.statusLine)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(state.phase.tint)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if state.phase == .needsResponse {
                            Link(destination: context.attributes.link) {
                                Text("Review")
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 32)
                                    .background(.orange.opacity(0.22), in: Capsule())
                            }
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Review in byot")
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: state.phase.symbol)
                    .foregroundStyle(state.phase.tint)
                    .accessibilityLabel(state.headline)
            } compactTrailing: {
                if state.phase == .needsResponse {
                    Text("Review")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                } else {
                    BYOTTurnElapsed(state: state)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(state.phase.tint)
                        .frame(maxWidth: 44)
                }
            } minimal: {
                Image(systemName: state.phase.symbol)
                    .foregroundStyle(state.phase.tint)
                    .accessibilityLabel(state.headline)
            }
            .widgetURL(context.attributes.link)
            .keylineTint(state.phase.tint)
        }
    }
}

/// A live timer while the turn runs, then its final duration.
struct BYOTTurnElapsed: View {
    let state: BYOTTurnActivityAttributes.ContentState

    var body: some View {
        Group {
            if let duration = state.duration {
                Text(Duration.seconds(duration.rounded()), format: .time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
            } else {
                Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
            }
        }
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}

struct BYOTTurnLockScreenView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let attributes: BYOTTurnActivityAttributes
    let state: BYOTTurnActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                BYOTWidgetWordmark(size: 14)
                    .foregroundStyle(BYOTBrand.accent)
                Text(attributes.serverName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                BYOTTurnElapsed(state: state)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            HStack(alignment: .center, spacing: 12) {
                BYOTWidgetBadge(symbol: state.phase.symbol, tint: state.phase.tint,
                                size: dynamicTypeSize.isAccessibilitySize ? 32 : 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attributes.sessionTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(state.statusLine)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(state.phase == .completed ? AnyShapeStyle(.secondary) : AnyShapeStyle(state.phase.tint))
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }
                Spacer(minLength: 0)
            }
            if isStale && state.phase.isActive {
                Label("Open byot for the latest status", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [attributes.sessionTitle, state.statusLine, "\(attributes.projectName) on \(attributes.serverName)"]
        if isStale && state.phase.isActive { parts.append("May be out of date. Open byot for the latest status") }
        return parts.joined(separator: ", ")
    }
}

#Preview("Lock Screen", as: .content, using: BYOTTurnActivityAttributes.preview) {
    BYOTTurnLiveActivity()
} contentStates: {
    BYOTTurnActivityAttributes.ContentState(phase: .working, tool: "Edit file", detail: "LoginView.swift",
                                            startedAt: .now - 95)
    BYOTTurnActivityAttributes.ContentState(phase: .needsResponse, response: .approval, tool: "Shell command",
                                            pendingCount: 1, startedAt: .now - 140)
    BYOTTurnActivityAttributes.ContentState(phase: .completed, startedAt: .now - 300, endedAt: .now)
}

extension BYOTTurnActivityAttributes {
    static var preview: BYOTTurnActivityAttributes {
        BYOTTurnActivityAttributes(serverID: UUID(), serverName: "Studio Mac", sessionID: "preview",
                                   sessionTitle: "Fix sign-in redirect", projectName: "web",
                                   directory: "/Users/me/web", workspace: nil)
    }
}
