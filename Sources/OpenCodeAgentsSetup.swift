import SwiftUI

/// OpenCode's guided AGENTS.md setup. Upstream's `POST /session/:id/init`
/// only runs the built-in `init` command against the session
/// (packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts),
/// so BYOT sends that same command the way typing `/init` does: through the
/// prompt queue, with the chosen model, agent and variant, on v1 and on v2
/// servers that accept commands. It is offered only where the server's
/// command catalog lists `init`.
enum OpenCodeAgentsSetup {
    static let commandName = "init"

    /// The composer text for the command; a focus becomes its arguments,
    /// which the template reads as `$ARGUMENTS`.
    static func prompt(focus: String) -> String {
        let focus = focus.components(separatedBy: .newlines).joined(separator: " ").trimmedNonEmpty
        return "/\(commandName)" + (focus.map { " \($0)" } ?? "")
    }
}

extension OpenCodeSessionStore {
    var supportsAgentsSetup: Bool {
        composerCatalog.commands.contains { $0.name == OpenCodeAgentsSetup.commandName && $0.kind == .command }
    }

    var agentsSetupUnavailableReason: String? {
        guard supportsAgentsSetup else { return String(localized: "This server does not offer AGENTS.md setup.") }
        guard canSubmitPrompt else { return String(localized: "Wait for the session to connect.") }
        // Sending now would discard the undone turns without asking.
        if revertMessageID != nil { return String(localized: "Redo or send your revised prompt first.") }
        return nil
    }

    @discardableResult
    func startAgentsSetup(focus: String = "") -> Bool {
        if let reason = agentsSetupUnavailableReason {
            errorMessage = reason
            return false
        }
        return send(OpenCodeAgentsSetup.prompt(focus: focus))
    }
}

/// Confirms the setup before it runs a turn, and takes an optional focus.
struct OpenCodeAgentsSetupAlert: ViewModifier {
    @Binding var isPresented: Bool
    @ObservedObject var store: OpenCodeSessionStore
    @State private var focus = ""

    func body(content: Content) -> some View {
        content.alert("Set up AGENTS.md", isPresented: $isPresented) {
            TextField("Focus (optional)", text: $focus)
                .accessibilityIdentifier("agents-setup-focus")
            Button("Cancel", role: .cancel) { focus = "" }
            // The session announces the turn starting, or the prompt queueing.
            Button("Start") {
                store.startAgentsSetup(focus: focus)
                focus = ""
            }
            .accessibilityIdentifier("agents-setup-start")
        } message: {
            Text("OpenCode studies this project, then creates or updates AGENTS.md with guidance for future sessions. It runs as a turn with \(store.selectedModel?.modelName ?? String(localized: "the session’s model")).")
        }
    }
}

extension View {
    func openCodeAgentsSetupAlert(isPresented: Binding<Bool>, store: OpenCodeSessionStore) -> some View {
        modifier(OpenCodeAgentsSetupAlert(isPresented: isPresented, store: store))
    }
}
