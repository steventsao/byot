import SwiftUI

struct OpenCodeAlwaysAllowButton: View {
    @State private var isConfirming = false
    let request: OpenCodePermissionRequest
    let isWorking: Bool
    var fillsWidth = false
    let respond: () async -> Void

    var body: some View {
        Button {
            isConfirming = true
        } label: {
            Label("Always allow", systemImage: "checkmark.shield").frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(BYOTBrand.accentInk)
        .frame(minHeight: 44)
        .disabled(isWorking || request.alwaysAllowConfirmationMessage == nil)
        .confirmationDialog(
            "Always allow \(request.permission)?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Confirm always allow") {
                Task { await respond() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationMessage: String {
        request.alwaysAllowConfirmationMessage
            ?? String(localized: "OpenCode did not provide a reusable permission scope.")
    }
}
