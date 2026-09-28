import SwiftUI

struct OpenCodeAgentPickerView: View {
    @ObservedObject var store: OpenCodeSessionStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        store.selectAgent(nil)
                        dismiss()
                    } label: {
                        Label("Default agent", systemImage: store.explicitAgentID == nil ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityIdentifier("opencode-agent-default")
                    Text("Inherit this session’s agent or the server default.")
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }
                Section("Primary agents") {
                    ForEach(store.composerCatalog.agents) { agent in
                        Button {
                            store.selectAgent(agent.id)
                            dismiss()
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: store.explicitAgentID == agent.id ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(agent.displayName).font(.cleanBodySemibold)
                                    if let description = agent.description {
                                        Text(description).font(.cleanCaption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .accessibilityIdentifier("opencode-agent-\(agent.id)")
                        .accessibilityAddTraits(store.explicitAgentID == agent.id ? .isSelected : [])
                    }
                }
                if let error = store.composerErrorMessage {
                    Section { Text(error).font(.cleanCaption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Choose agent")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.reloadComposerCatalog() }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct OpenCodeComposerAction {
    let name: String
    let title: String
    let unavailableReason: String?
    let run: () -> Void
}
