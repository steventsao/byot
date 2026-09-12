import Foundation

/// Contract: OpenCode v1 1.18.29 and v2 beta 19242/19271 schema.
/// Revert stages history reversibly. V2 explicitly excludes file rollback.
struct OpenCodeSessionFeatureService: Sendable {
    let context: OpenCodeFeatureContext
    private var v2: Bool { context.serverProtocol == .v2 }
    var support: OpenCodeSessionFeatureSupport { .negotiated(context) }

    func details(_ id: String, directory: String, workspace: String?) async throws -> OpenCodeSessionDetails {
        try require(support.details, "Session details")
        let value: OpenCodeJSONValue = try await context.transport.get(path(id), query: query(directory, workspace))
        return try decodeDetails(value)
    }

    func rename(_ id: String, directory: String, workspace: String?, title: String) async throws -> OpenCodeSessionDetails {
        try require(support.rename, "Rename")
        guard let title = title.trimmedNonEmpty else { throw OpenCodeSessionFeatureError(message: "Enter a session name.") }
        struct Body: Encodable { let title: String }
        let body = try JSONEncoder().encode(Body(title: title))
        let request = try context.transport.makeRequest(path: path(id) + (v2 ? ["rename"] : []),
            query: query(directory, workspace), method: v2 ? "POST" : "PATCH", body: body)
        if v2 {
            try await context.transport.performExpectingEmptyResponse(request)
            return try await details(id, directory: directory, workspace: workspace)
        }
        return try decodeDetails(try await context.transport.perform(request))
    }

    func delete(_ id: String, directory: String, workspace: String?) async throws {
        try require(support.delete, "Delete")
        let request = try context.transport.makeRequest(path: path(id), query: query(directory, workspace), method: "DELETE", body: nil)
        try await context.transport.performExpectingEmptyResponse(request)
    }

    func children(_ id: String, directory: String, workspace: String?) async throws -> [OpenCodeSession] {
        try require(support.children, "Child sessions")
        if !v2 {
            return try await context.transport.get(path(id) + ["children"], query: query(directory, workspace))
        }
        // Parent filtering is verified in the beta's schema. When absent, list
        // the project and filter locally; never guess a /children route.
        let parameters = context.schema?.objectValue?["paths"]?.objectValue?["/api/session"]?
            .objectValue?["get"]?.objectValue?["parameters"]?.arrayValue ?? []
        let hasParentFilter = parameters.contains { $0.objectValue?["name"]?.stringValue == "parentID" }
        var cursor: String?
        var seen = Set<String>()
        var sessions: [OpenCodeSession] = []
        repeat {
            var query = [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "directory", value: directory)]
            if hasParentFilter { query.append(URLQueryItem(name: "parentID", value: id)) }
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            else { query.append(URLQueryItem(name: "order", value: "desc")) }
            let response: OpenCodeJSONValue = try await context.transport.get(["api", "session"], query: query)
            guard let object = response.objectValue, let rows = object["data"]?.arrayValue else {
                throw OpenCodeConnectionError.invalidResponse
            }
            for row in rows {
                if let session = row.objectValue.flatMap(OpenCodeV2Normalization.session), session.parentID == id {
                    sessions.append(session)
                }
            }
            cursor = object["cursor"]?.objectValue?["next"]?.stringValue
            if let cursor, !seen.insert(cursor).inserted {
                throw OpenCodeSessionFeatureError(message: "OpenCode returned a repeated session cursor.")
            }
        } while cursor != nil
        return sessions
    }

    func todos(_ id: String, directory: String, workspace: String?) async throws -> [OpenCodeTodo]? {
        guard support.todoSnapshot else { return nil }
        return try await context.transport.get(path(id) + ["todo"], query: query(directory, workspace))
    }

    func stage(_ id: String, directory: String, workspace: String?, messageID: String) async throws {
        try require(support.undo, "Undo")
        if v2 {
            try await cancelPendingUsers(id)
            struct Body: Encodable { let messageID: String; let files = false }
            let _: OpenCodeJSONValue = try await context.transport.post(path(id) + ["revert", "stage"], body: Body(messageID: messageID))
        } else {
            struct Body: Encodable { let messageID: String }
            let _: OpenCodeJSONValue = try await context.transport.post(path(id) + ["revert"], query: query(directory, workspace), body: Body(messageID: messageID))
        }
    }

    func clear(_ id: String, directory: String, workspace: String?) async throws {
        try require(support.redo, "Redo")
        if v2 { try await cancelPendingUsers(id) }
        try await context.transport.postWithoutBodyExpectingEmptyResponse(
            path(id) + (v2 ? ["revert", "clear"] : ["unrevert"]), query: query(directory, workspace))
    }

    func commit(_ id: String) async throws -> Bool {
        guard v2 else { return false } // V1 cleans the staged boundary when accepting the next prompt.
        try require(support.undo, "Continue after undo")
        try await context.transport.postWithoutBodyExpectingEmptyResponse(path(id) + ["revert", "commit"])
        return true
    }

    func compact(_ id: String, directory: String, workspace: String?, model: OpenCodeModelOption?) async throws {
        try require(support.compact, "Compaction")
        if v2 {
            struct Body: Encodable {}
            // This route admits a compaction into the inbox and requires {}.
            let _: OpenCodeJSONValue = try await context.transport.post(path(id) + ["compact"], body: Body())
        } else {
            guard let model else { throw OpenCodeSessionFeatureError(message: "Choose a model before compacting this conversation.") }
            struct Body: Encodable { let providerID: String; let modelID: String }
            let result: Bool = try await context.transport.post(path(id) + ["summarize"], query: query(directory, workspace), body: Body(providerID: model.providerID, modelID: model.modelID), timeout: 180)
            guard result else { throw OpenCodeSessionFeatureError(message: "OpenCode did not confirm compaction.") }
        }
    }

    func fork(_ id: String, directory: String, workspace: String?, beforeMessageID: String?) async throws -> OpenCodeSession {
        try require(support.fork, "Fork")
        let value: OpenCodeJSONValue
        if v2 {
            struct Boundary: Encodable { let type: String; let messageID: String? }
            struct Body: Encodable { let boundary: Boundary }
            value = try await context.transport.post(path(id) + ["fork"], body: Body(boundary: Boundary(type: beforeMessageID == nil ? "through" : "before", messageID: beforeMessageID)))
        } else {
            struct Body: Encodable { let messageID: String? }
            value = try await context.transport.post(path(id) + ["fork"], query: query(directory, workspace), body: Body(messageID: beforeMessageID))
        }
        return try decodeDetails(value).session
    }

    private func cancelPendingUsers(_ id: String) async throws {
        // A staged boundary must not automatically consume a server-side user
        // prompt written against the previous history. Fail closed if the
        // authoritative inbox cannot be read or any cancellation fails.
        let response: OpenCodeJSONValue = try await context.transport.get(path(id) + ["inbox"], query: [])
        guard let rows = response.objectValue?["data"]?.arrayValue else { throw OpenCodeConnectionError.invalidResponse }
        for row in rows {
            guard let item = row.objectValue, item["type"]?.stringValue == "user",
                  let inboxID = item["id"]?.stringValue else { continue }
            let request = try context.transport.makeRequest(path: path(id) + ["inbox", inboxID], query: [], method: "DELETE", body: nil)
            try await context.transport.performExpectingEmptyResponse(request)
        }
    }

    private func path(_ id: String) -> [String] { (v2 ? ["api"] : []) + ["session", id] }
    private func query(_ directory: String, _ workspace: String?) -> [URLQueryItem] {
        guard !v2 else { return [] }
        var items = [URLQueryItem(name: "directory", value: directory)]
        if let workspace { items.append(URLQueryItem(name: "workspace", value: workspace)) }
        return items
    }
    private func decodeDetails(_ value: OpenCodeJSONValue) throws -> OpenCodeSessionDetails {
        guard let object = (v2 ? value.objectValue?["data"] : value)?.objectValue else { throw OpenCodeConnectionError.invalidResponse }
        let session: OpenCodeSession
        if v2 {
            guard let decoded = OpenCodeV2Normalization.session(object) else { throw OpenCodeConnectionError.invalidResponse }
            session = decoded
        } else {
            session = try JSONDecoder().decode(OpenCodeSession.self, from: JSONEncoder().encode(OpenCodeJSONValue.object(object)))
        }
        return OpenCodeSessionDetails(session: session, revertMessageID: object["revert"]?.objectValue?["messageID"]?.stringValue)
    }
    private func require(_ supported: Bool, _ name: String) throws {
        guard supported else { throw OpenCodeSessionFeatureError(message: "\(name) is unavailable on this OpenCode server.") }
    }
}

extension OpenCodeClient: OpenCodeSessionFeatureServicing {
    private func sessionFeatureService() async throws -> OpenCodeSessionFeatureService {
        OpenCodeSessionFeatureService(context: try await featureContext())
    }
    func sessionFeatureSupport() async throws -> OpenCodeSessionFeatureSupport { try await sessionFeatureService().support }
    func sessionDetails(sessionID: String, directory: String, workspace: String?) async throws -> OpenCodeSessionDetails {
        try await sessionFeatureService().details(sessionID, directory: directory, workspace: workspace)
    }
    func renameSession(sessionID: String, directory: String, workspace: String?, title: String) async throws -> OpenCodeSessionDetails {
        try await sessionFeatureService().rename(sessionID, directory: directory, workspace: workspace, title: title)
    }
    func deleteSession(sessionID: String, directory: String, workspace: String?) async throws {
        try await sessionFeatureService().delete(sessionID, directory: directory, workspace: workspace)
    }
    func childSessions(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeSession] {
        try await sessionFeatureService().children(sessionID, directory: directory, workspace: workspace)
    }
    func sessionTodos(sessionID: String, directory: String, workspace: String?) async throws -> [OpenCodeTodo]? {
        try await sessionFeatureService().todos(sessionID, directory: directory, workspace: workspace)
    }
    func stageSessionRevert(sessionID: String, directory: String, workspace: String?, messageID: String) async throws {
        try await sessionFeatureService().stage(sessionID, directory: directory, workspace: workspace, messageID: messageID)
    }
    func clearSessionRevert(sessionID: String, directory: String, workspace: String?) async throws {
        try await sessionFeatureService().clear(sessionID, directory: directory, workspace: workspace)
    }
    func commitSessionRevert(sessionID: String, directory: String, workspace: String?) async throws -> Bool {
        try await sessionFeatureService().commit(sessionID)
    }
    func compactSession(sessionID: String, directory: String, workspace: String?, model: OpenCodeModelOption?) async throws {
        try await sessionFeatureService().compact(sessionID, directory: directory, workspace: workspace, model: model)
    }
    func forkSession(sessionID: String, directory: String, workspace: String?, beforeMessageID: String?) async throws -> OpenCodeSession {
        try await sessionFeatureService().fork(sessionID, directory: directory, workspace: workspace, beforeMessageID: beforeMessageID)
    }
}
