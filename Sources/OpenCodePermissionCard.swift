import SwiftUI

struct OpenCodePermissionCard: View {
    let request: OpenCodePermissionRequest
    let isWorking: Bool
    let respond: (OpenCodePermissionReply) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Permission requested", systemImage: "hand.raised.fill")
                .font(.cleanBodySemibold)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 5) {
                Text(request.permission)
                    .font(.cleanBodySemibold)
                ForEach(request.patterns, id: \.self) { pattern in
                    Text(pattern)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if !request.always.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.rememberedScopeTitle)
                        .font(.cleanCaptionBold)
                        .foregroundStyle(.secondary)
                    ForEach(request.always, id: \.self) { pattern in
                        Text(pattern)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Text(request.rememberedScopeFooter)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("This request can’t be remembered.")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    rejectButton()
                    Spacer()
                    allowOnceButton()
                    if !request.always.isEmpty {
                        alwaysAllowButton()
                    }
                }
                // Stacked, the choices fill the card so none reads as a stray pill.
                VStack(spacing: 10) {
                    allowOnceButton(fillsWidth: true)
                    if !request.always.isEmpty {
                        alwaysAllowButton(fillsWidth: true)
                    }
                    rejectButton(fillsWidth: true)
                }
                .controlSize(.large)
            }
            .disabled(isWorking)
        }
        .padding(16)
        .background(BYOTBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: BYOTBrand.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: BYOTBrand.panelRadius)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func rejectButton(fillsWidth: Bool = false) -> some View {
        Button(role: .destructive) {
            Task { await respond(.reject) }
        } label: {
            Label("Reject", systemImage: "xmark").frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        // The app-wide tint otherwise paints the destructive choice blue.
        .tint(.red)
        .frame(minHeight: 44)
    }

    private func allowOnceButton(fillsWidth: Bool = false) -> some View {
        Button {
            Task { await respond(.once) }
        } label: {
            Label("Allow once", systemImage: "checkmark").frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
    }

    private func alwaysAllowButton(fillsWidth: Bool = false) -> some View {
        OpenCodeAlwaysAllowButton(request: request, isWorking: isWorking, fillsWidth: fillsWidth) {
            await respond(.always)
        }
    }
}
