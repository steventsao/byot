import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Publish, share, and unpublish a session's read-only web page, mirroring
/// OpenCode's "Publish on web" popover. Every state change is an explicit tap.
struct OpenCodeSessionShareView: View {
    @ObservedObject var store: OpenCodeSessionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isConfirmingUnpublish = false
    @State private var copiedLink: URL?
    @State private var detent = PresentationDetent.medium

    var body: some View {
        let presentation = store.sharePresentation
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: BYOTBrand.Space.lg) {
                    if presentation.isAvailable {
                        header(presentation)
                        if let link = presentation.link { linkCard(link) }
                        if let error = store.shareErrorMessage {
                            ErrorBanner(message: error)
                                .padding(.horizontal, -12)
                                .accessibilityIdentifier("session-share-error")
                        }
                        actions(presentation)
                        Text(presentation.isPublished
                             ? "New messages in this conversation keep appearing on the page until you unpublish it."
                             : "OpenCode uploads this conversation, including code and tool output, to its share service. New messages keep syncing until you unpublish.")
                            .font(.cleanCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ContentUnavailableView(
                            "Sharing unavailable",
                            systemImage: "globe",
                            description: Text(presentation.isSupported
                                              ? "Sharing is turned off in this server’s OpenCode config."
                                              : "This server can’t publish sessions on the web.")
                        )
                    }
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(BYOTBrand.canvas)
            .navigationTitle("Publish on web")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Unpublish this conversation?", isPresented: $isConfirmingUnpublish, titleVisibility: .visible) {
                Button("Unpublish", role: .destructive) { unpublish() }
                    .accessibilityIdentifier("session-share-confirm-unpublish")
            } message: {
                Text("The link stops working for everyone who has it. Publishing again creates a new link.")
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .onAppear {
            store.clearShareError()
            detent = preferredDetent(published: presentation.isPublished)
        }
        .onChange(of: presentation.isPublished) { _, published in
            // The published state carries the link and three more actions.
            if published { detent = .large }
        }
    }

    private func preferredDetent(published: Bool) -> PresentationDetent {
        published || dynamicTypeSize.isAccessibilitySize ? .large : .medium
    }

    private func header(_ presentation: OpenCodeSessionSharePresentation) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: BYOTBrand.Space.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: BYOTBrand.Space.md))
        return layout {
            Image(systemName: presentation.isPublished ? "globe" : "lock.fill")
                .font(.cleanControlIcon)
                .foregroundStyle(presentation.isPublished ? BYOTBrand.accent : .secondary)
                .frame(width: 44, height: 44)
                .background(presentation.isPublished ? BYOTBrand.accentSoft : BYOTBrand.surface, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: BYOTBrand.Space.xs) {
                Text(presentation.isPublished ? "Public on the web" : "Private")
                    .font(.cleanBodySemibold)
                    .accessibilityAddTraits(.isHeader)
                Text(presentation.isPublished
                     ? "Anyone with the link can view this conversation."
                     : "Publish a read-only copy of this conversation. Anyone with the link will be able to view it.")
                    .font(.cleanBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("session-share-state")
    }

    private func linkCard(_ link: URL) -> some View {
        Text(link.absoluteString)
            .font(.cleanMono)
            .textSelection(.enabled)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 8 : 3)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(BYOTBrand.surface, in: RoundedRectangle(cornerRadius: BYOTBrand.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: BYOTBrand.controlRadius).stroke(BYOTBrand.hairline, lineWidth: 1)
            }
            .accessibilityLabel("Public link")
            .accessibilityValue(link.absoluteString)
            .accessibilityIdentifier("session-share-link")
    }

    @ViewBuilder
    private func actions(_ presentation: OpenCodeSessionSharePresentation) -> some View {
        VStack(spacing: BYOTBrand.Space.sm) {
            if let link = presentation.link {
                ShareLink(item: link, subject: Text(store.session.title)) {
                    fullWidthLabel("Share link", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(BYOTBrand.accentInk)
                .accessibilityIdentifier("session-share-sheet")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BYOTBrand.Space.sm) { copyButton(link); openButton(link) }
                    VStack(spacing: BYOTBrand.Space.sm) { copyButton(link); openButton(link) }
                }
                Button(role: .destructive) { isConfirmingUnpublish = true } label: {
                    progressLabel(store.isUpdatingShare ? "Unpublishing…" : "Unpublish", systemImage: "eye.slash")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!presentation.canUnpublish)
                .accessibilityIdentifier("session-share-unpublish")
            } else {
                Button { publish() } label: {
                    progressLabel(store.isUpdatingShare ? "Publishing…" : "Publish", systemImage: "globe")
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(BYOTBrand.accentInk)
                .disabled(!presentation.canPublish)
                .accessibilityIdentifier("session-share-publish")
            }
        }
        .controlSize(.large)
    }

    private func copyButton(_ link: URL) -> some View {
        let copied = copiedLink == link
        return Button {
            // Both forms, so the link pastes into plain text fields too.
            UIPasteboard.general.items = [[UTType.url.identifier: link, UTType.plainText.identifier: link.absoluteString]]
            withAnimation(reduceMotion ? nil : .easeOut(duration: BYOTBrand.Motion.quick)) { copiedLink = link }
            AccessibilityNotification.Announcement("Link copied").post()
            Task {
                try? await Task.sleep(for: .seconds(2))
                if copiedLink == link { copiedLink = nil }
            }
        } label: {
            fullWidthLabel(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("session-share-copy")
    }

    private func openButton(_ link: URL) -> some View {
        Button { openURL(link) } label: {
            fullWidthLabel("View page", systemImage: "safari")
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Opens the published conversation in your browser.")
        .accessibilityIdentifier("session-share-open")
    }

    private func fullWidthLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.cleanBodySemibold)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
    }

    private func progressLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: BYOTBrand.Space.sm) {
            if store.isUpdatingShare {
                ProgressView().accessibilityHidden(true)
            } else {
                Image(systemName: systemImage).accessibilityHidden(true)
            }
            Text(title)
        }
        .font(.cleanBodySemibold)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    private func publish() {
        Task {
            if await store.publishShareLink() {
                AccessibilityNotification.Announcement("Published. Anyone with the link can view this conversation.").post()
            }
        }
    }

    private func unpublish() {
        Task {
            if await store.unpublishShareLink() {
                copiedLink = nil
                AccessibilityNotification.Announcement("Unpublished. The conversation is private.").post()
            }
        }
    }
}

/// Compact marker for a session that is published on the web.
struct OpenCodeSharedSessionBadge: View {
    var body: some View {
        Label("Public", systemImage: "globe")
            .font(.cleanCaptionBold)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(BYOTBrand.accent)
            .fixedSize()
            .accessibilityLabel("Published on the web")
    }
}
