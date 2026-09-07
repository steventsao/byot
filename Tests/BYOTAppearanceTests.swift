import SwiftUI
import Testing
@testable import byot

@Suite("Appearance contrast")
@MainActor
struct BYOTAppearanceTests {
    @Test("Transcript and composer text remain readable in either appearance", arguments: [false, true])
    func textContrast(dark: Bool) {
        var environment = EnvironmentValues()
        environment.colorScheme = dark ? .dark : .light
        for surface in [BYOTBrand.canvas, BYOTBrand.surface, BYOTBrand.elevatedSurface,
                        BYOTBrand.controlSurface] {
            #expect(contrast(.primary, surface, environment) >= 4.5)
        }
        #expect(contrast(BYOTBrand.primaryActionInk, BYOTBrand.primaryAction, environment) >= 4.5)
    }

    @Test("Mint controls remain readable on the canvas", arguments: [false, true])
    func accentContrast(dark: Bool) {
        var environment = EnvironmentValues()
        environment.colorScheme = dark ? .dark : .light
        #expect(contrast(BYOTBrand.accent, BYOTBrand.canvas, environment) >= 4.5)
    }

    private func contrast(_ foreground: Color, _ background: Color, _ environment: EnvironmentValues) -> Double {
        func luminance(_ color: Color) -> Double {
            let resolved = color.resolve(in: environment)
            let components = [resolved.red, resolved.green, resolved.blue].map { component -> Double in
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
        }
        let values = [luminance(foreground), luminance(background)].sorted()
        return (values[1] + 0.05) / (values[0] + 0.05)
    }
}
