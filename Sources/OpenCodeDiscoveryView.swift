import SwiftUI

struct OpenCodeDiscoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store: OpenCodeDiscoveryStore
    let select: (OpenCodeServerProfile) -> Void

    init(
        browser: any OpenCodeBonjourBrowsing = OpenCodeBonjourBrowser(),
        select: @escaping (OpenCodeServerProfile) -> Void
    ) {
        _store = StateObject(wrappedValue: OpenCodeDiscoveryStore(browser: browser))
        self.select = select
    }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage = store.errorMessage {
                    Section {
                        ErrorBanner(message: errorMessage)
                        Button("Try again", systemImage: "arrow.clockwise") {
                            store.start()
                        }
                    }
                }

                if !store.servers.isEmpty {
                    Section("Nearby OpenCode servers") {
                        ForEach(store.servers) { server in
                            Button {
                                select(server.profile())
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(server.name)
                                        .font(.cleanBodySemibold)
                                    Text(server.endpoint.absoluteString)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .overlay {
                if store.isSearching, store.servers.isEmpty, store.errorMessage == nil {
                    BYOTActivityView(
                        .loading,
                        title: "Looking nearby",
                        detail: "Searching the local network for OpenCode servers.",
                        layout: .blocking
                    )
                } else if !store.isSearching,
                          store.servers.isEmpty,
                          store.errorMessage == nil {
                    ContentUnavailableView {
                        Label("No servers found", systemImage: "network.slash")
                    } description: {
                        Text("On the Mac, start OpenCode with --mdns and keep both devices on the same network.")
                    } actions: {
                        Button("Search again", systemImage: "arrow.clockwise") {
                            store.start()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle("Nearby servers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if store.isSearching {
                        ProgressView()
                            .accessibilityLabel("Searching local network")
                    } else {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            store.start()
                        }
                    }
                }
            }
            .task { store.start() }
            .onDisappear { store.stop() }
        }
    }
}
