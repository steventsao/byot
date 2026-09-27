import SwiftUI
import UIKit

/// Code colors for Light and Dark appearance, after GitHub's Primer syntax
/// palette (OpenCode's `github` theme). Every swatch keeps at least 4.5:1
/// contrast on the app's code surfaces, and Increase Contrast pushes each one
/// further toward the label color.
enum BYOTSyntaxPalette {
    struct Swatch: Equatable, Sendable {
        let light: UInt32
        let dark: UInt32
    }

    static func swatch(for kind: BYOTSyntaxTokenKind) -> Swatch {
        switch kind {
        case .keyword, .preprocessor: Swatch(light: 0xCF222E, dark: 0xFF7B72)
        case .type, .variable: Swatch(light: 0x953800, dark: 0xFFA657)
        case .function, .hunk: Swatch(light: 0x7440D0, dark: 0xD2A8FF)
        case .string: Swatch(light: 0x0A3069, dark: 0xA5D6FF)
        case .constant, .property, .heading: Swatch(light: 0x0550AE, dark: 0x79C0FF)
        case .comment: Swatch(light: 0x57606A, dark: 0x9198A1)
        case .attribute: Swatch(light: 0x6639BA, dark: 0xBC8CFF)
        case .tag, .inserted: Swatch(light: 0x116329, dark: 0x7EE787)
        case .deleted: Swatch(light: 0x82071E, dark: 0xFFA198)
        }
    }

    /// sRGB components in 0...1 for one appearance.
    static func components(
        for kind: BYOTSyntaxTokenKind,
        dark: Bool,
        increasedContrast: Bool = false
    ) -> (red: Double, green: Double, blue: Double) {
        let swatch = swatch(for: kind)
        let hex = dark ? swatch.dark : swatch.light
        var red = Double((hex >> 16) & 0xFF) / 255
        var green = Double((hex >> 8) & 0xFF) / 255
        var blue = Double(hex & 0xFF) / 255
        if increasedContrast {
            // Toward white on dark surfaces, toward black on light ones.
            let target = dark ? 1.0 : 0.0
            let amount = 0.35
            red += (target - red) * amount
            green += (target - green) * amount
            blue += (target - blue) * amount
        }
        return (red, green, blue)
    }

    /// A dynamic color that follows appearance and Increase Contrast.
    static func uiColor(for kind: BYOTSyntaxTokenKind) -> UIColor {
        UIColor { traits in
            let value = components(
                for: kind,
                dark: traits.userInterfaceStyle == .dark,
                increasedContrast: traits.accessibilityContrast == .high
            )
            return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
        }
    }

    static func color(for kind: BYOTSyntaxTokenKind) -> Color { colors[kind] ?? .primary }

    private static let colors: [BYOTSyntaxTokenKind: Color] = Dictionary(
        uniqueKeysWithValues: BYOTSyntaxTokenKind.allCases.map { ($0, Color(uiColor: uiColor(for: $0))) }
    )
}

/// Turns highlighted lines into text for SwiftUI (`AttributedString`) and
/// UIKit (`NSAttributedString`). Both are lossless: their plain string equals
/// the source exactly, so copy and selection never change what the agent wrote.
enum BYOTSyntaxRenderer {
    static func attributedString(code: String, language: BYOTSyntaxLanguage?) -> AttributedString {
        guard let language else { return AttributedString(code) }
        return attributedString(BYOTSyntaxHighlighter.lines(code, language: language))
    }

    static func attributedString(_ lines: [BYOTSyntaxLine]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(AttributedString("\n")) }
            append(line, to: &result)
        }
        return result
    }

    static func attributedString(_ line: BYOTSyntaxLine) -> AttributedString {
        var result = AttributedString()
        append(line, to: &result)
        return result
    }

    private static func append(_ line: BYOTSyntaxLine, to result: inout AttributedString) {
        for segment in line.segments {
            var run = AttributedString(segment.text)
            if let kind = segment.kind {
                run.foregroundColor = BYOTSyntaxPalette.color(for: kind)
                if kind == .heading { run.inlinePresentationIntent = .stronglyEmphasized }
            }
            result.append(run)
        }
    }

    static func nsAttributedString(
        code: String,
        language: BYOTSyntaxLanguage?,
        attributes: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        guard let language else { return NSAttributedString(string: code, attributes: attributes) }
        let result = NSMutableAttributedString()
        let lines = BYOTSyntaxHighlighter.lines(code, language: language)
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
            for segment in line.segments {
                var runAttributes = attributes
                if let kind = segment.kind {
                    runAttributes[.foregroundColor] = BYOTSyntaxPalette.uiColor(for: kind)
                }
                result.append(NSAttributedString(string: segment.text, attributes: runAttributes))
            }
        }
        return result
    }
}

/// Monospace code with syntax color. Pass `nil` to render plain text.
struct BYOTCodeText: View {
    let code: String
    let language: BYOTSyntaxLanguage?

    var body: some View {
        Text(BYOTSyntaxRenderer.attributedString(code: code, language: language))
            .font(.cleanMono)
            .foregroundStyle(.primary)
    }
}
