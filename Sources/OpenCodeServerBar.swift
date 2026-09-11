import SwiftUI

struct OpenCodeServerBar: View {
    let profiles: [OpenCodeServerProfile]
    let selectedID: UUID?
    let select: (OpenCodeServerProfile) -> Void
    let add: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(profiles) { profile in
                        Button { select(profile) } label: {
                            HStack(spacing: 6) {
                                if profile.id == selectedID {
                                    Image(systemName: "checkmark").accessibilityHidden(true)
                                }
                                Text(profile.name)
                            }
                            .font(.cleanCaptionBold)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(profile.id == selectedID ? BYOTBrand.accent.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(profile.id == selectedID ? BYOTBrand.accent : .primary)
                        .accessibilityLabel(profile.name)
                        .accessibilityValue(profile.id == selectedID ? "Selected server" : "")
                        .accessibilityAddTraits(profile.id == selectedID ? .isSelected : [])
                        .id(profile.id)
                    }
                    Button("Add server", systemImage: "plus", action: add)
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .padding(.vertical, 8)
            .onChange(of: selectedID, initial: true) { _, id in
                if let id { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .accessibilityIdentifier("server-bar")
    }
}
