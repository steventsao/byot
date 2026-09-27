import SwiftUI
import WidgetKit

/// Home Screen and Lock Screen widget: which sessions need you and how many
/// are running, as of the app's last refresh.
struct BYOTSessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: BYOTWidgetKind.sessions, provider: BYOTSessionsProvider()) { entry in
            BYOTSessionsFamilyView(entry: entry)
                .containerBackground(for: .widget) { BYOTBrand.canvas }
        }
        .configurationDisplayName("Sessions")
        .description("See which OpenCode sessions need you and how many are running.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

struct BYOTSessionsEntry: TimelineEntry {
    let date: Date
    let snapshot: BYOTWidgetSnapshot

    var isStale: Bool { snapshot.isStale(at: date) }
}

struct BYOTSessionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> BYOTSessionsEntry {
        BYOTSessionsEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (BYOTSessionsEntry) -> Void) {
        let snapshot = BYOTWidgetSnapshotStore().load()
        // The widget gallery shows sample sessions until the app has shared some.
        completion(BYOTSessionsEntry(date: .now, snapshot: context.isPreview && snapshot.isEmpty ? .preview : snapshot))
    }

    /// The app reloads this timeline whenever it shares new state. The one
    /// scheduled entry flips the widget to "may be out of date" if it doesn't.
    func getTimeline(in context: Context, completion: @escaping (Timeline<BYOTSessionsEntry>) -> Void) {
        let now = Date.now
        let snapshot = BYOTWidgetSnapshotStore().load()
        var entries = [BYOTSessionsEntry(date: now, snapshot: snapshot)]
        if let refreshedAt = snapshot.refreshedAt, refreshedAt + BYOTWidgetSnapshot.freshness > now {
            entries.append(BYOTSessionsEntry(date: refreshedAt + BYOTWidgetSnapshot.freshness + 1, snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

private struct BYOTSessionsFamilyView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BYOTSessionsEntry

    var body: some View { BYOTSessionsWidgetView(entry: entry, family: family) }
}

struct BYOTSessionsWidgetView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let entry: BYOTSessionsEntry
    let family: WidgetFamily

    private var snapshot: BYOTWidgetSnapshot { entry.snapshot }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .systemSmall: small
            case .systemLarge: list(limit: dynamicTypeSize.isAccessibilitySize ? 3 : 6)
            default: list(limit: dynamicTypeSize.isAccessibilitySize ? 1 : 2)
            }
        }
        .widgetURL(snapshot.primaryLink)
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            BYOTWidgetWordmark()
            Spacer(minLength: 0)
            if snapshot.isEmpty {
                Text("Open byot to see your sessions here.")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
            } else if snapshot.attentionCount > 0 {
                headlineCount(snapshot.attentionCount, tint: .orange)
                Text(snapshot.attentionCount == 1 ? "session needs you" : "sessions need you")
                    .font(.footnote.weight(.semibold))
            } else if snapshot.activeCount > 0 {
                headlineCount(snapshot.activeCount, tint: BYOTBrand.accent)
                Text("running")
                    .font(.footnote.weight(.semibold))
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(BYOTBrand.accent)
                    .widgetAccentable()
                    .accessibilityHidden(true)
                Text("All quiet")
                    .font(.footnote.weight(.semibold))
            }
            Spacer(minLength: 0)
            if !snapshot.isEmpty { freshness }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
    }

    private func headlineCount(_ value: Int, tint: Color) -> some View {
        Text(value, format: .number)
            .font(.system(.largeTitle, design: .rounded, weight: .bold))
            .foregroundStyle(tint)
            .widgetAccentable()
            .contentTransition(.numericText())
    }

    private func list(limit: Int) -> some View {
        let sessions = snapshot.sessions
        let shown = Array(sessions.prefix(limit))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                BYOTWidgetWordmark()
                Spacer(minLength: 4)
                if !snapshot.isEmpty {
                    Text(entry.isStale ? String(localized: "May be out of date") : summary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.isStale ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            if shown.isEmpty {
                Spacer(minLength: 0)
                emptyState
                Spacer(minLength: 0)
            } else {
                ForEach(shown) { session in
                    Link(destination: session.link) { row(session) }
                }
                if sessions.count > shown.count {
                    Text("+\(sessions.count - shown.count) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if family == .systemLarge { freshness }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ session: BYOTWidgetSession) -> some View {
        HStack(spacing: 10) {
            BYOTWidgetBadge(symbol: session.state.symbol, tint: session.state.tint)
                .widgetAccentable()
            VStack(alignment: .leading, spacing: 1) {
                // Links tint their labels in the widget's accent; rows read as text.
                Text(session.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .privacySensitive()
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(snapshot.servers.count > 1 ? "\(session.projectName) · \(session.serverName)" : session.projectName)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(session.state.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(session.state.tint)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.accessibilityLabel)
        .accessibilityAddTraits(.isLink)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(snapshot.isEmpty ? "No sessions yet" : "All quiet",
                  systemImage: snapshot.isEmpty ? "bubble.left.and.bubble.right" : "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(snapshot.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(BYOTBrand.accent))
            Text(snapshot.isEmpty
                 ? "Open byot and connect a server to follow its sessions here."
                 : "Running sessions and anything that needs you will show up here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var freshness: some View {
        if entry.isStale {
            Text("Open byot to refresh")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
        } else if let refreshedAt = snapshot.refreshedAt {
            Text("Updated \(refreshedAt, style: .time)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Lock Screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Image(systemName: snapshot.attentionCount > 0 ? "hand.raised.fill" : "gearshape.2.fill")
                    .font(.caption.weight(.semibold))
                Text(snapshot.attentionCount > 0 ? snapshot.attentionCount : snapshot.activeCount, format: .number)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .minimumScaleFactor(0.5)
            }
            .widgetAccentable()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("byot, \(summary)")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(BYOTBrand.wordmark)
                .font(.headline)
                .widgetAccentable()
            if snapshot.attentionCount > 0 {
                Label(needsYou, systemImage: "hand.raised.fill")
                    .font(.body.weight(.semibold))
            }
            Text(snapshot.activeCount > 0 ? "\(snapshot.activeCount) active" : "Nothing running")
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var inline: some View {
        Label(summary, systemImage: snapshot.attentionCount > 0 ? "hand.raised.fill" : "gearshape.2.fill")
    }

    // MARK: Copy

    private var needsYou: String {
        snapshot.attentionCount == 1 ? String(localized: "1 needs you") : String(localized: "\(snapshot.attentionCount) need you")
    }

    private var summary: String {
        switch (snapshot.attentionCount, snapshot.activeCount) {
        case (0, 0): String(localized: "Nothing running")
        case (0, let active): String(localized: "\(active) active")
        case (_, 0): needsYou
        case (_, let active): String(localized: "\(needsYou) · \(active) active")
        }
    }
}

extension BYOTWidgetSnapshot {
    /// Sample sessions for the widget gallery and placeholders.
    static var preview: BYOTWidgetSnapshot {
        let server = UUID()
        let now = Date.now
        func session(_ id: String, _ title: String, _ project: String, _ state: BYOTWidgetSessionState,
                     minutesAgo: Double) -> BYOTWidgetSession {
            BYOTWidgetSession(serverID: server, serverName: "Studio Mac", sessionID: id, title: title,
                              projectName: project, directory: "/Users/me/\(project)", workspace: nil,
                              state: state, updatedAt: now - minutesAgo * 60)
        }
        var snapshot = BYOTWidgetSnapshot()
        snapshot.replace(BYOTWidgetServer(serverID: server, name: "Studio Mac", refreshedAt: now, sessions: [
            session("preview-1", "Fix sign-in redirect", "web", .needsResponse, minutesAgo: 1),
            session("preview-2", "Add dark mode tokens", "design-system", .running, minutesAgo: 3),
            session("preview-3", "Speed up CI cache", "infra", .running, minutesAgo: 8),
        ]))
        return snapshot
    }
}

#Preview(as: .systemMedium) {
    BYOTSessionsWidget()
} timeline: {
    BYOTSessionsEntry(date: .now, snapshot: .preview)
    BYOTSessionsEntry(date: .now, snapshot: BYOTWidgetSnapshot())
}
