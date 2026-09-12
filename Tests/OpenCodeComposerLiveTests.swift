import Foundation
import XCTest
@testable import byot

/// Runs against scripts/e2e/fixtures.py's pinned real servers, never a user's server.
final class OpenCodeComposerLiveTests: XCTestCase {
    func testLiveV1AndV2AdvertisedAgentsVariantsCommandsAndFileContext() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BYOT_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Requires isolated real server fixture") }
        let root = try XCTUnwrap(environment["BYOT_LIVE_ROOT"])
        for (major, port) in [("v1", 4195), ("v2", 4199)] {
            let directory = root + "/\(major)/project"
            let client = OpenCodeClient(profile: OpenCodeServerProfile(name: "Composer \(major)",
                baseURL: "https://127.0.0.1:\(port)", directory: directory), password: "byot-local-fixture-only")
            let session = try await client.createSession(directory: directory, title: "Composer acceptance \(major)")
            let providers = try await client.connectedProviderModels(directory: directory)
            let model = try XCTUnwrap(providers.first { $0.providerID == "fixture" }?.models.first { $0.modelID == "test" })
            XCTAssertTrue(model.variants.contains("byot-careful"), "Fixture variant must come from actual server catalog")
            let catalog = try await client.composerCatalog(sessionID: session.id, directory: directory, workspace: nil)
            XCTAssertTrue(catalog.supportsVariants)
            let agent = try XCTUnwrap(catalog.agents.first { $0.id.lowercased() == "plan" }
                                      ?? catalog.agents.first { $0.id.lowercased() == "build" })
            let command = try XCTUnwrap(catalog.commands.first { $0.name == "byot-acceptance" && $0.kind == .command })
            XCTAssertEqual(command.description, "Verify custom command arguments")
            let reference = OpenCodePromptFileReference(serverID: client.profile.id, projectID: session.projectID,
                directory: directory, path: "src/acceptance #%.txt", selection: OpenCodeFileLineRange(startLine: 2, endLine: 3))
            let prompt = OpenCodeQueuedPrompt(text: "Read the selected server file lines.", model: model,
                agent: agent.id, variant: "byot-careful", remoteReferences: [reference])
            try await client.sendPrompt(sessionID: session.id, directory: directory, workspace: nil, prompt: prompt)
            let messages = try await completedMessages(client, session: session, directory: directory, after: nil)
            let user = try XCTUnwrap(messages.first { $0.info.role == "user" })
            XCTAssertEqual(user.id, prompt.messageID)
            XCTAssertEqual(user.info.agent, agent.id)
            XCTAssertEqual(user.info.variant, "byot-careful")
            XCTAssertTrue(user.parts.contains { $0.type == "file" && $0.url == reference.fileURL }, "Server file URI and selected line range must round trip")
            if major == "v2" {
                let inherited = try await client.composerCatalog(sessionID: session.id, directory: directory, workspace: nil)
                XCTAssertEqual(inherited.inheritedAgent, agent.id)
                XCTAssertEqual(inherited.inheritedModelID, model.qualifiedID)
                XCTAssertEqual(inherited.inheritedVariant, "byot-careful")
                // Replaying a transport-ambiguous admission uses the same ID and payload.
                try await client.sendPrompt(sessionID: session.id, directory: directory, workspace: nil, prompt: prompt)
                let retryMessages = try await client.messages(sessionID: session.id, directory: directory)
                XCTAssertEqual(retryMessages.filter { $0.id == prompt.messageID }.count, 1)
            }
            let last = messages.last?.id
            let arguments = "BYOT-command-arguments-\(major) \"two words\""
            let commandPrompt = OpenCodeQueuedPrompt(text: "/\(command.name) \(arguments)", model: model,
                agent: agent.id, command: OpenCodeCommandInvocation(name: command.name, arguments: arguments, kind: .command))
            try await client.sendPrompt(sessionID: session.id, directory: directory, workspace: nil, prompt: commandPrompt)
            let commandMessages = try await completedMessages(client, session: session, directory: directory, after: last)
            XCTAssertTrue(commandMessages.contains { $0.info.role == "user" && $0.parts.contains(where: { $0.text?.contains(arguments) == true }) },
                          "The server must expand the custom command with the actual arguments")
            if major == "v2" {
                let inherited = try await client.composerCatalog(sessionID: session.id, directory: directory, workspace: nil)
                XCTAssertNil(inherited.inheritedVariant, "Selecting Default removes the prior variant from the model reference")
            }
        }
    }

    private func completedMessages(_ client: OpenCodeClient, session: OpenCodeSession,
                                   directory: String, after previousID: String?) async throws -> [OpenCodeMessageEnvelope] {
        for _ in 0..<150 {
            let messages = try await client.messages(sessionID: session.id, directory: directory)
            let start = previousID.flatMap { previous in messages.firstIndex { $0.id == previous } }.map { $0 + 1 } ?? 0
            let latest = messages.dropFirst(start)
            let statuses = try await client.sessionStatuses(directory: directory)
            if statuses[session.id]?.isActive != true,
               latest.contains(where: { $0.info.role == "assistant" && $0.info.time.completed != nil }) {
                XCTAssertTrue(latest.flatMap(\.parts).contains { $0.text == "BYOT upstream compatibility verified." })
                return messages
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("The real \(session.version) server did not complete the composer request")
        return try await client.messages(sessionID: session.id, directory: directory)
    }
}
