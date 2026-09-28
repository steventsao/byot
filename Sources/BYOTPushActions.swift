import Foundation
import UserNotifications

/// Notification categories the relay attaches to permission and question alerts
/// from an actionable companion. Every action that changes server state requires
/// an unlocked device; tapping the alert itself only opens the session.
enum BYOTPushCategory {
    static let permission = "BYOT_PERMISSION"
    static let question = "BYOT_QUESTION"

    static var all: Set<UNNotificationCategory> {
        let review = UNNotificationAction(
            identifier: BYOTPushAction.reviewIdentifier, title: String(localized: "Review in byot"),
            options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app"))
        let allow = UNNotificationAction(
            identifier: BYOTPushAction.allowOnceIdentifier, title: String(localized: "Allow once"),
            options: [.authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let reject = UNNotificationAction(
            identifier: BYOTPushAction.rejectIdentifier, title: String(localized: "Reject"),
            options: [.authenticationRequired, .destructive], icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let reply = UNTextInputNotificationAction(
            identifier: BYOTPushAction.replyIdentifier, title: String(localized: "Reply"),
            options: [.authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
            textInputButtonTitle: String(localized: "Send"), textInputPlaceholder: String(localized: "Your answer"))
        let open = UNNotificationAction(
            identifier: BYOTPushAction.reviewIdentifier, title: String(localized: "Open in byot"),
            options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "arrow.up.forward.app"))
        return [
            UNNotificationCategory(identifier: permission, actions: [allow, reject, review], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: String(localized: "Approval needed"), options: []),
            UNNotificationCategory(identifier: question, actions: [reply, open], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: String(localized: "OpenCode has a question"), options: []),
        ]
    }
}

/// A response chosen on a notification. There is deliberately no "always"
/// action: remembering a rule belongs in the app, where the request is visible.
enum BYOTPushAction: Equatable, Sendable {
    case allowOnce, reject
    case reply(String)

    static let allowOnceIdentifier = "byot.permission.allow-once"
    static let rejectIdentifier = "byot.permission.reject"
    static let replyIdentifier = "byot.question.reply"
    static let reviewIdentifier = "byot.review"

    init?(identifier: String, text: String?) {
        switch identifier {
        case Self.allowOnceIdentifier: self = .allowOnce
        case Self.rejectIdentifier: self = .reject
        case Self.replyIdentifier: self = .reply(text ?? "")
        default: return nil
        }
    }

    var kind: BYOTPushKind {
        switch self {
        case .allowOnce, .reject: .permission
        case .reply: .question
        }
    }
}

enum BYOTPushActionOutcome: Equatable, Sendable {
    /// The authoritative server accepted the response.
    case sent
    /// The request is no longer pending; someone answered it elsewhere or it expired.
    case alreadyHandled
    /// The alert does not identify a request, or the answer needs the full question UI.
    case needsReview
    /// The saved server was removed or its address or account changed since pairing.
    case serverChanged
    case failed

    /// Follow-up alerts are generic, like the relay's: they never repeat the reply text.
    var followUp: (title: String, body: String)? {
        switch self {
        case .sent: nil
        case .alreadyHandled: (String(localized: "Request already handled"), String(localized: "This request is no longer waiting for a response."))
        case .needsReview: (String(localized: "Open byot to respond"), String(localized: "This request needs a response in the app."))
        case .serverChanged: (String(localized: "Couldn’t send your response"), String(localized: "The saved server has changed or was removed. Open byot to review it."))
        case .failed: (String(localized: "Couldn’t send your response"), String(localized: "Your server couldn’t be reached or didn’t accept it. Open byot to try again."))
        }
    }
}

/// The narrow slice of the OpenCode API a notification action may use. Pending
/// requests are always read back from the server before replying, so a stale or
/// forged alert can never answer a request the server is not asking about.
protocol BYOTPushActionService: Sendable {
    func permissions(directory: String, workspace: String?) async throws -> [OpenCodePermissionRequest]
    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest]
    func questions(directory: String, workspace: String?) async throws -> [OpenCodeQuestionRequest]
    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest]
    func reply(to permission: OpenCodePermissionRequest, directory: String, workspace: String?,
               reply: OpenCodePermissionReply) async throws
    func answer(_ question: OpenCodeQuestionRequest, directory: String, workspace: String?, answers: [[String]]) async throws
}

extension OpenCodeClient: BYOTPushActionService {}

enum BYOTPushActionResponder {
    static let maximumReplyLength = 4_000

    static func perform(_ action: BYOTPushAction, route: BYOTPushRoute, service: any BYOTPushActionService,
                        timeout: Duration = .seconds(20)) async -> BYOTPushActionOutcome {
        guard let requestID = route.requestID, !route.sessionID.isEmpty else { return .needsReview }
        if case .reply(let text) = action, resolvedText(text) == nil { return .needsReview }
        return await withTaskGroup(of: BYOTPushActionOutcome?.self) { group in
            group.addTask { await respond(action, requestID: requestID, route: route, service: service) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            // Background actions get roughly 30 seconds; report a timeout rather than being killed silently.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? .failed
        }
    }

    private static func respond(_ action: BYOTPushAction, requestID: String, route: BYOTPushRoute,
                                service: any BYOTPushActionService) async -> BYOTPushActionOutcome {
        switch action {
        case .allowOnce, .reject:
            let lookup = await pending(
                legacy: { try await service.permissions(directory: route.directory, workspace: route.workspace) },
                v2: { try await service.v2Permissions(sessionID: route.sessionID) },
                matching: { $0.id == requestID && $0.sessionID == route.sessionID })
            guard case .found(let permission) = lookup else { return lookup.unansweredOutcome }
            do {
                try await service.reply(to: permission, directory: route.directory, workspace: route.workspace,
                                        reply: action == .allowOnce ? .once : .reject)
                return .sent
            } catch { return replyFailure(error) }
        case .reply(let text):
            let lookup = await pending(
                legacy: { try await service.questions(directory: route.directory, workspace: route.workspace) },
                v2: { try await service.v2Questions(sessionID: route.sessionID) },
                matching: { $0.id == requestID && $0.sessionID == route.sessionID })
            guard case .found(let question) = lookup else { return lookup.unansweredOutcome }
            guard let answers = answers(for: question, reply: text) else { return .needsReview }
            do {
                try await service.answer(question, directory: route.directory, workspace: route.workspace, answers: answers)
                return .sent
            } catch { return replyFailure(error) }
        }
    }

    /// OpenCode answers 404 when the request was resolved between the lookup and
    /// the reply, for example from the desktop; that is not a delivery failure.
    private static func replyFailure(_ error: any Error) -> BYOTPushActionOutcome {
        if case .httpStatus(404, _)? = error as? OpenCodeConnectionError { return .alreadyHandled }
        return .failed
    }

    /// A quick reply can only answer a single question: it selects the option whose
    /// label matches, or becomes the custom answer when the question allows one.
    static func answers(for request: OpenCodeQuestionRequest, reply text: String) -> [[String]]? {
        guard request.questions.count == 1, let question = request.questions.first,
              let text = resolvedText(text) else { return nil }
        if let option = question.options.first(where: {
            $0.label.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return [[option.id]]
        }
        return question.allowsCustomAnswer ? [[text]] : nil
    }

    private static func resolvedText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > maximumReplyLength ? nil : trimmed
    }

    private enum Lookup<Value: Sendable>: Sendable {
        case found(Value), missing, unavailable

        /// The outcome when no matching request can be answered.
        var unansweredOutcome: BYOTPushActionOutcome { if case .missing = self { .alreadyHandled } else { .failed } }
    }

    /// Both API generations are consulted, like the session view. A request that is
    /// absent from every successful response is treated as already handled; when a
    /// source failed, absence proves nothing and the action fails instead.
    private static func pending<Value: Sendable>(
        legacy: @escaping @Sendable () async throws -> [Value],
        v2: @escaping @Sendable () async throws -> [Value],
        matching: @escaping @Sendable (Value) -> Bool
    ) async -> Lookup<Value> {
        async let legacyResult = capture(legacy)
        async let v2Result = capture(v2)
        let results = await [legacyResult, v2Result]
        for case .success(let values) in results {
            if let match = values.first(where: matching) { return .found(match) }
        }
        return results.contains { if case .failure = $0 { true } else { false } } ? .unavailable : .missing
    }

    private static func capture<Value: Sendable>(
        _ body: @escaping @Sendable () async throws -> [Value]
    ) async -> Result<[Value], any Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }
}
