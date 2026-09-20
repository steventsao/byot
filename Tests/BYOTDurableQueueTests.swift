import XCTest
@testable import byot

@MainActor final class BYOTDurableQueueTests: XCTestCase {
    private func fixture(transport: QueueTestTransport = QueueTestTransport()) throws -> (BYOTDurableQueue, OpenCodeServerProfile, BYOTPushCredential, URL, UserDefaults) {
        let profile = OpenCodeServerProfile(name: "Queue fixture", baseURL: "https://fixture.example", directory: "/fixture")
        let credential = BYOTPushCredential.make(profile)
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let queue = BYOTDurableQueue(profile: profile, route: BYOTPushRoute(serverID: profile.id, sessionID: "ses_test", directory: "/fixture", workspace: nil), defaults: defaults, directory: folder, credential: credential, transport: transport)
        return (queue, profile, credential, folder, defaults)
    }
    private func prompt() -> OpenCodeQueuedPrompt {
        OpenCodeQueuedPrompt(text: "Run the tests", model: .init(providerID: "fixture", providerName: "Fixture", modelID: "test", modelName: "Test", status: nil, variants: ["careful"]), attachments: [.init(filename: "context.txt", mimeType: "text/plain", data: Data("context".utf8))], agent: "build", variant: "careful")
    }
    func testOutboxIsSavedBeforeReturnAndRestoresEverySelectionAfterRelaunch() async throws {
        let transport = QueueTestTransport(); await transport.setOffline(true)
        let (queue, profile, credential, directory, defaults) = try fixture(transport: transport)
        let original = prompt()
        try queue.enqueue(original)
        let restored = BYOTDurableQueue(profile: profile, route: queue.route, defaults: defaults, directory: directory, credential: credential, transport: transport)
        XCTAssertEqual(restored.entries.map(\.prompt), [original])
        XCTAssertEqual(restored.entries.first?.state, "local")
        let envelope = try BYOTQueueEnvelope.decrypt(XCTUnwrap(restored.entries.first?.ciphertext), key: credential.routeKey)
        XCTAssertEqual(envelope.prompt, original)
        XCTAssertEqual(envelope.route, queue.route)
        await queue.sync()
        XCTAssertFalse(queue.entries[0].uploaded)
    }
    func testDiskFailureDoesNotAcceptOrClearPrompt() throws {
        let transport = QueueTestTransport()
        let (queue, profile, credential, directory, defaults) = try fixture(transport: transport)
        try Data("not a directory".utf8).write(to: directory)
        let blocked = BYOTDurableQueue(profile: profile, route: queue.route, defaults: defaults, directory: directory, credential: credential, transport: transport)
        XCTAssertThrowsError(try blocked.enqueue(prompt()))
        XCTAssertTrue(blocked.entries.isEmpty)
    }
    func testLostCommitResponseRecoversSameIDWithoutSecondCommit() async throws {
        let transport = QueueTestTransport(); await transport.setLoseCommit(true)
        let (queue, _, _, _, _) = try fixture(transport: transport)
        let original = prompt(); try queue.enqueue(original)
        await queue.sync()
        for _ in 0..<20 { if !queue.syncing { break }; try await Task.sleep(for: .milliseconds(10)) }
        await queue.sync()
        XCTAssertEqual(queue.entries.first?.id, original.id)
        XCTAssertEqual(queue.entries.first?.state, "queued")
        let count = await transport.commitCount
        XCTAssertEqual(count, 1)
    }
    func testResumeCannotReleaseAnOlderRevisionWhileEditsAreUnsent() async throws {
        let transport = QueueTestTransport(); await transport.setOffline(true)
        let (queue, _, _, _, _) = try fixture(transport: transport)
        try queue.enqueue(prompt())
        do { try await queue.setPaused(false); XCTFail("Unsent content must block resume") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Finish syncing")) }
    }
    func testEncryptedQueueRejectsTampering() throws {
        let (queue, _, credential, _, _) = try fixture()
        let value = BYOTQueueEnvelope(version: 1, subscriptionID: credential.subscriptionID, revision: 1, route: queue.route, prompt: prompt(), references: [])
        let encrypted = try value.encrypted(key: credential.routeKey)
        var data = try XCTUnwrap(Data(base64Encoded: encrypted)); data[data.count - 1] ^= 1
        XCTAssertThrowsError(try BYOTQueueEnvelope.decrypt(data.base64EncodedString(), key: credential.routeKey))
    }
    func testLargeAttachmentsUseBoundedChunksAndRetainBytes() async throws {
        let transport = QueueTestTransport()
        let (queue, _, credential, _, _) = try fixture(transport: transport)
        let bytes = Data(repeating: 7, count: 1_000_000)
        try queue.enqueue(OpenCodeQueuedPrompt(text: "", model: nil, attachments: [.init(filename: "large.bin", mimeType: "application/octet-stream", data: bytes)]))
        await queue.sync()
        for _ in 0..<100 { if !queue.syncing { break }; try await Task.sleep(for: .milliseconds(10)) }
        let chunks = await transport.savedChunks
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 512 * 1024 })
        let decoded = try BYOTQueueEnvelope.decrypt(chunks.joined(), key: credential.routeKey)
        XCTAssertEqual(decoded.prompt.attachments.first?.data, bytes)
    }
}

actor QueueTestTransport: BYOTQueueTransport {
    private var offline = false
    private var loseCommit = false
    private var job: [String: Any]?
    private var chunks: [Int: String] = [:]
    private(set) var commitCount = 0
    var savedChunks: [String] { chunks.keys.sorted().compactMap { chunks[$0] } }
    func setOffline(_ value: Bool) { offline = value }
    func setLoseCommit(_ value: Bool) { loseCommit = value }
    func request(_ method: String, credential: BYOTPushCredential, path: String, body: Data?) async throws -> Data {
        if offline { throw URLError(.notConnectedToInternet) }
        let input = (try body.map { try JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:]
        var result: [String: Any] = ["ok": true]
        if path.isEmpty {
            result = ["jobs": job.map { [$0] } ?? [], "sessions": []]
        } else if path.contains("/chunks/") {
            let index = Int(path.components(separatedBy: "/chunks/")[1].components(separatedBy: "?")[0])!
            chunks[index] = input["content"] as? String
        } else if path.hasSuffix("/commit") {
            commitCount += 1
            job?["state"] = "queued"; job?["revision"] = input["revision"]
            job?["chunks"] = input["chunks"]; job?["digest"] = input["digest"]
            result = job!
            if loseCommit { loseCommit = false; throw URLError(.networkConnectionLost) }
        } else if method == "PUT" {
            if job == nil { job = ["id": String(path.dropFirst()), "thread": input["thread"]!, "state": "uploading", "revision": 0, "chunks": input["chunks"]!, "digest": input["digest"]!, "position": 0, "updated_at": Date().timeIntervalSince1970 * 1000] }
            result = job!
        }
        return try JSONSerialization.data(withJSONObject: result)
    }
}
