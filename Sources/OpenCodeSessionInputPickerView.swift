import SwiftUI

struct OpenCodeAgentPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: OpenCodeSessionInputStore

    var body: some View {
        NavigationStack {
            List(store.selectableAgents) { agent in
                Button {
                    store.selectAgent(agent)
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.id)
                                .font(.cleanBody)
                            if let description = agent.description {
                                Text(description)
                                    .font(.cleanCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if store.selectedAgent?.id == agent.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(BYOTBrand.accent)
                                .accessibilityLabel("Selected")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct OpenCodeCommandPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: OpenCodeSessionInputStore
    let select: (OpenCodeCommandOption) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let reason = store.policy?.commandUnavailableReason {
                    Section {
                        Label(reason, systemImage: "info.circle")
                            .font(.cleanCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Available commands") {
                    if store.commands.isEmpty {
                        Text(store.isLoading ? "Loading commands" : "No commands available")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.commands) { command in
                        Button {
                            select(command)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("/\(command.name)")
                                    .font(.cleanBody)
                                if let description = command.description {
                                    Text(description)
                                        .font(.cleanCaption)
                                        .foregroundStyle(.secondary)
                                }
                                if !command.hints.isEmpty {
                                    Text(command.hints.joined(separator: " · "))
                                        .font(.cleanCaption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(store.policy?.canExecuteCommands != true)
                    }
                }
            }
            .navigationTitle("Slash commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
