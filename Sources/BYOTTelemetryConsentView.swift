import SwiftUI

/// The consent state for views. Writes go through `BYOTTelemetry`, which
/// starts or stops the vendor and keeps the install id in step.
@MainActor
final class BYOTTelemetryConsentModel: ObservableObject {
    @Published private(set) var consent: BYOTTelemetryConsent
    let block: BYOTTelemetry.Block?
    private let telemetry: BYOTTelemetry

    init(telemetry: BYOTTelemetry = .shared) {
        self.telemetry = telemetry
        consent = telemetry.consent
        block = telemetry.block
    }

    /// Off for builds that never send: tests, the kill switch, or a fork.
    var isAvailable: Bool {
        switch block {
        case .automated, .killSwitch, .foreignBuild: false
        case .consentPending, .declined, nil: true
        }
    }

    func decide(_ enabled: Bool) {
        telemetry.setConsent(enabled)
        consent = telemetry.consent
    }
}

/// The one-time question, shown after the first server is saved. Closing it
/// without choosing counts as "Not now", so it never asks twice.
struct BYOTTelemetryConsentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = BYOTTelemetryConsentModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(BYOTBrand.accent)
                        .accessibilityHidden(true)
                    Text("Share anonymous usage data?")
                        .font(.cleanTitle)
                    Text("byot would send which features you use and whether turns finish, plus your iOS version and device model. It never sends your prompts, code, server addresses, project names, or passwords. You can change this anytime in About byot.")
                        .font(.cleanBody)
                        .foregroundStyle(.secondary)
                    Link("Privacy policy", destination: URL(string: "https://byot.app/privacy")!)
                        .font(.cleanBody)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    Button {
                        model.decide(true)
                        dismiss()
                    } label: {
                        Text("Share usage data").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("telemetry-consent-share")
                    Button("Not now") {
                        model.decide(false)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("telemetry-consent-decline")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
                .background(BYOTBrand.canvas)
            }
            .background(BYOTBrand.canvas)
            .navigationTitle(Text("Help improve byot"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .onDisappear {
            if model.consent == .undecided { model.decide(false) }
        }
    }
}

/// The Privacy section of About byot.
struct BYOTTelemetryPrivacySection: View {
    @StateObject private var model = BYOTTelemetryConsentModel()

    var body: some View {
        Section {
            Toggle("Share anonymous usage data", isOn: Binding(
                get: { model.consent == .enabled },
                set: { model.decide($0) }))
                .disabled(model.isAvailable == false)
                .accessibilityIdentifier("telemetry-toggle")
        } header: {
            Text("Privacy")
        } footer: {
            if model.isAvailable {
                Text("Seven anonymous events: app opened, server connected, session started, turn requested, turn completed, error category, and whether byot asked for a star or a review. Never your prompts, code, server addresses, or project names.")
            } else {
                Text("Usage data is turned off for this build.")
            }
        }
    }
}
