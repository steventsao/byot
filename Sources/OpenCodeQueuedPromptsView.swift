import SwiftUI

struct OpenCodeQueuedPromptsView: View {
    let prompts: [OpenCodeQueuedPrompt]
    let canRetryFirst: Bool
    let retry: (UUID) -> Void
    let remove: (UUID) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(Array(prompts.enumerated()), id: \.element.id) { index, prompt in
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: BYOTBrand.Space.sm) {
                            promptContent(index: index, prompt: prompt)

                            HStack(spacing: BYOTBrand.Space.sm) {
                                Spacer(minLength: 0)
                                if index == 0, canRetryFirst {
                                    retryButton(for: prompt, showsTitle: true)
                                }
                                removeButton(for: prompt, showsTitle: true)
                            }
                        }
                    } else {
                        HStack(alignment: .top, spacing: 10) {
                            promptContent(index: index, prompt: prompt)

                            if index == 0, canRetryFirst {
                                retryButton(for: prompt, showsTitle: false)
                            }
                            removeButton(for: prompt, showsTitle: false)
                        }
                    }
                }
                .padding(12)
                .background(
                    BYOTBrand.elevatedSurface,
                    in: RoundedRectangle(cornerRadius: BYOTBrand.panelRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: BYOTBrand.panelRadius)
                        .stroke(BYOTBrand.hairline, lineWidth: 1)
                }
                .accessibilityElement(children: .contain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func promptContent(index: Int, prompt: OpenCodeQueuedPrompt) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(prompt.text)
                    .font(.cleanBody)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 8 : 4)
                    .fixedSize(horizontal: false, vertical: true)
                Text(queueLabel(for: index, prompt: prompt))
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func retryButton(for prompt: OpenCodeQueuedPrompt, showsTitle: Bool) -> some View {
        if showsTitle {
            Button("Retry", systemImage: "arrow.clockwise") {
                retry(prompt.id)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint("Attempts to send this queued message again")
        } else {
            Button("Retry", systemImage: "arrow.clockwise") {
                retry(prompt.id)
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint("Attempts to send this queued message again")
        }
    }

    @ViewBuilder
    private func removeButton(for prompt: OpenCodeQueuedPrompt, showsTitle: Bool) -> some View {
        if showsTitle {
            Button("Remove", systemImage: "xmark.circle") {
                remove(prompt.id)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Remove queued message")
        } else {
            Button("Remove", systemImage: "xmark.circle") {
                remove(prompt.id)
            }
            .labelStyle(.iconOnly)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Remove queued message")
        }
    }

    private func queueLabel(for index: Int, prompt: OpenCodeQueuedPrompt) -> String {
        let state = index == 0 && canRetryFirst
            ? "Waiting to retry"
            : "Queued \(index + 1) · sends after the current turn"
        guard let model = prompt.model else { return state }
        return "\(state) · \(model.modelName)"
    }
}
