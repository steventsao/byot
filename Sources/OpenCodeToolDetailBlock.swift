import SwiftUI

struct OpenCodeToolDetailBlock: View {
    let title: String
    let text: String
    var isError = false
    var language: BYOTSyntaxLanguage? = nil
    /// Draws a line-number gutter starting at this line when set.
    var firstLineNumber: Int? = nil
    var footnote: String? = nil

    init(title: String, text: String, isError: Bool = false) {
        self.title = title
        self.text = text
        self.isError = isError
    }

    init(code: OpenCodeToolCode) {
        title = code.title
        text = code.text
        language = code.language
        firstLineNumber = code.firstLineNumber
        footnote = code.footnote
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: BYOTBrand.Space.sm) {
                Text(title)
                    .font(.cleanCaptionSemibold)
                    .foregroundStyle(isError ? Color.red : Color.secondary)
                Spacer(minLength: 0)
                if let language, language != .diff {
                    Text(language.displayName)
                        .font(.cleanCaption)
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("\(language.displayName) code")
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    if let gutter {
                        Text(gutter)
                            .font(.cleanMono)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.trailing)
                            .accessibilityHidden(true)
                    }
                    if isError {
                        Text(text)
                            .font(.cleanMono)
                            .foregroundStyle(Color.red)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                    } else {
                        BYOTCodeText(code: text, language: language)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                    }
                }
            }
            if let footnote {
                Text(footnote)
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One number per source line, in a single text so rows stay aligned with
    /// the code at every Dynamic Type size.
    private var gutter: String? {
        guard let firstLineNumber else { return nil }
        let lineCount = text.utf8.reduce(into: 1) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        return (firstLineNumber..<(firstLineNumber + lineCount)).map(String.init).joined(separator: "\n")
    }
}
