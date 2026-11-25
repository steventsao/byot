import AppKit
import SwiftUI

enum DesktopBrand {
    static let wordmark = "byot"

    static var canvas: Color { Color(nsColor: .windowBackgroundColor) }
    static var surface: Color { Color(nsColor: .controlBackgroundColor) }
    static var elevatedSurface: Color { Color(nsColor: .textBackgroundColor) }
    static var selectedSurface: Color { Color.primary.opacity(0.08) }
    static var chipSurface: Color { Color.secondary.opacity(0.10) }
    static var hairline: Color { Color.primary.opacity(0.11) }
    static var strongHairline: Color { Color.primary.opacity(0.18) }

    /// Strict monochrome primary buttons matching BYOT iOS (`BYOTBrand.primaryAction`).
    static var primaryAction: Color { Color(nsColor: .labelColor) }
    static var primaryActionInk: Color { Color(nsColor: .windowBackgroundColor) }

    /// Subtle semantic accent reserved for status dots & diff/active indicators only —
    /// never used for wordmarks, navigation chrome, or large filled buttons.
    static var statusLive: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(calibratedRed: 0.42, green: 0.84, blue: 0.58, alpha: 1)
                : NSColor(calibratedRed: 0.14, green: 0.54, blue: 0.32, alpha: 1)
        })
    }

    static var additionBackground: Color { Color.green.opacity(0.12) }
    static var deletionBackground: Color { Color.red.opacity(0.12) }

    /// Only the lowercase `byot` wordmark uses Open Runde (matching BYOT iOS).
    static func wordmarkFont(size: CGFloat) -> Font {
        if NSFont(name: "OpenRunde-Bold", size: size) != nil {
            return .custom("OpenRunde-Bold", size: size)
        }
        return .system(size: size, weight: .bold, design: .rounded)
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

struct DesktopWordmark: View {
    var size: CGFloat = 20

    var body: some View {
        Text(DesktopBrand.wordmark)
            .font(DesktopBrand.wordmarkFont(size: size))
            .foregroundStyle(.primary)
            .fixedSize()
            .accessibilityLabel(DesktopBrand.wordmark)
    }
}

/// High-contrast monochrome button matching BYOT's black-and-white brand palette.
struct DesktopPrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .callout.weight(.medium) : .callout.weight(.medium))
            .foregroundStyle(DesktopBrand.primaryActionInk)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 6 : 8)
            .background(
                DesktopBrand.primaryAction.opacity(configuration.isPressed ? 0.82 : 1.0),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}

/// Quiet, hairline-bordered secondary button for desktop chrome.
struct DesktopSecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 6 : 8)
            .background(
                (configuration.isPressed ? DesktopBrand.selectedSurface : DesktopBrand.surface),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(DesktopBrand.strongHairline, lineWidth: 1)
            )
    }
}

enum DesktopSyntaxTheme {
    static func attributedCode(
        _ text: String,
        language: BYOTSyntaxLanguage?,
        colorScheme: ColorScheme
    ) -> AttributedString {
        var result = AttributedString()
        let lines = BYOTSyntaxHighlighter.lines(text, language: language)
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            for segment in line.segments {
                var run = AttributedString(segment.text)
                if let kind = segment.kind {
                    run.foregroundColor = color(for: kind, isDark: colorScheme == .dark)
                }
                result.append(run)
            }
        }
        return result
    }

    static func color(for kind: BYOTSyntaxTokenKind, isDark: Bool) -> Color {
        switch kind {
        case .keyword: isDark ? Color(red: 0.99, green: 0.47, blue: 0.65) : Color(red: 0.68, green: 0.12, blue: 0.45)
        case .type: isDark ? Color(red: 0.56, green: 0.84, blue: 0.99) : Color(red: 0.08, green: 0.42, blue: 0.68)
        case .function: isDark ? Color(red: 0.72, green: 0.62, blue: 0.99) : Color(red: 0.36, green: 0.22, blue: 0.74)
        case .string: isDark ? Color(red: 0.99, green: 0.58, blue: 0.48) : Color(red: 0.76, green: 0.18, blue: 0.12)
        case .constant: isDark ? Color(red: 0.85, green: 0.78, blue: 0.45) : Color(red: 0.56, green: 0.34, blue: 0.04)
        case .comment: .secondary
        case .attribute, .preprocessor: isDark ? Color(red: 0.96, green: 0.70, blue: 0.44) : Color(red: 0.55, green: 0.31, blue: 0.08)
        case .property, .variable: isDark ? Color(red: 0.54, green: 0.88, blue: 0.70) : Color(red: 0.10, green: 0.44, blue: 0.30)
        case .tag: isDark ? Color(red: 0.56, green: 0.84, blue: 0.99) : Color(red: 0.08, green: 0.42, blue: 0.68)
        case .inserted: .green
        case .deleted: .red
        case .hunk, .heading: .accentColor
        }
    }
}
