import SwiftUI

enum BYOTAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Apply the choice to the window so navigation and every presented sheet
/// inherit it. Resetting SwiftUI's preferredColorScheme to nil can leave an
/// already-presented sheet in the previous appearance.
struct BYOTAppearanceOverride: UIViewRepresentable {
    let appearance: BYOTAppearance

    func makeUIView(context: Context) -> AppearanceView {
        AppearanceView()
    }

    func updateUIView(_ uiView: AppearanceView, context: Context) {
        uiView.interfaceStyle = appearance.interfaceStyle
    }

    final class AppearanceView: UIView {
        var interfaceStyle: UIUserInterfaceStyle = .unspecified {
            didSet { window?.overrideUserInterfaceStyle = interfaceStyle }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            window?.overrideUserInterfaceStyle = interfaceStyle
        }
    }
}
