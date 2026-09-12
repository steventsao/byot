import Foundation
import XCTest
@testable import byot

final class OpenCodeComposerFeatureTests: XCTestCase {
    func testAgentsRequireAnAdvertisedEligibleModeAndExcludeHiddenSubagents() throws {
        let raw: [OpenCodeJSONValue] = try decode("""
        [{"name":"build","mode":"primary"},{"id":"agent-plan","name":"Plan","mode":"all"},
         {"name":"hidden","mode":"primary","hidden":true},{"name":"explore","mode":"subagent"},
         {"name":"unknown"}]
        """)
        XCTAssertEqual(raw.compactMap(OpenCodeAgentOption.parse).map(\.id), ["build", "agent-plan"])
    }

    func testSlashCatalogPreservesArgumentsAndSeparatesSkills() {
        let catalog = [OpenCodeSlashCommand(name: "review", description: "Review", kind: .command),
                       OpenCodeSlashCommand(name: "review", description: "Skill", kind: .skill),
                       OpenCodeSlashCommand(name: "explain", description: nil, kind: .skill)]
        XCTAssertEqual(OpenCodeCommandInvocation.parse("/review\t\"two words\"  third\nlast", catalog: catalog),
                       OpenCodeCommandInvocation(name: "review", arguments: "\"two words\"  third\nlast", kind: .command))
        XCTAssertEqual(OpenCodeCommandInvocation.parse("/explain file.swift", catalog: catalog)?.kind, .skill)
        XCTAssertNil(OpenCodeCommandInvocation.parse("/unknown hello", catalog: catalog))
        XCTAssertNil(OpenCodeCommandInvocation.parse("Explain /review", catalog: catalog))
    }

    func testProviderVariantsOnlyContainAdvertisedEnabledNames() throws {
        let catalog: OpenCodeProviderCatalog = try decode("""
        {"all":[{"id":"fixture","name":"Fixture","models":{"m":{"name":"M","variants":{
          "careful":{"reasoningEffort":"high"},"hidden":{"disabled":true},"quick":{}}}}}],"connected":["fixture"]}
        """)
        XCTAssertEqual(catalog.connectedProviders.first?.models.first?.variants, ["careful", "quick"])
    }

    func testQueuedAgentVariantCommandAndFileIntentSurvivesFailureAndRetry() throws {
        var queue = OpenCodePromptQueue()
        let reference = OpenCodePromptFileReference(serverID: profile.id, projectID: "pro", directory: "/repo", path: "x.swift")
        let command = OpenCodeCommandInvocation(name: "review", arguments: "one two", kind: .command)
        let accepted = queue.accept(text: "/review one two", model: model, agent: "plan", variant: "careful",
                                    command: command, remoteReferences: [reference], serverIsActive: true)
        guard case .queued(let original) = accepted else { return XCTFail("Must queue behind running work") }
        XCTAssertEqual(queue.prompts, [original])
        let dispatched = try XCTUnwrap(queue.serverBecameIdle())
        queue.dispatchFailed(dispatched, requeue: true)
        XCTAssertNil(queue.serverBecameIdle(), "An ambiguous command error must never auto-retry")
        XCTAssertNil(queue.reconciledServerIdle())
        let retry = try XCTUnwrap(queue.retry(original.id))
        XCTAssertEqual(retry, original)
        XCTAssertEqual(retry.messageID, original.messageID)
        XCTAssertEqual(retry.remoteReferences, [reference])
    }

    func testV1CommandUsesArgumentsQualifiedModelAndStableMessageID() throws {
        let dispatcher = OpenCodeComposerDispatch(context: makeContext(protocol: .v1))
        let prompt = OpenCodeQueuedPrompt(text: "/review hello", model: model, agent: "plan", variant: "careful",
            command: OpenCodeCommandInvocation(name: "review", arguments: "hello", kind: .command))
        let body = try XCTUnwrap(dispatcher.v1Body(prompt).objectValue)
        XCTAssertEqual(body["arguments"], .string("hello"))
        XCTAssertEqual(body["model"], .string("fixture/m"))
        XCTAssertEqual(body["agent"], .string("plan"))
        XCTAssertEqual(body["variant"], .string("careful"))
        XCTAssertEqual(body["messageID"], .string(prompt.messageID))
        XCTAssertEqual(body["parts"], .array([]))
        let automatic = dispatcher.v1Body(OpenCodeQueuedPrompt(text: "hello", model: nil)).objectValue
        XCTAssertNil(automatic?["agent"])
        XCTAssertNil(automatic?["model"])
        XCTAssertNil(automatic?["variant"])
    }

    func testBetaAppliesSelectionOnlyAtIdleDispatchAndPreservesPromptIDAndMetadata() async throws {
        let transport = ComposerFeatureTransport()
        let context = try makeBetaContext(transport: transport)
        let prompt = OpenCodeQueuedPrompt(text: "hello", model: model, agent: "plan", variant: "careful")
        let dispatcher = OpenCodeComposerDispatch(context: context)
        try await dispatcher.send(sessionID: "ses_test", directory: "/repo", workspace: nil, prompt: prompt)
        try await dispatcher.send(sessionID: "ses_test", directory: "/repo", workspace: nil, prompt: prompt)
        let requests = await transport.requests
        XCTAssertEqual(requests.prefix(4).map { $0.url!.path }, ["/api/session/active", "/api/session/ses_test/agent", "/api/session/ses_test/model", "/api/session/ses_test/prompt"])
        let models = requests.filter { $0.url!.path.hasSuffix("/model") }
        XCTAssertEqual(try body(models[0])["model"]?.objectValue?["variant"], .string("careful"))
        let prompts = requests.filter { $0.url!.path.hasSuffix("/prompt") }
        XCTAssertEqual(try body(prompts[0])["id"], try body(prompts[1])["id"])
        XCTAssertEqual(try body(prompts[0])["metadata"]?.objectValue?["agent"], .string("plan"))
        XCTAssertEqual(try body(prompts[0])["metadata"]?.objectValue?["model"]?.objectValue?["variant"], .string("careful"))
        let defaultBody = try dispatcher.v2Body(OpenCodeQueuedPrompt(text: "hello", model: model)).objectValue
        XCTAssertNil(defaultBody?["metadata"]?.objectValue?["model"]?.objectValue?["variant"])
    }

    func testBetaActiveSessionDoesNotGetReconfiguredOrAdmitQueuedIntentEarly() async throws {
        let transport = ComposerFeatureTransport(active: true)
        let dispatcher = try OpenCodeComposerDispatch(context: makeBetaContext(transport: transport))
        do {
            try await dispatcher.send(sessionID: "ses_test", directory: "/repo", workspace: nil,
                prompt: OpenCodeQueuedPrompt(text: "later", model: model, agent: "plan", variant: "careful"))
            XCTFail("Active selection must be preserved")
        } catch { XCTAssertTrue(error.localizedDescription.contains("became active")) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
    }

    func testBetaCommandHasNoInventedAdmissionIDAndNeverAutomaticallyRetriesOnTimeout() async throws {
        let transport = ComposerFeatureTransport(failCommands: true)
        let dispatcher = try OpenCodeComposerDispatch(context: makeBetaContext(transport: transport))
        let prompt = OpenCodeQueuedPrompt(text: "/review argument", model: nil,
            command: OpenCodeCommandInvocation(name: "review", arguments: "argument", kind: .command))
        let wire = try XCTUnwrap(dispatcher.v2Body(prompt).objectValue)
        XCTAssertEqual(wire["command"], .string("review"))
        XCTAssertEqual(wire["text"], .string("argument"))
        XCTAssertNil(wire["id"])
        XCTAssertNil(wire["metadata"])
        do { try await dispatcher.send(sessionID: "ses_test", directory: "/repo", workspace: nil, prompt: prompt); XCTFail() }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testBetaMissingMetadataIsOmittedAndMissingCommandRouteRejected() throws {
        var schema = try betaSchema().objectValue!
        var paths = schema["paths"]!.objectValue!
        paths.removeValue(forKey: "/api/session/{sessionID}/command")
        var route = paths["/api/session/{sessionID}/prompt"]!.objectValue!
        var post = route["post"]!.objectValue!
        var requestBody = post["requestBody"]!.objectValue!
        var content = requestBody["content"]!.objectValue!
        var json = content["application/json"]!.objectValue!
        var shape = json["schema"]!.objectValue!
        var properties = shape["properties"]!.objectValue!
        properties.removeValue(forKey: "metadata")
        shape["properties"] = .object(properties); json["schema"] = .object(shape)
        content["application/json"] = .object(json); requestBody["content"] = .object(content)
        post["requestBody"] = .object(requestBody); route["post"] = .object(post)
        paths["/api/session/{sessionID}/prompt"] = .object(route); schema["paths"] = .object(paths)
        let dispatcher = OpenCodeComposerDispatch(context: OpenCodeFeatureContext(serverProtocol: .v2,
            schema: .object(schema), transport: ComposerFeatureTransport(), profile: profile))
        XCTAssertNil(try dispatcher.v2Body(OpenCodeQueuedPrompt(text: "test", model: model)).objectValue?["metadata"])
        XCTAssertThrowsError(try dispatcher.v2Body(OpenCodeQueuedPrompt(text: "/review", model: nil,
            command: OpenCodeCommandInvocation(name: "review", arguments: "", kind: .command))))
    }

    @MainActor
    func testAgentAndVariantPreferencesPreserveSessionServerAndModelScope() async throws {
        let suite = "composer-scope-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = ComposerFeatureTransport()
        let client = OpenCodeClient(profile: profile, transport: transport, serverProtocol: .v1)
        func session(_ id: String) -> OpenCodeSession {
            OpenCodeSession(id: id, slug: id, projectID: "pro", workspaceID: nil, directory: "/repo", parentID: nil,
                summary: nil, title: id, agent: nil, version: "1.18.29",
                time: OpenCodeSessionTime(created: 1, updated: 1, compacting: nil, archived: nil))
        }
        let first = OpenCodeSessionStore(client: client, session: session("ses_one"), directory: "/repo", defaults: defaults)
        await first.reloadModels()
        let m = try XCTUnwrap(first.providerModels.first?.models.first { $0.modelID == "m" })
        let alternate = try XCTUnwrap(first.providerModels.first?.models.first { $0.modelID == "other" })
        first.selectModel(m); first.selectAgent("plan"); first.selectVariant("careful")
        first.selectVariant("not-advertised")
        XCTAssertEqual(first.selectedVariant, "careful", "Invalid variants must never be persisted")
        first.selectModel(alternate)
        XCTAssertNil(first.selectedVariant)
        first.selectModel(m)
        XCTAssertEqual(first.selectedVariant, "careful")
        let reopened = OpenCodeSessionStore(client: client, session: session("ses_one"), directory: "/repo", defaults: defaults)
        await reopened.reloadModels()
        XCTAssertEqual(reopened.selectedAgentID, "plan")
        XCTAssertEqual(reopened.selectedVariant, "careful")
        let second = OpenCodeSessionStore(client: client, session: session("ses_two"), directory: "/repo", defaults: defaults)
        await second.reloadModels()
        XCTAssertEqual(second.selectedAgentID, "plan")
        XCTAssertEqual(second.selectedVariant, "careful")
        second.selectVariant(nil)
        second.selectAgent(nil)
        let firstAgain = OpenCodeSessionStore(client: client, session: session("ses_one"), directory: "/repo", defaults: defaults)
        await firstAgain.reloadModels()
        XCTAssertEqual(firstAgain.selectedVariant, "careful", "Another session's Default cannot erase this session's preference")
        let secondAgain = OpenCodeSessionStore(client: client, session: session("ses_two"), directory: "/repo", defaults: defaults)
        await secondAgain.reloadModels()
        XCTAssertNil(secondAgain.selectedVariant, "Explicit Default remains Default after reconnect")
        XCTAssertNil(secondAgain.selectedAgentID)
        let otherServer = OpenCodeClient(profile: OpenCodeServerProfile(name: "Other", baseURL: "https://fixture.test"),
            transport: transport, serverProtocol: .v1)
        let unrelated = OpenCodeSessionStore(client: otherServer, session: session("ses_one"), directory: "/repo", defaults: defaults)
        await unrelated.reloadModels()
        XCTAssertNil(unrelated.selectedModel)
        XCTAssertNil(unrelated.selectedAgentID)
        XCTAssertNil(unrelated.selectedVariant)
    }

    func testMessageSelectionMetadataSurvivesV1AndV2Reload() throws {
        let v1: OpenCodeMessageInfo = try decode("""
        {"id":"msg_a","sessionID":"ses_test","role":"user","time":{"created":1},"agent":"plan",
         "model":{"providerID":"fixture","modelID":"m"},"variant":"careful"}
        """)
        XCTAssertEqual(v1.modelID, "m")
        XCTAssertEqual(v1.variant, "careful")
        let raw: OpenCodeJSONValue = try decode("""
        {"id":"msg_a","type":"user","text":"argument","metadata":{"displayText":"/review argument",
         "agent":"plan","model":{"providerID":"fixture","modelID":"m","variant":"careful"}},"time":{"created":1}}
        """)
        let v2 = try XCTUnwrap(OpenCodeV2Normalization.message(raw.objectValue!, sessionID: "ses_test"))
        XCTAssertEqual(v2.parts.first?.text, "/review argument")
        XCTAssertEqual(v2.info.agent, "plan")
        XCTAssertEqual(v2.info.variant, "careful")
    }

    private var profile: OpenCodeServerProfile { OpenCodeServerProfile(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Fixture", baseURL: "https://fixture.test") }
    private var model: OpenCodeModelOption { OpenCodeModelOption(providerID: "fixture", providerName: "Fixture", modelID: "m", modelName: "M", status: nil, variants: ["careful", "quick"]) }
    private func makeContext(protocol value: OpenCodeServerProtocol) -> OpenCodeFeatureContext {
        OpenCodeFeatureContext(serverProtocol: value, schema: nil, transport: ComposerFeatureTransport(), profile: profile)
    }
    private func betaSchema() throws -> OpenCodeJSONValue {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "opencode2-beta-19242-openapi", withExtension: "json"))
        return try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(contentsOf: url))
    }
    private func makeBetaContext(transport: ComposerFeatureTransport) throws -> OpenCodeFeatureContext {
        OpenCodeFeatureContext(serverProtocol: .v2, schema: try betaSchema(), transport: transport, profile: profile)
    }
    private func decode<T: Decodable>(_ raw: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(raw.utf8)) }
    private func body(_ request: URLRequest) throws -> [String: OpenCodeJSONValue] {
        try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: XCTUnwrap(request.httpBody))
    }
}

private actor ComposerFeatureTransport: OpenCodeHTTPTransport {
    var requests: [URLRequest] = []
    let active: Bool
    let failCommands: Bool
    init(active: Bool = false, failCommands: Bool = false) { self.active = active; self.failCommands = failCommands }
    nonisolated func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        var components = URLComponents(string: "https://fixture.test/" + path.joined(separator: "/"))!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.httpBody = body
        return request
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url!.path
        if failCommands, path.hasSuffix("/command") { throw URLError(.timedOut) }
        let response: String
        if path == "/provider" {
            response = #"{"all":[{"id":"fixture","name":"Fixture","models":{"m":{"name":"M","variants":{"careful":{},"quick":{}}},"other":{"name":"Other","variants":{"quick":{}}}}}],"connected":["fixture"]}"#
        } else if path == "/agent" { response = #"[{"name":"plan","mode":"primary"},{"name":"build","mode":"primary"}]"# }
        else if path == "/command" { response = "[]" }
        else if path.hasSuffix("/active") { response = active ? #"{"data":{"ses_test":{}}}"# : #"{"data":{}}"# }
        else { response = #"{"data":{"sessionID":"ses_test"}}"# }
        return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!)
    }
    nonisolated func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
