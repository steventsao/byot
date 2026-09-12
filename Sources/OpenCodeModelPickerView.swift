import SwiftUI

struct OpenCodeModelPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject var store: OpenCodeSessionStore
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if automaticMatchesSearch {
                    Section {
                        Button(action: chooseAutomatic) {
                            HStack(alignment: .top, spacing: 12) {
                                selectionIndicator(selected: store.selectedModel == nil)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Automatic")
                                        .font(.cleanBodySemibold)
                                    Text("Server default")
                                        .font(.cleanCaption)
                                        .foregroundStyle(.secondary)
                                }
                                .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("automatic-model-option")
                    }
                }

                if store.providerModels.contains(where: { $0.connectionState == .unreported }) {
                    Text("This server does not report provider connection status.")
                        .font(.cleanCaption)
                        .foregroundStyle(.secondary)
                }

                ForEach(filteredProviders) { provider in
                    Section(provider.providerName) {
                        ForEach(provider.models) { model in
                            Button {
                                choose(model)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    selectionIndicator(selected: store.selectedModel?.id == model.id)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.modelName)
                                            .font(.cleanBodySemibold)
                                        Text(model.modelID)
                                            .font(.cleanCaption)
                                            .foregroundStyle(.secondary)
                                        if dynamicTypeSize.isAccessibilitySize,
                                           let status = model.status,
                                           status != "active" {
                                            modelStatus(status)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if !dynamicTypeSize.isAccessibilitySize,
                                       let status = model.status,
                                       status != "active" {
                                        modelStatus(status)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .foregroundStyle(.primary)
                            .accessibilityLabel(
                                "\(model.modelName), \(provider.providerName)"
                            )
                            .accessibilityValue(
                                store.selectedModel?.id == model.id ? "Selected" : ""
                            )
                        }
                    }
                }

                if store.isLoadingModels && store.providerModels.isEmpty {
                    Section {
                        BYOTActivityView(.loading, title: "Loading models", layout: .inline)
                    }
                } else if !store.isLoadingModels,
                          store.providerModels.isEmpty,
                          store.modelErrorMessage == nil {
                    Section {
                        ContentUnavailableView(
                            "No models", systemImage: "cpu",
                            description: Text("Connect a provider, then refresh.")
                        )
                        Button("Reload models", systemImage: "arrow.clockwise") {
                            Task { await store.reloadModels() }
                        }
                        .accessibilityIdentifier("opencode-reload-models")
                    }
                } else if !normalizedSearchText.isEmpty,
                          filteredProviders.isEmpty,
                          !automaticMatchesSearch {
                    Section {
                        Text("No matching models")
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage = store.modelErrorMessage {
                    Section {
                        ErrorBanner(message: errorMessage)
                            .listRowInsets(EdgeInsets())
                        Button("Try again", systemImage: "arrow.clockwise") {
                            Task { await store.reloadModels() }
                        }
                    }
                }
            }
            .navigationTitle("Choose model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models")
            .refreshable { await store.reloadModels() }
            .task {
                if store.protocolCapabilities != nil { await store.reloadModels() }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
    }

    private func selectionIndicator(selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.cleanBody)
            .foregroundStyle(selected ? BYOTBrand.accent : .secondary)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    private var filteredProviders: [OpenCodeProviderModels] {
        store.providerModels.compactMap { $0.matching(searchText) }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var automaticMatchesSearch: Bool {
        normalizedSearchText.isEmpty
            || "automatic server default".contains(normalizedSearchText)
    }

    private func modelStatus(_ status: String) -> some View {
        Text(status.capitalized)
            .font(.cleanCaptionBold)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseAutomatic() {
        store.selectModel(nil)
        dismiss()
    }

    private func choose(_ model: OpenCodeModelOption) {
        store.selectModel(model)
        dismiss()
    }
}
