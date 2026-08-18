import SwiftUI

struct OpenCodeAlwaysAllowButton: View {
    @State private var isConfirming = false
    let request: OpenCodePermissionRequest
    let isWorking: Bool
    let respond: () async -> Void

    var body: some View {
        Button("Always allow", systemImage: "checkmark.shield") {
            isConfirming = true
        }
        .buttonStyle(.borderedProminent)
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
            ?? "OpenCode did not provide a reusable permission scope."
    }
}
