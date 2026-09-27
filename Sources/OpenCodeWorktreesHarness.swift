#if DEBUG
import Foundation
import SwiftUI

/// UI-test and screenshot harness: the worktrees screen over an in-memory server with a
/// clean worktree, one with uncommitted changes and sessions, and creates that report
/// readiness after a short checkout, as a real server does.
struct OpenCodeWorktreesHarness: View {
    var body: some View {
        NavigationStack {
            OpenCodeWorktreesScreen(
                service: OpenCodeWorktreesFixtureService(),
                route: OpenCodeWorktreeRoute(directory: "/Users/dev/byot", projectName: "byot")
            ) { session in
                Text("Session in \(OpenCodeWorktree.name(of: session.directory))")
                    .font(.cleanBody)
                    .accessibilityIdentifier("worktree-fixture-session")
            }
        }
    }
}

final class OpenCodeWorktreesFixtureService: OpenCodeWorktreeServicing, @unchecked Sendable {
    private static let root = "/Users/dev/.local/share/opencode/worktree/byot"
    private let lock = NSLock()
    private var worktrees = [
        OpenCodeWorktree(directory: "\(root)/login-flow"),
        OpenCodeWorktree(directory: "\(root)/misty-island"),
    ]
    private var changes = ["login-flow": 3, "misty-island": 0]
    private var sessions = ["login-flow": 2, "misty-island": 0]
    private var listeners: [AsyncThrowingStream<OpenCodeWorktreeEvent, Error>.Continuation] = []

    func list() async throws -> [OpenCodeWorktree] {
        lock.withLock { worktrees }
    }

    func create(name: String?) async throws -> OpenCodeWorktree {
        try await Task.sleep(for: .milliseconds(400))
        let slug = name.map(OpenCodeWorktreeNaming.slug) ?? ""
        let chosen = slug.isEmpty ? "calm-river" : slug
        let worktree = OpenCodeWorktree(directory: "\(Self.root)/\(chosen)", name: chosen, branch: "opencode/\(chosen)")
        lock.withLock {
            worktrees.append(worktree)
            changes[chosen] = 0
            sessions[chosen] = 0
        }
        Task {
            // Checking out and booting happen after the create answers.
            try? await Task.sleep(for: .milliseconds(2_500))
            let listeners = lock.withLock { self.listeners }
            for listener in listeners { listener.yield(.ready(directory: worktree.directory)) }
        }
        return worktree
    }

    func remove(_ directory: String) async throws {
        try await Task.sleep(for: .milliseconds(500))
        lock.withLock { worktrees.removeAll { $0.directory == directory } }
    }

    func reset(_ directory: String) async throws {
        try await Task.sleep(for: .milliseconds(700))
        lock.withLock { changes[OpenCodeWorktree.name(of: directory)] = 0 }
    }

    func events() -> AsyncThrowingStream<OpenCodeWorktreeEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.withLock { listeners.append(continuation) }
            continuation.yield(.connected)
        }
    }

    func summary(of directory: String) async -> OpenCodeWorktreeSummary {
        try? await Task.sleep(for: .milliseconds(150))
        let name = OpenCodeWorktree.name(of: directory)
        return lock.withLock {
            OpenCodeWorktreeSummary(branch: "opencode/\(name)", defaultBranch: "main",
                                    changes: changes[name], sessions: sessions[name])
        }
    }

    func createSession(in directory: String) async throws -> OpenCodeSession {
        try await Task.sleep(for: .milliseconds(200))
        let name = OpenCodeWorktree.name(of: directory)
        lock.withLock { sessions[name, default: 0] += 1 }
        return OpenCodeSession(
            id: "ses_\(name)", slug: name, projectID: "byot", workspaceID: nil, directory: directory, parentID: nil,
            summary: nil, title: "New session", agent: nil, version: "1.18.21",
            time: OpenCodeSessionTime(created: 0, updated: 0, compacting: nil, archived: nil))
    }
}
#endif
