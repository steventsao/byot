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
                    rejectButton
                    Spacer()
                    allowOnceButton
                    if !request.always.isEmpty {
                        alwaysAllowButton
                    }
                }
                VStack(spacing: 10) {
                    allowOnceButton.frame(maxWidth: .infinity)
                    if !request.always.isEmpty {
                        alwaysAllowButton.frame(maxWidth: .infinity)
                    }
                    rejectButton.frame(maxWidth: .infinity)
                }
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

    private var rejectButton: some View {
        Button("Reject", systemImage: "xmark", role: .destructive) {
            Task { await respond(.reject) }
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
    }

    private var allowOnceButton: some View {
        Button("Allow once", systemImage: "checkmark") {
            Task { await respond(.once) }
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
    }

    private var alwaysAllowButton: some View {
        OpenCodeAlwaysAllowButton(request: request, isWorking: isWorking) {
            await respond(.always)
        }
    }
}
