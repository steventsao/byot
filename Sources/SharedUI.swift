import SwiftUI

struct AgentPressFeedbackButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == AgentPressFeedbackButtonStyle {
    static var agentPressFeedback: AgentPressFeedbackButtonStyle {
        AgentPressFeedbackButtonStyle()
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Text(message.agentDisplayErrorText)
            .font(.cleanCaptionBold)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(BYOTBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: BYOTBrand.controlRadius)
                    .stroke(BYOTBrand.hairline, lineWidth: 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

enum AgentHaptics {
    @MainActor
    static func send() {
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
    }

    @MainActor
    static func replyArrived() {
        let generator = UIImpactFeedbackGenerator(style: .soft)
        generator.impactOccurred(intensity: 0.7)
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var agentDisplayErrorText: String {
        trimmedNonEmpty ?? "Request failed. Check the connection and try again."
    }
}
