import SwiftUI

/// What a transcript needs to link task calls to their subagent sessions:
/// the parent's view of each child and a way to open one.
struct OpenCodeSubagentLinks: Sendable {
    let activity: [String: OpenCodeSubagentActivity]
    let children: [OpenCodeSession]
    let openingSessionID: String?
    /// Whether the server can look up a session this screen hasn't listed.
    let canOpenUnlisted: Bool
    let open: @MainActor @Sendable (_ sessionID: String) -> Void

    func sessionID(for task: OpenCodeSubagentTask) -> String? {
        task.sessionID ?? children.first(where: task.isChild)?.id
    }

    /// A card links only to a session it can actually open; otherwise it
    /// stays a plain card rather than a button that fails.
    func canOpen(_ sessionID: String) -> Bool {
        canOpenUnlisted || children.contains { $0.id == sessionID }
    }
}

private struct OpenCodeSubagentLinksKey: EnvironmentKey {
    static let defaultValue: OpenCodeSubagentLinks? = nil
}

extension EnvironmentValues {
    var openCodeSubagents: OpenCodeSubagentLinks? {
        get { self[OpenCodeSubagentLinksKey.self] }
        set { self[OpenCodeSubagentLinksKey.self] = newValue }
    }
}

// MARK: - Task card

/// A `task` call as a card that opens the subagent's own session, with the
/// child's live status while it works and its answer once it finishes.
struct OpenCodeSubagentTaskCard: View {
    let task: OpenCodeSubagentTask
    @Environment(\.openCodeSubagents) private var links
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let sessionID = links?.sessionID(for: task)
        let linkedID = sessionID.flatMap { id in links?.canOpen(id) == true ? id : nil }
        let presentation = OpenCodeSubagentCardPresentation(
            task: task, activity: sessionID.flatMap { links?.activity[$0] }, isLinked: linkedID != nil)
        VStack(alignment: .leading, spacing: BYOTBrand.Space.sm) {
            if let sessionID = linkedID, let links {
                Button { links.open(sessionID) } label: {
                    card(presentation, isOpening: links.openingSessionID == sessionID)
                }
                .buttonStyle(OpenCodeSubagentCardButtonStyle())
                .disabled(links.openingSessionID != nil)
                .accessibilityHint("Opens the subagent session")
                .accessibilityIdentifier("subagent-task-\(task.id)")
            } else {
                card(presentation, isOpening: false)
                    .accessibilityIdentifier("subagent-task-\(task.id)")
            }
            if let error = task.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.cleanCaption)
                    .foregroundStyle(.red)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 4)
            }
            // A background call's output is launch boilerplate; its answer
            // arrives later as a message in this conversation.
            if let result = task.result, task.status == "completed", !task.isBackground {
                DisclosureGroup {
                    AgentMarkdownText(text: result)
                        .padding(.top, BYOTBrand.Space.xs)
                        .textSelection(.enabled)
                } label: {
                    Text("Result")
                        .font(.cleanMono)
                        .foregroundStyle(.secondary)
                }
                .disclosureGroupStyle(OpenCodeInlineDisclosureStyle())
                .accessibilityIdentifier("subagent-task-result-\(task.id)")
            }
        }
    }

    private func card(_ presentation: OpenCodeSubagentCardPresentation, isOpening: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: BYOTBrand.controlRadius, style: .continuous)
        return HStack(alignment: .top, spacing: 12) {
            OpenCodeSubagentStatusGlyph(phase: presentation.phase)
            VStack(alignment: .leading, spacing: 3) {
                (Text(presentation.agentLabel).foregroundStyle(.secondary)
                    + Text(" · ").foregroundStyle(.tertiary)
                    + Text(presentation.statusLabel).foregroundStyle(presentation.phase.tint))
                    .font(.cleanCaptionBold)
                Text(presentation.title)
                    .font(.cleanBodySemibold)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = presentation.detail {
                    Text(detail)
                        .font(.cleanMono)
                        .foregroundStyle(.secondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isOpening {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else if presentation.isLinked {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(12)
        .frame(minHeight: 44)
        .background(BYOTBrand.surface, in: shape)
        .overlay {
            shape.stroke(presentation.phase == .needsResponse ? Color.orange.opacity(0.7) : BYOTBrand.hairline,
                         lineWidth: 1)
        }
        .contentShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

private struct OpenCodeSubagentCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct OpenCodeSubagentStatusGlyph: View {
    let phase: OpenCodeSubagentCardPresentation.Phase
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 20

    var body: some View {
        let size = min(size, 36)
        Group {
            switch phase {
            case .running:
                BYOTActivityGlyph(phase: .working, size: size * 0.8, tint: .secondary)
            case .retrying:
                BYOTActivityGlyph(phase: .retrying, size: size * 0.8)
            case .starting:
                Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            case .needsResponse:
                Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .background:
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(BYOTBrand.accent)
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .font(.body.weight(.semibold))
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension OpenCodeSubagentCardPresentation.Phase {
    var tint: Color {
        switch self {
        case .needsResponse: .orange
        case .failed: .red
        case .completed: BYOTBrand.accent
        default: .secondary
        }
    }
}

// MARK: - Subagent session chrome

/// The trail back to the conversation that started this subagent.
struct OpenCodeSubagentBreadcrumb: View {
    let parentTitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.turn.left.up")
                    .accessibilityHidden(true)
                Text(parentTitle ?? String(localized: "Main session"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.cleanCaptionBold)
            .foregroundStyle(BYOTBrand.accent)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to main session")
        .accessibilityValue(parentTitle ?? "")
        .accessibilityIdentifier("subagent-parent")
    }
}

/// Replaces the composer in a subagent session: OpenCode does not accept
/// prompts there, so the bar names the subagent and steps between siblings.
struct OpenCodeSubagentBar: View {
    let agentLabel: String
    let family: OpenCodeSubagentFamily
    let canStop: Bool
    let isStopping: Bool
    let stop: () -> Void
    let open: (OpenCodeSession) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: BYOTBrand.Space.sm) {
                    identity
                    Spacer(minLength: BYOTBrand.Space.sm)
                    controls.layoutPriority(1)
                }
                VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
                    identity
                    controls
                }
            }
            // At accessibility sizes the note would crowd out the transcript;
            // the composer's absence and the breadcrumb already say as much.
            if !dynamicTypeSize.isAccessibilitySize {
                Text("Subagents take their instructions from the main session.")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: BYOTBrand.conversationMaxWidth, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(BYOTBrand.canvas)
        .overlay(alignment: .top) {
            Rectangle().fill(BYOTBrand.hairline).frame(height: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("subagent-bar")
    }

    @ViewBuilder
    private var identity: some View {
        let position = family.count > 1 ? family.position.map { String(localized: "\($0) of \(family.count)") } : nil
        if dynamicTypeSize.isAccessibilitySize {
            (Text("\(agentLabel) subagent").font(.cleanBodySemibold)
                + Text(position.map { " · " + $0 } ?? "").font(.cleanCaption).foregroundStyle(.secondary))
                .lineLimit(3)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(agentLabel) subagent")
                    .font(.cleanBodySemibold)
                if let position {
                    Text(position)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var controls: some View {
        HStack(spacing: BYOTBrand.Space.xs) {
            if canStop || isStopping {
                Button(action: stop) {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.cleanCaptionBold)
                        // Never wrap mid-word beside the agent name; the bar stacks instead.
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(isStopping)
                .accessibilityLabel("Stop subagent")
                .accessibilityIdentifier("subagent-stop")
            }
            if family.count > 1 {
                stepButton(to: family.previous, symbol: "chevron.left", title: String(localized: "Previous subagent"), id: "subagent-previous")
                stepButton(to: family.next, symbol: "chevron.right", title: String(localized: "Next subagent"), id: "subagent-next")
            }
        }
    }

    private func stepButton(to session: OpenCodeSession?, symbol: String, title: String, id: String) -> some View {
        Button {
            if let session { open(session) }
        } label: {
            Image(systemName: symbol)
                .font(.cleanControlIcon)
                .frame(width: 44, height: 44)
                .background(BYOTBrand.controlSurface, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(session == nil ? Color.secondary.opacity(0.5) : BYOTBrand.chromeTint)
        .disabled(session == nil)
        .accessibilityLabel(title)
        .accessibilityValue(session.map(OpenCodeSubagentTitle.displayTitle) ?? String(localized: "None"))
        .accessibilityIdentifier(id)
    }
}

// MARK: - Session details

/// One child in the session details' Subagents section.
struct OpenCodeSubagentSessionRow: View {
    let session: OpenCodeSession
    let activity: OpenCodeSubagentActivity?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(OpenCodeSubagentTitle.displayTitle(of: session))
                    .font(.cleanBody)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Text([OpenCodeSubagentTitle.agentLabel(OpenCodeSubagentTitle.agent(of: session)), statusLabel]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.cleanCaption)
                    .foregroundStyle(activity?.needsResponse == true ? Color.orange : Color.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var statusLabel: String? {
        if activity?.needsResponse == true { return String(localized: "Needs your response") }
        switch activity?.status {
        case .busy?: return String(localized: "Running")
        case .retry?: return String(localized: "Retrying")
        case .idle?: return String(localized: "Idle")
        case nil: return nil
        }
    }
}
