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
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Automatic")
                                        .font(.cleanBodySemibold)
                                    Text("Server default")
                                        .font(.cleanCaption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: store.selectedModel == nil ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(store.selectedModel == nil ? BYOTBrand.accent : .secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }

                ForEach(filteredProviders) { provider in
                    Section(provider.providerName) {
                        ForEach(provider.models) { model in
                            Button {
                                choose(model)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(
                                        systemName: store.selectedModel?.id == model.id
                                            ? "checkmark.circle.fill"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        store.selectedModel?.id == model.id
                                            ? BYOTBrand.accent
                                            : .secondary
                                    )
                                    .accessibilityHidden(true)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(model.modelName)
                                            .font(.cleanBodySemibold)
                                        Text(model.modelID)
                                            .font(.cleanCaption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
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
            .overlay {
                if store.isLoadingModels && store.providerModels.isEmpty {
                    BYOTActivityView(
                        .loading,
                        title: "Loading models",
                        layout: .blocking
                    )
                } else if !store.isLoadingModels,
                          store.providerModels.isEmpty,
                          store.modelErrorMessage == nil {
                    ContentUnavailableView(
                        "No models",
                        systemImage: "cpu",
                        description: Text("Connect a provider, then refresh.")
                    )
                } else if !normalizedSearchText.isEmpty,
                          filteredProviders.isEmpty,
                          !automaticMatchesSearch {
                    ContentUnavailableView.search
                }
            }
            .navigationTitle("Choose model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search models")
            .refreshable { await store.reloadModels() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss.callAsFunction)
                }
            }
        }
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
