import SwiftUI

enum BYOTBrand {
    static let wordmark = "byot"
    static let radius: CGFloat = 16
    static let controlRadius = radius
    static let prominentControlRadius = radius
    static let panelRadius = radius
    /// Composer prompt box — soft Cursor-scale rounding (finer than panel chrome).
    static let composerRadius: CGFloat = 12
    /// Nested chips inside the composer (concentric with composerRadius − padding).
    static let composerChipRadius: CGFloat = 6
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

    /// Near-white overlay base — Cursor paints text, borders, and washes as
    /// this color at low alpha over opaque dark backgrounds.
    static let overlayBase = Color(red: 0.894, green: 0.894, blue: 0.894)

    static var background: Color { canvas }
    static var canvas: Color { Color(red: 0.025, green: 0.026, blue: 0.030) }
    static var surface: Color { Color(red: 0.086, green: 0.088, blue: 0.098) }
    static var elevatedSurface: Color { Color(red: 0.118, green: 0.120, blue: 0.132) }
    static var controlSurface: Color { Color(red: 0.150, green: 0.152, blue: 0.166) }
    /// Soft field wash for the prompt composer (overlay @ ~4%).
    static var composerWash: Color { overlayBase.opacity(0.04) }
    static var selectedSurface: Color { Color.white.opacity(0.08) }
    static var composerChip: Color { overlayBase.opacity(0.12) }
    static var accent: Color { Color(red: 0.54, green: 0.88, blue: 0.70) }
    static var accentSoft: Color { Color(red: 0.090, green: 0.180, blue: 0.145) }
    static var accentInk: Color { Color(red: 0.025, green: 0.055, blue: 0.040) }
    /// Quiet off-white fill for primary CTAs. The saturated mint accent is
    /// reserved for selection and state; large buttons stay calm ink on the
    /// dark canvas, matching modern agent apps.
    static var primaryAction: Color { Color(red: 0.93, green: 0.94, blue: 0.95) }
    static var primaryActionInk: Color { Color(red: 0.070, green: 0.072, blue: 0.086) }
    static var ink: Color { .primary }
    static var mutedInk: Color { .secondary }
    static var inverseInk: Color { Color(.systemBackground) }
    static var placeholderInk: Color { overlayBase.opacity(0.37) }
    static var hairline: Color { Color.primary.opacity(0.12) }
    static var strongHairline: Color { Color.primary.opacity(0.18) }
    static var brightHairline: Color { Color.white.opacity(0.18) }
    /// Composer resting border — barely-there (overlay @ ~7%).
    static var composerBorder: Color { overlayBase.opacity(0.07) }
    /// Composer focus border — slightly brighter, no glow.
    static var composerBorderFocus: Color { overlayBase.opacity(0.15) }
    static var shadow: Color { Color.black.opacity(0.28) }
}
