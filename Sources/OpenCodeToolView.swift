import SwiftUI

/// One tool call as a quiet monospace row, as in OpenCode's transcript:
/// `› Write file · src/middleware/rateLimit.ts`. Input and output stay behind
/// the disclosure; only unfinished or failed calls show a status.
struct OpenCodeToolView: View {
    let name: String
    let state: OpenCodeToolState

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var presentation: OpenCodeToolPresentation {
        OpenCodeToolPresentation(name: name, state: state)
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: BYOTBrand.Space.sm) {
                if let input = presentation.input {
                    OpenCodeToolDetailBlock(title: "Input", text: input)
                }
                if let output = presentation.output {
                    OpenCodeToolDetailBlock(title: "Output", text: output)
                }
                if let error = presentation.error {
                    OpenCodeToolDetailBlock(title: "Error", text: error, isError: true)
                }
            }
            .padding(10)
            .background(BYOTBrand.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.top, BYOTBrand.Space.xs)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: BYOTBrand.Space.sm) {
                Text([presentation.title, presentation.summary].compactMap { $0 }.joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                statusIndicator
            }
            .font(.cleanMono)
        }
        .disclosureGroupStyle(OpenCodeInlineDisclosureStyle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        [presentation.title, presentation.summary, presentation.statusLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch normalizedStatus {
        case "completed":
            EmptyView()
        case "running":
            BYOTActivityGlyph(phase: .working, size: 14, tint: .secondary)
                .frame(width: 14, height: 14)
        default:
            Text(presentation.statusLabel)
                .foregroundStyle(normalizedStatus == "error" ? Color.red : Color.secondary)
                .fixedSize()
        }
    }

    private var normalizedStatus: String {
        state.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// OpenCode's transcript disclosure: a leading chevron that turns down when
/// open, with the content indented beneath the label.
struct OpenCodeInlineDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        OpenCodeInlineDisclosure(configuration: configuration)
    }
}

private struct OpenCodeInlineDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: BYOTBrand.Motion.quick)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                    configuration.label
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            if configuration.isExpanded {
                configuration.content
                    .padding(.leading, 15)
            }
        }
    }
}
