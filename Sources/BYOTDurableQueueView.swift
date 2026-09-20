import SwiftUI

struct BYOTDurableQueueView: View {
    @ObservedObject var queue: BYOTDurableQueue
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var editing: BYOTQueueEntry?
    @State private var editText = ""
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            List {
                if !queue.enabled {
                    Section {
                        Text("Queue messages on your computer so they continue after you close byot. Prompts and attachments are encrypted before they pass through the BYOT relay. Your computer must stay awake and the companion must keep running.")
                        Button("Enable computer queue", systemImage: "desktopcomputer") {
                            perform { try await queue.enable() }
                        }.accessibilityIdentifier("queue-enable")
                        Button("Set up or update companion") { showSetup = true }
                    }
                } else {
                    Section {
                        Label(queue.paused ? "Queue paused" : "Computer queue enabled", systemImage: queue.paused ? "pause.circle" : "desktopcomputer")
                        Text("Messages marked Accepted can run with byot closed. Saved on this iPhone means the upload still needs to finish.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button(queue.paused ? "Resume queue" : "Pause queue", systemImage: queue.paused ? "play" : "pause") {
                            perform { try await queue.setPaused(!queue.paused) }
                        }.accessibilityIdentifier("queue-pause")
                        Button("Use phone queue instead") { perform { try queue.disable() } }
                        Text("Pausing prevents the next message from starting. Use Stop in the conversation to interrupt the current turn.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = queue.error {
                    Section { Text(error).foregroundStyle(.red); Button("Sync again") { Task { await queue.sync() } } }
                }
                if queue.entries.isEmpty { Text("No queued messages").foregroundStyle(.secondary) }
                ForEach(queue.entries) { entry in
                    Section {
                        if !entry.prompt.text.isEmpty { Text(entry.prompt.text).textSelection(.enabled) }
                        if !entry.prompt.attachments.isEmpty {
                            Label("\(entry.prompt.attachments.count) attachments", systemImage: "paperclip")
                        }
                        Text([entry.prompt.agent, entry.prompt.model?.modelName, entry.prompt.variant].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Label(entry.title, systemImage: symbol(entry.state)).font(.subheadline)
                            .accessibilityIdentifier("queue-state-\(entry.state)")
                        if entry.state == "queued" {
                            HStack {
                                if entry.prompt.command == nil {
                                    Button("Edit") { editText = entry.prompt.text; editing = entry }.buttonStyle(.borderless)
                                }
                                Button("Move up", systemImage: "arrow.up") { perform { try await queue.move(entry.id, offset: -1) } }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                                Button("Move down", systemImage: "arrow.down") { perform { try await queue.move(entry.id, offset: 1) } }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                        }
                        if ["queued", "uploading", "local", "needsReview"].contains(entry.state) {
                            Button(entry.state == "needsReview" ? "Dismiss after reviewing session" : "Cancel message", role: .destructive) {
                                perform { try await queue.cancel(entry.id) }
                            }
                        }
                        if entry.state == "needsReview" {
                            Text("The connection ended before execution could be confirmed. Review the conversation, dismiss this item, and compose a new message only if needed. Later messages remain blocked until you dismiss it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .disabled(busy)
            .refreshable { await queue.sync() }
            .navigationTitle("Message queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editing) { entry in
                NavigationStack {
                    Form {
                        TextEditor(text: $editText).frame(minHeight: 160)
                        Text("Saving pauses the queue. Resume it when your edits are ready.").font(.caption)
                    }
                    .navigationTitle("Edit queued message")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { editing = nil } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") { editing = nil; perform { try await queue.edit(entry.id, text: editText) } }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSetup) { BYOTPushSettingsView(profile: queue.profile) }
        }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true
        Task { do { try await action() } catch { queue.error = error.localizedDescription }; busy = false }
    }
    private func symbol(_ state: String) -> String {
        switch state {
        case "completed": "checkmark.circle"
        case "needsReview": "exclamationmark.triangle"
        case "local", "uploading": "iphone.and.arrow.forward"
        case "cancelled": "xmark.circle"
        default: "desktopcomputer"
        }
    }
}

struct BYOTQueueSummary: View {
    @ObservedObject var queue: BYOTDurableQueue
    let open: () -> Void
    var body: some View {
        if queue.enabled || !queue.pending.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: open) {
                    Label(queue.paused ? "Queue paused · \(queue.pending.count) pending" : "Computer queue · \(queue.pending.count) pending", systemImage: "list.bullet.rectangle")
                }.accessibilityIdentifier("queue-summary")
                ForEach(queue.pending.prefix(3)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.prompt.text.isEmpty ? "Attachments" : entry.prompt.text).lineLimit(2)
                        Text(entry.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = queue.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(BYOTBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
