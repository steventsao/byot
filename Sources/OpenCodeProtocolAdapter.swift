import Foundation

struct OpenCodeEventRoute: Equatable, Sendable {
    let path: [String]
    let query: [URLQueryItem]
}

protocol OpenCodeProtocolAdapting: Sendable {
    var serverProtocol: OpenCodeServerProtocol { get }
    var capabilities: OpenCodeProtocolCapabilities { get }

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
        attachments: [OpenCodePromptAttachment],
        promptID: UUID
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

    func abortSession(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> Bool

    func eventRoute(directory: String, workspace: String?) -> OpenCodeEventRoute
}

final class OpenCodeProtocolCache: @unchecked Sendable {
    private let lock = NSLock()
    private var value: OpenCodeServerProtocol?
    private var contract: OpenCodeV2Contract?

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
        if self.value != value { contract = nil }
        self.value = value
        lock.unlock()
    }
    func readContract() -> OpenCodeV2Contract? {
        lock.lock()
        defer { lock.unlock() }
        return contract
    }

    func storeContract(_ contract: OpenCodeV2Contract) {
        lock.lock()
        self.contract = contract
        lock.unlock()
    }

}

struct OpenCodeV1Adapter: OpenCodeProtocolAdapting {
    let serverProtocol = OpenCodeServerProtocol.v1
    let capabilities = OpenCodeProtocolCapabilities.v1

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
        attachments: [OpenCodePromptAttachment],
        promptID: UUID
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

    func abortSession(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> Bool {
        return try await transport.postWithoutBody(
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
    let contract: OpenCodeV2Contract
    let serverProtocol = OpenCodeServerProtocol.v2
    let capabilities = OpenCodeProtocolCapabilities.v2

    func listProjects(
        using transport: OpenCodeTransport,
        profile: OpenCodeServerProfile
    ) async throws -> [OpenCodeProject] {
        if contract.projectList, profile.normalizedDirectory == nil {
            struct Project: Decodable {
                let id: String; let canonical: String; let vcs: String?; let name: String?
                let time: OpenCodeProjectTime; let sandboxes: [String]
            }
            let projects: [Project] = try await transport.get(["api", "project"], query: [])
            if !projects.isEmpty { return projects.map { OpenCodeProject(id: $0.id, worktree: $0.canonical, vcs: $0.vcs, name: $0.name, time: $0.time, sandboxes: $0.sandboxes) } }
        }
        if let directory = profile.normalizedDirectory {
            let location: OpenCodeV2Location = try await transport.get(
                ["api", "location"],
                query: locationQuery(directory: directory, workspace: nil)
            )
            return [location.normalizedProject]
        }

        let sessions = try await allSessions(using: transport, directory: nil)
        if sessions.isEmpty {
            let location: OpenCodeV2Location = try await transport.get(["api", "location"], query: [])
            return [location.normalizedProject]
        }
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
            let title: String?
        }
        let response: OpenCodeV2DataResponse<OpenCodeV2Session> = try await transport.post(
            ["api", "session"],
            body: Body(location: OpenCodeV2LocationReference(directory: directory), title: contract.sessionTitle ? title : nil)
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
            .filter { $0.disabled != true && $0.activation != "disabled" }
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
                    models: models,
                    connectionState: .unreported
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
        var messages: [OpenCodeJSONValue] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        repeat {
            var query = [
                URLQueryItem(name: "limit", value: "200"),
            ]
            if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
            else { query.append(URLQueryItem(name: "order", value: "asc")) }
            let response: OpenCodeV2CursorResponse<OpenCodeJSONValue> = try await transport.get(
                ["api", "session", sessionID, "message"],
                query: query
            )
            messages.append(contentsOf: response.data)
            cursor = try nextCursor(response.cursor.next, seen: &seenCursors)
        } while cursor != nil
        return messages.compactMap { value in
            guard let object = value.objectValue else { return nil }
            return OpenCodeV2Normalization.message(object, sessionID: sessionID)
        }
    }

    func sendMessage(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?,
        model: OpenCodeModelOption?,
        text: String,
        attachments: [OpenCodePromptAttachment],
        promptID: UUID
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
        let files = attachments.isEmpty ? nil : attachments.map {
            File(uri: $0.dataURL, name: $0.filename)
        }
        let prompt = Prompt(text: text, files: files)
        let messageID = "msg_" + promptID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let response: OpenCodeV2DataResponse<OpenCodeV2Admission>
        if contract.flatPrompts {
            struct Body: Encodable { let id: String; let text: String; let files: [File]?; let delivery = "queue" }
            response = try await transport.post(
                ["api", "session", sessionID, "prompt"],
                body: Body(id: messageID, text: text, files: files)
            )
        } else {
            struct Body: Encodable { let id: String; let prompt: Prompt; let delivery = "queue" }
            response = try await transport.post(
                ["api", "session", sessionID, "prompt"], body: Body(id: messageID, prompt: prompt)
            )
        }
        guard response.data.sessionID == sessionID else { throw OpenCodeConnectionError.invalidResponse }
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

    func abortSession(
        using transport: OpenCodeTransport,
        sessionID: String,
        directory: String,
        workspace: String?
    ) async throws -> Bool {
        try await transport.postWithoutBodyExpectingEmptyResponse(
            ["api", "session", sessionID, "interrupt"]
        )
        // The beta acknowledges an idle no-op as {interrupted:false}; this
        // still permits authoritative status reconciliation after Stop.
        return true
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
    let title: String?
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
            title: title ?? "New session",
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
    let activation: String?
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
    let admittedSeq: Int?
    let id: String
    let sessionID: String
}

