import Foundation
import Testing
@testable import byot

@Suite("Transcript loading on slow connections")
@MainActor
struct OpenCodeTranscriptLoadingTests {
    @Test(
        "Messages render before a slow status request, while sending stays disabled",
        .bug(id: "ASC-AKWY7o8vHhCEjrJIhzCg0sM")
    )
    func messagesArriveFirst() async throws {
        let service = TranscriptLoadingService(delayStatus: true)
        let store = makeStore(service)
        let load = Task { await store.start() }
        defer { store.stop() }
        try await wait { !store.messages.isEmpty }
        #expect(store.messages.first?.id == "message-1")
        #expect(!store.isLoadingTranscript)
        #expect(store.isLoading)
        #expect(!store.canSubmitPrompt)
        await service.statusGate.open()
        await load.value
        #expect(store.canSubmitPrompt)
        #expect(!store.isLoading)
    }

    @Test(
        "A transcript error is visible before auxiliary requests finish",
        .bug(id: "ASC-AKWY7o8vHhCEjrJIhzCg0sM")
    )
    func transcriptFailureArrivesFirst() async throws {
        let service = TranscriptLoadingService(delayStatus: true, failMessages: true)
        let store = makeStore(service)
        let load = Task { await store.start() }
        defer { store.stop() }
        try await wait { store.errorMessage != nil }
        #expect(!store.isLoadingTranscript)
        #expect(store.messages.isEmpty)
        #expect(store.isLoading)
        #expect(!store.canSubmitPrompt)
        await service.statusGate.open()
        await load.value
        #expect(store.errorMessage != nil)
    }

    @Test(
        "A superseded message snapshot cannot replace a newer transcript",
        .bug(id: "ASC-AKWY7o8vHhCEjrJIhzCg0sM")
    )
    func supersededSnapshot() async throws {
        let service = TranscriptLoadingService(delayFirstMessages: true)
        let store = makeStore(service)
        let first = Task { await store.refresh(showLoading: true) }
        try await wait { await service.messageGate.isWaiting }
        #expect(store.isLoadingTranscript)
        await store.refresh(showLoading: true)
        #expect(store.messages.first?.id == "message-2")
        #expect(!store.isLoadingTranscript)
        await service.messageGate.open()
        await first.value
        #expect(store.messages.first?.id == "message-2")
        #expect(!store.isLoadingTranscript)
    }

    @Test(
        "Leaving during loading clears progress and ignores late messages",
        .bug(id: "ASC-AKWY7o8vHhCEjrJIhzCg0sM")
    )
    func stopDuringLoad() async throws {
        let service = TranscriptLoadingService(delayFirstMessages: true)
        let store = makeStore(service)
        let load = Task { await store.start() }
        try await wait { await service.messageGate.isWaiting }
        store.stop()
        #expect(!store.isLoadingTranscript)
        #expect(!store.isLoading)
        await service.messageGate.open()
        await load.value
        #expect(store.messages.isEmpty)
        #expect(!store.canSubmitPrompt)
    }

    @Test(
        "Refreshing an existing transcript keeps its messages visible",
        .bug(id: "ASC-AKWY7o8vHhCEjrJIhzCg0sM")
    )
    func keepsExistingMessages() async throws {
        let service = TranscriptLoadingService()
        let store = makeStore(service)
        await store.refresh(showLoading: true)
        await service.delayNextMessages()
        let load = Task { await store.refresh(showLoading: true) }
        try await wait { await service.messageGate.isWaiting }
        #expect(store.isLoadingTranscript)
        #expect(store.messages.first?.id == "message-1")
        await service.messageGate.open()
        await load.value
        #expect(store.messages.first?.id == "message-2")
    }

    private func makeStore(_ service: TranscriptLoadingService) -> OpenCodeSessionStore {
        OpenCodeSessionStore(service: service, serverID: UUID(), session: OpenCodeSession(
            id: "session", slug: "session", projectID: "project", workspaceID: nil,
            directory: "/project", parentID: nil, summary: nil, title: "Slow connection",
            agent: nil, version: "1", time: OpenCodeSessionTime(created: 1, updated: 2, compacting: nil, archived: nil)
        ), directory: "/project")
    }

    private func wait(until predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Timed out waiting for fixture response")
    }
}

private actor TranscriptLoadingGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    var isWaiting: Bool { continuation != nil }
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

private actor TranscriptLoadingService: OpenCodeSessionServicing {
    let statusGate = TranscriptLoadingGate()
    let messageGate = TranscriptLoadingGate()
    private let delayStatus: Bool
    private let failMessages: Bool
    private var delayMessages: Bool
    private var messageCount = 0

    init(delayStatus: Bool = false, failMessages: Bool = false, delayFirstMessages: Bool = false) {
        self.delayStatus = delayStatus
        self.failMessages = failMessages
        delayMessages = delayFirstMessages
    }
    func delayNextMessages() { delayMessages = true }
    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] { [] }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] {
        messageCount += 1
        let id = "message-\(messageCount)"
        if delayMessages {
            delayMessages = false
            await messageGate.wait()
        }
        if failMessages { throw URLError(.timedOut) }
        return try JSONDecoder().decode([OpenCodeMessageEnvelope].self, from: Data("""
        [{"info":{"id":"\(id)","sessionID":"session","role":"assistant","time":{"created":1}},
          "parts":[{"id":"part-\(id)","sessionID":"session","messageID":"\(id)","type":"text","text":"Loaded message"}]}]
        """.utf8))
    }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] {
        if delayStatus { await statusGate.wait() }
        return [:]
    }
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff] { [] }
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest] { [] }
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest] { [] }
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] { [] }
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] { [] }
    func sendMessage(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String, attachments: [OpenCodePromptAttachment], promptID: UUID) async throws {}
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool { true }
    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?, reply: OpenCodePermissionReply) async throws {}
    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws {}
    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?) async throws {}
    nonisolated func events(directory: String, workspace: String?) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { _ in }
    }
}
