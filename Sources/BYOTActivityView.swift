import SwiftUI

/// Product-level activity semantics. Screens map their domain state here so
/// animation choices, language, color, accessibility, and energy use stay
/// consistent across native agents and OpenCode.
enum BYOTActivityPhase: String, CaseIterable, Identifiable, Sendable {
    case connecting
    case reconnecting
    case loading
    case thinking
    case working
    case waiting
    case queued
    case retrying
    case completed
    case failed

    var id: String { rawValue }

    var defaultTitle: String {
        switch self {
        case .connecting: "Connecting"
        case .reconnecting: "Reconnecting"
        case .loading: "Loading"
        case .thinking: "Thinking"
        case .working: "Working"
        case .waiting: "Waiting"
        case .queued: "Queued"
        case .retrying: "Retrying"
        case .completed: "Complete"
        case .failed: "Failed"
        }
    }

    var animationStyle: BYOTActivityAnimationStyle {
        switch self {
        case .thinking, .working:
            .wave
        case .connecting, .reconnecting, .loading, .retrying:
            .steppedOrbit
        case .waiting, .queued, .completed, .failed:
            .none
        }
    }

    var tone: BYOTActivityTone {
        switch self {
        case .connecting, .loading, .thinking, .working:
            .accent
        case .reconnecting, .retrying:
            .warning
        case .waiting, .queued:
            .muted
        case .completed:
            .success
        case .failed:
            .error
        }
    }

    var staticSystemImage: String {
        switch self {
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .loading: "ellipsis"
        case .thinking: "sparkles"
        case .working: "gearshape.2"
        case .waiting: "hand.raised.fill"
        case .queued: "clock"
        case .retrying: "arrow.clockwise"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    func accessibilityDescription(title: String? = nil, detail: String? = nil) -> String {
        [title ?? defaultTitle, detail]
            .compactMap { value in
                guard let value else { return nil }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: ", ")
    }
}

enum BYOTActivityAnimationStyle: Equatable, Sendable {
    case wave
    case steppedOrbit
    case none
}

enum BYOTActivityTone: Equatable, Sendable {
    case accent
    case muted
    case warning
    case success
    case error

    var color: Color {
        switch self {
        case .accent: BYOTBrand.accent
        case .muted: .secondary
        case .warning: .orange
        case .success: .green
        case .error: .red
        }
    }
}

enum BYOTActivityLayout: Sendable {
    case compact
    case inline
    case blocking
}

/// Opinionated activity presentation used for toolbar status, timeline work,
/// and blocking initial loads. It pauses when the scene is inactive and swaps
/// motion for a static symbol when Reduce Motion is enabled.
struct BYOTActivityView: View {
    let phase: BYOTActivityPhase
    let title: String
    let detail: String?
    let layout: BYOTActivityLayout
    let accessibilityLabel: String
    let tint: Color?

    @ScaledMetric(relativeTo: .caption) private var compactGlyphSize = 14.0
    @ScaledMetric(relativeTo: .caption) private var inlineGlyphSize = 22.0
    @ScaledMetric(relativeTo: .body) private var blockingGlyphSize = 34.0
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(
        _ phase: BYOTActivityPhase,
        title: String? = nil,
        detail: String? = nil,
        layout: BYOTActivityLayout = .inline,
        accessibilityLabel: String? = nil,
        tint: Color? = nil
    ) {
        self.phase = phase
        self.title = title ?? phase.defaultTitle
        self.detail = detail
        self.layout = layout
        self.accessibilityLabel = accessibilityLabel
            ?? phase.accessibilityDescription(title: title, detail: detail)
        self.tint = tint
    }

    var body: some View {
        Group {
            switch layout {
            case .compact:
                compactContent
            case .inline:
                inlineContent
            case .blocking:
                blockingContent
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var compactContent: some View {
        HStack(spacing: 6) {
            BYOTActivityGlyph(
                phase: phase,
                size: min(compactGlyphSize, 28),
                tint: tint
            )
            Text(title)
                .font(.cleanCaptionBold)
                .lineLimit(1)
        }
        .foregroundStyle(tint ?? phase.tone.color)
    }

    private var inlineContent: some View {
        Group {
            let glyphSize = min(inlineGlyphSize, 44)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    BYOTActivityGlyph(phase: phase, size: glyphSize, tint: tint)
                    inlineLabels
                }
            } else {
                HStack(alignment: .top, spacing: 9) {
                    BYOTActivityGlyph(phase: phase, size: glyphSize, tint: tint)
                        .frame(width: glyphSize + 2, height: glyphSize + 2)
                    inlineLabels
                    Spacer(minLength: 8)
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var inlineLabels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.cleanCaptionBold)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(detail)
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var blockingContent: some View {
        VStack(spacing: 10) {
            let glyphSize = min(blockingGlyphSize, 68)
            BYOTActivityGlyph(phase: phase, size: glyphSize, tint: tint)
                .frame(width: glyphSize + 6, height: glyphSize + 6)

            VStack(spacing: 4) {
                Text(title)
                    .font(.cleanBodySemibold)
                    .foregroundStyle(.primary)
                if let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(detail)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 320)
        .padding(24)
    }
}

struct BYOTActivityGlyph: View {
    let phase: BYOTActivityPhase
    var size: CGFloat = 22
    var tint: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if shouldAnimate {
                switch phase.animationStyle {
                case .wave:
                    BYOTActivityWave(size: size, color: resolvedTint)
                case .steppedOrbit:
                    BYOTSteppedOrbit(size: size, color: resolvedTint)
                case .none:
                    staticSymbol
                }
            } else {
                staticSymbol
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var shouldAnimate: Bool {
        !reduceMotion && scenePhase == .active && phase.animationStyle != .none
    }

    private var resolvedTint: Color {
        tint ?? phase.tone.color
    }

    private var staticSymbol: some View {
        Image(systemName: phase.staticSystemImage)
            .font(.system(size: size * 0.62, weight: .semibold))
            .foregroundStyle(resolvedTint)
    }
}

private struct BYOTActivityWave: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        PhaseAnimator([0, 1, 2, 3]) { phase in
            HStack(spacing: size * 0.09) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(color.opacity(phase == index ? 1 : 0.34))
                        .frame(width: max(2, size * 0.16), height: size * 0.72)
                        .scaleEffect(y: phase == index ? 1 : 0.46)
                }
            }
            .frame(width: size, height: size)
        } animation: { _ in
            .easeInOut(duration: BYOTBrand.Motion.activityStep)
        }
    }
}

private struct BYOTSteppedOrbit: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        PhaseAnimator(Array(0..<6)) { phase in
            ZStack {
                ForEach(0..<6, id: \.self) { index in
                    Capsule()
                        .fill(color.opacity(phase == index ? 1 : 0.24))
                        .frame(width: max(2, size * 0.12), height: size * 0.28)
                        .offset(y: -size * 0.31)
                        .rotationEffect(.degrees(Double(index) * 60))
                        .scaleEffect(phase == index ? 1 : 0.76, anchor: .bottom)
                }
            }
            .frame(width: size, height: size)
        } animation: { _ in
            .linear(duration: 0.01)
                .delay(BYOTBrand.Motion.activityStep - 0.01)
        }
    }
}

extension View {
    /// A lightweight skeleton sheen for short-lived initial loads. The effect
    /// is absent under Reduce Motion and while the scene is backgrounded.
    func byotShimmer(active: Bool = true) -> some View {
        modifier(BYOTShimmerModifier(isActive: active))
    }
}

private struct BYOTShimmerModifier: ViewModifier {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            if isActive && !reduceMotion && scenePhase == .active {
                PhaseAnimator([false, true]) { isAtEnd in
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.20), .clear],
                            startPoint: layoutDirection == .leftToRight ? .leading : .trailing,
                            endPoint: layoutDirection == .leftToRight ? .trailing : .leading
                        )
                        .frame(width: max(64, width * 0.48))
                        .offset(x: shimmerOffset(isAtEnd: isAtEnd, width: width))
                    }
                } animation: { isAtEnd in
                    isAtEnd
                        ? .linear(duration: BYOTBrand.Motion.shimmer).delay(0.12)
                        : .linear(duration: 0.01)
                }
                .mask(content)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }

    private func shimmerOffset(isAtEnd: Bool, width: CGFloat) -> CGFloat {
        let start = -max(64, width * 0.55)
        let end = width + max(16, width * 0.08)
        if layoutDirection == .rightToLeft {
            return isAtEnd ? start : end
        }
        return isAtEnd ? end : start
    }
}
