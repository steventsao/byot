import SwiftUI

/// Says that what's on screen was saved on this iPhone because the server can't be
/// reached, how old it is, and offers to try again.
struct OpenCodeOfflineNotice: View {
    enum Subject {
        case sessions, transcript

        var phrase: String {
            switch self {
            case .sessions: String(localized: "sessions saved")
            case .transcript: String(localized: "this conversation as saved")
            }
        }
    }

    let subject: Subject
    let savedAt: Date
    var detail: String?
    var isTruncated = false
    var isRetrying = false
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: BYOTBrand.Space.sm) {
            VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
                Label("Offline", systemImage: "wifi.slash")
                    .font(.cleanBodySemibold)
                    // Lists tint row icons; this one is a status, not an action.
                    .foregroundStyle(.primary)
                Text(summary)
                    .font(.cleanCaption)
                    .foregroundStyle(.primary)
                if let detail = detail?.agentDisplayErrorText.trimmedNonEmpty {
                    Text(detail)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("offline-notice")

            if isRetrying {
                HStack(spacing: BYOTBrand.Space.sm) {
                    ProgressView()
                    Text("Reconnecting…")
                        .font(.cleanCaptionBold)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
            } else {
                Button(action: retry) {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(.cleanCaptionBold)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("offline-retry")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .background(BYOTBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius))
        .overlay {
            RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                .stroke(BYOTBrand.hairline, lineWidth: 1)
        }
    }

    private var summary: String {
        let age = savedAt.formatted(.relative(presentation: .named))
        let shown = String(localized: "Showing \(subject.phrase) \(age).")
        return isTruncated ? String(localized: "\(shown) Earlier messages load once the server is back.") : shown
    }
}
