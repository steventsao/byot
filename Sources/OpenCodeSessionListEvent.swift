import Foundation

/// What a server-wide event means for the session list. v1 (`/global/event`)
/// and v2 (`/api/event`) name the same changes differently; the list only
/// reacts to lifecycle, status, failure and pending-input changes.
enum OpenCodeSessionListEvent: Equatable, Sendable {
    /// A (re)connected stream: anything may have been missed while it was down.
    case connected
    /// An instance or the whole server was disposed; its sessions must be refetched.
    case disposed
    case upserted(OpenCodeSession)
    case removed(sessionID: String)
    case renamed(sessionID: String, title: String?)
    case status(sessionID: String, OpenCodeSessionStatus)
    case failed(sessionID: String, message: String)
    /// v2 turn activity without an authoritative status. `mayHaveSettled`
    /// marks events after which the turn may be over.
    case activity(sessionID: String, mayHaveSettled: Bool)
    case inputRequested(sessionID: String, requestID: String)
    case inputResolved(sessionID: String, requestID: String?)

    init?(_ event: OpenCodeEvent) {
        let properties = event.properties
        switch event.type {
        case "server.connected":
            self = .connected
            return
        case "server.instance.disposed", "global.disposed":
            self = .disposed
            return
        default:
            break
        }
        guard let sessionID = event.sessionID else { return nil }
        switch event.type {
        case "session.created", "session.updated":
            guard let info = properties["info"],
                  let session = try? JSONDecoder().decode(OpenCodeSession.self, from: JSONEncoder().encode(info)),
                  session.id == sessionID
            else { return nil }
            self = .upserted(session)
        case "session.deleted":
            self = .removed(sessionID: sessionID)
        case "session.renamed":
            self = .renamed(sessionID: sessionID, title: properties["title"]?.stringValue?.trimmedNonEmpty)
        case "session.status":
            guard let value = properties["status"],
                  let status = try? JSONDecoder().decode(OpenCodeSessionStatus.self, from: JSONEncoder().encode(value))
            else { return nil }
            self = .status(sessionID: sessionID, status)
        case "session.idle", "session.execution.succeeded", "session.execution.interrupted":
            self = .status(sessionID: sessionID, .idle)
        case "session.execution.started":
            self = .status(sessionID: sessionID, .busy)
        case "session.retry.scheduled", "session.next.retried":
            let error = properties["error"]?.objectValue
            self = .status(sessionID: sessionID, .retry(
                attempt: Int(properties["attempt"]?.numberValue ?? 1),
                message: error?["message"]?.stringValue ?? properties["message"]?.stringValue ?? String(localized: "Retrying"),
                next: properties["at"]?.numberValue ?? properties["next"]?.numberValue ?? 0))
        case "session.error":
            let error = properties["error"]?.objectValue
            // Stopping a turn is the user's choice, not a failure to flag.
            if error?["name"]?.stringValue == "MessageAbortedError" { return nil }
            let message = error.flatMap {
                OpenCodeMessageError(name: $0["name"]?.stringValue ?? "Error", data: $0["data"]?.objectValue)
                    .displayMessage.trimmedNonEmpty
            }
            // A failure without details still needs flagging; an empty message would clear it.
            self = .failed(sessionID: sessionID, message: message ?? String(localized: "The last turn failed."))
        case "session.execution.failed", "session.next.step.failed":
            let error = properties["error"]?.objectValue
            self = .failed(sessionID: sessionID,
                           message: OpenCodeFailure(message: String(localized: "The turn failed."), details: error).message)
        case "permission.asked", "permission.v2.asked", "question.asked", "question.v2.asked", "form.created":
            guard let requestID = Self.requestID(properties) else { return nil }
            self = .inputRequested(sessionID: sessionID, requestID: requestID)
        case "permission.replied", "permission.v2.replied", "question.replied", "question.rejected",
             "question.v2.replied", "question.v2.rejected", "form.replied", "form.cancelled":
            self = .inputResolved(sessionID: sessionID, requestID: Self.requestID(properties))
        case let type where event.isV2 && type.hasPrefix("session."):
            // Streaming deltas and progress only repeat what a turn's start
            // already said; skipping them keeps token traffic off the main actor.
            if type.hasSuffix(".delta") || type.hasSuffix(".progress") { return nil }
            self = .activity(sessionID: sessionID, mayHaveSettled: type.hasSuffix(".step.ended"))
        default:
            return nil
        }
    }

    private static func requestID(_ properties: [String: OpenCodeJSONValue]) -> String? {
        properties["requestID"]?.stringValue ?? properties["id"]?.stringValue
            ?? properties["formID"]?.stringValue ?? properties["form"]?.objectValue?["id"]?.stringValue
    }
}

/// Reconnect budget for the session list's live stream. A connection only
/// counts as healthy once it outlives `healthyConnection`; heartbeats keep a
/// real stream open, so a server that accepts and drops cannot cause a storm.
struct OpenCodeSessionListLiveTiming: Sendable {
    var initialDelay: Duration = .seconds(1)
    var maximumDelay: Duration = .seconds(30)
    var maximumAttempts = 5
    var healthyConnection: Duration = .seconds(30)
    /// Polling cadence while live updates are down.
    var pollInterval: Duration = .seconds(15)
    /// How long the list polls before it tries the stream again.
    var retryLiveAfter: Duration = .seconds(120)
    /// Coalesces a burst of v2 turn activity into one status refresh.
    var statusDebounce: Duration = .seconds(1)

    static let standard = OpenCodeSessionListLiveTiming()

    func delay(afterFailure attempt: Int) -> Duration {
        let exponent = min(max(attempt - 1, 0), 16)
        return min(initialDelay * (1 << exponent), maximumDelay)
    }
}

enum OpenCodeSessionListLiveState: Equatable, Sendable {
    case off, connecting, live, reconnecting
    /// The stream failed repeatedly; the list is polling until it retries.
    case polling
    /// The server has no usable server-wide stream; the list polls.
    case unsupported
}

extension OpenCodeSession {
    func retitled(_ title: String) -> OpenCodeSession {
        OpenCodeSession(id: id, slug: slug, projectID: projectID, workspaceID: workspaceID, directory: directory,
                        parentID: parentID, summary: summary, title: title, agent: agent, version: version,
                        time: time, forkSourceID: forkSourceID, share: share)
    }
}
