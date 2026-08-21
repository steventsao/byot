import SwiftUI

struct OpenCodeSessionComposerView: View {
    @ObservedObject var store: OpenCodeSessionStore
    @State private var text = ""
    @State private var isShowingModelPicker = false
    @FocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var canSend: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && store.canSubmitPrompt
    }

    private var composerShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: BYOTBrand.composerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BYOTBrand.Space.sm) {
            if store.canSubmitPrompt == false {
                statusHint(
                    title: "Checking session status",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            } else if store.willQueueNextPrompt {
                statusHint(
                    title: "Next message will be queued",
                    systemImage: "clock.arrow.circlepath"
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Message OpenCode", text: $text, axis: .vertical)
                    .font(.cleanBody)
                    .foregroundStyle(BYOTBrand.overlayBase.opacity(0.92))
                    .tint(BYOTBrand.accent)
                    .focused($isFocused)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityLabel("Message OpenCode")

                HStack(alignment: .center, spacing: 8) {
                    modelChip

                    Spacer(minLength: 0)

                    sendButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(BYOTBrand.composerWash, in: composerShape)
            .overlay {
                composerShape
                    .strokeBorder(
                        isFocused ? BYOTBrand.composerBorderFocus : BYOTBrand.composerBorder,
                        lineWidth: 1
                    )
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: BYOTBrand.Motion.quick),
                value: isFocused
            )
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(BYOTBrand.canvas)
        .sheet(isPresented: $isShowingModelPicker) {
            OpenCodeModelPickerView(store: store)
        }
    }

    private var modelChip: some View {
        Button(action: showModelPicker) {
            Label(
                store.selectedModel?.modelName ?? "Automatic model",
                systemImage: "cpu"
            )
            .font(.cleanCaptionSemibold)
            .foregroundStyle(BYOTBrand.overlayBase.opacity(0.55))
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                BYOTBrand.composerChip,
                in: RoundedRectangle(cornerRadius: BYOTBrand.composerChipRadius, style: .continuous)
            )
            .frame(minHeight: 32, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Choose model")
        .accessibilityValue(
            store.selectedModel.map {
                "\($0.modelName), \($0.providerName)"
            } ?? "Automatic"
        )
    }

    private var sendButton: some View {
        Button(action: send) {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    canSend
                        ? BYOTBrand.primaryActionInk
                        : BYOTBrand.overlayBase.opacity(0.28)
                )
                .frame(width: 28, height: 28)
                .background(
                    canSend
                        ? BYOTBrand.primaryAction
                        : BYOTBrand.overlayBase.opacity(0.08),
                    in: Circle()
                )
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.agentPressFeedback)
        .accessibilityLabel(
            store.willQueueNextPrompt ? "Queue message" : "Send message"
        )
        .disabled(canSend == false)
        .animation(
            reduceMotion ? nil : .easeOut(duration: BYOTBrand.Motion.quick),
            value: canSend
        )
    }

    private func statusHint(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.cleanCaption)
            .foregroundStyle(BYOTBrand.overlayBase.opacity(0.55))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    private func showModelPicker() {
        isShowingModelPicker = true
    }

    private func send() {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, store.canSubmitPrompt else { return }
        text = ""
        if store.send(prompt) == false, text.isEmpty {
            text = prompt
        }
    }
}
