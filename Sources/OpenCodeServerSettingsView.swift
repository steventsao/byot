import SwiftUI

/// Edits the server-wide defaults in the server's global config: models, default agent,
/// sharing, snapshots, updates and shell. Mirrors the settings the web app writes through
/// `PATCH /global/config`, and sends only what changed.
struct OpenCodeServerSettingsSheet: View {
    /// What the project runs with, to point out settings its own config overrides.
    let effective: OpenCodeServerConfiguration?
    let onSaved: () -> Void
    @StateObject private var store: OpenCodeServerSettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingSave = false
    @State private var isConfirmingDiscard = false

    init(service: any OpenCodeServerContextServicing, effective: OpenCodeServerConfiguration?,
         onSaved: @escaping () -> Void) {
        self.effective = effective
        self.onSaved = onSaved
        _store = StateObject(wrappedValue: OpenCodeServerSettingsStore(service: service))
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.phase == .loaded {
                    OpenCodeServerSettingsForm(store: store, effective: effective)
                }
            }
            .disabled(store.isSaving)
            .overlay { stateOverlay }
            .navigationTitle("Server settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if store.hasChanges { isConfirmingDiscard = true } else { dismiss() }
                    }
                    .tint(BYOTBrand.chromeTint)
                    .accessibilityIdentifier("settings-cancel")
                    .confirmationDialog("Discard your changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                        Button("Discard changes", role: .destructive) { dismiss() }
                        Button("Keep editing", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isSaving {
                        ProgressView().accessibilityLabel("Saving")
                    } else {
                        Button("Save") { isConfirmingSave = true }
                            .fontWeight(.semibold)
                            .tint(BYOTBrand.chromeTint)
                            .disabled(!store.hasChanges)
                            .accessibilityIdentifier("settings-save")
                            .confirmationDialog("Save server settings?", isPresented: $isConfirmingSave,
                                                titleVisibility: .visible) {
                                Button("Save and reload") { Task { await save() } }
                                    .accessibilityIdentifier("settings-save-confirm")
                                Button("Cancel", role: .cancel) {}
                            } message: {
                                Text("OpenCode reloads every project on the server to apply them. Agents that are working may stop.")
                            }
                    }
                }
            }
            .task { await store.loadIfNeeded() }
        }
        .interactiveDismissDisabled(store.hasChanges || store.isSaving)
        .accessibilityIdentifier("server-settings")
    }

    @ViewBuilder private var stateOverlay: some View {
        switch store.phase {
        case .loading:
            BYOTActivityView(.loading, title: String(localized: "Loading settings"), layout: .inline)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t load settings", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message.agentDisplayErrorText)
            } actions: {
                Button("Try again", systemImage: "arrow.clockwise") { Task { await store.load() } }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(BYOTBrand.accentInk)
            }
        case .unsupported:
            ContentUnavailableView("Settings unavailable", systemImage: "slider.horizontal.3",
                                   description: Text("This OpenCode server doesn’t let apps change its settings."))
        case .loaded:
            EmptyView()
        }
    }

    private func save() async {
        guard await store.save() else {
            if let error = store.saveError {
                AccessibilityNotification.Announcement(String(localized: "Couldn’t save. \(error.agentDisplayErrorText)")).post()
            }
            return
        }
        AccessibilityNotification.Announcement(String(localized: "Server settings saved")).post()
        onSaved()
        dismiss()
    }
}

private struct OpenCodeServerSettingsForm: View {
    @ObservedObject var store: OpenCodeServerSettingsStore
    let effective: OpenCodeServerConfiguration?

    var body: some View {
        Section {
            Text("Defaults for every project on this server. A project’s own opencode.json can override them.")
                .font(.cleanCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
        }

        if let error = store.saveError {
            Section {
                Label("Couldn’t save. \(error.agentDisplayErrorText)", systemImage: "exclamationmark.triangle")
                    .font(.cleanCaption)
                    .foregroundStyle(BYOTBrand.diffDeletion)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-save-error")
            }
        }

        Section {
            modelLink(title: String(localized: "Default model"), selection: $store.draft.model,
                      identifier: "settings-model")
            modelLink(title: String(localized: "Small model"), selection: $store.draft.smallModel,
                      identifier: "settings-small-model")
        } header: {
            Text("Models")
        } footer: {
            footer([
                String(localized: "The small model writes session titles and summaries. Automatic lets OpenCode choose."),
                overridden(effective?.model, saved: store.saved.model).map {
                    String(localized: "This project’s config uses \($0) as its model.")
                },
                overridden(effective?.smallModel, saved: store.saved.smallModel).map {
                    String(localized: "This project’s config uses \($0) as its small model.")
                },
            ])
        }

        Section {
            OpenCodeServerSettingsChoice(title: String(localized: "Default agent"), selection: $store.draft.defaultAgent,
                                         value: agentName(store.draft.defaultAgent), identifier: "settings-agent") {
                Text("Automatic").tag(String?.none)
                ForEach(agentChoices, id: \.self) { id in
                    Text(agentName(id)).tag(String?.some(id))
                }
            }
        } header: {
            Text("Agent")
        } footer: {
            footer([
                String(localized: "New sessions start with this agent. Automatic uses Build."),
                overridden(effective?.defaultAgent, saved: store.saved.defaultAgent).map {
                    String(localized: "This project’s config starts sessions with the \($0) agent.")
                },
            ])
        }

        Section {
            OpenCodeServerSettingsChoice(title: String(localized: "Sharing"), selection: $store.draft.sharing,
                                         value: store.draft.sharing.title, identifier: "settings-sharing") {
                ForEach(OpenCodeServerSettings.Sharing.allCases) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $store.draft.snapshots) {
                Text("Snapshots").font(.cleanBody)
            }
            .tint(BYOTBrand.accent)
            .accessibilityIdentifier("settings-snapshots")
        } header: {
            Text("Sessions")
        } footer: {
            footer([
                store.draft.sharing == .auto
                    ? String(localized: "Automatic sharing creates a public link for every new session.")
                    : String(localized: "Manual sharing creates a link only when you share a session."),
                store.draft.snapshots
                    ? String(localized: "Snapshots let you undo and revert the agent’s file changes.")
                    : String(localized: "Without snapshots, undo and revert can’t restore the agent’s file changes."),
            ])
        }

        Section {
            OpenCodeServerSettingsChoice(title: String(localized: "Updates"), selection: $store.draft.updates,
                                         value: store.draft.updates.title, identifier: "settings-updates") {
                ForEach(OpenCodeServerSettings.Updates.allCases) { Text($0.title).tag($0) }
            }
            OpenCodeServerSettingsShellField(shell: $store.draft.shell)
        } header: {
            Text("Server")
        } footer: {
            footer([String(localized: "The shell runs the agent’s commands and terminals. Leave it empty to use the login shell.")])
        }

        if let error = store.optionsError {
            Section {
                Label("Couldn’t load models and agents. \(error.agentDisplayErrorText)", systemImage: "exclamationmark.triangle")
                    .font(.cleanCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Primary agents, plus a saved agent the server didn't list so it stays selectable.
    private var agentChoices: [String] {
        var ids = store.options.agents.map(\.id)
        for id in [store.saved.defaultAgent, store.draft.defaultAgent].compactMap({ $0 })
        where store.options.agent(id) == nil && !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    private func modelLink(title: String, selection: Binding<String?>, identifier: String) -> some View {
        NavigationLink {
            OpenCodeServerSettingsModelPicker(title: title, selection: selection, options: store.options)
        } label: {
            OpenCodeServerSettingsValueLabel(title: title, value: modelName(selection.wrappedValue))
        }
        .accessibilityIdentifier(identifier)
    }

    private func agentName(_ id: String?) -> String {
        guard let id else { return String(localized: "Automatic") }
        return store.options.agent(id)?.displayName ?? id
    }

    private func modelName(_ id: String?) -> String {
        guard let id else { return String(localized: "Automatic") }
        return store.options.model(id)?.modelName ?? id
    }

    /// The project's value when its own config sets something other than the server default.
    private func overridden(_ effective: String?, saved: String?) -> String? {
        guard let effective, effective != saved else { return nil }
        return effective
    }

    private func footer(_ lines: [String?]) -> some View {
        Text(lines.compactMap { $0 }.joined(separator: "\n"))
            .font(.cleanCaption)
    }
}

/// Title and current value, side by side or stacked at accessibility text sizes.
private struct OpenCodeServerSettingsValueLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let value: String

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(title).font(.cleanBody).foregroundStyle(BYOTBrand.ink)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(value)
                .font(.cleanBody)
                .foregroundStyle(BYOTBrand.mutedInk)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                .truncationMode(.middle)
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// A menu of choices whose collapsed label is plain text, like the new-session options: the
/// system menu picker insets its label and clips a wrapped choice at accessibility sizes.
private struct OpenCodeServerSettingsChoice<Value: Hashable, Options: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    @Binding var selection: Value
    let value: String
    let identifier: String
    @ViewBuilder let options: () -> Options

    var body: some View {
        Menu {
            Picker(title, selection: $selection, content: options)
        } label: {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
            layout {
                Text(title).font(.cleanBody).foregroundStyle(BYOTBrand.ink)
                if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(.cleanBody)
                        .foregroundStyle(BYOTBrand.mutedInk)
                        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.cleanCaptionBold)
                        .foregroundStyle(Color(uiColor: .tertiaryLabel))
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityIdentifier(identifier)
    }
}

private struct OpenCodeServerSettingsShellField: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var shell: String

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text("Shell").font(.cleanBody).accessibilityHidden(true)
            TextField("Shell", text: $shell, prompt: Text("Login shell"))
                .font(.cleanMono)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .accessibilityLabel("Shell")
                .accessibilityHint("Leave empty to use the login shell")
                .accessibilityIdentifier("settings-shell")
        }
        .frame(minHeight: 44)
    }
}

/// Picks a connected provider's model, Automatic, or a typed `provider/model`.
struct OpenCodeServerSettingsModelPicker: View {
    let title: String
    @Binding var selection: String?
    let options: OpenCodeServerSettingsOptions
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .callout) private var indicatorWidth = 24.0
    @State private var searchText = ""

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    row(title: String(localized: "Automatic"), detail: String(localized: "OpenCode chooses"),
                        selected: selection == nil) { choose(nil) }
                        .accessibilityIdentifier("settings-model-automatic")
                }
            }
            if let current = selection, options.model(current) == nil, matches(current) {
                Section("Current") {
                    row(title: current, detail: String(localized: "Not offered by a connected provider"),
                        selected: true, monospaced: true) { choose(current) }
                }
            }
            if let custom = OpenCodeServerSettingsModelPicker.customModel(query), options.model(custom) == nil,
               custom != selection {
                Section {
                    row(title: String(localized: "Use “\(custom)”"), detail: String(localized: "Typed model ID"),
                        selected: false) { choose(custom) }
                        .accessibilityIdentifier("settings-model-custom")
                }
            }
            ForEach(filteredProviders) { provider in
                Section(provider.providerName) {
                    ForEach(provider.models) { model in
                        row(title: model.modelName, detail: model.modelID, selected: selection == model.qualifiedID) {
                            choose(model.qualifiedID)
                        }
                        .accessibilityLabel("\(model.modelName), \(provider.providerName)")
                    }
                }
            }
            if options.providers.isEmpty && query.isEmpty {
                Section {
                    Text("No connected providers reported models. Type a model ID such as anthropic/claude-sonnet-4-5 in the search field.")
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !query.isEmpty && filteredProviders.isEmpty
                        && OpenCodeServerSettingsModelPicker.customModel(query) == nil {
                Section {
                    Text("No matching models").font(.cleanBody).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search or type provider/model")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private var query: String { searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var filteredProviders: [OpenCodeProviderModels] {
        options.providers.compactMap { $0.matching(query) }
    }

    private func matches(_ text: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query)
    }

    /// A typed `provider/model`, with no spaces and something on both sides of the slash.
    static func customModel(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slash = text.firstIndex(of: "/"), slash != text.startIndex,
              text.index(after: slash) != text.endIndex,
              !text.contains(where: \.isWhitespace) else { return nil }
        return text
    }

    private func choose(_ value: String?) {
        selection = value
        dismiss()
    }

    private func row(title: String, detail: String, selected: Bool, monospaced: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.cleanBodySemibold)
                    .foregroundStyle(BYOTBrand.accent)
                    .opacity(selected ? 1 : 0)
                    .frame(width: indicatorWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(monospaced ? .cleanMono : .cleanBodySemibold)
                        .foregroundStyle(BYOTBrand.ink)
                    Text(detail)
                        .font(.cleanCaption)
                        .foregroundStyle(BYOTBrand.mutedInk)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
