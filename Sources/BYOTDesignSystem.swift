import SwiftUI

struct BYOTWordmark: View {
    var body: some View {
        Text(BYOTBrand.wordmark)
            .font(.custom("OpenRunde-Bold", size: 23, relativeTo: .headline))
            .accessibilityLabel(BYOTBrand.wordmark)
    }
}

/// OpenCode's UI type: the platform sans (`system-ui`) for prose and chrome and
/// the platform monospace (`ui-monospace`) for tools and code, at its 16pt
/// large and 13pt small sizes. Only the byot wordmark and app icon keep Open Runde.
extension Font {
    static let cleanTitle = Font.system(.title, weight: .semibold)
    static let cleanTitleBold = Font.system(.title, weight: .bold)
    static let cleanBody = Font.system(.callout)
    static let cleanBodySemibold = Font.system(.callout, weight: .semibold)
    static let cleanBodyBold = Font.system(.callout, weight: .bold)
    static let cleanCaption = Font.system(.footnote, weight: .medium)
    static let cleanCaptionSemibold = Font.system(.footnote, weight: .semibold)
    static let cleanCaptionBold = Font.system(.footnote, weight: .bold)
    static let cleanMono = Font.system(.footnote, design: .monospaced)
    static let cleanControlIcon = Font.system(size: 19, weight: .semibold)
}

enum SolarIconAsset: String {
    case chat = "SolarChat"
}

struct SolarIcon: View {
    let asset: SolarIconAsset
    var size: CGFloat = 24
    var tint: Color = BYOTBrand.accent

    var body: some View {
        Image(asset.rawValue)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct DesignCreditsView: View {
    var body: some View {
        List {
            Section("Typography") {
                Text("Wordmark in Open Runde by Laurids Kern, based on Inter")
                    .font(.cleanBody)
                Link("SIL Open Font License 1.1", destination: URL(string: "https://openfontlicense.org")!)
                    .font(.cleanCaption)
            }
            Section("Icons") {
                Text("Solar Icons by 480 Design")
                    .font(.cleanBody)
                Link("Creative Commons Attribution 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
                    .font(.cleanCaption)
            }
        }
        .navigationTitle("Design credits")
        .navigationBarTitleDisplayMode(.inline)
    }
}
