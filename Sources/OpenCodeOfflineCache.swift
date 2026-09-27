import CryptoKit
import Foundation

/// The session list last loaded from a server, as saved on this device.
struct OpenCodeCachedSessionList: Codable, Equatable, Sendable {
    struct Group: Codable, Equatable, Sendable {
        let project: OpenCodeProject
        let sessions: [OpenCodeSession]
    }

    var version = OpenCodeOfflineCache.formatVersion
    var savedAt: Date
    var fingerprint: String
    var groups: [Group]
}

/// The most recent messages of one session, as saved on this device.
struct OpenCodeCachedTranscript: Codable, Equatable, Sendable {
    var version = OpenCodeOfflineCache.formatVersion
    var savedAt: Date
    var fingerprint: String
    var sessionID: String
    var messages: [OpenCodeMessageEnvelope]
    /// Older messages were left out to stay within the size limits.
    var isTruncated: Bool
}

/// Describes a saved transcript while a session shows it in place of the server's.
struct OpenCodeOfflineTranscriptInfo: Equatable, Sendable {
    let savedAt: Date
    let isTruncated: Bool
}

/// Last-known session lists and recent transcripts for each server, kept on this
/// device so the app opens instantly and still shows something useful while a
/// server is unreachable. The server stays the source of truth: every successful
/// load replaces what is saved here, and removing a server deletes its folder.
///
/// Writes run in order on one serial queue, so an older snapshot can never land
/// after a newer one. Reads of a transcript wait behind pending writes.
final class OpenCodeOfflineCache: Sendable {
    struct Limits: Sendable {
        var projects = 50
        var sessionsPerProject = 200
        var transcriptsPerServer = 30
        var messagesPerTranscript = 300
        var bytesPerTranscript = 2 * 1024 * 1024
        /// Shared by every server's transcripts; least recently used go first.
        var transcriptBytes = 40 * 1024 * 1024
    }

    static let formatVersion = 1

    /// `nil` in unit tests and UI fixtures, which bring their own data and must
    /// never read or write what a real launch saved.
    static let shared: OpenCodeOfflineCache? = {
        let process = ProcessInfo.processInfo
        if process.environment["XCTestConfigurationFilePath"] != nil { return nil }
#if DEBUG
        // Every fixture launch flag starts with `--`.
        if process.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { return nil }
#endif
        return OpenCodeOfflineCache(root: defaultRoot)
    }()

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OfflineCache")
    }

    let root: URL
    let limits: Limits
    private let queue = DispatchQueue(label: "app.byot.offline-cache", qos: .utility)

    init(root: URL, limits: Limits = Limits()) {
        self.root = root
        self.limits = limits
    }

    /// Identifies what a server profile points at. Editing the address, user or
    /// working directory makes older snapshots unusable; the password does not.
    static func fingerprint(of profile: OpenCodeServerProfile) -> String {
        let parts = [
            profile.normalizedURL?.absoluteString ?? profile.baseURL,
            profile.username.trimmingCharacters(in: .whitespacesAndNewlines),
            profile.normalizedDirectory ?? "",
        ]
        return digest(parts.map { "\($0.utf8.count):\($0)" }.joined())
    }

    // MARK: Session lists

    /// Synchronous so the first frame can already show the list. The file is small
    /// and bounded by `Limits.projects` and `Limits.sessionsPerProject`.
    func sessionList(serverID: UUID, fingerprint: String) -> OpenCodeCachedSessionList? {
        guard let list: OpenCodeCachedSessionList = read(sessionListURL(serverID)),
              list.version == Self.formatVersion, list.fingerprint == fingerprint
        else { return nil }
        return list
    }

    func saveSessionList(_ groups: [OpenCodeCachedSessionList.Group], serverID: UUID, fingerprint: String,
                         savedAt: Date = Date()) {
        let limits = limits
        let bounded = groups.prefix(limits.projects).map { group in
            OpenCodeCachedSessionList.Group(
                project: group.project,
                sessions: Array(group.sessions.sorted { $0.time.updated > $1.time.updated }
                    .prefix(limits.sessionsPerProject)))
        }
        let list = OpenCodeCachedSessionList(savedAt: savedAt, fingerprint: fingerprint, groups: bounded)
        let url = sessionListURL(serverID)
        queue.async { [self] in
            guard let data = try? JSONEncoder().encode(list) else { return }
            write(data, to: url)
        }
    }

    // MARK: Transcripts

    func transcript(serverID: UUID, fingerprint: String, sessionID: String, directory: String,
                    workspace: String?) async -> OpenCodeCachedTranscript? {
        let url = transcriptURL(serverID: serverID, sessionID: sessionID, directory: directory, workspace: workspace)
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let transcript: OpenCodeCachedTranscript = read(url),
                      transcript.version == Self.formatVersion,
                      transcript.fingerprint == fingerprint, transcript.sessionID == sessionID
                else { return continuation.resume(returning: nil) }
                // Reading counts as use, so an open session is the last to be evicted.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
                continuation.resume(returning: transcript)
            }
        }
    }

    func saveTranscript(_ messages: [OpenCodeMessageEnvelope], serverID: UUID, fingerprint: String,
                        sessionID: String, directory: String, workspace: String?, savedAt: Date = Date()) {
        let url = transcriptURL(serverID: serverID, sessionID: sessionID, directory: directory, workspace: workspace)
        let limits = limits
        queue.async { [self] in
            guard let data = Self.encodeTranscript(messages, limits: limits, savedAt: savedAt,
                                                   fingerprint: fingerprint, sessionID: sessionID)
            else {
                // Too large to keep even one message: an older copy would only mislead.
                try? FileManager.default.removeItem(at: url)
                return
            }
            write(data, to: url)
            evictTranscripts()
        }
    }

    func removeTranscript(serverID: UUID, sessionID: String, directory: String, workspace: String?) {
        let url = transcriptURL(serverID: serverID, sessionID: sessionID, directory: directory, workspace: workspace)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: Servers

    func removeServer(_ serverID: UUID) {
        let url = serverURL(serverID)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Deletes folders of servers that no longer exist, for example after a removal
    /// that happened while a write was still queued.
    func retainServers(_ serverIDs: some Sequence<UUID>) {
        let keep = Set(serverIDs.map(\.uuidString))
        let root = root
        queue.async {
            let folders = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for folder in folders where !keep.contains(folder.lastPathComponent) {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    /// Waits until every write queued so far is on disk.
    func flush() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    // MARK: Bounds

    /// Keeps the newest messages. Starts at a prompt where one is kept, so the saved
    /// transcript never opens partway through a reply.
    nonisolated static func encodeTranscript(
        _ messages: [OpenCodeMessageEnvelope], limits: Limits, savedAt: Date, fingerprint: String, sessionID: String
    ) -> Data? {
        var kept = Array(messages.suffix(limits.messagesPerTranscript))
        while true {
            if kept.count < messages.count, kept.count > 1,
               let prompt = kept.firstIndex(where: { $0.info.role == "user" }), prompt > 0 {
                kept.removeFirst(prompt)
            }
            let transcript = OpenCodeCachedTranscript(
                savedAt: savedAt, fingerprint: fingerprint, sessionID: sessionID,
                messages: kept, isTruncated: kept.count < messages.count)
            guard let data = try? JSONEncoder().encode(transcript) else { return nil }
            if data.count <= limits.bytesPerTranscript { return data }
            guard kept.count > 1 else { return nil }
            kept = Array(kept.suffix(kept.count / 2))
        }
    }

    /// Reads modification dates and sizes of this app's own files only
    /// (privacy manifest reason C617.1).
    private func evictTranscripts() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var retained: [(url: URL, date: Date, size: Int)] = []
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: folder.appending(path: "transcripts"), includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])) ?? []
            let entries = files.map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url: url, date: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0)
            }.sorted { $0.date > $1.date }
            for entry in entries.dropFirst(limits.transcriptsPerServer) {
                try? FileManager.default.removeItem(at: entry.url)
            }
            retained += entries.prefix(limits.transcriptsPerServer)
        }
        var total = 0
        for entry in retained.sorted(by: { $0.date > $1.date }) {
            total += entry.size
            if total > limits.transcriptBytes { try? FileManager.default.removeItem(at: entry.url) }
        }
    }

    // MARK: Files

    private func serverURL(_ serverID: UUID) -> URL { root.appending(path: serverID.uuidString) }

    private func sessionListURL(_ serverID: UUID) -> URL { serverURL(serverID).appending(path: "sessions.json") }

    private func transcriptURL(serverID: UUID, sessionID: String, directory: String, workspace: String?) -> URL {
        // Encode components before hashing so delimiters in remote paths cannot collide.
        let context = [sessionID, directory, workspace].map { value in
            value.map { "\($0.utf8.count):\($0)" } ?? "nil"
        }.joined()
        return serverURL(serverID).appending(path: "transcripts").appending(path: "\(Self.digest(context)).json")
    }

    private func read<Value: Decodable>(_ url: URL) -> Value? {
        // A missing, locked or older-format file is simply a cache miss.
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func write(_ data: Data, to url: URL) {
        do {
            let folder = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var root = root
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try? root.setResourceValues(resources)
            // Transcripts can quote code and secrets. Keep them unreadable while locked.
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            // Best effort: a failed write leaves the previous snapshot, or none.
        }
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One server's slice of the cache, as the stores use it.
struct OpenCodeOfflineCacheScope: Sendable {
    let cache: OpenCodeOfflineCache
    let serverID: UUID
    let fingerprint: String

    init(cache: OpenCodeOfflineCache, profile: OpenCodeServerProfile) {
        self.cache = cache
        serverID = profile.id
        fingerprint = OpenCodeOfflineCache.fingerprint(of: profile)
    }

    func sessionList() -> OpenCodeCachedSessionList? {
        cache.sessionList(serverID: serverID, fingerprint: fingerprint)
    }

    func saveSessionList(_ groups: [OpenCodeCachedSessionList.Group]) {
        cache.saveSessionList(groups, serverID: serverID, fingerprint: fingerprint)
    }

    func transcript(sessionID: String, directory: String, workspace: String?) async -> OpenCodeCachedTranscript? {
        await cache.transcript(serverID: serverID, fingerprint: fingerprint, sessionID: sessionID,
                               directory: directory, workspace: workspace)
    }

    func saveTranscript(_ messages: [OpenCodeMessageEnvelope], sessionID: String, directory: String, workspace: String?) {
        cache.saveTranscript(messages, serverID: serverID, fingerprint: fingerprint, sessionID: sessionID,
                             directory: directory, workspace: workspace)
    }

    func removeTranscript(sessionID: String, directory: String, workspace: String?) {
        cache.removeTranscript(serverID: serverID, sessionID: sessionID, directory: directory, workspace: workspace)
    }
}
