import SwiftUI

struct OpenCodeServerContextView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: OpenCodeServerContextStore

    init(
        client: OpenCodeClient,
        directory: String,
        workspace: String? = nil
    ) {
        _store = StateObject(
            wrappedValue: OpenCodeServerContextStore(
                service: client,
                directory: directory,
                workspace: workspace
            )
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                OpenCodeServerStatusSections(store: store)
                OpenCodeServerSettingsSection(store: store)
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await store.load() }
                    }
                    .disabled(store.isLoading || store.isSavingConfiguration)
                }
            }
            .refreshable { await store.load() }
            .task { await store.load() }
        }
    }
}

private struct OpenCodeServerStatusSections: View {
    @ObservedObject var store: OpenCodeServerContextStore

    var body: some View {
        Section("Version control") {
            switch store.vcs {
            case .available(let vcs):
                if let branch = vcs.branch {
                    LabeledContent("Branch", value: branch)
                }
                if let defaultBranch = vcs.defaultBranch {
                    LabeledContent("Default branch", value: defaultBranch)
                }
                if vcs.branch == nil, vcs.defaultBranch == nil {
                    Text("No branch information reported.")
                        .foregroundStyle(.secondary)
                }
            default:
                OpenCodeServerSectionStateView(state: store.vcs)
            }
        }

        Section("Paths") {
            switch store.paths {
            case .available(let paths):
                LabeledContent("Directory", value: paths.directory)
                optionalPath("Worktree", paths.worktree)
                optionalPath("Home", paths.home)
                optionalPath("State", paths.state)
                optionalPath("Config", paths.config)
                optionalPath("Workspace", paths.workspaceID)
                optionalPath("Project", paths.projectID)
            default:
                OpenCodeServerSectionStateView(state: store.paths)
            }
        }

        Section("MCP servers") {
            switch store.mcp {
            case .available(let statuses):
                if statuses.isEmpty {
                    Text("No MCP servers reported.")
                        .foregroundStyle(.secondary)
                }
                ForEach(statuses.keys.sorted(), id: \.self) { name in
                    if let status = statuses[name] {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent(name, value: status.status.displayName)
                            if let error = status.error {
                                Text(error.agentDisplayErrorText)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }
                }
            default:
                OpenCodeServerSectionStateView(state: store.mcp)
            }
        }

        Section("Language servers") {
            switch store.lsp {
            case .available(let statuses):
                if statuses.isEmpty {
                    Text("No language servers reported.")
                        .foregroundStyle(.secondary)
                }
                ForEach(statuses) { status in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(status.name, value: status.status.displayName)
                        Text(status.root)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            default:
                OpenCodeServerSectionStateView(state: store.lsp)
            }
        }

        Section("Formatters") {
            switch store.formatters {
            case .available(let formatters):
                if formatters.isEmpty {
                    Text("No formatters reported.")
                        .foregroundStyle(.secondary)
                }
                ForEach(formatters) { formatter in
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent(
                            formatter.name,
                            value: formatter.enabled ? "Enabled" : "Disabled"
                        )
                        Text(formatter.extensions.joined(separator: ", "))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            default:
                OpenCodeServerSectionStateView(state: store.formatters)
            }
        }
    }

    @ViewBuilder
    private func optionalPath(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(label, value: value)
        }
    }
}

private struct OpenCodeServerSettingsSection: View {
    @ObservedObject var store: OpenCodeServerContextStore

    var body: some View {
        Section("Configuration") {
            switch store.configuration {
            case .available:
                Text("The complete server configuration is preserved as JSON, including fields this app does not interpret.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $store.configurationText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 280)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(store.configurationWriteUnavailableReason != nil)

                if let reason = store.configurationWriteUnavailableReason {
                    Label(reason, systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let message = store.configurationErrorMessage {
                    Label(message.agentDisplayErrorText, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button("Save configuration", systemImage: "checkmark.circle") {
                    Task { await store.saveConfiguration() }
                }
                .disabled(!store.canSaveConfiguration)
            default:
                OpenCodeServerSectionStateView(state: store.configuration)
            }
        }
    }
}

private struct OpenCodeServerSectionStateView<Value: Equatable & Sendable>: View {
    let state: OpenCodeServerContextSection<Value>

    var body: some View {
        switch state {
        case .idle, .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
        case .unavailable(let reason):
            Label(reason, systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message.agentDisplayErrorText, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case .available:
            EmptyView()
        }
    }
}

private extension OpenCodeMCPStatus.State {
    var displayName: String {
        switch self {
        case .connected: "Connected"
        case .disabled: "Disabled"
        case .failed: "Failed"
        case .needsAuth: "Needs authorization"
        case .needsClientRegistration: "Needs client registration"
        }
    }
}

private extension OpenCodeLSPStatus.State {
    var displayName: String {
        switch self {
        case .connected: "Connected"
        case .error: "Error"
        }
    }
}
