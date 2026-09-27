import Foundation
import Testing
@testable import byot

@Suite("Composer agent toggle")
struct OpenCodeAgentToggleTests {
    private static let build = OpenCodeAgentOption(id: "build", name: "build", description: nil)
    private static let plan = OpenCodeAgentOption(id: "plan", name: "plan", description: nil)
    private static let docs = OpenCodeAgentOption(id: "docs", name: "docs", description: nil)

    @Test("Cycling wraps both ways like the TUI's Tab and Shift-Tab")
    func cycleWraps() {
        let agents = [Self.build, Self.plan, Self.docs]
        #expect(OpenCodeAgentCycle.next(after: "build", in: agents)?.id == "plan")
        #expect(OpenCodeAgentCycle.next(after: "docs", in: agents)?.id == "build")
        #expect(OpenCodeAgentCycle.next(after: "build", in: agents, direction: .backward)?.id == "docs")
        #expect(OpenCodeAgentCycle.next(after: "plan", in: agents, direction: .backward)?.id == "build")
        #expect(OpenCodeAgentCycle.next(after: "build", in: [Self.build, Self.plan])?.id == "plan")
        #expect(OpenCodeAgentCycle.next(after: "plan", in: [Self.build, Self.plan])?.id == "build")
    }

    @Test("An agent outside the primary list starts from either end")
    func cycleFromUnknownAgent() {
        let agents = [Self.build, Self.plan]
        #expect(OpenCodeAgentCycle.next(after: "explore", in: agents)?.id == "build")
        #expect(OpenCodeAgentCycle.next(after: nil, in: agents, direction: .backward)?.id == "plan")
        #expect(OpenCodeAgentCycle.next(after: "build", in: []) == nil)
    }

    @Test("Current v2 agents without a name use their id and read title-cased")
    func parsesIDOnlyAgents() throws {
        let raw: [OpenCodeJSONValue] = try JSONDecoder().decode([OpenCodeJSONValue].self, from: Data("""
        [{"id":"plan","mode":"primary","hidden":false},{"id":"explore","mode":"subagent","hidden":false},
         {"name":"build","mode":"primary"},{"name":"Docs Writer","mode":"all"}]
        """.utf8))
        let agents = raw.compactMap(OpenCodeAgentOption.parse)
        #expect(agents.map(\.id) == ["plan", "build", "Docs Writer"])
        #expect(agents.map(\.displayName) == ["Plan", "Build", "Docs Writer"])
        #expect(agents.map(\.systemImage) == ["list.bullet.clipboard", "hammer", "person.crop.circle"])
    }

    @Test("Legacy catalogs keep the server's default agent first, the rest by name")
    func legacyOrdering() async throws {
        let transport = AgentCatalogTransport(agents: """
        [{"name":"plan","mode":"primary"},{"name":"title","mode":"primary","hidden":true},
         {"name":"docs","mode":"primary"},{"name":"build","mode":"primary"},{"name":"general","mode":"subagent"}]
        """)
        let context = OpenCodeFeatureContext(serverProtocol: .v1, schema: nil, transport: transport, profile: Self.profile)
        let catalog = try await OpenCodeClient.loadComposerCatalog(context, sessionID: "ses_a", directory: "/repo", workspace: nil)
        #expect(catalog.defaultAgentID == "plan")
        #expect(catalog.agents.map(\.id) == ["plan", "build", "docs"])
    }

    @Test("V2 catalogs gate on the agent routes, read id-only agents, and inherit the session agent")
    func v2Catalog() async throws {
        let schema: OpenCodeJSONValue = .object(["paths": .object([
            "/api/agent": .object(["get": .object([:])]),
            "/api/session/{sessionID}/agent": .object(["post": .object([:])]),
            "/api/session/{sessionID}": .object(["get": .object([:])]),
        ])])
        let transport = AgentCatalogTransport(agents: """
        {"data":[{"id":"plan","mode":"primary","hidden":false},{"id":"build","mode":"primary","hidden":false},
         {"id":"explore","mode":"subagent","hidden":false}]}
        """, sessionAgent: "plan")
        let context = OpenCodeFeatureContext(serverProtocol: .v2, schema: schema, transport: transport, profile: Self.profile)
        let catalog = try await OpenCodeClient.loadComposerCatalog(context, sessionID: "ses_a", directory: "/repo", workspace: nil)
        #expect(catalog.agents.map(\.id) == ["build", "plan"])
        #expect(catalog.defaultAgentID == "build")
        #expect(catalog.inheritedAgent == "plan")

        let ungated = OpenCodeFeatureContext(serverProtocol: .v2, schema: .object(["paths": .object([:])]),
                                             transport: transport, profile: Self.profile)
        let hidden = try await OpenCodeClient.loadComposerCatalog(ungated, sessionID: "ses_a", directory: "/repo", workspace: nil)
        #expect(hidden.agents.isEmpty, "Servers without agent routes hide the toggle instead of failing")
    }

    @MainActor
    @Test("Without a pick the toggle reflects the agent the session last ran")
    func reflectsTranscriptAgent() async throws {
        let (store, _, defaults) = try await makeStore(messages: [
            Self.message("msg_1", role: "user", agent: "plan", created: 1),
            Self.message("msg_2", role: "assistant", agent: "plan", created: 2),
            Self.message("msg_3", role: "user", agent: "explore", created: 3),
        ])
        defer { defaults.cleanUp() }
        #expect(store.currentAgentID == "plan", "Subagent turns do not change the primary agent")
        #expect(store.effectiveAgentID == "plan", "The next prompt continues with the shown agent")
        #expect(store.currentAgentName == "Plan")
        #expect(store.explicitAgentID == nil)

        let (fresh, _, freshDefaults) = try await makeStore(messages: [])
        defer { freshDefaults.cleanUp() }
        #expect(fresh.currentAgentID == "build", "A fresh session shows the server default")
        #expect(fresh.currentAgentName == "Build")
        #expect(fresh.effectiveAgentID == nil, "The server still chooses its own default")
    }

    @MainActor
    @Test("One tap cycles, persists for the session, and outranks the transcript")
    func cyclePersists() async throws {
        let (store, _, defaults) = try await makeStore(messages: [
            Self.message("msg_1", role: "user", agent: "plan", created: 1)
        ])
        defer { defaults.cleanUp() }
        #expect(store.nextAgentInCycle?.id == "build")
        store.cycleAgent()
        #expect(store.currentAgentID == "build")
        #expect(store.explicitAgentID == "build")
        store.cycleAgent()
        #expect(store.effectiveAgentID == "plan")
        store.cycleAgent(.backward)
        #expect(store.effectiveAgentID == "build")

        let reopened = OpenCodeSessionStore(service: AgentStoreService(messages: [
            Self.message("msg_1", role: "user", agent: "plan", created: 1)
        ]), serverID: Self.profile.id, session: Self.session, directory: "/repo", defaults: defaults.value)
        await reopened.reloadComposerCatalog()
        await reopened.refresh()
        #expect(reopened.currentAgentID == "build")
    }

    @MainActor
    @Test("A server-wide agent preference yields to this session's own history")
    func seededPreferenceYieldsToTranscript() async throws {
        let defaults = try IsolatedDefaults()
        defer { defaults.cleanUp() }
        defaults.value.set("build", forKey: "byot.opencode.agent.default.\(Self.profile.id.uuidString)")
        let (store, _, _) = try await makeStore(messages: [
            Self.message("msg_1", role: "user", agent: "plan", created: 1)
        ], defaults: defaults)
        #expect(store.selectedAgentID == "build")
        #expect(store.explicitAgentID == nil)
        #expect(store.currentAgentID == "plan")

        let (fresh, _, _) = try await makeStore(messages: [], defaults: defaults)
        #expect(fresh.effectiveAgentID == "build", "New sessions still start with the last agent picked on this server")
    }

    @MainActor
    @Test("A v2 agent switch from another client updates the toggle")
    func v2SwitchEvent() async throws {
        let (store, _, defaults) = try await makeStore(messages: [])
        defer { defaults.cleanUp() }
        for type in ["session.next.agent.switched", "session.agent.switched"] {
            let target = store.currentAgentID == "plan" ? "build" : "plan"
            store.handle(OpenCodeEvent(id: UUID().uuidString, type: type, properties: [
                "sessionID": .string("ses_a"), "messageID": .string("msg_x"), "agent": .string(target),
            ], isV2: true))
            #expect(store.currentAgentID == target)
        }
        store.handle(OpenCodeEvent(id: "evt_other", type: "session.next.agent.switched", properties: [
            "sessionID": .string("ses_other"), "agent": .string("docs"),
        ], isV2: true))
        #expect(store.currentAgentID == "build", "Other sessions' switches are ignored")
        store.selectAgent("plan")
        store.handle(OpenCodeEvent(id: "evt_late", type: "session.next.agent.switched", properties: [
            "sessionID": .string("ses_a"), "agent": .string("build"),
        ], isV2: true))
        #expect(store.currentAgentID == "plan", "An explicit pick on this device stays authoritative")
    }

    @MainActor
    @Test("A lone primary agent cannot be cycled")
    func singleAgent() async throws {
        let (store, _, defaults) = try await makeStore(
            messages: [], catalog: OpenCodeComposerCatalog(agents: [Self.build], defaultAgentID: "build"))
        defer { defaults.cleanUp() }
        #expect(store.nextAgentInCycle == nil)
        store.cycleAgent()
        #expect(store.explicitAgentID == nil)
        #expect(store.currentAgentName == "Build")
    }

    // MARK: Fixtures

    private static let profile = OpenCodeServerProfile(
        id: UUID(uuidString: "84848484-8484-8484-8484-848484848484")!, name: "Fixture", baseURL: "https://fixture.test")

    private static let session = OpenCodeSession(
        id: "ses_a", slug: "a", projectID: "pro", workspaceID: nil, directory: "/repo", parentID: nil,
        summary: nil, title: "Agent toggle", agent: nil, version: "1.18.29",
        time: OpenCodeSessionTime(created: 1, updated: 1, compacting: nil, archived: nil))

    fileprivate static let catalog = OpenCodeComposerCatalog(agents: [build, plan], defaultAgentID: "build")

    static func message(_ id: String, role: String, agent: String?, created: Double) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(info: OpenCodeMessageInfo(
            id: id, sessionID: "ses_a", role: role, time: OpenCodeMessageTime(created: created, completed: created),
            agent: agent, modelID: nil, providerID: nil, finish: nil, error: nil), parts: [])
    }

    @MainActor
    private func makeStore(messages: [OpenCodeMessageEnvelope], catalog: OpenCodeComposerCatalog = Self.catalog,
                           defaults: IsolatedDefaults? = nil) async throws
        -> (OpenCodeSessionStore, AgentStoreService, IsolatedDefaults) {
        let defaults = try defaults ?? IsolatedDefaults()
        let service = AgentStoreService(messages: messages, catalog: catalog)
        let store = OpenCodeSessionStore(service: service, serverID: Self.profile.id, session: Self.session,
                                         directory: "/repo", defaults: defaults.value)
        await store.reloadComposerCatalog()
        await store.refresh()
        return (store, service, defaults)
    }
}

private struct IsolatedDefaults {
    let suite = "agent-toggle-\(UUID().uuidString)"
    let value: UserDefaults
    init() throws { value = try #require(UserDefaults(suiteName: suite)) }
    func cleanUp() { value.removePersistentDomain(forName: suite) }
}

private actor AgentStoreService: OpenCodeSessionServicing {
    let transcript: [OpenCodeMessageEnvelope]
    let catalog: OpenCodeComposerCatalog
    init(messages: [OpenCodeMessageEnvelope], catalog: OpenCodeComposerCatalog = OpenCodeAgentToggleTests.catalog) {
        transcript = messages; self.catalog = catalog
    }
    func composerCatalog(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeComposerCatalog { catalog }
    func capabilities() async throws -> OpenCodeProtocolCapabilities { .v1 }
    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] { [] }
    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] { transcript }
    func sendMessage(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?, text: String,
                     attachments: [OpenCodePromptAttachment], promptID: UUID) async throws {}
    func abort(sessionID: String, directory: String, workspace: String?) async throws -> Bool { true }
    func diffs(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeDiff] { [] }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] { [:] }
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest] { [] }
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest] { [] }
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] { [] }
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] { [] }
    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?,
               reply: OpenCodePermissionReply) async throws {}
    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws {}
    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?) async throws {}
    nonisolated func events(directory: String, workspace: String?) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor AgentCatalogTransport: OpenCodeHTTPTransport {
    let agents: String
    let sessionAgent: String?
    init(agents: String, sessionAgent: String? = nil) { self.agents = agents; self.sessionAgent = sessionAgent }
    nonisolated func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        var components = URLComponents(string: "https://fixture.test/" + path.joined(separator: "/"))!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.httpBody = body
        return request
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = switch request.url!.path {
        case "/agent", "/api/agent": agents
        case "/api/session/ses_a": #"{"data":{"id":"ses_a","agent":"\#(sessionAgent ?? "")"}}"#
        default: "[]"
        }
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                                    headerFields: ["Content-Type": "application/json"])!)
    }
    nonisolated func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
