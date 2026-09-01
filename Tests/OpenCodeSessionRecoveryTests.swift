import Foundation
import Testing
@testable import byot

@Suite("OpenCode session recovery")
struct OpenCodeSessionRecoveryTests {
    @Test(
        "An unanswered transcript keeps Stop available when status cannot load",
        .bug(id: "ASC-ANy3NA4eHNR2IR5fHp0S56U")
    )
    @MainActor
    func unknownStatusCanBeAbortedAndSettlesLocally() async {
        let harness = OpenCodeRecoveryStub.register(
            messages: Self.userOnlyMessages,
            statusCode: 500,
            statusBody: #"{"message":"Unexpected server error"}"#
        )
        defer { harness.unregister() }
        let store = makeStore(client: harness.client, sessionID: harness.sessionID)

        await store.start()
        defer { store.stop() }

        #expect(store.isStatusReady == false)
        #expect(store.canSubmitPrompt == false)
        #expect(store.canStopTurn)

        await store.stopTurn()

        #expect(harness.abortCount == 1)
        #expect(store.status == .idle)
        #expect(store.isStatusReady)
        #expect(store.canSubmitPrompt)
        #expect(store.canStopTurn == false)
    }

    @Test(
        "An idle user-only turn offers an explicit stop-and-retry path",
        .bug(id: "ASC-ANy3NA4eHNR2IR5fHp0S56U")
    )
    @MainActor
    func idleUnansweredPromptCanRetry() async {
        let harness = OpenCodeRecoveryStub.register(
            messages: Self.userOnlyMessages,
            statusCode: 200,
            statusBody: "{}"
        )
        defer { harness.unregister() }
        let store = makeStore(client: harness.client, sessionID: harness.sessionID)

        await store.start()
        defer { store.stop() }

        #expect(store.isStatusReady)
        #expect(store.canSubmitPrompt)
        #expect(store.canStopTurn == false)
        #expect(store.hasRecoverableUnansweredPrompt)
        #expect(store.canRetryUnansweredPrompt)

        let accepted = await store.retryUnansweredPrompt()
        for _ in 0..<50 where harness.promptBodies.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(accepted)
        #expect(harness.abortCount == 1)
        #expect(harness.promptBodies.count == 1)
        #expect(store.hasRecoverableUnansweredPrompt == false)
    }

    @Test("An answered idle turn does not offer recovery")
    @MainActor
    func answeredPromptDoesNotRetry() async {
        let harness = OpenCodeRecoveryStub.register(
            messages: Self.answeredMessages,
            statusCode: 200,
            statusBody: "{}"
        )
        defer { harness.unregister() }
        let store = makeStore(client: harness.client, sessionID: harness.sessionID)

        await store.start()
        defer { store.stop() }

        #expect(store.canSubmitPrompt)
        #expect(store.hasRecoverableUnansweredPrompt == false)
        #expect(store.canRetryUnansweredPrompt == false)
    }

    @Test(
        "Abort failure preserves the unknown-status escape hatch",
        .bug(id: "ASC-ANy3NA4eHNR2IR5fHp0S56U")
    )
    @MainActor
    func failedAbortCanBeRetried() async {
        let harness = OpenCodeRecoveryStub.register(
            messages: Self.userOnlyMessages,
            statusCode: 500,
            statusBody: #"{"message":"Unexpected server error"}"#,
            abortCode: 500,
            abortBody: #"{"message":"Abort failed"}"#
        )
        defer { harness.unregister() }
        let store = makeStore(client: harness.client, sessionID: harness.sessionID)

        await store.start()
        defer { store.stop() }
        await store.stopTurn()

        #expect(harness.abortCount == 1)
        #expect(store.isStatusReady == false)
        #expect(store.canSubmitPrompt == false)
        #expect(store.canStopTurn)
        #expect(store.errorMessage?.contains("Abort failed") == true)
    }

    @Test(
        "Stop settles a known busy turn even when no idle event follows",
        .bug(id: "ASC-ANy3NA4eHNR2IR5fHp0S56U")
    )
    @MainActor
    func abortSettlesBusyTurnWithoutIdleEvent() async {
        let harness = OpenCodeRecoveryStub.register(
            messages: Self.userOnlyMessages,
            statusCode: 200,
            statusBody: #"{"ses-recovery":{"type":"busy"}}"#
        )
        defer { harness.unregister() }
        let store = makeStore(client: harness.client, sessionID: harness.sessionID)

        await store.start()
        defer { store.stop() }
        #expect(store.status == .busy)
        #expect(store.canStopTurn)

        await store.stopTurn()

        #expect(store.status == .idle)
        #expect(store.canSubmitPrompt)
        #expect(store.canStopTurn == false)
    }

    @Test("A completed assistant envelope is never treated as unanswered")
    @MainActor
    func completedAssistantEnvelopeDoesNotRecover() async {
        let harness = OpenCodeRecoveryStub.register(
            messages: Self.completedAssistantWithoutParts,
            statusCode: 500,
            statusBody: #"{"message":"Unexpected server error"}"#
        )
        defer { harness.unregister() }
        let store = makeStore(client: harness.client, sessionID: harness.sessionID)

        await store.start()
        defer { store.stop() }

        #expect(store.isStatusReady == false)
        #expect(store.canStopTurn == false)
        #expect(store.canRetryUnansweredPrompt == false)
    }

    @Test("A later status failure exposes recovery after a known idle state")
    @MainActor
    func laterStatusFailureDisablesSubmitAndExposesStop() async {
        let harness = OpenCodeRecoveryStub.register(
            messages: Self.userOnlyMessages,
            statusCode: 200,
            statusBody: "{}"
        )
        defer { harness.unregister() }
        let store = makeStore(client: harness.client, sessionID: harness.sessionID)

        await store.start()
        defer { store.stop() }
        #expect(store.isStatusReady)

        harness.updateStatus(
            code: 500,
            body: #"{"message":"Unexpected server error"}"#
        )
        await store.refresh()

        #expect(store.isStatusReady == false)
        #expect(store.canSubmitPrompt == false)
        #expect(store.canStopTurn)
        #expect(store.canRetryUnansweredPrompt == false)
    }

    @Test("Abort false keeps the turn recoverable instead of claiming success")
    @MainActor
    func abortFalseDoesNotSettle() async {
        let harness = OpenCodeRecoveryStub.register(
            messages: Self.userOnlyMessages,
            statusCode: 200,
            statusBody: #"{"ses-recovery":{"type":"busy"}}"#,
            abortBody: "false"
        )
        defer { harness.unregister() }
        let store = makeStore(client: harness.client, sessionID: harness.sessionID)

        await store.start()
        defer { store.stop() }
        await store.stopTurn()

        #expect(harness.abortCount == 1)
        #expect(store.status == .busy)
        #expect(store.canStopTurn)
        #expect(store.errorMessage?.contains("did not confirm") == true)
    }

    @Test("Session error invalidates a dispatch and pauses its follow-up")
    @MainActor
    func sessionErrorSettlesInFlightDispatch() async {
        let harness = OpenCodeRecoveryStub.register(
            messages: Self.userOnlyMessages,
            statusCode: 200,
            statusBody: "{}"
        )
        defer { harness.unregister() }
        let store = makeStore(client: harness.client, sessionID: harness.sessionID)

        await store.start()
        defer { store.stop() }
        #expect(store.send("Start a fresh turn"))
        #expect(store.send("Queued follow-up"))
        #expect(store.isSending)

        store.handle(
            OpenCodeEvent(
                id: "evt-error",
                type: "session.error",
                properties: [
                    "sessionID": .string(harness.sessionID),
                    "error": .object([
                        "name": .string("ProviderError"),
                        "data": .object(["message": .string("Provider failed")]),
                    ]),
                ]
            )
        )
        await Task.yield()

        #expect(store.status == .idle)
        #expect(store.isStatusReady)
        #expect(store.isSending == false)
        #expect(store.queuedPrompts.map(\.text) == ["Queued follow-up"])
        #expect(store.canRetryFirstQueuedPrompt)
        #expect(store.errorMessage == "Provider failed")
    }

    @MainActor
    private func makeStore(
        client: OpenCodeClient,
        sessionID: String
    ) -> OpenCodeSessionStore {
        OpenCodeSessionStore(
            client: client,
            session: OpenCodeSession(
                id: sessionID,
                slug: sessionID,
                projectID: "project",
                workspaceID: nil,
                directory: "/repo",
                parentID: nil,
                summary: nil,
                title: "Recovery test",
                agent: nil,
                version: "1.18.10",
                time: OpenCodeSessionTime(
                    created: 0,
                    updated: 1,
                    compacting: nil,
                    archived: nil
                )
            ),
            directory: "/repo",
            defaults: UserDefaults(
                suiteName: "opencode-recovery-\(UUID().uuidString)"
            ) ?? .standard
        )
    }

    private static let userOnlyMessages = #"""
        [
        {
          "info": {
            "id": "msg-user",
            "sessionID": "ses-recovery",
            "role": "user",
            "time": { "created": 1 }
          },
          "parts": [
            {
              "id": "part-user",
              "sessionID": "ses-recovery",
              "messageID": "msg-user",
              "type": "text",
              "text": "Find accessible PDF labeling tools"
            }
          ]
        }
        ]
        """#

    private static let answeredMessages = #"""
        [
        {
          "info": {
            "id": "msg-user",
            "sessionID": "ses-recovery",
            "role": "user",
            "time": { "created": 1 }
          },
          "parts": [
            {
              "id": "part-user",
              "sessionID": "ses-recovery",
              "messageID": "msg-user",
              "type": "text",
              "text": "Find accessible PDF labeling tools"
            }
          ]
        },
        {
          "info": {
            "id": "msg-assistant",
            "sessionID": "ses-recovery",
            "role": "assistant",
            "time": { "created": 2, "completed": 3 },
            "finish": "stop"
          },
          "parts": [
            {
              "id": "part-assistant",
              "sessionID": "ses-recovery",
              "messageID": "msg-assistant",
              "type": "text",
              "text": "Here are the options."
            }
          ]
        }
        ]
        """#

    private static let completedAssistantWithoutParts = #"""
        [
          {
            "info": {
              "id": "msg-user",
              "sessionID": "ses-recovery",
              "role": "user",
              "time": { "created": 1 }
            },
            "parts": [
              {
                "id": "part-user",
                "sessionID": "ses-recovery",
                "messageID": "msg-user",
                "type": "text",
                "text": "Find accessible PDF labeling tools"
              }
            ]
          },
          {
            "info": {
              "id": "msg-assistant",
              "sessionID": "ses-recovery",
              "role": "assistant",
              "time": { "created": 2, "completed": 3 },
              "finish": "stop"
            },
            "parts": []
          }
        ]
        """#
}

private struct OpenCodeRecoveryHarness: Sendable {
    let host: String
    let sessionID = "ses-recovery"

    var client: OpenCodeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeRecoveryStub.self]
        return OpenCodeClient(
            profile: OpenCodeServerProfile(
                id: UUID(),
                name: "Recovery stub",
                baseURL: "https://\(host)",
                username: "opencode"
            ),
            password: "test-secret",
            session: URLSession(configuration: configuration)
        )
    }

    var abortCount: Int {
        OpenCodeRecoveryStub.abortCount(host: host)
    }

    var promptBodies: [Data] {
        OpenCodeRecoveryStub.promptBodies(host: host)
    }

    func updateStatus(code: Int, body: String) {
        OpenCodeRecoveryStub.updateStatus(host: host, code: code, body: body)
    }

    func unregister() {
        OpenCodeRecoveryStub.unregister(host: host)
    }
}

private final class OpenCodeRecoveryStub: URLProtocol, @unchecked Sendable {
    private struct Scenario: Sendable {
        let messages: Data
        var statusCode: Int
        var statusBody: Data
        let abortCode: Int
        let abortBody: Data
        var abortCount = 0
        var promptBodies: [Data] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var scenarios: [String: Scenario] = [:]

    static func register(
        messages: String,
        statusCode: Int,
        statusBody: String,
        abortCode: Int = 200,
        abortBody: String = "true"
    ) -> OpenCodeRecoveryHarness {
        let host = "opencode-recovery-\(UUID().uuidString).example.test"
        lock.lock()
        scenarios[host] = Scenario(
            messages: Data(messages.utf8),
            statusCode: statusCode,
            statusBody: Data(statusBody.utf8),
            abortCode: abortCode,
            abortBody: Data(abortBody.utf8)
        )
        lock.unlock()
        return OpenCodeRecoveryHarness(host: host)
    }

    static func unregister(host: String) {
        lock.lock()
        scenarios.removeValue(forKey: host)
        lock.unlock()
    }

    static func updateStatus(host: String, code: Int, body: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var scenario = scenarios[host] else { return }
        scenario.statusCode = code
        scenario.statusBody = Data(body.utf8)
        scenarios[host] = scenario
    }

    static func abortCount(host: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return scenarios[host]?.abortCount ?? 0
    }

    static func promptBodies(host: String) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return scenarios[host]?.promptBodies ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        lock.lock()
        defer { lock.unlock() }
        return scenarios[host] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let host = url.host,
              let response = Self.stubbedResponse(for: request, host: host)
        else { return }

        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": response.contentType]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }

    private static func stubbedResponse(
        for request: URLRequest,
        host: String
    ) -> (statusCode: Int, body: Data, contentType: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard var scenario = scenarios[host], let path = request.url?.path else { return nil }

        let response: (Int, Data, String)
        switch true {
        case path == "/session/status":
            response = (scenario.statusCode, scenario.statusBody, "application/json")
        case path.hasSuffix("/message"):
            response = (200, scenario.messages, "application/json")
        case path.hasSuffix("/diff"):
            response = (200, Data("[]".utf8), "application/json")
        case path.hasSuffix("/abort"):
            scenario.abortCount += 1
            response = (scenario.abortCode, scenario.abortBody, "application/json")
        case path.hasSuffix("/prompt_async"):
            if let body = requestBody(request) {
                scenario.promptBodies.append(body)
            }
            response = (200, Data("true".utf8), "application/json")
        case path == "/permission" || path == "/question":
            response = (200, Data("[]".utf8), "application/json")
        case path == "/provider":
            response = (
                200,
                Data(#"{"all":[],"connected":[],"default":{}}"#.utf8),
                "application/json"
            )
        default:
            response = (404, Data(#"{"message":"not found"}"#.utf8), "application/json")
        }
        scenarios[host] = scenario
        return response
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 16_384
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
