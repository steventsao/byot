import SwiftUI

/// The byot wordmark in Open Runde, sized for widget chrome.
struct BYOTWidgetWordmark: View {
    var size: CGFloat = 15

    var body: some View {
        Text(BYOTBrand.wordmark)
            .font(.custom("OpenRunde-Bold", size: size, relativeTo: .footnote))
            .accessibilityLabel(BYOTBrand.wordmark)
    }
}

/// A tinted circle holding a state symbol.
struct BYOTWidgetBadge: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.16), in: Circle())
            .accessibilityHidden(true)
    }
}
