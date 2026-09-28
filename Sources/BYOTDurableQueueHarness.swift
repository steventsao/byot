#if DEBUG
import SwiftUI

struct BYOTDurableQueueHarness: View {
    @StateObject private var queue: BYOTDurableQueue
    init() {
        let profile = OpenCodeServerProfile(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, name: "Mac mini", baseURL: "https://queue-fixture.example", directory: "/project")
        let credential = BYOTPushCredential(subscriptionID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!, serverID: profile.id, fingerprint: BYOTPushCredential.fingerprint(profile), ownerKey: "fixture", routeKey: Data(repeating: 9, count: 32).base64EncodedString())
        let defaults = UserDefaults(suiteName: "byot-queue-fixture")!
        defaults.set(true, forKey: "byot.queue.enabled.\(profile.id)")
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "QueueUIFixture")
        if ProcessInfo.processInfo.arguments.contains("--reset-queue-fixture") { try? FileManager.default.removeItem(at: directory) }
        let queue = BYOTDurableQueue(profile: profile, route: BYOTPushRoute(serverID: profile.id, sessionID: "ses_queue", directory: "/project", workspace: nil), defaults: defaults, directory: directory, credential: credential, transport: BYOTQueueOfflineFixture())
        if queue.entries.isEmpty {
            try? queue.enqueue(OpenCodeQueuedPrompt(text: "Implement the account settings screen", model: nil, agent: "build"))
            try? queue.enqueue(OpenCodeQueuedPrompt(text: "Then run the tests and fix any failures", model: nil, agent: "build"))
        }
        _queue = StateObject(wrappedValue: queue)
    }
    var body: some View { BYOTDurableQueueView(queue: queue) }
}
private struct BYOTQueueOfflineFixture: BYOTQueueTransport {
    func request(_ method: String, credential: BYOTPushCredential, path: String, body: Data?) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
}
#endif
