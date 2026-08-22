import SwiftUI

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
            .padding(.top, BYOTBrand.Space.sm)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                statusIndicator

                VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
                                toolTitle
                                statusLabel
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: BYOTBrand.Space.sm) {
                                toolTitle
                                    .lineLimit(1)
                                Spacer(minLength: BYOTBrand.Space.sm)
                                statusLabel
                                    .lineLimit(1)
                            }
                        }
                    }

                    if let summary = presentation.summary {
                        Text(summary)
                            .font(.cleanCaption.monospaced())
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 4 : 2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .tint(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(BYOTBrand.surface, in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                .stroke(BYOTBrand.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var toolTitle: some View {
        Text(presentation.title)
            .font(.cleanCaptionBold)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusLabel: some View {
        Text(presentation.statusLabel)
            .font(.cleanCaption)
            .foregroundStyle(statusColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilityLabel: String {
        [presentation.title, presentation.summary, presentation.statusLabel]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if normalizedStatus == "running" {
            BYOTActivityGlyph(phase: .working, size: 20, tint: statusColor)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: statusIcon)
                .font(.cleanCaptionBold)
                .foregroundStyle(statusColor)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }

    private var normalizedStatus: String {
        state.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var statusIcon: String {
        switch normalizedStatus {
        case "completed": "checkmark.circle.fill"
        case "error": "xmark.circle.fill"
        case "running": "gearshape.2.fill"
        default: "clock.fill"
        }
    }

    private var statusColor: Color {
        switch normalizedStatus {
        case "completed": BYOTBrand.accent
        case "error": .red
        case "running": .orange
        default: .secondary
        }
    }
}
