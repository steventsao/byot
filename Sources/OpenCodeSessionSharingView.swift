import SwiftUI

struct OpenCodeSessionSharingView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: OpenCodeSessionSharingStore

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if store.isLoadingCapabilities {
                        BYOTActivityView(
                            .loading,
                            title: "Checking sharing",
                            detail: "Reading this server’s session capabilities.",
                            layout: .blocking
                        )
                    } else if let reason = store.presentation.unavailableReason {
                        ContentUnavailableView(
                            "Sharing unavailable",
                            systemImage: "square.and.arrow.up",
                            description: Text(reason)
                        )
                    } else if let url = store.presentation.shareURL {
                        published(url: url)
                    } else {
                        privateSession
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Publish on web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await store.prepareForPresentation() }
        .presentationDetents([.medium, .large])
    }

    private var privateSession: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Private session", systemImage: "lock.fill")
                .font(.headline)
            Text("Publish this conversation on the web. Anyone with its link will be able to view it.")
                .foregroundStyle(.secondary)
            if let error = store.errorMessage {
                ErrorBanner(message: error)
            }
            Button {
                Task { await store.publish() }
            } label: {
                Label(
                    store.isMutating ? "Publishing…" : "Publish on web",
                    systemImage: "globe"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.presentation.canPublish)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func published(url: URL) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Public session", systemImage: "globe")
                .font(.headline)
            Text("Anyone with this link can view the conversation.")
                .foregroundStyle(.secondary)
            Text(url.absoluteString)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            if let error = store.errorMessage {
                ErrorBanner(message: error)
            }
            ShareLink(item: url) {
                Label("Share link", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Link(destination: url) {
                Label("View published session", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button(role: .destructive) {
                Task { await store.unpublish() }
            } label: {
                Label(
                    store.isMutating ? "Unpublishing…" : "Unpublish",
                    systemImage: "eye.slash"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!store.presentation.canUnpublish)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
