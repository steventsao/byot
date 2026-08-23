import Foundation
import XCTest
@testable import byot

final class OpenCodeV2ContractTests: XCTestCase {
    override func tearDown() {
        OpenCodeV2URLProtocolStub.reset()
        super.tearDown()
    }

    func testSessionListPaginatesNormalizesAndFiltersChildSessions() async throws {
        let (client, session) = makeClient { request in
            let query = v2QueryValues(for: request)
            if query["cursor"] == "next-page" {
                return .json(
                    #"{"data":[{"id":"ses_2","projectID":"proj_1","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":30,"updated":40},"title":"Second","location":{"directory":"/repo","workspaceID":"wrk_1"}}],"cursor":{}}"#
                )
            }
            return .json(
                #"{"data":[{"id":"ses_1","projectID":"proj_1","agent":"build","cost":0,"tokens":{"input":1,"output":2,"reasoning":3,"cache":{"read":4,"write":5}},"time":{"created":10,"updated":20},"title":"First","location":{"directory":"/repo","workspaceID":"wrk_1"}},{"id":"ses_child","parentID":"ses_1","projectID":"proj_1","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":11,"updated":12},"title":"Child","location":{"directory":"/repo"}}],"cursor":{"next":"next-page"}}"#
            )
        }
        defer { session.invalidateAndCancel() }

        let sessions = try await client.listSessions(directory: "/repo")

        XCTAssertEqual(sessions.map(\.id), ["ses_1", "ses_2"])
        XCTAssertEqual(sessions.first?.directory, "/repo")
        XCTAssertEqual(sessions.first?.workspaceID, "wrk_1")
        XCTAssertEqual(sessions.first?.agent, "build")
        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/session", "/api/session"])
        XCTAssertEqual(v2QueryValues(for: requests[0])["directory"], "/repo")
        XCTAssertEqual(v2QueryValues(for: requests[0])["limit"], "100")
        XCTAssertEqual(v2QueryValues(for: requests[0])["order"], "desc")
        XCTAssertEqual(v2QueryValues(for: requests[1])["cursor"], "next-page")
    }

    func testSessionCreationUsesLocationAndNormalizesDataEnvelope() async throws {
        let (client, session) = makeClient { _ in
            .json(
                #"{"data":{"id":"ses_new","projectID":"proj_1","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":10,"updated":10},"title":"New session","location":{"directory":"/repo","workspaceID":"wrk_1"}}}"#
            )
        }
        defer { session.invalidateAndCancel() }

        let created = try await client.createSession(directory: "/repo", title: "Ignored by v2")

        XCTAssertEqual(created.id, "ses_new")
        XCTAssertEqual(created.directory, "/repo")
        let request = try XCTUnwrap(OpenCodeV2URLProtocolStub.recordedRequests().first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/session")
        let body = try v2JSONObject(for: request)
        let location = try XCTUnwrap(body["location"] as? [String: Any])
        XCTAssertEqual(location["directory"] as? String, "/repo")
        XCTAssertNil(body["title"])
    }

    func testMessageListPaginatesAndNormalizesProjectedContent() async throws {
        let (client, session) = makeClient { request in
            let query = v2QueryValues(for: request)
            if query["cursor"] == "messages-2" {
                return .json(
                    #"{"data":[{"id":"msg_a","time":{"created":2,"completed":3},"type":"assistant","agent":"build","model":{"id":"gpt-5","providerID":"openai"},"content":[{"type":"text","id":"txt_1","text":"Done"},{"type":"reasoning","id":"rsn_1","text":"Checked"},{"type":"tool","id":"tool_1","name":"bash","state":{"status":"completed","input":{"command":"pwd"},"content":[],"structured":{},"result":"/repo"},"time":{"created":2,"completed":3}}]}],"cursor":{}}"#
                )
            }
            return .json(
                #"{"data":[{"id":"msg_u","time":{"created":1},"text":"Hello","type":"user"}],"cursor":{"next":"messages-2"}}"#
            )
        }
        defer { session.invalidateAndCancel() }

        let messages = try await client.messages(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )

        XCTAssertEqual(messages.map(\.info.role), ["user", "assistant"])
        XCTAssertEqual(messages[0].parts.map(\.text), ["Hello"])
        XCTAssertEqual(messages[1].info.providerID, "openai")
        XCTAssertEqual(messages[1].info.modelID, "gpt-5")
        XCTAssertEqual(messages[1].parts.map(\.type), ["text", "reasoning", "tool"])
        XCTAssertEqual(messages[1].parts.last?.state?.input?["command"], .string("pwd"))
        XCTAssertEqual(messages[1].parts.last?.state?.output, "/repo")
        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/session/ses_1/message",
            "/api/session/ses_1/message",
        ])
        XCTAssertEqual(v2QueryValues(for: requests[1])["cursor"], "messages-2")
    }

    func testPromptSwitchesModelThenUsesV2AdmissionBody() async throws {
        let (client, session) = makeClient { request in
            if request.url?.path.hasSuffix("/model") == true {
                return .empty(statusCode: 204)
            }
            return .json(
                #"{"data":{"admittedSeq":1,"id":"msg_new","sessionID":"ses_1","prompt":{"text":"Ship it"},"delivery":"queue","timeCreated":1}}"#
            )
        }
        defer { session.invalidateAndCancel() }
        let model = OpenCodeModelOption(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5",
            modelName: "GPT-5",
            status: "active"
        )
        let attachment = OpenCodePromptAttachment(
            filename: "notes.txt",
            mimeType: "text/plain",
            data: Data("hello".utf8)
        )

        try await client.sendMessage(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1",
            model: model,
            text: "Ship it",
            attachments: [attachment]
        )

        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/session/ses_1/model",
            "/api/session/ses_1/prompt",
        ])
        let modelBody = try v2JSONObject(for: requests[0])
        let modelReference = try XCTUnwrap(modelBody["model"] as? [String: Any])
        XCTAssertEqual(modelReference["id"] as? String, "gpt-5")
        XCTAssertEqual(modelReference["providerID"] as? String, "openai")
        let admission = try v2JSONObject(for: requests[1])
        XCTAssertEqual(Set(admission.keys), ["prompt", "delivery"])
        XCTAssertEqual(admission["delivery"] as? String, "queue")
        let prompt = try XCTUnwrap(admission["prompt"] as? [String: Any])
        XCTAssertEqual(prompt["text"] as? String, "Ship it")
        let files = try XCTUnwrap(prompt["files"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0]["name"] as? String, "notes.txt")
        XCTAssertEqual(files[0]["uri"] as? String, "data:text/plain;base64,aGVsbG8=")
    }

    func testActiveStatusesAndInterruptUseCurrentV2Routes() async throws {
        let (client, session) = makeClient { request in
            if request.httpMethod == "POST" { return .empty(statusCode: 204) }
            return .json(#"{"data":{"ses_busy":{"type":"running"}}}"#)
        }
        defer { session.invalidateAndCancel() }

        let statuses = try await client.sessionStatuses(directory: "/not/sent")
        try await client.abortSession(
            sessionID: "ses_busy",
            directory: "/not/sent",
            workspace: "not-sent"
        )

        XCTAssertEqual(statuses, ["ses_busy": .busy])
        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/session/active",
            "/api/session/ses_busy/interrupt",
        ])
        XCTAssertTrue(requests.allSatisfy { v2QueryValues(for: $0).isEmpty })
    }

    func testProviderAndModelResponsesJoinByProvider() async throws {
        let (client, session) = makeClient { request in
            switch request.url?.path {
            case "/api/provider":
                return .json(
                    #"{"location":{"directory":"/repo","project":{"id":"proj_1","directory":"/repo"}},"data":[{"id":"openai","name":"OpenAI","api":{"type":"openai","url":"https://example.test"},"request":{"headers":{},"body":{}}},{"id":"off","name":"Disabled","disabled":true,"api":{"type":"openai","url":"https://example.test"},"request":{"headers":{},"body":{}}}]}"#
                )
            case "/api/model":
                return .json(
                    #"{"location":{"directory":"/repo","project":{"id":"proj_1","directory":"/repo"}},"data":[{"id":"gpt-5","providerID":"openai","name":"GPT-5","api":{"id":"gpt-5"},"capabilities":{"tools":true,"input":["text"],"output":["text"]},"request":{"headers":{},"body":{}},"variants":[],"time":{"released":1},"cost":[],"status":"active","enabled":true,"limit":{"context":1000,"output":100}},{"id":"old","providerID":"openai","name":"Old","api":{"id":"old"},"capabilities":{"tools":true,"input":["text"],"output":["text"]},"request":{"headers":{},"body":{}},"variants":[],"time":{"released":1},"cost":[],"status":"deprecated","enabled":false,"limit":{"context":1000,"output":100}}]}"#
                )
            default:
                return .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }

        let providers = try await client.connectedProviderModels(directory: "/repo")

        XCTAssertEqual(providers.map(\.providerID), ["openai"])
        XCTAssertEqual(providers.first?.models.map(\.modelID), ["gpt-5"])
        XCTAssertEqual(providers.first?.connectionState, .unreported)
        for request in OpenCodeV2URLProtocolStub.recordedRequests() {
            XCTAssertEqual(v2QueryValues(for: request)["location[directory]"], "/repo")
        }
    }

    func testV2CapabilitiesRequireNoSpeculativeNetworkProbe() async throws {
        let (client, session) = makeClient { _ in
            .json(#"{"message":"no capability route"}"#, statusCode: 500)
        }
        defer { session.invalidateAndCancel() }

        let capabilities = try await client.protocolCapabilities()

        XCTAssertFalse(capabilities.sessionDiff.isSupported)
        XCTAssertFalse(capabilities.providerConnectionState.isSupported)
        XCTAssertTrue(OpenCodeV2URLProtocolStub.recordedRequests().isEmpty)
    }

    func testProjectListDerivesUniqueLocationsFromV2Sessions() async throws {
        let (client, session) = makeClient { _ in
            .json(
                #"{"data":[{"id":"ses_1","projectID":"proj_1","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":10,"updated":30},"title":"One","location":{"directory":"/repo"}},{"id":"ses_2","projectID":"proj_1","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":20,"updated":40},"title":"Two","location":{"directory":"/repo"}}],"cursor":{}}"#
            )
        }
        defer { session.invalidateAndCancel() }

        let projects = try await client.listProjects()

        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects[0].id, "proj_1")
        XCTAssertEqual(projects[0].worktree, "/repo")
        XCTAssertEqual(projects[0].time, OpenCodeProjectTime(created: 10, updated: 40))
    }

    func testV2EventSemanticsReconcileCurrentSessionNextFamilies() {
        XCTAssertEqual(OpenCodeEventSemantics.effect(for: "session.next.prompted"), .busyAndMessages)
        XCTAssertEqual(OpenCodeEventSemantics.effect(for: "session.next.text.delta"), .messages)
        XCTAssertEqual(OpenCodeEventSemantics.effect(for: "session.next.step.ended"), .messages)
        XCTAssertEqual(OpenCodeEventSemantics.effect(for: "session.next.step.failed"), .messages)
        XCTAssertEqual(OpenCodeEventSemantics.effect(for: "permission.v2.asked"), .pendingActions)
        XCTAssertEqual(OpenCodeEventSemantics.effect(for: "unrelated"), .none)
    }

    func testV2PendingActionsUseLocationRoutesAndFilterTheSession() async throws {
        let (client, session) = makeClient { request in
            switch request.url?.path {
            case "/api/permission/request":
                return .json(
                    #"{"location":{"directory":"/repo","project":{"id":"proj_1","directory":"/repo"}},"data":[{"id":"per_keep","sessionID":"ses_1","action":"bash","resources":["git status"],"save":["git *"],"metadata":{}},{"id":"per_other","sessionID":"ses_2","action":"read","resources":["README.md"]}]}"#
                )
            case "/api/question/request":
                return .json(
                    #"{"location":{"directory":"/repo","project":{"id":"proj_1","directory":"/repo"}},"data":[{"id":"que_keep","sessionID":"ses_1","questions":[{"question":"Ship?","header":"Decision","options":[{"label":"Yes","description":"Ship it"}],"multiple":false}]},{"id":"que_other","sessionID":"ses_2","questions":[{"question":"Other?","header":"Other","options":[],"multiple":false}]}]}"#
                )
            default:
                return .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }

        let permissions = try await client.permissions(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )
        let questions = try await client.questions(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )

        XCTAssertEqual(permissions.map(\.id), ["per_keep"])
        XCTAssertEqual(permissions.first?.resolvedAPIVersion, .v2)
        XCTAssertEqual(questions.map(\.id), ["que_keep"])
        XCTAssertEqual(questions.first?.resolvedAPIVersion, .v2)
        for request in OpenCodeV2URLProtocolStub.recordedRequests() {
            XCTAssertEqual(v2QueryValues(for: request)["location[directory]"], "/repo")
            XCTAssertEqual(v2QueryValues(for: request)["location[workspace]"], "wrk_1")
        }
    }

    func testV2ActionResponsesUseDetectedProtocolRoutesAndBodies() async throws {
        let (client, session) = makeClient { _ in .empty(statusCode: 204) }
        defer { session.invalidateAndCancel() }
        let permission = OpenCodePermissionRequest(
            id: "per_1",
            sessionID: "ses_1",
            permission: "bash",
            patterns: ["git status"],
            metadata: [:],
            always: ["git *"],
            apiVersion: .legacy
        )
        let question = OpenCodeQuestionRequest(
            id: "que_1",
            sessionID: "ses_1",
            questions: [
                OpenCodeQuestion(
                    question: "Ship?",
                    header: "Decision",
                    options: [],
                    multiple: false,
                    custom: true
                ),
            ],
            apiVersion: .legacy
        )

        try await client.reply(
            to: permission,
            directory: "/not/sent",
            workspace: "not-sent",
            reply: .always
        )
        try await client.answer(
            question,
            directory: "/not/sent",
            workspace: "not-sent",
            answers: [["Yes"]]
        )
        try await client.reject(
            question,
            directory: "/not/sent",
            workspace: "not-sent"
        )

        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/session/ses_1/permission/per_1/reply",
            "/api/session/ses_1/question/que_1/reply",
            "/api/session/ses_1/question/que_1/reject",
        ])
        XCTAssertEqual(try v2JSONObject(for: requests[0])["reply"] as? String, "always")
        XCTAssertEqual(
            try v2JSONObject(for: requests[1])["answers"] as? [[String]],
            [["Yes"]]
        )
        XCTAssertNil(requests[2].httpBody)
        XCTAssertTrue(requests.allSatisfy { v2QueryValues(for: $0).isEmpty })
    }

    func testV1PendingActionsStayOnLegacyRoutesAndFilterTheSession() async throws {
        let (client, session) = makeClient(serverProtocol: .v1) { request in
            switch request.url?.path {
            case "/permission":
                return .json(
                    #"[{"id":"per_keep","sessionID":"ses_1","permission":"bash","patterns":["git status"],"metadata":{},"always":[]},{"id":"per_other","sessionID":"ses_2","permission":"read","patterns":["README.md"],"metadata":{},"always":[]}]"#
                )
            case "/question":
                return .json(
                    #"[{"id":"que_keep","sessionID":"ses_1","questions":[{"question":"Ship?","header":"Decision","options":[],"multiple":false}]},{"id":"que_other","sessionID":"ses_2","questions":[{"question":"Other?","header":"Other","options":[],"multiple":false}]}]"#
                )
            default:
                return .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }

        let permissions = try await client.permissions(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )
        let questions = try await client.questions(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )

        XCTAssertEqual(permissions.map(\.id), ["per_keep"])
        XCTAssertEqual(questions.map(\.id), ["que_keep"])
        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/permission", "/question"])
        XCTAssertTrue(requests.allSatisfy {
            v2QueryValues(for: $0) == ["directory": "/repo", "workspace": "wrk_1"]
        })
    }

    private func makeClient(
        serverProtocol: OpenCodeServerProtocol = .v2,
        handler: @escaping @Sendable (URLRequest) -> OpenCodeV2URLProtocolStub.Response
    ) -> (OpenCodeClient, URLSession) {
        OpenCodeV2URLProtocolStub.reset(handler: handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeV2URLProtocolStub.self]
        let session = URLSession(configuration: configuration)
        let profile = OpenCodeServerProfile(
            name: "v2",
            baseURL: "https://v2.example.test",
            username: "opencode"
        )
        return (
            OpenCodeClient(
                profile: profile,
                password: "secret",
                session: session,
                serverProtocol: serverProtocol
            ),
            session
        )
    }

}

private func v2QueryValues(for request: URLRequest) -> [String: String] {
    let items = URLComponents(
        url: request.url!,
        resolvingAgainstBaseURL: false
    )?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.compactMap { item in
        item.value.map { (item.name, $0) }
    })
}

private func v2JSONObject(for request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(
        JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.httpBody)
        ) as? [String: Any]
    )
}

private final class OpenCodeV2URLProtocolStub: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data

        static func json(_ body: String, statusCode: Int = 200) -> Response {
            Response(
                statusCode: statusCode,
                headers: ["Content-Type": "application/json"],
                data: Data(body.utf8)
            )
        }

        static func empty(statusCode: Int) -> Response {
            Response(statusCode: statusCode, headers: [:], data: Data())
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler:
        (@Sendable (URLRequest) -> Response)?
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func reset(
        handler: (@Sendable (URLRequest) -> Response)? = nil
    ) {
        lock.lock()
        self.handler = handler
        requests = []
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "v2.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4_096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4_096)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            recorded.httpBody = data
        }

        Self.lock.lock()
        Self.requests.append(recorded)
        let handler = Self.handler
        Self.lock.unlock()

        guard let url = request.url, let handler else {
            client?.urlProtocol(self, didFailWithError: OpenCodeConnectionError.invalidResponse)
            return
        }
        let value = handler(recorded)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: value.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: value.headers
        ) else {
            client?.urlProtocol(self, didFailWithError: OpenCodeConnectionError.invalidResponse)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !value.data.isEmpty { client?.urlProtocol(self, didLoad: value.data) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
