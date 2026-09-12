import Foundation
import XCTest
@testable import byot

/// Exercises only isolated real fixture servers, using the production feature
/// service, HTTPS transport and negotiated schema. No UI-test fake endpoints.
final class OpenCodeLiveSessionFeatureTests: XCTestCase {
    func testLiveV1LifecycleHistoryAndTaskSnapshot() async throws {
        try await exerciseFeatures(major: "v1", port: 4195)
    }
    func testLiveBetaLifecycleHistoryAndTaskCapability() async throws {
        try await exerciseFeatures(major: "v2", port: 4199)
    }

    private func exerciseFeatures(major: String, port: Int) async throws {
        guard ProcessInfo.processInfo.environment["BYOT_LIVE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires the isolated live server fixture")
        }
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["BYOT_LIVE_ROOT"])
        let directory = root + "/" + major + "/project"
        let client = OpenCodeClient(profile: OpenCodeServerProfile(name: "Live session features", baseURL: "https://127.0.0.1:\(port)", directory: directory), password: "byot-local-fixture-only")
        _ = try await client.probeCompatibility()
        let support = try await client.sessionFeatureSupport()
        XCTAssertTrue(support.details && support.rename && support.delete && support.children)
        XCTAssertTrue(support.undo && support.redo && support.fork && support.compact)
        let session = try await client.createSession(directory: directory, title: "Session lifecycle acceptance")
        let details = try await client.sessionDetails(sessionID: session.id, directory: directory, workspace: nil)
        XCTAssertEqual(details.session.id, session.id)
        let renamed = try await client.renameSession(sessionID: session.id, directory: directory, workspace: nil, title: "Session feature validation")
        XCTAssertEqual(renamed.session.title, "Session feature validation")
        let providers = try await client.connectedProviderModels(directory: directory)
        let model = try XCTUnwrap(providers.first { $0.providerID == "fixture" }?.models.first)
        try await client.sendMessage(sessionID: session.id, directory: directory, model: model, text: "Verify session history features.")
        let messages = try await settledMessages(client, sessionID: session.id, directory: directory)
        let user = try XCTUnwrap(messages.first { $0.info.role == "user" })
        let todos = try await client.sessionTodos(sessionID: session.id, directory: directory, workspace: nil)
        if major == "v1" { XCTAssertNotNil(todos) } else { XCTAssertNil(todos) }
        try await client.stageSessionRevert(sessionID: session.id, directory: directory, workspace: nil, messageID: user.id)
        let staged = try await client.sessionDetails(sessionID: session.id, directory: directory, workspace: nil)
        XCTAssertEqual(staged.revertMessageID, user.id)
        try await client.clearSessionRevert(sessionID: session.id, directory: directory, workspace: nil)
        let cleared = try await client.sessionDetails(sessionID: session.id, directory: directory, workspace: nil)
        XCTAssertNil(cleared.revertMessageID)
        let fullFork = try await client.forkSession(sessionID: session.id, directory: directory, workspace: nil, beforeMessageID: nil)
        let beforeFork = try await client.forkSession(sessionID: session.id, directory: directory, workspace: nil, beforeMessageID: user.id)
        XCTAssertNotEqual(fullFork.id, session.id)
        XCTAssertNotEqual(beforeFork.id, fullFork.id)
        let beforeMessages = try await client.messages(sessionID: beforeFork.id, directory: directory)
        XCTAssertFalse(beforeMessages.contains { $0.info.role == "user" })
        let children = try await client.childSessions(sessionID: session.id, directory: directory, workspace: nil)
        // V2 forks are children. V1 forks are independent sessions; verify its
        // actual children response without imposing v2 parent semantics.
        if major == "v2" { XCTAssertTrue(children.contains { $0.id == fullFork.id }) }
        if major == "v2" {
            try await client.stageSessionRevert(sessionID: session.id, directory: directory, workspace: nil, messageID: user.id)
            let committed = try await client.commitSessionRevert(sessionID: session.id, directory: directory, workspace: nil)
            XCTAssertTrue(committed)
            try await client.sendMessage(sessionID: session.id, directory: directory, model: model, text: "Revised direction after undo.")
            let revised = try await settledMessages(client, sessionID: session.id, directory: directory)
            XCTAssertFalse(revised.contains { $0.id == user.id })
            XCTAssertTrue(revised.contains { $0.parts.contains { $0.text == "Revised direction after undo." } })
        }
        try await client.compactSession(sessionID: session.id, directory: directory, workspace: nil, model: model)
        _ = try await settledMessages(client, sessionID: session.id, directory: directory)
        try await client.deleteSession(sessionID: beforeFork.id, directory: directory, workspace: nil)
        try await client.deleteSession(sessionID: fullFork.id, directory: directory, workspace: nil)
        try await client.deleteSession(sessionID: session.id, directory: directory, workspace: nil)
        let remaining = try await client.listSessions(directory: directory)
        XCTAssertFalse(remaining.contains { $0.id == session.id || $0.id == fullFork.id || $0.id == beforeFork.id })
    }

    private func settledMessages(_ client: OpenCodeClient, sessionID: String, directory: String) async throws -> [OpenCodeMessageEnvelope] {
        var snapshot: [OpenCodeMessageEnvelope] = []
        // Compaction admission can precede its busy event; require consecutive
        // idle observations so deleting the fixture cannot race its executor.
        var idleObservations = 0
        for _ in 0..<150 {
            snapshot = try await client.messages(sessionID: sessionID, directory: directory)
            let statuses = try await client.sessionStatuses(directory: directory)
            if statuses[sessionID]?.isActive != true && snapshot.contains(where: { $0.info.role == "assistant" }) {
                idleObservations += 1
                if idleObservations >= 3 { return snapshot }
            } else { idleObservations = 0 }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("Fixture session did not finish")
        return snapshot
    }
}
