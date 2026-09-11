import Combine
import Foundation

/// Carries errors seen in a conversation back to its server's session list.
/// On return/relaunch, only these sessions need transcript reconciliation;
/// ordinary browsing does not download every conversation's history.
@MainActor
final class OpenCodeSessionAttentionStore: ObservableObject {
    @Published private(set) var failures: [String: String]
    private let defaults: UserDefaults
    private let key: String
    private var revision = 0

    init(serverID: UUID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "byot.opencode.attention.\(serverID.uuidString)"
        failures = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func record(sessionID: String, message: String?) {
        let message = message?.trimmedNonEmpty
        guard failures[sessionID] != message else { return }
        revision &+= 1
        failures[sessionID] = message
        defaults.set(failures, forKey: key)
    }

    func reload() {
        let stored = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        guard stored != failures else { return }
        revision &+= 1
        failures = stored
    }

    func refresh(sessions: [OpenCodeSession], service: any OpenCodeSessionServicing) async {
        let revision = revision
        let targets = sessions.filter { failures[$0.id] != nil }
        await withTaskGroup(of: (String, [OpenCodeMessageEnvelope]?).self) { tasks in
            var next = 0
            func enqueue() {
                guard next < targets.count else { return }
                let session = targets[next]
                next += 1
                tasks.addTask {
                    let messages = try? await service.messages(sessionID: session.id,
                        directory: session.directory, workspace: session.workspaceID)
                    return (session.id, messages)
                }
            }
            for _ in 0..<min(3, targets.count) { enqueue() }
            var updated = failures
            for await (id, messages) in tasks {
                guard !Task.isCancelled, self.revision == revision else {
                    tasks.cancelAll()
                    return
                }
                if let messages { updated[id] = Self.message(in: messages) }
                enqueue()
            }
            guard !Task.isCancelled, self.revision == revision, updated != failures else { return }
            self.revision &+= 1
            failures = updated
            defaults.set(updated, forKey: key)
        }
    }

    nonisolated static func message(in messages: [OpenCodeMessageEnvelope]) -> String? {
        guard let user = messages.lastIndex(where: { $0.info.role == "user" }) else { return nil }
        return messages.suffix(from: user + 1).last(where: { $0.info.role == "assistant" })?
            .info.error?.displayMessage.trimmedNonEmpty
    }
}
