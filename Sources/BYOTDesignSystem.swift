import SwiftUI

extension Font {
    static let cleanTitle = Font.custom("OpenRunde-Semibold", size: 28, relativeTo: .title)
    static let cleanTitleBold = Font.custom("OpenRunde-Bold", size: 28, relativeTo: .title)
    static let cleanBody = Font.custom("OpenRunde-Regular", size: 17, relativeTo: .body)
    static let cleanBodySemibold = Font.custom("OpenRunde-Semibold", size: 17, relativeTo: .body)
    static let cleanBodyBold = Font.custom("OpenRunde-Bold", size: 17, relativeTo: .body)
    static let cleanCaption = Font.custom("OpenRunde-Medium", size: 13, relativeTo: .caption)
    static let cleanCaptionSemibold = Font.custom("OpenRunde-Semibold", size: 13, relativeTo: .caption)
    static let cleanCaptionBold = Font.custom("OpenRunde-Bold", size: 13, relativeTo: .caption)
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
                Text("Open Runde by Laurids Kern, based on Inter")
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
