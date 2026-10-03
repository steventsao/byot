import SwiftUI

/// The GitHub star ask, shown above the composer after a turn finishes well.
struct BYOTStarNudgeCard: View {
    let star: () -> Void
    let later: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BYOTBrand.Space.sm) {
            VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
                Label("Like byot?", systemImage: "star")
                    .font(.cleanBodySemibold)
                    .foregroundStyle(.primary)
                Text("A star on GitHub helps other OpenCode users find it.")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            HStack(spacing: BYOTBrand.Space.sm) {
                Button(action: star) {
                    Label("Star byot", systemImage: "star.fill")
                        .font(.cleanCaptionBold)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("star-nudge-star")
                Button("Later", action: later)
                    .font(.cleanCaptionBold)
                    .frame(minHeight: 44)
                    .buttonStyle(.borderless)
                    .tint(.secondary)
                    .accessibilityIdentifier("star-nudge-later")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .background(BYOTBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                .stroke(BYOTBrand.hairline, lineWidth: 1)
        }
        .accessibilityIdentifier("star-nudge")
    }
}
