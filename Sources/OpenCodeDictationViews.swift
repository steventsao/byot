import SwiftUI

/// The composer's microphone. It reads as on while dictation runs, and a
/// second tap stops listening and keeps the words.
struct OpenCodeDictationButton: View {
    @ObservedObject var dictation: OpenCodeDictationController
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Group {
                if dictation.phase == .preparing {
                    BYOTActivityGlyph(phase: .loading, size: 18, tint: .primary)
                } else {
                    Image(systemName: dictation.isActive ? "mic.fill" : "mic")
                        .font(.cleanControlIcon)
                        .symbolEffect(.pulse, options: .repeating,
                                      isActive: dictation.phase == .listening && !reduceMotion)
                }
            }
            .frame(width: 44, height: 44)
            .background(dictation.isActive ? BYOTBrand.selectedSurface : .clear, in: Circle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(dictation.phase == .finishing)
        .accessibilityLabel(dictation.isActive ? "Stop dictation" : "Dictate")
        .accessibilityHint(dictation.isActive
            ? "Keeps the words so far in your message."
            : "Speak to add words to your message.")
        .accessibilityIdentifier("opencode-dictation-toggle")
    }
}

/// Shown above the message while dictation runs: a live input level, where the
/// audio is transcribed, and Done.
struct OpenCodeDictationStatusView: View {
    @ObservedObject var dictation: OpenCodeDictationController
    let onDone: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Large text wraps instead of truncating; Done gets its own row.
                VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
                    HStack(spacing: BYOTBrand.Space.sm) {
                        OpenCodeDictationLevelView(meter: dictation.meter)
                            .accessibilityHidden(true)
                        caption
                    }
                    doneButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(alignment: .center, spacing: BYOTBrand.Space.sm) {
                    OpenCodeDictationLevelView(meter: dictation.meter)
                        .accessibilityHidden(true)
                    caption
                    Spacer(minLength: 0)
                    doneButton
                }
            }
        }
        .padding(.leading, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("opencode-dictation-status")
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.cleanCaptionBold)
            Text(dictation.isOnDevice ? "Stays on this device" : "Transcribed by Apple")
                .font(.cleanCaption)
                .foregroundStyle(.secondary)
                .opacity(dictation.phase == .preparing ? 0 : 1)
                // Before the engine starts, where audio goes isn't known yet.
                .accessibilityHidden(dictation.phase == .preparing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch dictation.phase {
        case .preparing: String(localized: "Starting…")
        case .finishing: String(localized: "Finishing…")
        case .idle, .listening: String(localized: "Listening…")
        }
    }

    private var doneButton: some View {
        Button("Done", action: onDone)
            .font(.cleanCaptionBold)
            .foregroundStyle(.primary)
            .padding(.horizontal, BYOTBrand.Space.sm)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(dictation.phase != .listening)
            .accessibilityLabel("Done dictating")
            .accessibilityIdentifier("opencode-dictation-done")
    }
}

/// Four bars that follow the microphone level. With Reduce Motion they hold
/// still at a resting shape instead of bouncing.
private struct OpenCodeDictationLevelView: View {
    @ObservedObject var meter: OpenCodeDictationMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var height: CGFloat = 20

    private static let weights: [CGFloat] = [0.55, 1, 0.8, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.primary)
                    .frame(width: 3.5, height: barHeight(Self.weights[index]))
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: meter.level)
    }

    private func barHeight(_ weight: CGFloat) -> CGFloat {
        let level = reduceMotion ? 0.35 : CGFloat(meter.level)
        return max(4, height * (0.3 + 0.7 * level) * weight)
    }
}
