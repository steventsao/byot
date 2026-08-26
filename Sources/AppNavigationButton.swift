import SwiftUI

struct AppNavigationButton: View {
    var isToolbarItem = false
    var action: () -> Void

    var body: some View {
        Button("Navigation", systemImage: "line.3.horizontal", action: action)
            .labelStyle(.iconOnly)
            .font(.cleanControlIcon)
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
            .background(
                isToolbarItem ? Color.clear : BYOTBrand.elevatedSurface,
                in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
            )
            .overlay {
                RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                    .stroke(isToolbarItem ? Color.clear : BYOTBrand.hairline, lineWidth: 1)
            }
            .buttonStyle(.agentPressFeedback)
            .accessibilityHint("Opens app information")
    }
}
