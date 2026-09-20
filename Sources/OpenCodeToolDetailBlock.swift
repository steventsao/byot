import SwiftUI

struct OpenCodeToolDetailBlock: View {
    let title: String
    let text: String
    var isError = false

    var body: some View {
        VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
            Text(title)
                .font(.cleanCaptionSemibold)
                .foregroundStyle(isError ? Color.red : Color.secondary)
            ScrollView(.horizontal) {
                Text(text)
                    .font(.cleanMono)
                    .foregroundStyle(isError ? Color.red : Color.primary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
