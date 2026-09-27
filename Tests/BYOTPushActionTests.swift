import Foundation
import Testing
import UserNotifications
@testable import byot

@MainActor
struct BYOTPushActionTests {
    private let key = Data(repeating: 9, count: 32).base64EncodedString()
    private let profile = OpenCodeServerProfile(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, name: "Mac mini", baseURL: "https://mini.example.test")

    @Test("Notification actions map to explicit replies and never include an always-allow action")
    func categories() throws {
        #expect(BYOTPushAction(identifier: BYOTPushAction.allowOnceIdentifier, text: nil) == .allowOnce)
        #expect(BYOTPushAction(identifier: BYOTPushAction.rejectIdentifier, text: nil) == .reject)
        #expect(BYOTPushAction(identifier: BYOTPushAction.replyIdentifier, text: "yes") == .reply("yes"))
        #expect(BYOTPushAction(identifier: BYOTPushAction.reviewIdentifier, text: nil) == nil)
        #expect(BYOTPushAction(identifier: UNNotificationDefaultActionIdentifier, text: nil) == nil)

        let categories = BYOTPushCategory.all
        let permission = try #require(categories.first { $0.identifier == BYOTPushCategory.permission })
        #expect(permission.actions.map(\.identifier) == [
            BYOTPushAction.allowOnceIdentifier, BYOTPushAction.rejectIdentifier, BYOTPushAction.reviewIdentifier,
        ])
        for action in permission.actions.prefix(2) {
            #expect(action.options.contains(.authenticationRequired))
            #expect(!action.options.contains(.foreground))
        }
        #expect(permission.actions[2].options.contains(.foreground))
        #expect(!permission.actions.contains { $0.title.localizedCaseInsensitiveContains("always") })

        let question = try #require(categories.first { $0.identifier == BYOTPushCategory.question })
        let reply = try #require(question.actions.first as? UNTextInputNotificationAction)
        #expect(reply.identifier == BYOTPushAction.replyIdentifier)
        #expect(reply.options.contains(.authenticationRequired))
    }

    @Test("Request IDs survive encryption and must be plain identifiers")
    func routeRequestID() throws {
        let route = BYOTPushRoute(serverID: profile.id, sessionID: "ses_1", directory: "/project", workspace: nil, requestID: "per_1")
        #expect(try BYOTPushRoute.decrypt(route.encrypted(key: key), key: key) == route)
        #expect(!BYOTPushRoute(serverID: profile.id, sessionID: "ses_1", directory: "/p", workspace: nil, requestID: "../per").isValid)
        #expect(!BYOTPushRoute(serverID: profile.id, sessionID: "ses_1", directory: "/p", workspace: nil, requestID: "").isValid)
        #expect(!BYOTPushRoute(serverID: profile.id, sessionID: "ses_1", directory: "/p", workspace: nil,
                               requestID: String(repeating: "a", count: 201)).isValid)
    }

    @Test("Only permission and question alerts may name a request")
    func requestKinds() throws {
        let (manager, credential) = manager()
        let route = BYOTPushRoute(serverID: profile.id, sessionID: "ses_1", directory: "/project", workspace: nil, requestID: "per_1")
        let decoded = try manager.decodeNotification(envelope(route, credential: credential, kind: "permission"))
        #expect(decoded.route == route)
        #expect(decoded.kind == .permission)
        #expect(throws: BYOTPushError.self) { try manager.decodeNotification(envelope(route, credential: credential, kind: "complete")) }
    }

    @Test("Allow once and Reject answer only the exact pending permission on the authoritative server")
    func permissionReplies() async throws {
        let service = FakeActionService()
        await service.set(permissions: [permission("per_1", session: "ses_1"), permission("per_2", session: "ses_1")])
        let route = route(requestID: "per_2")
        #expect(await BYOTPushActionResponder.perform(.allowOnce, route: route, service: service) == .sent)
        #expect(await BYOTPushActionResponder.perform(.reject, route: route, service: service) == .sent)
        #expect(await service.permissionReplies == ["per_2:once", "per_2:reject"])
        // Both API generations are read concurrently before every reply.
        #expect(await service.lookups.sorted() == ["legacy:/project:work_1", "legacy:/project:work_1", "v2:ses_1", "v2:ses_1"])
    }

    @Test("v2 permissions are found through the session route and answered with the v2 API")
    func v2PermissionReply() async throws {
        let service = FakeActionService()
        var request = permission("per_9", session: "ses_1")
        request.apiVersion = .v2
        await service.set(v2Permissions: [request])
        #expect(await BYOTPushActionResponder.perform(.allowOnce, route: route(requestID: "per_9"), service: service) == .sent)
        #expect(await service.permissionReplies == ["per_9:once"])
    }

    @Test("Stale, mismatched and unidentified requests are never answered")
    func staleRequests() async throws {
        let service = FakeActionService()
        await service.set(permissions: [permission("per_1", session: "ses_other")])
        #expect(await BYOTPushActionResponder.perform(.allowOnce, route: route(requestID: "per_1"), service: service) == .alreadyHandled)
        #expect(await BYOTPushActionResponder.perform(.allowOnce, route: route(requestID: nil), service: service) == .needsReview)
        await service.set(failsLookups: true)
        #expect(await BYOTPushActionResponder.perform(.allowOnce, route: route(requestID: "per_1"), service: service) == .failed)
        #expect(await service.permissionReplies.isEmpty)
    }

    @Test("A server that rejects the reply or never answers reports a failure")
    func replyFailures() async throws {
        let service = FakeActionService()
        await service.set(permissions: [permission("per_1", session: "ses_1")], failsReplies: true)
        #expect(await BYOTPushActionResponder.perform(.reject, route: route(requestID: "per_1"), service: service) == .failed)
        // A request resolved elsewhere after the lookup is reported as handled, not as a failure.
        await service.set(permissions: [permission("per_1", session: "ses_1")], resolvedBeforeReply: true)
        #expect(await BYOTPushActionResponder.perform(.allowOnce, route: route(requestID: "per_1"), service: service) == .alreadyHandled)
        let open = question("que_1", questions: [OpenCodeQuestion(question: "Branch?", header: "Branch", options: [],
                                                                   multiple: nil, custom: true)])
        await service.set(questions: [open], resolvedBeforeReply: true)
        #expect(await BYOTPushActionResponder.perform(.reply("main"), route: route(requestID: "que_1"), service: service) == .alreadyHandled)
        #expect(await service.permissionReplies.isEmpty)
        #expect(await service.answers.isEmpty)
        await service.set(permissions: [permission("per_1", session: "ses_1")], hangs: true)
        #expect(await BYOTPushActionResponder.perform(.allowOnce, route: route(requestID: "per_1"), service: service,
                                                      timeout: .milliseconds(50)) == .failed)
    }

    @Test("Quick replies select a matching option or become the custom answer for a single question")
    func quickReplyAnswers() {
        let choice = question("que_1", questions: [OpenCodeQuestion(question: "Deploy?", header: "Deploy", options: [
            OpenCodeQuestionOption(label: "Yes", description: "", wireValue: "true"),
            OpenCodeQuestionOption(label: "No", description: "", wireValue: "false"),
        ], multiple: false, custom: false)])
        #expect(BYOTPushActionResponder.answers(for: choice, reply: "  yes ") == [["true"]])
        #expect(BYOTPushActionResponder.answers(for: choice, reply: "maybe") == nil)
        #expect(BYOTPushActionResponder.answers(for: choice, reply: "   ") == nil)

        let open = question("que_2", questions: [OpenCodeQuestion(question: "Name?", header: "Name", options: [
            OpenCodeQuestionOption(label: "Café", description: ""),
        ], multiple: nil, custom: nil)])
        #expect(BYOTPushActionResponder.answers(for: open, reply: "cafe") == [["Café"]])
        #expect(BYOTPushActionResponder.answers(for: open, reply: "Release notes") == [["Release notes"]])
        #expect(BYOTPushActionResponder.answers(for: open, reply: String(repeating: "a", count: 4_001)) == nil)

        let two = question("que_3", questions: open.questions + open.questions)
        #expect(BYOTPushActionResponder.answers(for: two, reply: "Café") == nil)
    }

    @Test("Replies answer the pending question, and questions needing the full UI are left for review")
    func questionReplies() async throws {
        let service = FakeActionService()
        let single = question("que_1", questions: [OpenCodeQuestion(question: "Branch?", header: "Branch", options: [],
                                                                     multiple: nil, custom: true)])
        let multiple = question("que_2", questions: single.questions + single.questions)
        await service.set(questions: [single, multiple])
        #expect(await BYOTPushActionResponder.perform(.reply("main"), route: route(requestID: "que_1"), service: service) == .sent)
        #expect(await BYOTPushActionResponder.perform(.reply("main"), route: route(requestID: "que_2"), service: service) == .needsReview)
        #expect(await BYOTPushActionResponder.perform(.reply(" "), route: route(requestID: "que_1"), service: service) == .needsReview)
        #expect(await service.answers == ["que_1:main"])
    }

    @Test("The manager uses the saved server, and follow-ups stay generic and reopen the session")
    func managerRespond() async throws {
        let (manager, credential) = manager()
        let service = FakeActionService()
        await service.set(permissions: [permission("per_1", session: "ses_1")])
        let profile = profile
        let followUps = Recorder<UNNotificationRequest>(), passwords = Recorder<String>()
        manager.resolveServer = { id in id == profile.id ? (profile, "saved-password") : nil }
        manager.makeActionService = { _, password in passwords.items.append(password); return service }
        manager.deliverFollowUp = { followUps.items.append($0) }

        let data = try envelope(route(requestID: "per_1"), credential: credential, kind: "permission")
        #expect(await manager.respond(to: .allowOnce, notification: data, threadIdentifier: "thread") == .sent)
        #expect(passwords.items == ["saved-password"])
        #expect(followUps.items.isEmpty)

        // A reply action on an approval alert is not a valid answer to anything.
        #expect(await manager.respond(to: .reply("yes"), notification: data, threadIdentifier: "thread") == .needsReview)
        #expect(passwords.items.count == 1)
        await service.set(permissions: [])
        #expect(await manager.respond(to: .allowOnce, notification: data, threadIdentifier: "thread") == .alreadyHandled)
        #expect(followUps.items.map(\.content.title) == ["Open byot to respond", "Request already handled"])
        let followUp = try #require(followUps.items.last)
        #expect(followUp.content.title == "Request already handled")
        #expect(followUp.content.threadIdentifier == "thread")
        #expect(followUp.content.categoryIdentifier.isEmpty)
        let userInfo = try JSONSerialization.data(withJSONObject: followUp.content.userInfo)
        #expect(followUp.content.userInfo["aps"] == nil)
        #expect(try manager.decode(userInfo) == route(requestID: "per_1"))
        #expect(await service.permissionReplies == ["per_1:once"])
    }

    @Test("Changed or removed servers are never contacted")
    func changedServer() async throws {
        let (manager, credential) = manager()
        let contacted = Recorder<Bool>(), followUps = Recorder<String>()
        manager.makeActionService = { _, _ in contacted.items.append(true); return FakeActionService() }
        manager.deliverFollowUp = { followUps.items.append($0.content.title) }
        let data = try envelope(route(requestID: "per_1"), credential: credential, kind: "permission")

        manager.resolveServer = { _ in nil }
        #expect(await manager.respond(to: .allowOnce, notification: data) == .serverChanged)
        var moved = profile
        moved.baseURL = "https://other.example.test"
        manager.resolveServer = { [moved] _ in (moved, "password") }
        #expect(await manager.respond(to: .reject, notification: data) == .serverChanged)
        #expect(contacted.items.isEmpty)
        #expect(followUps.items == ["Couldn’t send your response", "Couldn’t send your response"])
    }

    // MARK: - Fixtures

    private func manager() -> (BYOTPushNotifications, BYOTPushCredential) {
        let credential = BYOTPushCredential(subscriptionID: UUID(), serverID: profile.id,
                                            fingerprint: BYOTPushCredential.fingerprint(profile), ownerKey: "fixture", routeKey: key)
        let manager = BYOTPushNotifications(credentials: [credential])
        manager.deliverFollowUp = { _ in }
        return (manager, credential)
    }

    private func route(requestID: String?) -> BYOTPushRoute {
        BYOTPushRoute(serverID: profile.id, sessionID: "ses_1", directory: "/project", workspace: "work_1", requestID: requestID)
    }

    private func envelope(_ route: BYOTPushRoute, credential: BYOTPushCredential, kind: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "aps": ["alert": ["title": "Approval needed"], "category": BYOTPushCategory.permission],
            "byot": ["version": 1, "subscriptionID": credential.subscriptionID.uuidString, "kind": kind,
                     "route": try route.encrypted(key: credential.routeKey)],
        ])
    }

    private func permission(_ id: String, session: String) -> OpenCodePermissionRequest {
        OpenCodePermissionRequest(id: id, sessionID: session, permission: "bash", patterns: ["npm test"], metadata: [:], always: [])
    }

    private func question(_ id: String, questions: [OpenCodeQuestion]) -> OpenCodeQuestionRequest {
        OpenCodeQuestionRequest(id: id, sessionID: "ses_1", questions: questions)
    }
}

@MainActor
private final class Recorder<Item> {
    var items: [Item] = []
}

private actor FakeActionService: BYOTPushActionService {
    private var legacyPermissions: [OpenCodePermissionRequest] = []
    private var v2PermissionList: [OpenCodePermissionRequest] = []
    private var questionList: [OpenCodeQuestionRequest] = []
    private var failsLookups = false
    private var failsReplies = false
    private var hangs = false
    private var resolvedBeforeReply = false
    private(set) var lookups: [String] = []
    private(set) var permissionReplies: [String] = []
    private(set) var answers: [String] = []

    func set(permissions: [OpenCodePermissionRequest]? = nil, v2Permissions: [OpenCodePermissionRequest]? = nil,
             questions: [OpenCodeQuestionRequest]? = nil, failsLookups: Bool = false, failsReplies: Bool = false,
             hangs: Bool = false, resolvedBeforeReply: Bool = false) {
        if let permissions { legacyPermissions = permissions }
        if let v2Permissions { v2PermissionList = v2Permissions }
        if let questions { questionList = questions }
        self.failsLookups = failsLookups
        self.failsReplies = failsReplies
        self.hangs = hangs
        self.resolvedBeforeReply = resolvedBeforeReply
    }

    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest] {
        lookups.append("legacy:\(directory):\(workspace ?? "")")
        if failsLookups { throw OpenCodeConnectionError.server("offline") }
        return legacyPermissions
    }

    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] {
        lookups.append("v2:\(sessionID)")
        return v2PermissionList
    }

    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest] {
        if failsLookups { throw OpenCodeConnectionError.server("offline") }
        return questionList
    }

    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] { [] }

    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?,
               reply: OpenCodePermissionReply) async throws {
        if hangs { try await Task.sleep(for: .seconds(30)) }
        if failsReplies { throw OpenCodeConnectionError.server("rejected") }
        if resolvedBeforeReply { throw OpenCodeConnectionError.httpStatus(404, "Permission request not found") }
        permissionReplies.append("\(permission.id):\(reply.rawValue)")
    }

    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws {
        if resolvedBeforeReply { throw OpenCodeConnectionError.httpStatus(404, "Question request not found") }
        self.answers.append("\(question.id):\(answers.flatMap { $0 }.joined(separator: ","))")
    }
}
