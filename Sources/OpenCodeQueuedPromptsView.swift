import SwiftUI

struct OpenCodeQueuedPromptsView: View {
    let prompts: [OpenCodeQueuedPrompt]
    let canRetryFirst: Bool
    let retry: (UUID) -> Void
    let remove: (UUID) -> Void

    @State private var commandToRetry: OpenCodeQueuedPrompt?

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
        .confirmationDialog("Run this command again?", isPresented: Binding(
            get: { commandToRetry != nil }, set: { if !$0 { commandToRetry = nil } }
        ), titleVisibility: .visible) {
            Button("Run again") {
                if let prompt = commandToRetry { retry(prompt.id) }
                commandToRetry = nil
            }
            Button("Cancel", role: .cancel) { commandToRetry = nil }
        } message: {
            Text("The server may already have run this command. Review the session first to avoid repeating its effects.")
        }
    }

    private func promptContent(index: Int, prompt: OpenCodeQueuedPrompt) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                if !prompt.text.isEmpty {
                    Text(prompt.text)
                        .font(.cleanBody)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 8 : 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !prompt.attachments.isEmpty {
                    Label(attachmentLabel(for: prompt), systemImage: "paperclip")
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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
            Button(prompt.command?.kind == .command ? "Run again" : "Retry", systemImage: "arrow.clockwise") {
                retryOrConfirm(prompt)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityHint("Attempts to send this queued message again")
        } else {
            Button(prompt.command?.kind == .command ? "Run again" : "Retry", systemImage: "arrow.clockwise") {
                retryOrConfirm(prompt)
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
            : "Queued \(index + 1)"
        return [state, prompt.agent, prompt.model?.modelName, prompt.variant].compactMap { $0 }.joined(separator: " · ")
    }

    private func retryOrConfirm(_ prompt: OpenCodeQueuedPrompt) {
        if prompt.command?.kind == .command { commandToRetry = prompt }
        else { retry(prompt.id) }
    }

    private func attachmentLabel(for prompt: OpenCodeQueuedPrompt) -> String {
        if prompt.attachments.count == 1 {
            return prompt.attachments[0].filename
        }
        return "\(prompt.attachments.count) attachments"
    }
}
