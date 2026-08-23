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

    func testV1SessionLifecycleUsesCurrentRoutesAndBodies() async throws {
        let sessionJSON = #"{"id":"ses_1","slug":"first","projectID":"proj_1","directory":"/repo","title":"First","version":"1","time":{"created":10,"updated":20}}"#
        let renamedJSON = #"{"id":"ses_1","slug":"first","projectID":"proj_1","directory":"/repo","title":"Renamed","version":"1","time":{"created":10,"updated":30}}"#
        let childJSON = #"{"id":"ses_child","slug":"child","projectID":"proj_1","directory":"/repo","parentID":"ses_1","title":"Subagent","version":"1","time":{"created":15,"updated":25}}"#
        let (client, session) = makeClient(serverProtocol: .v1) { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/session/ses_1"):
                return .json(sessionJSON)
            case ("PATCH", "/session/ses_1"):
                return .json(renamedJSON)
            case ("GET", "/session/ses_1/children"):
                return .json("[\(childJSON)]")
            case ("DELETE", "/session/ses_1"), ("POST", "/session/ses_1/abort"):
                return .json("true")
            default:
                return .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }

        let fetched = try await client.getSession(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )
        let renamed = try await client.renameSession(
            sessionID: "ses_1",
            title: "Renamed",
            directory: "/repo",
            workspace: "wrk_1"
        )
        let children = try await client.childSessions(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )
        try await client.deleteSession(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )
        try await client.abortSession(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )

        XCTAssertEqual(fetched.title, "First")
        XCTAssertEqual(renamed.title, "Renamed")
        XCTAssertEqual(children.map(\.id), ["ses_child"])
        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { ($0.httpMethod ?? "") + " " + ($0.url?.path ?? "") }, [
            "GET /session/ses_1",
            "PATCH /session/ses_1",
            "GET /session/ses_1/children",
            "DELETE /session/ses_1",
            "POST /session/ses_1/abort",
        ])
        XCTAssertEqual(try v2JSONObject(for: requests[1])["title"] as? String, "Renamed")
        XCTAssertNil(requests[3].httpBody)
        XCTAssertTrue(requests.allSatisfy {
            v2QueryValues(for: $0) == ["directory": "/repo", "workspace": "wrk_1"]
        })
    }

    func testV2GetSessionUsesCurrentDataEnvelope() async throws {
        let (client, session) = makeClient { _ in
            .json(
                #"{"data":{"id":"ses_1","projectID":"proj_1","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":10,"updated":20},"title":"Current","location":{"directory":"/repo","workspaceID":"wrk_1"}}}"#
            )
        }
        defer { session.invalidateAndCancel() }

        let fetched = try await client.getSession(
            sessionID: "ses_1",
            directory: "/not/sent",
            workspace: "not-sent"
        )

        XCTAssertEqual(fetched.title, "Current")
        XCTAssertEqual(fetched.directory, "/repo")
        let request = try XCTUnwrap(OpenCodeV2URLProtocolStub.recordedRequests().first)
        XCTAssertEqual(request.url?.path, "/api/session/ses_1")
        XCTAssertTrue(v2QueryValues(for: request).isEmpty)
    }

    func testV2UnavailableLifecycleMethodsNeverProbeGuessedRoutes() async throws {
        let (client, session) = makeClient { _ in
            .json(#"{"message":"must not request"}"#, statusCode: 500)
        }
        defer { session.invalidateAndCancel() }

        do {
            _ = try await client.renameSession(
                sessionID: "ses_1",
                title: "No route",
                directory: "/repo"
            )
            XCTFail("Expected rename to be unavailable")
        } catch let error as OpenCodeFeatureUnavailableError {
            XCTAssertEqual(error.feature, "Rename session")
        }
        do {
            try await client.deleteSession(sessionID: "ses_1", directory: "/repo")
            XCTFail("Expected delete to be unavailable")
        } catch is OpenCodeFeatureUnavailableError { }
        do {
            _ = try await client.childSessions(sessionID: "ses_1", directory: "/repo")
            XCTFail("Expected children to be unavailable")
        } catch is OpenCodeFeatureUnavailableError { }

        XCTAssertTrue(OpenCodeV2URLProtocolStub.recordedRequests().isEmpty)
    }

    func testV1TodosUseCurrentSessionRouteAndLocation() async throws {
        let (client, session) = makeClient(serverProtocol: .v1) { _ in
            .json(
                #"[{"content":"Inspect","status":"completed","priority":"high"},{"content":"Implement","status":"in_progress","priority":"medium"}]"#
            )
        }
        defer { session.invalidateAndCancel() }

        let todos = try await client.todos(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )

        XCTAssertEqual(todos.map(\.content), ["Inspect", "Implement"])
        let request = try XCTUnwrap(OpenCodeV2URLProtocolStub.recordedRequests().first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/session/ses_1/todo")
        XCTAssertEqual(v2QueryValues(for: request), [
            "directory": "/repo", "workspace": "wrk_1",
        ])
    }

    func testV2TodosStayProbeFreeUntilUpstreamAddsARoute() async throws {
        let (client, session) = makeClient { _ in
            .json(#"{"message":"must not request"}"#, statusCode: 500)
        }
        defer { session.invalidateAndCancel() }

        let todos = try await client.todos(sessionID: "ses_1", directory: "/repo")

        XCTAssertTrue(todos.isEmpty)
        XCTAssertTrue(OpenCodeV2URLProtocolStub.recordedRequests().isEmpty)
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

    func testV1SessionHistoryActionsUseCurrentRoutesBodiesAndResponses() async throws {
        let sessionJSON = #"{"id":"ses_1","slug":"one","projectID":"proj_1","directory":"/repo","title":"One","version":"1","time":{"created":10,"updated":20}}"#
        let revertedJSON = #"{"id":"ses_1","slug":"one","projectID":"proj_1","directory":"/repo","title":"One","version":"1","time":{"created":10,"updated":21},"revert":{"messageID":"msg_2","partID":"prt_2","snapshot":"snap_1","diff":"patch"}}"#
        let forkJSON = #"{"id":"ses_fork","slug":"fork","projectID":"proj_1","directory":"/repo","title":"Fork","version":"1","time":{"created":30,"updated":30}}"#
        let (client, session) = makeClient(serverProtocol: .v1) { request in
            switch request.url?.path {
            case "/session/ses_1/revert": .json(revertedJSON)
            case "/session/ses_1/unrevert": .json(sessionJSON)
            case "/session/ses_1/summarize": .json("true")
            case "/session/ses_1/fork": .json(forkJSON)
            default: .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }
        let model = OpenCodeModelOption(
            providerID: "anthropic",
            providerName: "Anthropic",
            modelID: "claude-sonnet",
            modelName: "Claude Sonnet",
            status: nil
        )

        let reverted = try await client.revertSession(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1",
            target: OpenCodeSessionRevertTarget(
                messageID: "msg_2",
                partID: "prt_2",
                files: nil
            )
        )
        let restored = try await client.unrevertSession(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1"
        )
        let summarized = try await client.summarizeSession(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1",
            model: model,
            automatically: true
        )
        let forked = try await client.forkSession(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1",
            messageID: "msg_2"
        )

        XCTAssertEqual(reverted.session?.revert?.messageID, "msg_2")
        XCTAssertNil(restored.session?.revert)
        XCTAssertTrue(summarized)
        XCTAssertEqual(forked.id, "ses_fork")
        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/session/ses_1/revert",
            "/session/ses_1/unrevert",
            "/session/ses_1/summarize",
            "/session/ses_1/fork",
        ])
        XCTAssertEqual(Set(try v2JSONObject(for: requests[0]).keys), ["messageID", "partID"])
        XCTAssertNil(requests[1].httpBody)
        let summarizeBody = try v2JSONObject(for: requests[2])
        XCTAssertEqual(summarizeBody["providerID"] as? String, "anthropic")
        XCTAssertEqual(summarizeBody["modelID"] as? String, "claude-sonnet")
        XCTAssertEqual(summarizeBody["auto"] as? Bool, true)
        XCTAssertEqual(try v2JSONObject(for: requests[3])["messageID"] as? String, "msg_2")
        XCTAssertTrue(requests.allSatisfy {
            v2QueryValues(for: $0) == ["directory": "/repo", "workspace": "wrk_1"]
        })
    }

    func testV2SessionHistoryMapsStageClearAndCompactWithoutGuessingFork() async throws {
        let (client, session) = makeClient { request in
            switch request.url?.path {
            case "/api/session/ses_1/revert/stage":
                return .json(#"{"data":{"messageID":"msg_2","snapshot":"snap_1","diff":"raw","files":[{"path":"Sources/App.swift","status":"modified","additions":2,"deletions":1,"patch":"@@"}]}}"#)
            case "/api/session/ses_1/revert/clear", "/api/session/ses_1/compact":
                return .empty(statusCode: 204)
            default:
                return .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }

        let reverted = try await client.revertSession(
            sessionID: "ses_1",
            directory: "/must/not/be/sent",
            workspace: "must-not-be-sent",
            target: OpenCodeSessionRevertTarget(
                messageID: "msg_2",
                partID: "prt_not_supported_by_v2",
                files: true
            )
        )
        let restored = try await client.unrevertSession(
            sessionID: "ses_1",
            directory: "/must/not/be/sent"
        )
        let summarized = try await client.summarizeSession(
            sessionID: "ses_1",
            directory: "/must/not/be/sent",
            model: nil,
            automatically: nil
        )

        XCTAssertEqual(reverted.revert?.messageID, "msg_2")
        XCTAssertEqual(reverted.diffs?.first?.file, "Sources/App.swift")
        XCTAssertNil(restored.revert)
        XCTAssertTrue(summarized)
        do {
            _ = try await client.forkSession(
                sessionID: "ses_1",
                directory: "/must/not/be/sent",
                messageID: nil
            )
            XCTFail("Expected v2 fork to be unavailable")
        } catch let error as OpenCodeFeatureUnavailableError {
            XCTAssertEqual(error.feature, "Fork session")
        }

        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/session/ses_1/revert/stage",
            "/api/session/ses_1/revert/clear",
            "/api/session/ses_1/compact",
        ])
        let revertBody = try v2JSONObject(for: requests[0])
        XCTAssertEqual(Set(revertBody.keys), ["messageID", "files"])
        XCTAssertEqual(revertBody["messageID"] as? String, "msg_2")
        XCTAssertEqual(revertBody["files"] as? Bool, true)
        XCTAssertNil(requests[1].httpBody)
        XCTAssertNil(requests[2].httpBody)
        XCTAssertTrue(requests.allSatisfy { v2QueryValues(for: $0).isEmpty })
    }

    func testV1FileBrowsingUsesCurrentRoutesQueriesAndShapes() async throws {
        let (client, session) = makeClient(serverProtocol: .v1) { request in
            switch request.url?.path {
            case "/file":
                return .json(#"[{"name":"App.swift","path":"Sources/App.swift","absolute":"/repo/Sources/App.swift","type":"file","ignored":false},{"name":"Tests","path":"Tests","absolute":"/repo/Tests","type":"directory","ignored":false}]"#)
            case "/file/content":
                return .json(#"{"type":"text","content":"let value = 1\n","mimeType":"text/x-swift"}"#)
            case "/file/status":
                return .json(#"[{"path":"Sources/App.swift","added":2,"removed":1,"status":"modified"}]"#)
            case "/find/file":
                return .json(#"["Sources/App.swift","Tests/AppTests.swift"]"#)
            default:
                return .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }

        let entries = try await client.listFiles(
            directory: "/repo",
            workspace: "wrk_1",
            path: "Sources"
        )
        let content = try await client.readFile(
            directory: "/repo",
            workspace: "wrk_1",
            path: "Sources/App.swift"
        )
        let statuses = try await client.fileStatuses(
            directory: "/repo",
            workspace: "wrk_1"
        )
        let matches = try await client.findFiles(
            directory: "/repo",
            workspace: "wrk_1",
            query: "App"
        )

        XCTAssertEqual(entries.map(\.path), ["Sources/App.swift", "Tests"])
        XCTAssertEqual(content.content, "let value = 1\n")
        XCTAssertEqual(statuses.first?.additions, 2)
        XCTAssertEqual(matches.map(\.path), ["Sources/App.swift", "Tests/AppTests.swift"])
        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/file", "/file/content", "/file/status", "/find/file",
        ])
        XCTAssertEqual(v2QueryValues(for: requests[0]), [
            "directory": "/repo", "workspace": "wrk_1", "path": "Sources",
        ])
        XCTAssertEqual(v2QueryValues(for: requests[1]), [
            "directory": "/repo", "workspace": "wrk_1", "path": "Sources/App.swift",
        ])
        XCTAssertEqual(v2QueryValues(for: requests[2]), [
            "directory": "/repo", "workspace": "wrk_1",
        ])
        XCTAssertEqual(v2QueryValues(for: requests[3]), [
            "directory": "/repo", "workspace": "wrk_1", "query": "App",
            "type": "file", "limit": "200",
        ])
    }

    func testV2FileSearchUsesCurrentRouteAndMissingSurfacesNeverProbe() async throws {
        let (client, session) = makeClient { request in
            .json(#"{"location":{"directory":"/repo","workspaceID":"wrk_1","project":{"id":"proj_1","directory":"/repo"}},"data":[{"path":"Sources/App.swift","type":"file"},{"path":"Sources/UI","type":"directory"}]}"#)
        }
        defer { session.invalidateAndCancel() }

        for operation in [
            { try await client.listFiles(directory: "/repo", path: "") as Any },
            { try await client.readFile(directory: "/repo", path: "README.md") as Any },
            { try await client.fileStatuses(directory: "/repo") as Any },
        ] {
            do {
                _ = try await operation()
                XCTFail("Expected unavailable v2 file surface")
            } catch is OpenCodeFeatureUnavailableError { }
        }
        XCTAssertTrue(OpenCodeV2URLProtocolStub.recordedRequests().isEmpty)

        let matches = try await client.findFiles(
            directory: "/repo",
            workspace: "wrk_1",
            query: "App"
        )

        XCTAssertEqual(matches.map(\.path), ["Sources/App.swift", "Sources/UI"])
        let request = try XCTUnwrap(OpenCodeV2URLProtocolStub.recordedRequests().first)
        XCTAssertEqual(request.url?.path, "/api/fs/find")
        XCTAssertEqual(v2QueryValues(for: request), [
            "location[directory]": "/repo",
            "location[workspace]": "wrk_1",
            "query": "App",
            "type": "file",
            "limit": "200",
        ])
    }

    func testV1CommandsShellAndAgentsUseCurrentRoutesAndBodies() async throws {
        let message = #"{"info":{"id":"msg_1","sessionID":"ses_1","role":"assistant","time":{"created":1}},"parts":[]}"#
        let (client, session) = makeClient(serverProtocol: .v1) { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/command"):
                return .json(#"[{"name":"review","description":"Review changes","template":"Review $ARGUMENTS","source":"command","hints":["scope"]}]"#)
            case ("GET", "/agent"):
                return .json(#"[{"name":"build","description":"Build mode","mode":"primary","hidden":false}]"#)
            case ("POST", "/session/ses_1/prompt_async"):
                return .empty(statusCode: 204)
            case ("POST", "/session/ses_1/command"), ("POST", "/session/ses_1/shell"):
                return .json(message)
            default:
                return .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }
        let model = OpenCodeModelOption(
            providerID: "openai",
            providerName: "OpenAI",
            modelID: "gpt-5",
            modelName: "GPT-5",
            status: nil
        )

        let commands = try await client.commands(directory: "/repo", workspace: "wrk_1")
        let agents = try await client.agents(directory: "/repo", workspace: "wrk_1")
        try await client.sendMessage(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1",
            agent: "build",
            text: "Ship it"
        )
        try await client.executeCommand(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1",
            command: "review",
            arguments: "staged changes",
            agent: "build",
            model: model
        )
        try await client.runShell(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1",
            command: "git status",
            agent: "build",
            model: model
        )

        XCTAssertEqual(commands.map(\.name), ["review"])
        XCTAssertEqual(agents.map(\.id), ["build"])
        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { ($0.httpMethod ?? "") + " " + ($0.url?.path ?? "") }, [
            "GET /command",
            "GET /agent",
            "POST /session/ses_1/prompt_async",
            "POST /session/ses_1/command",
            "POST /session/ses_1/shell",
        ])
        XCTAssertTrue(requests.allSatisfy {
            v2QueryValues(for: $0) == ["directory": "/repo", "workspace": "wrk_1"]
        })
        XCTAssertEqual(try v2JSONObject(for: requests[2])["agent"] as? String, "build")
        let commandBody = try v2JSONObject(for: requests[3])
        XCTAssertEqual(commandBody["command"] as? String, "review")
        XCTAssertEqual(commandBody["arguments"] as? String, "staged changes")
        XCTAssertEqual(commandBody["agent"] as? String, "build")
        XCTAssertEqual(commandBody["model"] as? String, "openai/gpt-5")
        let shellBody = try v2JSONObject(for: requests[4])
        XCTAssertEqual(shellBody["command"] as? String, "git status")
        XCTAssertEqual(shellBody["agent"] as? String, "build")
        let shellModel = try XCTUnwrap(shellBody["model"] as? [String: Any])
        XCTAssertEqual(shellModel["providerID"] as? String, "openai")
        XCTAssertEqual(shellModel["modelID"] as? String, "gpt-5")
    }

    func testV2CatalogsAndAgentSelectionUseCurrentRoutesWhileExecutionGapsDoNotProbe() async throws {
        let (client, session) = makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/command"):
                return .json(#"{"location":{"directory":"/repo","workspaceID":"wrk_1","project":{"id":"proj_1","directory":"/repo"}},"data":[{"name":"review","template":"Review $ARGUMENTS","description":"Review changes"}]}"#)
            case ("GET", "/api/agent"):
                return .json(#"{"location":{"directory":"/repo","workspaceID":"wrk_1","project":{"id":"proj_1","directory":"/repo"}},"data":[{"id":"plan","request":{},"mode":"primary","hidden":false,"permissions":[]}]}"#)
            case ("POST", "/api/session/ses_1/agent"):
                return .empty(statusCode: 204)
            case ("POST", "/api/session/ses_1/prompt"):
                return .json(#"{"data":{"admittedSeq":1,"id":"msg_new","sessionID":"ses_1","prompt":{"text":"Plan it"},"delivery":"queue","timeCreated":1}}"#)
            default:
                return .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }

        let commands = try await client.commands(directory: "/repo", workspace: "wrk_1")
        let agents = try await client.agents(directory: "/repo", workspace: "wrk_1")
        try await client.sendMessage(
            sessionID: "ses_1",
            directory: "/repo",
            workspace: "wrk_1",
            agent: "plan",
            text: "Plan it"
        )
        let requestCount = OpenCodeV2URLProtocolStub.recordedRequests().count
        do {
            try await client.executeCommand(
                sessionID: "ses_1",
                directory: "/repo",
                command: "review",
                arguments: "",
                agent: "plan",
                model: nil
            )
            XCTFail("Expected v2 command execution to be unavailable")
        } catch is OpenCodeFeatureUnavailableError { }
        do {
            try await client.runShell(
                sessionID: "ses_1",
                directory: "/repo",
                command: "pwd",
                agent: "plan",
                model: nil
            )
            XCTFail("Expected v2 shell execution to be unavailable")
        } catch is OpenCodeFeatureUnavailableError { }

        XCTAssertEqual(commands.map(\.name), ["review"])
        XCTAssertEqual(agents.map(\.id), ["plan"])
        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.count, requestCount)
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/api/command",
            "/api/agent",
            "/api/session/ses_1/agent",
            "/api/session/ses_1/prompt",
        ])
        XCTAssertEqual(v2QueryValues(for: requests[0]), [
            "location[directory]": "/repo",
            "location[workspace]": "wrk_1",
        ])
        XCTAssertEqual(v2QueryValues(for: requests[1]), [
            "location[directory]": "/repo",
            "location[workspace]": "wrk_1",
        ])
        XCTAssertEqual(try v2JSONObject(for: requests[2])["agent"] as? String, "plan")
    }

    func testV1ProviderAuthenticationUsesPinnedMethodsKeyAndOAuthContracts() async throws {
        let (client, session) = makeClient(serverProtocol: .v1) { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/provider"):
                return .json(#"{"all":[{"id":"openai","name":"OpenAI","models":{}},{"id":"anthropic","name":"Anthropic","models":{}}],"connected":["anthropic"],"default":{}}"#)
            case ("GET", "/provider/auth"):
                return .json(#"{"openai":[{"type":"api","label":"API key"},{"type":"oauth","label":"Browser login","prompts":[{"type":"select","key":"account","message":"Account type","options":[{"label":"Personal","value":"personal"}]},{"type":"text","key":"hostname","message":"Hostname","when":{"key":"account","op":"eq","value":"enterprise"}}]}]}"#)
            case ("PUT", "/auth/openai"), ("POST", "/instance/dispose"), ("POST", "/provider/openai/oauth/callback"):
                return .json("true")
            case ("POST", "/provider/openai/oauth/authorize"):
                return .json(#"{"url":"https://auth.example.test","method":"code","instructions":"Paste the code"}"#)
            default:
                return .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }

        let providers = try await client.providerConnections(directory: "/repo", workspace: "wrk_1")
        try await client.connectProviderKey(
            providerID: "openai",
            key: "secret-key",
            directory: "/repo",
            workspace: "wrk_1"
        )
        let authorization = try await client.startProviderOAuth(
            providerID: "openai",
            methodID: "1",
            inputs: ["account": "personal"],
            directory: "/repo",
            workspace: "wrk_1"
        )
        try await client.completeProviderOAuth(
            providerID: "openai",
            attemptID: authorization.attemptID,
            code: "oauth-code",
            directory: "/repo",
            workspace: "wrk_1"
        )
        let status = try await client.providerOAuthStatus(
            providerID: "openai",
            attemptID: authorization.attemptID,
            directory: "/repo",
            workspace: "wrk_1"
        )

        XCTAssertEqual(providers.map(\.id), ["anthropic", "openai"])
        XCTAssertTrue(try XCTUnwrap(providers.first { $0.id == "anthropic" }).isConnected)
        let openAI = try XCTUnwrap(providers.first { $0.id == "openai" })
        XCTAssertEqual(openAI.methods.map(\.id), ["0", "1"])
        XCTAssertEqual(openAI.methods.map(\.kind), [.key, .oauth])
        XCTAssertEqual(openAI.methods[1].prompts.map(\.key), ["account", "hostname"])
        XCTAssertEqual(authorization.attemptID, "openai:1")
        XCTAssertEqual(authorization.mode, .code)
        XCTAssertEqual(status, .complete)

        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { ($0.httpMethod ?? "") + " " + ($0.url?.path ?? "") }, [
            "GET /provider",
            "GET /provider/auth",
            "PUT /auth/openai",
            "POST /instance/dispose",
            "POST /provider/openai/oauth/authorize",
            "POST /provider/openai/oauth/callback",
            "POST /provider/openai/oauth/callback",
        ])
        XCTAssertEqual(try v2JSONObject(for: requests[2])["type"] as? String, "api")
        XCTAssertEqual(try v2JSONObject(for: requests[2])["key"] as? String, "secret-key")
        XCTAssertTrue(v2QueryValues(for: requests[2]).isEmpty)
        XCTAssertEqual(v2QueryValues(for: requests[3]), ["directory": "/repo", "workspace": "wrk_1"])
        let authorizeBody = try v2JSONObject(for: requests[4])
        XCTAssertEqual(authorizeBody["method"] as? Int, 1)
        XCTAssertEqual((authorizeBody["inputs"] as? [String: String])?["account"], "personal")
        let callbackBody = try v2JSONObject(for: requests[5])
        XCTAssertEqual(callbackBody["method"] as? Int, 1)
        XCTAssertEqual(callbackBody["code"] as? String, "oauth-code")
        let statusBody = try v2JSONObject(for: requests[6])
        XCTAssertEqual(statusBody["method"] as? Int, 1)
        XCTAssertNil(statusBody["code"])
        XCTAssertEqual(requests[6].timeoutInterval, 10 * 60, accuracy: 0.1)
    }

    func testV2ProviderAuthenticationUsesPinnedIntegrationAttemptContracts() async throws {
        let (client, session) = makeClient { request in
            switch (request.httpMethod, request.url?.path) {
            case ("GET", "/api/integration"):
                return .json(#"{"location":{"directory":"/repo","workspaceID":"wrk_1","project":{"id":"proj_1","directory":"/repo"}},"data":[{"id":"openai","name":"OpenAI","methods":[{"type":"key","label":"API key"},{"id":"oauth-browser","type":"oauth","label":"Browser login","prompts":[]}],"connections":[{"type":"credential","id":"cred_1","label":"Personal"}]}]}"#)
            case ("POST", "/api/integration/openai/connect/key"),
                 ("POST", "/api/integration/attempt/attempt_1/complete"),
                 ("DELETE", "/api/integration/attempt/attempt_1"):
                return .empty(statusCode: 204)
            case ("POST", "/api/integration/openai/connect/oauth"):
                return .json(#"{"location":{"directory":"/repo","workspaceID":"wrk_1","project":{"id":"proj_1","directory":"/repo"}},"data":{"attemptID":"attempt_1","url":"https://auth.example.test","instructions":"Confirm ABCD","mode":"auto","time":{"created":10,"expires":20}}}"#)
            case ("GET", "/api/integration/attempt/attempt_1"):
                return .json(#"{"location":{"directory":"/repo","workspaceID":"wrk_1","project":{"id":"proj_1","directory":"/repo"}},"data":{"status":"pending","time":{"created":10,"expires":20}}}"#)
            default:
                return .json(#"{"message":"unexpected"}"#, statusCode: 404)
            }
        }
        defer { session.invalidateAndCancel() }

        let providers = try await client.providerConnections(directory: "/repo", workspace: "wrk_1")
        try await client.connectProviderKey(
            providerID: "openai",
            key: "secret-key",
            directory: "/repo",
            workspace: "wrk_1"
        )
        let authorization = try await client.startProviderOAuth(
            providerID: "openai",
            methodID: "oauth-browser",
            inputs: [:],
            directory: "/repo",
            workspace: "wrk_1"
        )
        let status = try await client.providerOAuthStatus(
            providerID: "openai",
            attemptID: authorization.attemptID,
            directory: "/repo",
            workspace: "wrk_1"
        )
        try await client.completeProviderOAuth(
            providerID: "openai",
            attemptID: authorization.attemptID,
            code: nil,
            directory: "/repo",
            workspace: "wrk_1"
        )
        try await client.cancelProviderOAuth(
            providerID: "openai",
            attemptID: authorization.attemptID,
            directory: "/repo",
            workspace: "wrk_1"
        )

        XCTAssertEqual(providers.map(\.id), ["openai"])
        XCTAssertTrue(try XCTUnwrap(providers.first).isConnected)
        XCTAssertEqual(providers.first?.methods.map(\.id), ["key", "oauth-browser"])
        XCTAssertEqual(authorization.mode, .automatic)
        XCTAssertEqual(status, .pending)

        let requests = OpenCodeV2URLProtocolStub.recordedRequests()
        XCTAssertEqual(requests.map { ($0.httpMethod ?? "") + " " + ($0.url?.path ?? "") }, [
            "GET /api/integration",
            "POST /api/integration/openai/connect/key",
            "POST /api/integration/openai/connect/oauth",
            "GET /api/integration/attempt/attempt_1",
            "POST /api/integration/attempt/attempt_1/complete",
            "DELETE /api/integration/attempt/attempt_1",
        ])
        XCTAssertTrue(requests.allSatisfy {
            v2QueryValues(for: $0) == [
                "location[directory]": "/repo",
                "location[workspace]": "wrk_1",
            ]
        })
        XCTAssertEqual(try v2JSONObject(for: requests[1])["key"] as? String, "secret-key")
        let oauthBody = try v2JSONObject(for: requests[2])
        XCTAssertEqual(oauthBody["methodID"] as? String, "oauth-browser")
        XCTAssertNotNil(oauthBody["inputs"] as? [String: String])
        XCTAssertTrue(try v2JSONObject(for: requests[4]).isEmpty)
        XCTAssertNil(requests[5].httpBody)
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
