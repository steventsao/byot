import SwiftUI

enum BYOTBrand {
    static let wordmark = "byot"
    static let radius: CGFloat = 16
    static let controlRadius = radius
    static let prominentControlRadius = radius
    static let panelRadius = radius
    static let sidebarWidth: CGFloat = 372
    static let conversationMaxWidth: CGFloat = 820

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    /// Shared motion cadence. Ambient loops stay deliberately slow so the app
    /// communicates progress without turning a waiting screen into a light show.
    enum Motion {
        static let quick = 0.18
        static let activityStep = 0.24
        static let shimmer = 1.45
    }

    static var background: Color { canvas }
    // Match semantic text and system sheets in both appearances. Fixed dark
    // fills leave light-mode labels black on black (TestFlight ADZMRhL…).
    static var canvas: Color { Color(uiColor: .systemBackground) }
    static var surface: Color { Color(uiColor: .secondarySystemBackground) }
    static var elevatedSurface: Color { Color(uiColor: .tertiarySystemBackground) }
    static var controlSurface: Color { Color(uiColor: .secondarySystemBackground) }
    static var selectedSurface: Color { Color.primary.opacity(0.08) }
    static var accent: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.54, green: 0.88, blue: 0.70, alpha: 1)
                : UIColor(red: 0.12, green: 0.38, blue: 0.26, alpha: 1)
        })
    }
    static var accentSoft: Color { accent.opacity(0.12) }
    // Filled accent buttons need white ink on forest green in Light appearance
    // and black ink on mint in Dark appearance.
    static var accentInk: Color { Color(uiColor: .systemBackground) }
    static var primaryAction: Color { Color(uiColor: .label) }
    static var primaryActionInk: Color { Color(uiColor: .systemBackground) }
    static var ink: Color { .primary }
    static var mutedInk: Color { .secondary }
    static var inverseInk: Color { Color(.systemBackground) }
    static var hairline: Color { Color.primary.opacity(0.12) }
    static var strongHairline: Color { Color.primary.opacity(0.18) }
    static var brightHairline: Color { Color.primary.opacity(0.18) }
    static var shadow: Color { Color.black.opacity(0.28) }
}
