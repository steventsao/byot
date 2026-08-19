import SwiftUI

struct OpenCodeSessionComposerView: View {
    @ObservedObject var store: OpenCodeSessionStore
    @State private var text = ""
    @State private var isShowingModelPicker = false
    @FocusState private var isFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Button(action: showModelPicker) {
                    Label(
                        store.selectedModel?.modelName ?? "Automatic model",
                        systemImage: "cpu"
                    )
                    .font(.cleanCaptionBold)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 44)
                    .background(
                        BYOTBrand.controlSurface,
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Choose model")
                .accessibilityValue(
                    store.selectedModel.map {
                        "\($0.modelName), \($0.providerName)"
                    } ?? "Automatic"
                )

                if store.canSubmitPrompt == false {
                    Label("Checking session status", systemImage: "arrow.triangle.2.circlepath")
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.willQueueNextPrompt {
                    Label(
                        "Next message will be queued",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Message OpenCode", text: $text, axis: .vertical)
                        .focused($isFocused)
                        .lineLimit(1...8)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(
                            BYOTBrand.controlSurface,
                            in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                        )
                        .submitLabel(.send)
                        .onSubmit(send)

                    if showsStopControl {
                        Button(action: stopTurn) {
                            Image(systemName: "stop.fill")
                                .font(.cleanControlIcon)
                                .foregroundStyle(BYOTBrand.primaryActionInk)
                                .frame(width: 44, height: 44)
                                .background(
                                    BYOTBrand.primaryAction,
                                    in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                                )
                        }
                        .accessibilityLabel("Stop the current turn")
                        .accessibilityInputLabels(["Stop", "Stop turn"])
                        .accessibilityIdentifier("opencode-composer-stop")
                    } else {
                        Button(action: send) {
                            Image(systemName: "arrow.up")
                                .font(.cleanControlIcon)
                            .foregroundStyle(BYOTBrand.primaryActionInk)
                            .frame(width: 44, height: 44)
                            .background(
                                BYOTBrand.primaryAction,
                                in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                            )
                        }
                        .accessibilityLabel(
                            store.willQueueNextPrompt ? "Queue message" : "Send message"
                        )
                        .disabled(
                            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || store.canSubmitPrompt == false
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        }
        .sheet(isPresented: $isShowingModelPicker) {
            OpenCodeModelPickerView(store: store)
        }
    }

    private var showsStopControl: Bool {
        Self.showsStopControl(canStop: store.canStopTurn, text: text)
    }

    // The stop control takes the send slot only while the composer is empty;
    // typed text switches back to send/queue so a steering message is never
    // blocked by the stop affordance.
    static func showsStopControl(canStop: Bool, text: String) -> Bool {
        canStop && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func showModelPicker() {
        isShowingModelPicker = true
    }

    private func stopTurn() {
        Task { await store.stopTurn() }
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
