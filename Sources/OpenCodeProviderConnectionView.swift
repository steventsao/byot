import SwiftUI

struct OpenCodeProviderConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: OpenCodeProviderConnectionStore

    init(client: OpenCodeClient, directory: String, workspace: String? = nil) {
        _store = StateObject(
            wrappedValue: OpenCodeProviderConnectionStore(
                client: client,
                directory: directory,
                workspace: workspace
            )
        )
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(store.selectedProvider?.name ?? "Providers")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if store.selectedProvider != nil,
                           case .connected = store.phase {
                            EmptyView()
                        } else if store.selectedMethod != nil {
                            Button("Methods", systemImage: "chevron.left") {
                                Task { await store.leaveToMethods() }
                            }
                            .disabled(store.isNavigationLocked)
                        } else if store.selectedProvider != nil {
                            Button("Providers", systemImage: "chevron.left") {
                                Task { await store.leaveToProviders() }
                            }
                            .disabled(store.isNavigationLocked)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Task {
                                if await store.prepareToDismiss() { dismiss() }
                            }
                        }
                        .disabled(store.isNavigationLocked)
                    }
                }
        }
        .task { await store.load() }
        .interactiveDismissDisabled(
            store.authorization != nil
                || store.phase == .startingOAuth
                || store.isSubmitting
        )
    }

    @ViewBuilder
    private var content: some View {
        if store.isLoading && store.providers.isEmpty {
            BYOTActivityView(
                .loading,
                title: "Loading providers",
                detail: "Checking authentication methods from OpenCode.",
                layout: .blocking
            )
        } else if store.providers.isEmpty, let errorMessage = store.errorMessage {
            ContentUnavailableView {
                Label("Couldn’t load providers", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage.agentDisplayErrorText)
            } actions: {
                Button("Try again", systemImage: "arrow.clockwise") {
                    Task { await store.load() }
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            switch store.phase {
            case .providerSelection:
                OpenCodeProviderPickerView(store: store)
            case .methodSelection:
                OpenCodeProviderMethodPickerView(store: store)
            case .keyEntry:
                OpenCodeProviderKeyView(store: store)
            case .oauthPrompts:
                OpenCodeProviderOAuthPromptsView(store: store)
            case .oauthReady:
                OpenCodeProviderOAuthReadyView(store: store)
            case .startingOAuth:
                BYOTActivityView(
                    .connecting,
                    title: "Starting sign-in",
                    detail: "Requesting authorization details from OpenCode.",
                    layout: .blocking
                )
            case .oauthCode:
                OpenCodeProviderOAuthCodeView(store: store)
            case .oauthWaiting:
                OpenCodeProviderOAuthWaitingView(store: store)
            case .connected(let providerID):
                OpenCodeProviderConnectedView(
                    provider: store.providers.first { $0.id == providerID },
                    done: { dismiss() }
                )
            }
        }
    }
}

private struct OpenCodeProviderPickerView: View {
    @ObservedObject var store: OpenCodeProviderConnectionStore
    @State private var searchText = ""

    var body: some View {
        List {
            if let errorMessage = presentation.refreshErrorMessage {
                Section {
                    ErrorBanner(message: errorMessage)
                        .listRowInsets(EdgeInsets())
                }
            }
            ForEach(presentation.filteredProviders) { provider in
                Button {
                    store.selectProvider(provider)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(BYOTBrand.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(provider.name)
                                .font(.cleanBodySemibold)
                            Text(provider.id)
                                .font(.cleanCaption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if provider.isConnected {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(BYOTBrand.accent)
                                .accessibilityLabel("Connected")
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $searchText, prompt: "Search providers")
        .refreshable { await store.load() }
        .overlay {
            switch presentation.emptyState {
            case .none:
                EmptyView()
            case .catalog:
                ContentUnavailableView(
                    "No providers",
                    systemImage: "shippingbox",
                    description: Text("OpenCode did not report any providers to connect.")
                )
            case .search:
                ContentUnavailableView.search
            }
        }
    }

    private var presentation: OpenCodeProviderCatalogPresentation {
        OpenCodeProviderCatalogPresentation(
            providers: store.providers,
            query: searchText,
            errorMessage: store.errorMessage
        )
    }
}

private struct OpenCodeProviderMethodPickerView: View {
    @ObservedObject var store: OpenCodeProviderConnectionStore

    var body: some View {
        List {
            if let errorMessage = store.errorMessage {
                ErrorBanner(message: errorMessage)
                    .listRowInsets(EdgeInsets())
            }
            Section("Choose a connection method") {
                ForEach(store.selectedProvider?.methods ?? []) { method in
                    Button {
                        store.selectMethod(method)
                    } label: {
                        Label(
                            method.label,
                            systemImage: method.kind == .key ? "key.horizontal" : "person.badge.key"
                        )
                    }
                }
            }
        }
    }
}

private struct OpenCodeProviderKeyView: View {
    @ObservedObject var store: OpenCodeProviderConnectionStore
    @State private var key = ""

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)
            } header: {
                Text(store.selectedMethod?.label ?? "API key")
            } footer: {
                Text("The key is sent directly to your OpenCode server and is not saved by this app.")
            }
            errorSection
            Section {
                Button {
                    Task { await store.connectKey(key) }
                } label: {
                    HStack {
                        Text("Connect")
                        Spacer()
                        if store.isSubmitting { ProgressView() }
                    }
                }
                .disabled(store.isSubmitting || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let errorMessage = store.errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
    }
}

private struct OpenCodeProviderOAuthPromptsView: View {
    @ObservedObject var store: OpenCodeProviderConnectionStore

    var body: some View {
        Form {
            ForEach(store.visiblePrompts) { prompt in
                Section {
                    switch prompt.kind {
                    case .text:
                        TextField(
                            prompt.placeholder ?? prompt.message,
                            text: binding(for: prompt.key)
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    case .select:
                        Picker(prompt.message, selection: binding(for: prompt.key)) {
                            Text("Choose…").tag("")
                            ForEach(prompt.options) { option in
                                Text(option.hint.map { "\(option.label) — \($0)" } ?? option.label)
                                    .tag(option.value)
                            }
                        }
                    }
                } header: {
                    Text(prompt.message)
                }
            }
            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button("Continue") {
                    Task { await store.beginOAuth() }
                }
                .disabled(store.isSubmitting)
            }
        }
    }

    private func binding(for key: String) -> Binding<String> {
        Binding(
            get: { store.inputs[key] ?? "" },
            set: { store.setInput($0, for: key) }
        )
    }
}

private struct OpenCodeProviderOAuthReadyView: View {
    @ObservedObject var store: OpenCodeProviderConnectionStore

    var body: some View {
        Form {
            Section {
                Label(store.selectedMethod?.label ?? "OAuth", systemImage: "person.badge.key")
            } footer: {
                Text("OpenCode will provide a browser link or a code-based sign-in flow.")
            }
            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button("Start sign-in") {
                    Task { await store.beginOAuth() }
                }
                .disabled(store.isSubmitting)
            }
        }
    }
}

private struct OpenCodeProviderOAuthCodeView: View {
    @ObservedObject var store: OpenCodeProviderConnectionStore
    @State private var code = ""

    var body: some View {
        Form {
            authorizationSection
            Section("Authorization code") {
                TextField("Paste code", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button("Complete sign-in") {
                    Task { await store.completeOAuth(code: code) }
                }
                .disabled(store.isSubmitting || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @ViewBuilder
    private var authorizationSection: some View {
        if let authorization = store.authorization {
            Section("Open provider sign-in") {
                Link(destination: authorization.url) {
                    Label(
                        OpenCodeProviderAuthorizationURLPolicy.destinationLabel(
                            for: authorization.url
                        ),
                        systemImage: "safari"
                    )
                }
                if !authorization.instructions.isEmpty {
                    Text(authorization.instructions)
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct OpenCodeProviderOAuthWaitingView: View {
    @ObservedObject var store: OpenCodeProviderConnectionStore

    var body: some View {
        Form {
            if let authorization = store.authorization {
                Section("Finish in your browser") {
                    Link(destination: authorization.url) {
                        Label(
                            OpenCodeProviderAuthorizationURLPolicy.destinationLabel(
                                for: authorization.url
                            ),
                            systemImage: "safari"
                        )
                    }
                    if !authorization.instructions.isEmpty {
                        Text(authorization.instructions)
                            .font(.cleanBodySemibold)
                            .textSelection(.enabled)
                    }
                    HStack {
                        ProgressView()
                        Text("Waiting for OpenCode")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            if let errorMessage = store.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                Button("Cancel sign-in", role: .destructive) {
                    Task { await store.cancelOAuth() }
                }
            }
        }
        .task(id: store.authorization?.attemptID) {
            while !Task.isCancelled, store.phase == .oauthWaiting, store.errorMessage == nil {
                await store.pollOAuthOnce()
                guard store.phase == .oauthWaiting, store.errorMessage == nil else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct OpenCodeProviderConnectedView: View {
    let provider: OpenCodeProviderConnection?
    let done: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Provider connected", systemImage: "checkmark.circle.fill")
        } description: {
            Text("\(provider?.name ?? "The provider") is ready to use in OpenCode.")
        } actions: {
            Button("Done", action: done)
                .buttonStyle(.borderedProminent)
        }
    }
}
