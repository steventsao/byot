import SwiftUI

/// A command the user ran in shell mode: the command line, its status and the
/// tail of its output, set apart from the agent's own tool calls.
struct OpenCodeShellRunView: View {
    let run: OpenCodeShellRun
    var dismiss: (() -> Void)?

    @State private var showsFullOutput = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: BYOTBrand.Space.sm) {
            header
            Text("\(Text("$").foregroundStyle(.secondary)) \(run.command)")
                .font(.cleanMono.weight(.semibold))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityLabel("Command: \(run.command)")
            if let problem { problemLabel(problem) }
            outputSection
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BYOTBrand.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(BYOTBrand.hairline, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shell command, \(run.statusLabel)")
        .accessibilityAction(named: "Copy command") { UIPasteboard.general.string = run.command }
        .accessibilityIdentifier("opencode-shell-run")
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: BYOTBrand.Space.sm) {
            Label("Shell", systemImage: "terminal")
                .font(.cleanCaptionSemibold)
                .foregroundStyle(.secondary)
            Spacer(minLength: BYOTBrand.Space.sm)
            status
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.cleanCaptionBold)
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .padding(.trailing, -12)
                .accessibilityLabel("Dismiss")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if run.isRunning {
            HStack(spacing: 6) {
                BYOTActivityGlyph(phase: .working, size: 14, tint: .secondary)
                Text(run.statusLabel)
            }
            .font(.cleanCaption)
            .foregroundStyle(.secondary)
        } else {
            Text(run.statusLabel)
                .font(.cleanCaptionSemibold)
                .foregroundStyle(run.isFailure ? Color.red : Color.secondary)
                .accessibilityIdentifier("opencode-shell-status")
        }
    }

    private var problem: String? {
        switch run.status {
        case .notRun(let message), .unconfirmed(let message): message
        case .timedOut: "OpenCode stopped the command when it ran too long."
        case .running, .exited, .stopped: nil
        }
    }

    private func problemLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.cleanCaption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var outputSection: some View {
        let lines = Self.lines(run.output)
        if !lines.isEmpty {
            let shown = Self.visibleOutput(lines, expanded: showsFullOutput)
            VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
                if shown.hiddenLeadingLines > 0 {
                    Text("\(shown.hiddenLeadingLines) earlier line\(shown.hiddenLeadingLines == 1 ? "" : "s") hidden")
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(shown.text)
                        .font(.cleanMono)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .background(BYOTBrand.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                if lines.count > Self.collapsedLineCount {
                    Button(showsFullOutput ? "Show less" : "Show all \(lines.count) lines") {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: BYOTBrand.Motion.quick)) {
                            showsFullOutput.toggle()
                        }
                    }
                    .font(.cleanCaptionBold)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("opencode-shell-output-toggle")
                }
                if run.isTruncated {
                    Text("OpenCode kept only part of this output.")
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Copy output") { UIPasteboard.general.string = run.output }
        } else if !run.isRunning, case .exited = run.status {
            Text("No output")
                .font(.cleanCaption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Output windowing

    /// A finished command's result is usually at its end, so the collapsed
    /// card keeps the last lines, the way a terminal scrolls.
    static let collapsedLineCount = 12
    /// Text views slow down on very long output; Copy Output keeps it all.
    static let expandedLineLimit = 2_000

    static func lines(_ output: String) -> [Substring] {
        output.isEmpty ? [] : output.split(separator: "\n", omittingEmptySubsequences: false)
    }

    static func visibleOutput(_ lines: [Substring], expanded: Bool) -> (text: String, hiddenLeadingLines: Int) {
        let limit = expanded ? expandedLineLimit : collapsedLineCount
        let hidden = max(0, lines.count - limit)
        return (lines.dropFirst(hidden).joined(separator: "\n"), hidden)
    }
}
