import Foundation

struct OpenCodeEventRoute: Equatable, Sendable {
    let path: [String]
    let query: [URLQueryItem]
}

protocol OpenCodeProtocolAdapting: Sendable {
    var serverProtocol: OpenCodeServerProtocol { get }

    func listProjects(
        using transport: OpenCodeTransport,
        profile: OpenCodeServerProfile
    ) async throws -> [OpenCodeProject]

    func listSessions(
        using transport: OpenCodeTransport,
        directory: String
    ) async throws -> [OpenCodeSession]

    func createSession(
        using transport: OpenCodeTransport,
        directory: String,
        title: String?
    ) async throws -> OpenCodeSession

    func connectedProviderModels(
        using transport: OpenCodeTransport,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeProviderModels]

    func messages(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeMessageEnvelope]

    func sendMessage(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?,
        model: OpenCodeModelOption?,
        text: String,
        attachments: [OpenCodePromptAttachment]
    ) async throws

    func diffs(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeDiff]

    func sessionStatuses(
        using transport: OpenCodeTransport,
        directory: String,
        workspace: String?
    ) async throws -> [String: OpenCodeSessionStatus]

    func permissions(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodePermissionRequest]

    func reply(
        using transport: OpenCodeTransport,
        to permission: OpenCodePermissionRequest,
        directory: String,
        workspace: String?,
        reply: OpenCodePermissionReply
    ) async throws

    func questions(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeQuestionRequest]

    func answer(
        using transport: OpenCodeTransport,
        question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String?,
        answers: [[String]]
    ) async throws

    func reject(
        using transport: OpenCodeTransport,
        question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String?
    ) async throws

    func abortSession(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws

    func eventRoute(directory: String, workspace: String?) -> OpenCodeEventRoute
}

enum OpenCodeProtocolAdapterFactory {
    static func adapter(for serverProtocol: OpenCodeServerProtocol) -> any OpenCodeProtocolAdapting {
        switch serverProtocol {
        case .v1: OpenCodeV1Adapter()
        case .v2: OpenCodeV2Adapter()
        }
    }
}

final class OpenCodeProtocolCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OpenCodeServerProtocol?

    init(_ value: OpenCodeServerProtocol? = nil) {
        self.value = value
    }

    func read() -> OpenCodeServerProtocol? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func store(_ value: OpenCodeServerProtocol) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

struct OpenCodeV1Adapter: OpenCodeProtocolAdapting {
    let serverProtocol = OpenCodeServerProtocol.v1

    func listProjects(
        using transport: OpenCodeTransport,
        profile: OpenCodeServerProfile
    ) async throws -> [OpenCodeProject] {
        try await transport.get(
            ["project"],
            query: instanceQuery(directory: profile.normalizedDirectory)
        )
    }

    func listSessions(
        using transport: OpenCodeTransport,
        directory: String
    ) async throws -> [OpenCodeSession] {
        try await transport.get(
            ["session"],
            query: instanceQuery(directory: directory) + [
                URLQueryItem(name: "scope", value: "project"),
                URLQueryItem(name: "roots", value: "true"),
                URLQueryItem(name: "limit", value: "100"),
            ]
        )
    }

    func createSession(
        using transport: OpenCodeTransport,
        directory: String,
        title: String?
    ) async throws -> OpenCodeSession {
        struct Body: Encodable { let title: String? }
        return try await transport.post(
            ["session"],
            query: instanceQuery(directory: directory),
            body: Body(title: title)
        )
    }

    func connectedProviderModels(
        using transport: OpenCodeTransport,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeProviderModels] {
        let catalog: OpenCodeProviderCatalog = try await transport.get(
            ["provider"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
        return catalog.connectedProviders
    }

    func messages(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeMessageEnvelope] {
        try await transport.get(
            ["session", sessionID, "message"],
            query: instanceQuery(directory: directory, workspace: workspace)
                + [URLQueryItem(name: "limit", value: "200")]
        )
    }

    func sendMessage(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?,
        model: OpenCodeModelOption?,
        text: String,
        attachments: [OpenCodePromptAttachment]
    ) async throws {
        let request = try makeSendMessageRequest(
            using: transport,
            sessionID: sessionID,
            directory: directory,
            workspace: workspace,
            model: model,
            text: text,
            attachments: attachments
        )
        try await transport.performExpectingEmptyResponse(request)
    }

    func makeSendMessageRequest(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?,
        model: OpenCodeModelOption?,
        text: String,
        attachments: [OpenCodePromptAttachment]
    ) throws -> URLRequest {
        try OpenCodePromptAttachment.validate(attachments)
        var parts: [OpenCodeV1PromptPart] = []
        if !text.isEmpty {
            parts.append(.text(OpenCodeV1PromptTextPart(text: text)))
        }
        parts.append(contentsOf: attachments.map { attachment in
            .file(
                OpenCodeV1PromptFilePart(
                    mime: attachment.mimeType,
                    filename: attachment.filename,
                    url: attachment.dataURL
                )
            )
        })
        let data = try JSONEncoder().encode(
            OpenCodeV1PromptBody(
                model: model.map {
                    OpenCodeV1PromptModel(
                        providerID: $0.providerID,
                        modelID: $0.modelID
                    )
                },
                parts: parts
            )
        )
        return try transport.makeRequest(
            path: ["session", sessionID, "prompt_async"],
            query: instanceQuery(directory: directory, workspace: workspace),
            method: "POST",
            body: data
        )
    }

    func diffs(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeDiff] {
        try await transport.get(
            ["session", sessionID, "diff"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
    }

    func sessionStatuses(
        using transport: OpenCodeTransport,
        directory: String,
        workspace: String?
    ) async throws -> [String: OpenCodeSessionStatus] {
        try await transport.get(
            ["session", "status"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
    }

    func permissions(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodePermissionRequest] {
        let requests: [OpenCodePermissionRequest] = try await transport.get(
            ["permission"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
        return requests.map { request in
            var request = request
            request.apiVersion = .legacy
            return request
        }
    }

    func reply(
        using transport: OpenCodeTransport,
        to permission: OpenCodePermissionRequest,
        directory: String,
        workspace: String?,
        reply: OpenCodePermissionReply
    ) async throws {
        struct Body: Encodable { let reply: OpenCodePermissionReply }
        let _: Bool = try await transport.post(
            ["permission", permission.id, "reply"],
            query: instanceQuery(directory: directory, workspace: workspace),
            body: Body(reply: reply)
        )
    }

    func questions(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeQuestionRequest] {
        let requests: [OpenCodeQuestionRequest] = try await transport.get(
            ["question"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
        return requests.map { request in
            var request = request
            request.apiVersion = .legacy
            return request
        }
    }

    func answer(
        using transport: OpenCodeTransport,
        question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String?,
        answers: [[String]]
    ) async throws {
        struct Body: Encodable { let answers: [[String]] }
        let _: Bool = try await transport.post(
            ["question", question.id, "reply"],
            query: instanceQuery(directory: directory, workspace: workspace),
            body: Body(answers: answers)
        )
    }

    func reject(
        using transport: OpenCodeTransport,
        question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String?
    ) async throws {
        let _: Bool = try await transport.postWithoutBody(
            ["question", question.id, "reject"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
    }

    func abortSession(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws {
        let _: Bool = try await transport.postWithoutBody(
            ["session", sessionID, "abort"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
    }

    func eventRoute(directory: String, workspace: String?) -> OpenCodeEventRoute {
        OpenCodeEventRoute(
            path: ["event"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
    }

    private struct OpenCodeV1PromptTextPart: Encodable {
        let type = "text"
        let text: String
    }

    private struct OpenCodeV1PromptFilePart: Encodable {
        let type = "file"
        let mime: String
        let filename: String
        let url: String
    }

    private enum OpenCodeV1PromptPart: Encodable {
        case text(OpenCodeV1PromptTextPart)
        case file(OpenCodeV1PromptFilePart)

        func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let part): try part.encode(to: encoder)
            case .file(let part): try part.encode(to: encoder)
            }
        }
    }

    private struct OpenCodeV1PromptModel: Encodable {
        let providerID: String
        let modelID: String
    }

    private struct OpenCodeV1PromptBody: Encodable {
        let model: OpenCodeV1PromptModel?
        let parts: [OpenCodeV1PromptPart]
    }
}

struct OpenCodeV2Adapter: OpenCodeProtocolAdapting {
    let serverProtocol = OpenCodeServerProtocol.v2

    func listProjects(
        using transport: OpenCodeTransport,
        profile: OpenCodeServerProfile
    ) async throws -> [OpenCodeProject] {
        if let directory = profile.normalizedDirectory {
            let location: OpenCodeV2Location = try await transport.get(
                ["api", "location"],
                query: locationQuery(directory: directory, workspace: nil)
            )
            return [location.normalizedProject]
        }

        let sessions = try await allSessions(using: transport, directory: nil)
        let grouped = Dictionary(grouping: sessions, by: { session in
            OpenCodeV2ProjectKey(id: session.projectID, directory: session.location.directory)
        })
        return grouped.map { key, sessions in
            OpenCodeProject(
                id: key.id,
                worktree: key.directory,
                vcs: nil,
                name: nil,
                time: OpenCodeProjectTime(
                    created: sessions.map(\.time.created).min() ?? 0,
                    updated: sessions.map(\.time.updated).max() ?? 0
                ),
                sandboxes: []
            )
        }
        .sorted { $0.time.updated > $1.time.updated }
    }

    func listSessions(
        using transport: OpenCodeTransport,
        directory: String
    ) async throws -> [OpenCodeSession] {
        try await allSessions(using: transport, directory: directory)
            .filter { $0.parentID == nil }
            .map(\.normalized)
    }

    func createSession(
        using transport: OpenCodeTransport,
        directory: String,
        title: String?
    ) async throws -> OpenCodeSession {
        struct Body: Encodable {
            let location: OpenCodeV2LocationReference
        }
        let response: OpenCodeV2DataResponse<OpenCodeV2Session> = try await transport.post(
            ["api", "session"],
            body: Body(location: OpenCodeV2LocationReference(directory: directory))
        )
        return response.data.normalized
    }

    func connectedProviderModels(
        using transport: OpenCodeTransport,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeProviderModels] {
        let query = locationQuery(directory: directory, workspace: workspace)
        async let providerRequest: OpenCodeV2LocationDataResponse<[OpenCodeV2Provider]> =
            transport.get(["api", "provider"], query: query)
        async let modelRequest: OpenCodeV2LocationDataResponse<[OpenCodeV2Model]> =
            transport.get(["api", "model"], query: query)
        let (providerResponse, modelResponse) = try await (providerRequest, modelRequest)
        let modelsByProvider = Dictionary(grouping: modelResponse.data.filter(\.enabled), by: \.providerID)

        return providerResponse.data
            .filter { $0.disabled != true }
            .compactMap { provider in
                let models = (modelsByProvider[provider.id] ?? [])
                    .map { model in
                        OpenCodeModelOption(
                            providerID: provider.id,
                            providerName: provider.name,
                            modelID: model.id,
                            modelName: model.name,
                            status: model.status
                        )
                    }
                    .sorted {
                        $0.modelName.localizedStandardCompare($1.modelName) == .orderedAscending
                    }
                guard !models.isEmpty else { return nil }
                return OpenCodeProviderModels(
                    providerID: provider.id,
                    providerName: provider.name,
                    models: models
                )
            }
            .sorted {
                $0.providerName.localizedStandardCompare($1.providerName) == .orderedAscending
            }
    }

    func messages(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeMessageEnvelope] {
        var messages: [OpenCodeV2Message] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var query = [
                URLQueryItem(name: "limit", value: "200"),
                URLQueryItem(name: "order", value: "asc"),
            ]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let response: OpenCodeV2CursorResponse<OpenCodeV2Message> = try await transport.get(
                ["api", "session", sessionID, "message"],
                query: query
            )
            messages.append(contentsOf: response.data)
            cursor = try nextCursor(response.cursor.next, seen: &seenCursors)
        } while cursor != nil
        return messages.map { $0.normalized(sessionID: sessionID) }
    }

    func sendMessage(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?,
        model: OpenCodeModelOption?,
        text: String,
        attachments: [OpenCodePromptAttachment]
    ) async throws {
        try OpenCodePromptAttachment.validate(attachments)
        if let model {
            struct ModelBody: Encodable { let model: OpenCodeV2ModelReference }
            try await transport.postExpectingEmptyResponse(
                ["api", "session", sessionID, "model"],
                body: ModelBody(
                    model: OpenCodeV2ModelReference(
                        id: model.modelID,
                        providerID: model.providerID
                    )
                )
            )
        }
        struct File: Encodable {
            let uri: String
            let name: String
        }
        struct Prompt: Encodable {
            let text: String
            let files: [File]?
        }
        struct PromptBody: Encodable {
            let prompt: Prompt
            let delivery = "queue"
        }
        let files = attachments.isEmpty ? nil : attachments.map {
            File(uri: $0.dataURL, name: $0.filename)
        }
        let _: OpenCodeV2DataResponse<OpenCodeV2Admission> = try await transport.post(
            ["api", "session", sessionID, "prompt"],
            body: PromptBody(prompt: Prompt(text: text, files: files))
        )
    }

    func diffs(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeDiff] {
        []
    }

    func sessionStatuses(
        using transport: OpenCodeTransport,
        directory: String,
        workspace: String?
    ) async throws -> [String: OpenCodeSessionStatus] {
        let response: OpenCodeV2DataResponse<[String: OpenCodeV2ActiveSession]> =
            try await transport.get(["api", "session", "active"], query: [])
        return response.data.mapValues { _ in .busy }
    }

    func permissions(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodePermissionRequest] {
        let response: OpenCodeV2LocationDataResponse<[OpenCodePermissionV2Request]> =
            try await transport.get(
                ["api", "permission", "request"],
                query: locationQuery(directory: directory, workspace: workspace)
            )
        return response.data
            .filter { $0.sessionID == sessionID }
            .map(\.normalized)
    }

    func reply(
        using transport: OpenCodeTransport,
        to permission: OpenCodePermissionRequest,
        directory: String,
        workspace: String?,
        reply: OpenCodePermissionReply
    ) async throws {
        struct Body: Encodable { let reply: OpenCodePermissionReply }
        try await transport.postExpectingEmptyResponse(
            [
                "api", "session", permission.sessionID,
                "permission", permission.id, "reply",
            ],
            body: Body(reply: reply)
        )
    }

    func questions(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> [OpenCodeQuestionRequest] {
        let response: OpenCodeV2LocationDataResponse<[OpenCodeQuestionRequest]> =
            try await transport.get(
                ["api", "question", "request"],
                query: locationQuery(directory: directory, workspace: workspace)
            )
        return response.data
            .filter { $0.sessionID == sessionID }
            .map { request in
                var request = request
                request.apiVersion = .v2
                return request
            }
    }

    func answer(
        using transport: OpenCodeTransport,
        question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String?,
        answers: [[String]]
    ) async throws {
        struct Body: Encodable { let answers: [[String]] }
        try await transport.postExpectingEmptyResponse(
            [
                "api", "session", question.sessionID,
                "question", question.id, "reply",
            ],
            body: Body(answers: answers)
        )
    }

    func reject(
        using transport: OpenCodeTransport,
        question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String?
    ) async throws {
        try await transport.postWithoutBodyExpectingEmptyResponse(
            [
                "api", "session", question.sessionID,
                "question", question.id, "reject",
            ]
        )
    }

    func abortSession(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws {
        try await transport.postWithoutBodyExpectingEmptyResponse(
            ["api", "session", sessionID, "interrupt"]
        )
    }

    func eventRoute(directory: String, workspace: String?) -> OpenCodeEventRoute {
        OpenCodeEventRoute(path: ["api", "event"], query: [])
    }

    private func allSessions(
        using transport: OpenCodeTransport,
        directory: String?
    ) async throws -> [OpenCodeV2Session] {
        var sessions: [OpenCodeV2Session] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var query = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "order", value: "desc"),
            ]
            if let directory { query.append(URLQueryItem(name: "directory", value: directory)) }
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            let response: OpenCodeV2CursorResponse<OpenCodeV2Session> = try await transport.get(
                ["api", "session"],
                query: query
            )
            sessions.append(contentsOf: response.data)
            cursor = try nextCursor(response.cursor.next, seen: &seenCursors)
        } while cursor != nil
        return sessions
    }

    private func nextCursor(_ next: String?, seen: inout Set<String>) throws -> String? {
        guard let next else { return nil }
        guard seen.insert(next).inserted else {
            throw OpenCodeConnectionError.server(
                "OpenCode returned a repeated pagination cursor."
            )
        }
        return next
    }
}

private func instanceQuery(
    directory: String?,
    workspace: String? = nil
) -> [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let directory, !directory.isEmpty {
        items.append(URLQueryItem(name: "directory", value: directory))
    }
    if let workspace, !workspace.isEmpty {
        items.append(URLQueryItem(name: "workspace", value: workspace))
    }
    return items
}

private func locationQuery(
    directory: String?,
    workspace: String?
) -> [URLQueryItem] {
    var items: [URLQueryItem] = []
    if let directory, !directory.isEmpty {
        items.append(URLQueryItem(name: "location[directory]", value: directory))
    }
    if let workspace, !workspace.isEmpty {
        items.append(URLQueryItem(name: "location[workspace]", value: workspace))
    }
    return items
}

private struct OpenCodeV2DataResponse<Value: Decodable>: Decodable {
    let data: Value
}

private struct OpenCodeV2LocationDataResponse<Value: Decodable>: Decodable {
    let data: Value
}

private struct OpenCodeV2CursorResponse<Value: Decodable>: Decodable {
    struct Cursor: Decodable {
        let previous: String?
        let next: String?
    }

    let data: [Value]
    let cursor: Cursor
}

private struct OpenCodeV2ProjectKey: Hashable {
    let id: String
    let directory: String
}

private struct OpenCodeV2LocationReference: Codable {
    let directory: String
    let workspaceID: String?

    init(directory: String, workspaceID: String? = nil) {
        self.directory = directory
        self.workspaceID = workspaceID
    }
}

private struct OpenCodeV2Location: Decodable {
    struct Project: Decodable {
        let id: String
        let directory: String
    }

    let directory: String
    let workspaceID: String?
    let project: Project

    var normalizedProject: OpenCodeProject {
        OpenCodeProject(
            id: project.id,
            worktree: project.directory,
            vcs: nil,
            name: nil,
            time: OpenCodeProjectTime(created: 0, updated: 0),
            sandboxes: []
        )
    }
}

private struct OpenCodeV2Session: Decodable {
    struct Time: Decodable {
        let created: Double
        let updated: Double
        let archived: Double?
    }

    let id: String
    let parentID: String?
    let projectID: String
    let agent: String?
    let model: OpenCodeV2ModelReference?
    let time: Time
    let title: String
    let location: OpenCodeV2LocationReference

    var normalized: OpenCodeSession {
        OpenCodeSession(
            id: id,
            slug: id,
            projectID: projectID,
            workspaceID: location.workspaceID,
            directory: location.directory,
            parentID: parentID,
            summary: nil,
            title: title,
            agent: agent,
            version: "2",
            time: OpenCodeSessionTime(
                created: time.created,
                updated: time.updated,
                compacting: nil,
                archived: time.archived
            )
        )
    }
}

private struct OpenCodeV2Provider: Decodable {
    let id: String
    let name: String
    let disabled: Bool?
}

private struct OpenCodeV2Model: Decodable {
    let id: String
    let providerID: String
    let name: String
    let status: String?
    let enabled: Bool
}

private struct OpenCodeV2ModelReference: Codable {
    let id: String
    let providerID: String
}

private struct OpenCodeV2ActiveSession: Decodable {
    let type: String
}

private struct OpenCodeV2Admission: Decodable {
    let admittedSeq: Int
    let id: String
    let sessionID: String
}

private struct OpenCodeV2Message: Decodable {
    struct Time: Decodable {
        let created: Double
        let completed: Double?
    }

    struct File: Decodable {
        let uri: String
        let mime: String?
        let name: String?
    }

    struct Content: Decodable {
        struct ToolTime: Decodable {
            let created: Double
            let completed: Double?
        }

        struct ToolState: Decodable {
            let status: String
            let input: OpenCodeJSONValue?
            let result: OpenCodeJSONValue?
            let content: [OpenCodeJSONValue]?
            let error: OpenCodeJSONValue?
        }

        let type: String
        let id: String
        let text: String?
        let name: String?
        let state: ToolState?
        let time: ToolTime?
    }

    struct Error: Decodable {
        let type: String
        let message: String
    }

    let id: String
    let type: String
    let time: Time
    let text: String?
    let files: [File]?
    let agent: String?
    let model: OpenCodeV2ModelReference?
    let content: [Content]?
    let callID: String?
    let command: String?
    let output: String?
    let summary: String?
    let error: Error?

    func normalized(sessionID: String) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessageInfo(
                id: id,
                sessionID: sessionID,
                role: type == "user" ? "user" : "assistant",
                time: OpenCodeMessageTime(
                    created: time.created,
                    completed: time.completed
                ),
                agent: agent,
                modelID: model?.id,
                providerID: model?.providerID,
                finish: nil,
                error: error.map {
                    OpenCodeMessageError(
                        name: $0.type,
                        data: ["message": .string($0.message)]
                    )
                }
            ),
            parts: normalizedParts(sessionID: sessionID)
        )
    }

    private func normalizedParts(sessionID: String) -> [OpenCodePart] {
        if type == "user" {
            var parts: [OpenCodePart] = []
            if let text, !text.isEmpty {
                parts.append(textPart(id: "\(id)-text", text: text, sessionID: sessionID))
            }
            parts.append(contentsOf: (files ?? []).enumerated().map { index, file in
                OpenCodePart(
                    id: "\(id)-file-\(index)",
                    sessionID: sessionID,
                    messageID: id,
                    type: "file",
                    text: nil,
                    mime: file.mime,
                    filename: file.name,
                    url: file.uri,
                    callID: nil,
                    tool: nil,
                    state: nil,
                    files: nil,
                    description: nil,
                    agent: nil
                )
            })
            return parts
        }
        if type == "assistant" {
            return (content ?? []).map { content in
                switch content.type {
                case "tool":
                    return toolPart(content, sessionID: sessionID)
                default:
                    return textPart(
                        id: content.id,
                        text: content.text ?? "",
                        sessionID: sessionID,
                        type: content.type
                    )
                }
            }
        }
        if type == "shell" {
            let state = OpenCodeToolState(
                status: "completed",
                input: command.map { ["command": .string($0)] },
                raw: nil,
                title: nil,
                output: output,
                error: nil,
                time: OpenCodeToolTime(start: time.created, end: time.completed)
            )
            return [
                OpenCodePart(
                    id: callID ?? id,
                    sessionID: sessionID,
                    messageID: id,
                    type: "tool",
                    text: nil,
                    mime: nil,
                    filename: nil,
                    url: nil,
                    callID: callID,
                    tool: "shell",
                    state: state,
                    files: nil,
                    description: nil,
                    agent: nil
                ),
            ]
        }
        let fallbackText: String
        switch type {
        case "agent-switched":
            fallbackText = agent.map { "Switched agent to \($0)" } ?? "Agent switched"
        case "model-switched":
            fallbackText = model.map { "Switched model to \($0.providerID)/\($0.id)" }
                ?? "Model switched"
        default:
            fallbackText = ""
        }
        return [
            textPart(
                id: "\(id)-text",
                text: text ?? summary ?? fallbackText,
                sessionID: sessionID
            ),
        ]
    }

    private func textPart(
        id partID: String,
        text: String,
        sessionID: String,
        type: String = "text"
    ) -> OpenCodePart {
        OpenCodePart(
            id: partID,
            sessionID: sessionID,
            messageID: id,
            type: type,
            text: text,
            mime: nil,
            filename: nil,
            url: nil,
            callID: nil,
            tool: nil,
            state: nil,
            files: nil,
            description: nil,
            agent: nil
        )
    }

    private func toolPart(_ content: Content, sessionID: String) -> OpenCodePart {
        let state = content.state
        let input: [String: OpenCodeJSONValue]?
        let raw: String?
        switch state?.input {
        case .object(let value):
            input = value
            raw = nil
        case .string(let value):
            input = nil
            raw = value
        default:
            input = nil
            raw = nil
        }
        let output = state?.result?.compactDescription
            ?? state?.content?.map(\.compactDescription).joined(separator: "\n")
        let error: String?
        if case .object(let value) = state?.error {
            error = value["message"]?.stringValue ?? state?.error?.compactDescription
        } else {
            error = state?.error?.compactDescription
        }
        return OpenCodePart(
            id: content.id,
            sessionID: sessionID,
            messageID: id,
            type: "tool",
            text: nil,
            mime: nil,
            filename: nil,
            url: nil,
            callID: content.id,
            tool: content.name,
            state: OpenCodeToolState(
                status: state?.status ?? "pending",
                input: input,
                raw: raw,
                title: nil,
                output: output,
                error: error,
                time: content.time.map {
                    OpenCodeToolTime(start: $0.created, end: $0.completed)
                }
            ),
            files: nil,
            description: nil,
            agent: nil
        )
    }
}
