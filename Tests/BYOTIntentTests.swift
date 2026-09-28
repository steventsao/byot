import Foundation
import Testing
@testable import byot

@MainActor
struct BYOTIntentTests {
    private let mini = OpenCodeServerProfile(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Mac mini",
        baseURL: "https://mini.example.test")
    private let studio = OpenCodeServerProfile(
        id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, name: "Studio",
        baseURL: "https://studio.example.test")

    // MARK: Ask OpenCode

    @Test("Ask OpenCode starts a session in the configured directory with the server's saved model, agent and variant")
    func askUsesSavedChoices() async throws {
        var profile = mini
        profile.directory = "/repo/app"
        let fake = FakeIntentService()
        await fake.set(providers: [OpenCodeProviderModels(providerID: "anthropic", providerName: "Anthropic",
                                                          models: [model("anthropic", "sonnet", variants: ["high"])])],
                       catalog: OpenCodeComposerCatalog(agents: [OpenCodeAgentOption(id: "plan", name: "Plan", description: nil)],
                                                        supportsVariants: true))
        let defaults = Defaults()
        defaults.store.set("anthropic/sonnet", forKey: OpenCodeSessionStore.serverDefaultModelKey(profile.id))
        defaults.store.set("plan", forKey: OpenCodeSessionStore.serverDefaultAgentKey(profile.id))
        defaults.store.set("high", forKey: OpenCodeSessionStore.serverDefaultVariantKey(
            profile.id, model: model("anthropic", "sonnet", variants: ["high"])))
        let recorder = Recorder()
        let service = service([profile.id: fake], profiles: [profile], defaults: defaults, recorder: recorder)

        let result = try await service.ask(prompt: "  Fix the login crash\n", serverID: nil, directory: nil)

        #expect(await fake.createdDirectories == ["/repo/app"])
        let sent = try #require(await fake.sentPrompts.first)
        #expect(sent.text == "Fix the login crash")
        #expect(sent.model?.qualifiedID == "anthropic/sonnet")
        #expect(sent.agent == "plan")
        #expect(sent.variant == "high")
        #expect(result.session.state == .running)
        #expect(result.session.projectName == "app")
        #expect(result.dialog == "Sent. OpenCode is working in app on Mac mini.")
        #expect(recorder.started == ["ses_new"])
    }

    @Test("Saved choices the server no longer offers fall back to the server's own defaults")
    func askDropsStaleChoices() async throws {
        let fake = FakeIntentService()
        await fake.set(providers: [OpenCodeProviderModels(providerID: "openai", providerName: "OpenAI",
                                                          models: [model("openai", "gpt")])],
                       catalog: OpenCodeComposerCatalog(agents: [OpenCodeAgentOption(id: "build", name: "Build", description: nil)]))
        let defaults = Defaults()
        defaults.store.set("anthropic/retired", forKey: OpenCodeSessionStore.serverDefaultModelKey(mini.id))
        defaults.store.set("removed-agent", forKey: OpenCodeSessionStore.serverDefaultAgentKey(mini.id))
        let service = service([mini.id: fake], profiles: [mini], defaults: defaults)

        _ = try await service.ask(prompt: "Hi", serverID: mini.id, directory: "/repo")

        let sent = try #require(await fake.sentPrompts.first)
        #expect(sent.model == nil)
        #expect(sent.agent == nil)
        #expect(sent.variant == nil)
    }

    @Test("Without a configured directory Ask uses the only project, and asks when there are several")
    func askResolvesProject() async throws {
        let fake = FakeIntentService()
        // V1 always lists its catch-all global project; it never counts as a choice.
        let global = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: nil,
                                     time: OpenCodeProjectTime(created: 0, updated: 9), sandboxes: [])
        await fake.set(projects: [global, project("/repo/one", updated: 1)])
        let service = service([mini.id: fake], profiles: [mini])
        #expect(try await service.projects(serverID: mini.id).map(\.directory) == ["/repo/one"])
        let result = try await service.ask(prompt: "Hi", serverID: mini.id, directory: nil)
        #expect(await fake.createdDirectories == ["/repo/one"])
        #expect(result.session.projectName == "one")

        await fake.set(projects: [project("/repo/one", updated: 1), project("/repo/two", updated: 2)])
        await #expect(throws: BYOTIntentError.needsProject) {
            try await service.ask(prompt: "Hi", serverID: mini.id, directory: nil)
        }
        await fake.set(projects: [global])
        await #expect(throws: BYOTIntentError.noProjects(server: "Mac mini")) {
            try await service.ask(prompt: "Hi", serverID: mini.id, directory: nil)
        }
        // Only the first request created a session.
        #expect(await fake.createdDirectories == ["/repo/one"])
    }

    @Test("Ask refuses empty prompts and missing, unsupported, unreachable or rejecting servers")
    func askFailures() async throws {
        let fake = FakeIntentService()
        let service = service([mini.id: fake], profiles: [mini], timeout: .milliseconds(100))
        await #expect(throws: BYOTIntentError.emptyPrompt) {
            try await service.ask(prompt: " \n ", serverID: nil, directory: "/repo")
        }
        await #expect(throws: BYOTIntentError.promptTooLong) {
            try await service.ask(prompt: String(repeating: "a", count: BYOTIntentService.maximumPromptLength + 1),
                                  serverID: nil, directory: "/repo")
        }
        await #expect(throws: BYOTIntentError.serverRemoved) {
            try await service.ask(prompt: "Hi", serverID: studio.id, directory: "/repo")
        }
        await #expect(throws: BYOTIntentError.noServers) {
            try await self.service([:], profiles: []).ask(prompt: "Hi", serverID: nil, directory: "/repo")
        }

        await fake.set(compatibility: .unsupported(reason: "OpenCode 0.9 is too old."))
        await #expect(throws: BYOTIntentError.unsupported(server: "Mac mini", detail: "OpenCode 0.9 is too old.")) {
            try await service.ask(prompt: "Hi", serverID: nil, directory: "/repo")
        }
        await fake.set(compatibility: .compatible(isVerifiedBaseline: true), hangs: true)
        await #expect(throws: BYOTIntentError.unreachable(server: "Mac mini")) {
            try await service.ask(prompt: "Hi", serverID: nil, directory: "/repo")
        }
        await fake.set(hangs: false, rejectsProbe: true)
        await #expect(throws: BYOTIntentError.failed(server: "Mac mini",
                                                     detail: "OpenCode rejected the username or password.")) {
            try await service.ask(prompt: "Hi", serverID: nil, directory: "/repo")
        }
        await fake.set(rejectsProbe: false, rejectsPrompts: true)
        await #expect(throws: BYOTIntentError.notSent(server: "Mac mini", detail: "OpenCode returned 400: No provider")) {
            try await service.ask(prompt: "Hi", serverID: nil, directory: "/repo")
        }
        #expect(await fake.sentPrompts.isEmpty)
    }

    // MARK: Sessions needing attention

    @Test("The attention check lists waiting and failed sessions across servers and shares them with the widget")
    func attentionAcrossServers() async throws {
        let fake = FakeIntentService()
        await fake.set(projects: [project("/repo", updated: 1)],
                       sessions: ["/repo": [session("waiting", updated: 3), session("broken", updated: 2),
                                            session("busy", updated: 4), session("done", updated: 5)]],
                       statuses: ["waiting": .busy, "busy": .busy, "broken": .idle, "done": .idle],
                       pending: ["waiting"],
                       messages: ["broken": failedTurn("Rate limited")])
        let offline = FakeIntentService()
        await offline.set(failsProjects: true)
        let defaults = Defaults()
        defaults.store.set(["broken": "Rate limited"], forKey: "byot.opencode.attention.\(mini.id.uuidString)")
        let recorder = Recorder()
        let service = service([mini.id: fake, studio.id: offline], profiles: [mini, studio], defaults: defaults,
                              recorder: recorder)

        let report = try await service.attention(serverID: nil)

        #expect(report.sessions.map(\.sessionID) == ["waiting", "broken"])
        #expect(report.sessions.map(\.state) == [.needsResponse, .failed])
        #expect(report.runningCount == 1)
        #expect(report.checkedServers == 1)
        #expect(report.unreachable == ["Studio"])
        #expect(recorder.published.map(\.serverID) == [mini.id])
        #expect(report.dialog == "2 sessions need you: “waiting” is waiting for you and “broken” failed. "
                + "1 session is running. Couldn’t fully check Studio.")
    }

    @Test("A failure since retried from another client is cleared instead of reported")
    func attentionReconcilesFailures() async throws {
        let fake = FakeIntentService()
        await fake.set(projects: [project("/repo", updated: 1)], sessions: ["/repo": [session("fixed", updated: 1)]],
                       statuses: ["fixed": .idle], messages: ["fixed": []])
        let defaults = Defaults()
        let key = "byot.opencode.attention.\(mini.id.uuidString)"
        defaults.store.set(["fixed": "Rate limited"], forKey: key)
        let service = service([mini.id: fake], profiles: [mini], defaults: defaults)

        let report = try await service.attention(serverID: mini.id)

        #expect(report.sessions.isEmpty)
        #expect((defaults.store.dictionary(forKey: key) ?? [:]).isEmpty)
        #expect(report.dialog == "Nothing needs you right now.")
    }

    @Test("Spoken summaries name a few sessions, count the rest and report servers that didn't answer")
    func attentionDialog() {
        #expect(BYOTAttentionReport(checkedServers: 1).dialog == "Nothing needs you right now.")
        #expect(BYOTAttentionReport(runningCount: 2, checkedServers: 1).dialog
                == "Nothing needs you right now. 2 sessions are running.")
        let sessions = ["A", "B", "C", "D", "E"].map { title in
            BYOTIntentSession(serverID: mini.id, serverName: "Mac mini", sessionID: title, title: title,
                              projectName: "app", directory: "/app", workspace: nil, state: .needsResponse,
                              updatedAt: .now)
        }
        #expect(BYOTAttentionReport(sessions: Array(sessions.prefix(1)), checkedServers: 1).dialog
                == "1 session needs you: “A” is waiting for you.")
        #expect(BYOTAttentionReport(sessions: sessions, checkedServers: 1).dialog
                == "5 sessions need you: “A” is waiting for you, “B” is waiting for you, “C” is waiting for you, and 2 more.")
        #expect(BYOTAttentionReport(unreachable: ["Mac mini", "Studio"]).dialog
                == "Couldn’t reach Mac mini and Studio. Check that byot’s servers are running, then try again.")
    }

    // MARK: Entities

    @Test("Recent sessions for Open Session merge servers newest first and skip servers that don't answer")
    func recentSessions() async throws {
        let first = FakeIntentService()
        await first.set(projects: [project("/a", updated: 1)],
                        sessions: ["/a": [session("a1", updated: 1, directory: "/a"), session("a2", updated: 30, directory: "/a")]],
                        statuses: ["a2": .busy])
        let second = FakeIntentService()
        await second.set(projects: [project("/b", updated: 1)],
                         sessions: ["/b": [session("b1", updated: 20, directory: "/b")]])
        let service = service([mini.id: first, studio.id: second], profiles: [mini, studio])

        let sessions = try await service.recentSessions(limit: 2)

        #expect(sessions.map(\.sessionID) == ["a2", "b1"])
        #expect(sessions.map(\.state) == [.running, nil])
        #expect(sessions.map(\.serverName) == ["Mac mini", "Studio"])
    }

    @Test("Project and session identifiers find the same place again")
    func identifiers() throws {
        let id = BYOTIntentProject.id(serverID: mini.id, directory: "/repo/odd|name")
        let parsed = try #require(BYOTIntentProject.parse(id))
        #expect(parsed.serverID == mini.id)
        #expect(parsed.directory == "/repo/odd|name")
        #expect(BYOTIntentProject.parse("not-a-uuid|/repo") == nil)
        #expect(BYOTIntentProject.parse("\(mini.id.uuidString)|") == nil)

        let entry = BYOTIntentSession(profile: mini, session: session("ses_1", updated: 1, workspace: "wrk_1"))
        let link = try #require(URL(string: entry.id).flatMap(BYOTWidgetLink.init(url:)))
        #expect(link == entry.link)
        #expect(link.workspace == "wrk_1")
        #expect(entry.state == nil)
    }

    @Test("Open Session routes through the same path as a widget tap, without notification pairing")
    func openSessionRoute() {
        let destination = BYOTPushDestination(
            route: BYOTPushRoute(serverID: mini.id, sessionID: "ses_1", directory: "/repo", workspace: nil),
            origin: .shortcut)
        #expect(destination.route.isValid)
        #expect(destination.origin != .notification)
    }

    // MARK: Fixtures

    private func service(
        _ fakes: [UUID: FakeIntentService], profiles: [OpenCodeServerProfile], defaults: Defaults = Defaults(),
        timeout: Duration = .seconds(2), recorder: Recorder = Recorder()
    ) -> BYOTIntentService {
        BYOTIntentService(
            profiles: { profiles }, activeProfileID: { nil },
            makeService: { fakes[$0.id] ?? FakeIntentService() },
            defaultsSuiteName: defaults.suite, timeout: timeout,
            publish: { recorder.published.append($0) },
            started: { _, session in recorder.started.append(session.id) })
    }

    private func model(_ provider: String, _ id: String, variants: [String] = []) -> OpenCodeModelOption {
        OpenCodeModelOption(providerID: provider, providerName: provider, modelID: id, modelName: id, status: nil,
                            variants: variants)
    }

    private func project(_ worktree: String, updated: Double) -> OpenCodeProject {
        OpenCodeProject(id: worktree, worktree: worktree, vcs: "git", name: nil,
                        time: OpenCodeProjectTime(created: 0, updated: updated), sandboxes: [])
    }

    private func session(_ id: String, updated: Double, directory: String = "/repo",
                         workspace: String? = nil) -> OpenCodeSession {
        OpenCodeSession(id: id, slug: id, projectID: directory, workspaceID: workspace, directory: directory,
                        parentID: nil, summary: nil, title: id, agent: nil, version: "1.18.29",
                        time: OpenCodeSessionTime(created: 0, updated: updated * 1000, compacting: nil, archived: nil))
    }

    private func failedTurn(_ message: String) -> [OpenCodeMessageEnvelope] {
        [envelope("u", role: "user", error: nil),
         envelope("a", role: "assistant", error: OpenCodeMessageError(name: "APIError", data: ["message": .string(message)]))]
    }

    private func envelope(_ id: String, role: String, error: OpenCodeMessageError?) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(info: OpenCodeMessageInfo(id: id, sessionID: "broken", role: role,
            time: OpenCodeMessageTime(created: 1, completed: nil), agent: nil, modelID: nil,
            providerID: nil, finish: nil, error: error), parts: [])
    }
}

/// An isolated defaults suite per test.
private struct Defaults {
    let suite = "byot.tests.intents.\(UUID().uuidString)"
    var store: UserDefaults { UserDefaults(suiteName: suite)! }
}

@MainActor
private final class Recorder {
    var published: [BYOTWidgetServer] = []
    var started: [String] = []
}

private actor FakeIntentService: BYOTIntentServing {
    private var compatibility: OpenCodeCompatibility = .compatible(isVerifiedBaseline: true)
    private var projects: [OpenCodeProject] = []
    private var sessions: [String: [OpenCodeSession]] = [:]
    private var statuses: [String: OpenCodeSessionStatus] = [:]
    private var pending: Set<String> = []
    private var messages: [String: [OpenCodeMessageEnvelope]] = [:]
    private var providers: [OpenCodeProviderModels] = []
    private var catalog = OpenCodeComposerCatalog()
    private var failsProjects = false
    private var hangs = false
    private var rejectsProbe = false
    private var rejectsPrompts = false
    private(set) var createdDirectories: [String] = []
    private(set) var sentPrompts: [OpenCodeQueuedPrompt] = []

    func set(compatibility: OpenCodeCompatibility? = nil, projects: [OpenCodeProject]? = nil,
             sessions: [String: [OpenCodeSession]]? = nil, statuses: [String: OpenCodeSessionStatus]? = nil,
             pending: Set<String>? = nil, messages: [String: [OpenCodeMessageEnvelope]]? = nil,
             providers: [OpenCodeProviderModels]? = nil, catalog: OpenCodeComposerCatalog? = nil,
             failsProjects: Bool? = nil, hangs: Bool? = nil, rejectsProbe: Bool? = nil,
             rejectsPrompts: Bool? = nil) {
        if let compatibility { self.compatibility = compatibility }
        if let projects { self.projects = projects }
        if let sessions { self.sessions = sessions }
        if let statuses { self.statuses = statuses }
        if let pending { self.pending = pending }
        if let messages { self.messages = messages }
        if let providers { self.providers = providers }
        if let catalog { self.catalog = catalog }
        if let failsProjects { self.failsProjects = failsProjects }
        if let hangs { self.hangs = hangs }
        if let rejectsProbe { self.rejectsProbe = rejectsProbe }
        if let rejectsPrompts { self.rejectsPrompts = rejectsPrompts }
    }

    private func wait() async throws {
        if hangs { try await Task.sleep(for: .seconds(30)) }
    }

    func probeCompatibility() async throws -> OpenCodeCompatibilitySummary {
        try await wait()
        if rejectsProbe { throw OpenCodeConnectionError.httpStatus(401, nil) }
        return OpenCodeCompatibilitySummary(verdict: compatibility, health: OpenCodeHealth(healthy: true, version: "1.18.29"),
                                            capabilityProbe: .unavailable)
    }

    func listProjects() async throws -> [OpenCodeProject] {
        try await wait()
        if failsProjects { throw URLError(.cannotConnectToHost) }
        return projects
    }

    func listSessions(directory: String) async throws -> [OpenCodeSession] { sessions[directory] ?? [] }

    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] {
        statuses
    }

    func pendingInputRequests(directory: String) async throws -> [String: Set<String>]? {
        Dictionary(uniqueKeysWithValues: pending.map { ($0, ["per_\($0)"]) })
    }

    func createSession(directory: String, title: String?) async throws -> OpenCodeSession {
        try await wait()
        createdDirectories.append(directory)
        return OpenCodeSession(id: "ses_new", slug: "new", projectID: "pro", workspaceID: nil, directory: directory,
                               parentID: nil, summary: nil, title: "", agent: nil, version: "1.18.29",
                               time: OpenCodeSessionTime(created: 0, updated: 0, compacting: nil, archived: nil))
    }

    func connectedProviderModels(directory: String, workspace: String?) async throws -> [OpenCodeProviderModels] {
        providers
    }

    func composerCatalog(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeComposerCatalog {
        catalog
    }

    func sendPrompt(sessionID: String, directory: String, workspace: String?, prompt: OpenCodeQueuedPrompt) async throws {
        if rejectsPrompts { throw OpenCodeConnectionError.httpStatus(400, "No provider") }
        sentPrompts.append(prompt)
    }

    func messages(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeMessageEnvelope] {
        messages[sessionID] ?? []
    }

    func sessionDetails(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSessionDetails {
        throw OpenCodeConnectionError.httpStatus(404, nil)
    }
}
