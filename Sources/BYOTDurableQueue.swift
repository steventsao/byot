import Foundation
import CryptoKit
import Combine

struct BYOTQueueJob: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let thread: String
    let state: String
    let revision: Int
    let chunks: Int
    let digest: String
    let position: Int
    let updated_at: Double
    var editable: Bool { state == "queued" || state == "uploading" }
    var terminal: Bool { state == "completed" || state == "cancelled" }
}
struct BYOTQueueSnapshot: Codable, Sendable {
    struct Session: Codable, Sendable { let thread: String; let paused: Int }
    let jobs: [BYOTQueueJob]
    let sessions: [Session]
}
struct BYOTQueueEnvelope: Codable, Sendable {
    struct Reference: Codable, Sendable { let uri: String; let name: String; let mime: String }
    let version: Int
    let subscriptionID: UUID
    let revision: Int
    let route: BYOTPushRoute
    let prompt: OpenCodeQueuedPrompt
    let references: [Reference]
    func encrypted(key: String) throws -> String {
        guard let key = Data(base64Encoded: key), key.count == 32 else { throw BYOTQueueError.message("Pair your computer again.") }
        return try AES.GCM.seal(JSONEncoder().encode(self), using: SymmetricKey(data: key)).combined!.base64EncodedString()
    }
    static func decrypt(_ text: String, key: String) throws -> Self {
        guard let key = Data(base64Encoded: key), let data = Data(base64Encoded: text), key.count == 32 else { throw BYOTQueueError.message("Couldn’t read this queued message.") }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key))
        return try JSONDecoder().decode(Self.self, from: clear)
    }
}
enum BYOTQueueError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}
struct BYOTQueueEntry: Codable, Identifiable, Equatable, Sendable {
    var prompt: OpenCodeQueuedPrompt
    var ciphertext: String
    var revision: Int
    var uploaded = false
    var remote: BYOTQueueJob?
    var id: UUID { prompt.id }
    var state: String { uploaded ? remote?.state ?? "queued" : "local" }
    var title: String {
        switch state {
        case "local": "Saved on this iPhone"
        case "uploading": "Uploading to queue"
        case "queued": "Accepted for computer"
        case "claimed": "Starting on computer"
        case "submitted": "Running on computer"
        case "completed": "Completed"
        case "needsReview": "Needs review · won’t resend"
        case "cancelled": "Cancelled"
        default: "Waiting"
        }
    }
}

protocol BYOTQueueTransport: Sendable {
    func request(_ method: String, credential: BYOTPushCredential, path: String, body: Data?) async throws -> Data
}
struct BYOTQueueHTTP: BYOTQueueTransport {
    func request(_ method: String, credential: BYOTPushCredential, path: String, body: Data? = nil) async throws -> Data {
        let base = BYOTPushClient.baseURL.appending(path: "v1/subscriptions/\(credential.subscriptionID.uuidString.lowercased())/queue")
        guard let url = URL(string: base.absoluteString + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(credential.ownerKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral, delegate: BYOTQueueRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 600_000 else { throw BYOTQueueError.message("The queue returned an invalid response.") }
            data.append(byte)
        }
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if method == "DELETE", response.statusCode == 404 { return Data() }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 409 { throw BYOTQueueError.message("The queue changed or this message already started. Refresh before changing it.") }
            if response.statusCode == 403 || response.statusCode == 404 { throw BYOTQueueError.message("Reconnect the companion in Notifications settings. Your unsent messages are saved here.") }
            throw BYOTQueueError.message("Couldn’t reach the queue. Unsent messages remain saved on this iPhone.")
        }
        return data
    }
}
private final class BYOTQueueRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// The disk outbox is written before the composer clears. Uploads are idempotent;
/// only the computer claims jobs, and a claimed job is never resent by the phone.
@MainActor final class BYOTDurableQueue: ObservableObject {
    @Published private(set) var entries: [BYOTQueueEntry] = []
    @Published private(set) var enabled: Bool
    @Published private(set) var paused = false
    @Published private(set) var syncing = false
    @Published var error: String?
    let profile: OpenCodeServerProfile
    let route: BYOTPushRoute
    private let transport: any BYOTQueueTransport
    private let defaults: UserDefaults
    private let file: URL
    private var timer: Task<Void, Never>?
    private var restoreFailed = false
    private var credentialOverride: BYOTPushCredential?
    private var settingKey: String { "byot.queue.enabled.\(profile.id)" }
    var pending: [BYOTQueueEntry] { entries.filter { !["completed", "cancelled"].contains($0.state) } }
    var credential: BYOTPushCredential? {
        let value = credentialOverride ?? BYOTPushNotifications.shared.credentials[profile.id]
        return value?.fingerprint == BYOTPushCredential.fingerprint(profile) ? value : nil
    }
    init(profile: OpenCodeServerProfile, route: BYOTPushRoute, defaults: UserDefaults = .standard,
         directory: URL? = nil, credential: BYOTPushCredential? = nil,
         transport: any BYOTQueueTransport = BYOTQueueHTTP()) {
        self.profile = profile; self.route = route; self.defaults = defaults; self.transport = transport
        credentialOverride = credential
        enabled = defaults.bool(forKey: "byot.queue.enabled.\(profile.id)")
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "PromptQueues")
        file = directory.appending(path: BYOTPushCredential.digest("\(profile.id):\(route.sessionID)") + ".json")
        do {
            if FileManager.default.fileExists(atPath: file.path) { entries = try JSONDecoder().decode([BYOTQueueEntry].self, from: Data(contentsOf: file)) }
        } catch { self.restoreFailed = true; self.error = "Couldn’t restore saved messages. The saved queue has been kept for recovery." }
    }
    deinit { timer?.cancel() }
    func start() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    func stop() { timer?.cancel(); timer = nil }
    func enable() async throws {
        guard credential != nil else { throw BYOTQueueError.message("Set up the computer companion in this server’s Notifications settings first.") }
        if credentialOverride == nil {
            try await BYOTPushNotifications.shared.refresh(profile.id)
            guard BYOTPushNotifications.shared.preferences[profile.id]?.queueVersion == 1 else {
                throw BYOTQueueError.message("Update the computer companion using the setup command in Notifications settings, then check again.")
            }
        }
        enabled = true; defaults.set(true, forKey: settingKey)
        await sync()
    }
    func disable() throws {
        guard pending.isEmpty else { throw BYOTQueueError.message("Finish or cancel pending messages before switching back to the phone queue.") }
        enabled = false; defaults.set(false, forKey: settingKey)
    }
    func enqueue(_ prompt: OpenCodeQueuedPrompt) throws {
        guard let credential else { throw BYOTQueueError.message("Reconnect the computer companion before queueing messages.") }
        guard pending.count < 20 else { throw BYOTQueueError.message("This queue has 20 pending messages. Wait or remove one before adding another.") }
        try OpenCodePromptAttachment.validate(prompt.attachments)
        let envelope = makeEnvelope(prompt, revision: 1, credential: credential)
        let entry = BYOTQueueEntry(prompt: prompt, ciphertext: try envelope.encrypted(key: credential.routeKey), revision: 1)
        guard entry.ciphertext.utf8.count <= 80 * 512 * 1024 else { throw BYOTQueueError.message("This message is too large to queue.") }
        var next = entries; next.append(entry)
        try persist(next); entries = next
        Task { await sync() }
    }
    private func makeEnvelope(_ prompt: OpenCodeQueuedPrompt, revision: Int, credential: BYOTPushCredential) -> BYOTQueueEnvelope {
        BYOTQueueEnvelope(version: 1, subscriptionID: credential.subscriptionID, revision: revision, route: route, prompt: prompt,
            references: prompt.remoteReferences.map { .init(uri: $0.fileURL, name: $0.filename, mime: $0.mimeType) })
    }
    private func persist(_ values: [BYOTQueueEntry]) throws {
        guard !restoreFailed else { throw BYOTQueueError.message("The saved queue needs recovery before it can be changed.") }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(values)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var folder = file.deletingLastPathComponent(); try folder.setResourceValues(resource)
    }
    private func call<T: Encodable>(_ method: String, _ path: String, _ body: T) async throws -> Data {
        guard let credential else { throw BYOTQueueError.message("Reconnect the companion.") }
        return try await transport.request(method, credential: credential, path: path, body: JSONEncoder().encode(body))
    }
    private func get(_ path: String = "") async throws -> Data {
        guard let credential else { throw BYOTQueueError.message("Reconnect the companion.") }
        return try await transport.request("GET", credential: credential, path: path, body: nil)
    }
    func sync() async {
        guard !syncing, credential != nil, enabled || !entries.isEmpty else { return }
        syncing = true
        defer { syncing = false }
        do {
            try await refresh()
            // Always resume an interrupted upload with the original ciphertext and ID.
            for entry in entries where !entry.uploaded {
                try Task.checkCancellation()
                try await upload(entry)
            }
            try await refresh(); error = nil
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
    private func upload(_ entry: BYOTQueueEntry) async throws {
        guard let credential else { return }
        let envelope = try BYOTQueueEnvelope.decrypt(entry.ciphertext, key: credential.routeKey)
        guard envelope.subscriptionID == credential.subscriptionID, envelope.route == route else { throw BYOTQueueError.message("This message belongs to a previous server pairing. Cancel it and compose it again.") }
        let id = entry.id.uuidString.lowercased(), text = entry.ciphertext
        let chunkSize = 512 * 1024
        let bytes = Array(text.utf8)
        let chunks = stride(from: 0, to: bytes.count, by: chunkSize).map { String(decoding: bytes[$0..<min($0 + chunkSize, bytes.count)], as: UTF8.self) }
        guard chunks.count <= 80 else { throw BYOTQueueError.message("This message is too large to queue.") }
        struct Begin: Encodable { let thread: String; let chunks: Int; let digest: String }
        let digest = BYOTPushCredential.digest(text)
        let existing = try JSONDecoder().decode(BYOTQueueJob.self, from: await call("PUT", "/\(id)", Begin(thread: credential.thread(route.sessionID), chunks: chunks.count, digest: digest)))
        if existing.revision < entry.revision {
            for (index, content) in chunks.enumerated() {
                _ = try await call("PUT", "/\(id)/chunks/\(index)?revision=\(entry.revision)", ["content": content])
            }
            struct Commit: Encodable { let revision: Int; let chunks: Int; let digest: String }
            _ = try await call("POST", "/\(id)/commit", Commit(revision: entry.revision, chunks: chunks.count, digest: digest))
        } else if existing.revision != entry.revision || existing.digest != digest {
            throw BYOTQueueError.message("This queued message changed on the computer. Refresh before editing it.")
        }
        if let index = entries.firstIndex(where: { $0.id == entry.id && $0.revision == entry.revision }) {
            var next = entries; next[index].uploaded = true; next[index].remote = existing
            try persist(next); entries = next
        }
    }
    func refresh() async throws {
        guard let credential else { return }
        let snapshot = try JSONDecoder().decode(BYOTQueueSnapshot.self, from: await get())
        let thread = credential.thread(route.sessionID)
        paused = snapshot.sessions.first(where: { $0.thread == thread })?.paused == 1
        var next = entries
        for job in snapshot.jobs where job.thread == thread {
            if let index = next.firstIndex(where: { $0.id == job.id }) {
                next[index].remote = job
                if job.revision == next[index].revision, job.digest == BYOTPushCredential.digest(next[index].ciphertext), job.state != "uploading" { next[index].uploaded = true }
            } else if job.revision > 0 && !job.terminal {
                var ciphertext = ""
                for ordinal in 0..<job.chunks {
                    struct Chunk: Decodable { let content: String }
                    ciphertext += try JSONDecoder().decode(Chunk.self, from: await get("/\(job.id.uuidString.lowercased())/chunks/\(ordinal)?revision=\(job.revision)")).content
                }
                guard BYOTPushCredential.digest(ciphertext) == job.digest else { throw BYOTQueueError.message("Couldn’t verify the saved message.") }
                let envelope = try BYOTQueueEnvelope.decrypt(ciphertext, key: credential.routeKey)
                guard envelope.route == route, envelope.prompt.id == job.id, envelope.subscriptionID == credential.subscriptionID, envelope.revision == job.revision else { throw BYOTQueueError.message("This message belongs to another queue.") }
                next.append(BYOTQueueEntry(prompt: envelope.prompt, ciphertext: ciphertext, revision: job.revision, uploaded: true, remote: job))
            }
        }
        // Network reads above may yield while another prompt is saved. Merge against
        // the current outbox, preserving newly added or edited entries.
        var merged = entries
        for value in next {
            if let index = merged.firstIndex(where: { $0.id == value.id }) {
                if merged[index].revision == value.revision { merged[index] = value }
            } else { merged.append(value) }
        }
        next = merged
        let active = next.filter { !["completed", "cancelled"].contains($0.state) }.sorted { ($0.remote?.position ?? Int.max) < ($1.remote?.position ?? Int.max) }
        next = active + Array(next.filter { ["completed", "cancelled"].contains($0.state) }.suffix(10))
        try persist(next); entries = next
    }
    func setPaused(_ value: Bool) async throws {
        if !value, entries.contains(where: { !$0.uploaded }) { throw BYOTQueueError.message("Finish syncing saved messages and edits before resuming the queue.") }
        guard let credential else { throw BYOTQueueError.message("Reconnect the companion to pause this queue.") }
        struct Pause: Encodable { let thread: String; let paused: Bool }
        _ = try await call("PATCH", "/sessions", Pause(thread: credential.thread(route.sessionID), paused: value))
        paused = value
    }
    func cancel(_ id: UUID) async throws {
        guard !syncing else { throw BYOTQueueError.message("Wait for the queue to finish syncing.") }
        syncing = true; defer { syncing = false }
        _ = try await call("DELETE", "/\(id.uuidString.lowercased())", [String: String]())
        var next = entries; next.removeAll { $0.id == id }
        try persist(next); entries = next
        try await refresh()
    }
    func edit(_ id: UUID, text: String) async throws {
        guard !syncing else { throw BYOTQueueError.message("Wait for the queue to finish syncing.") }
        syncing = true; defer { syncing = false }
        try await setPaused(true); try await refresh()
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].remote?.state == "queued" else { throw BYOTQueueError.message("This message has already started and can’t be edited.") }
        let old = entries[index].prompt
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !old.attachments.isEmpty || !old.remoteReferences.isEmpty else { throw BYOTQueueError.message("Add text or an attachment.") }
        guard old.command == nil else { throw BYOTQueueError.message("Remove this command and compose it again to change its arguments.") }
        let prompt = OpenCodeQueuedPrompt(id: old.id, text: text, model: old.model, attachments: old.attachments, agent: old.agent, variant: old.variant, command: old.command, remoteReferences: old.remoteReferences)
        guard let credential else { return }
        var next = entries; next[index].revision += 1; next[index].prompt = prompt; next[index].uploaded = false
        next[index].ciphertext = try makeEnvelope(prompt, revision: next[index].revision, credential: credential).encrypted(key: credential.routeKey)
        try persist(next); entries = next
        try await upload(next[index]); try await refresh()
    }
    func move(_ id: UUID, offset: Int) async throws {
        guard !syncing else { throw BYOTQueueError.message("Wait for the queue to finish syncing.") }
        syncing = true; defer { syncing = false }
        try await setPaused(true); try await refresh()
        var ids = entries.filter { $0.remote?.state == "queued" }.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset), let credential else { return }
        ids.swapAt(index, index + offset)
        struct Order: Encodable { let thread: String; let ids: [String] }
        _ = try await call("PATCH", "/order", Order(thread: credential.thread(route.sessionID), ids: ids.map { $0.uuidString.lowercased() }))
        try await refresh()
    }
}
