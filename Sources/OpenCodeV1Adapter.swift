import Foundation

struct OpenCodeV1Adapter: OpenCodeProtocolAdapting {
    let transport: any OpenCodeHTTPTransport
    let profile: OpenCodeServerProfile
    let serverProtocol = OpenCodeServerProtocol.v1
    var usesForms: Bool { false }
    let capabilities = OpenCodeProtocolCapabilities.v1

    func listProjects() async throws -> [OpenCodeProject] {
        try await transport.get(
            ["project"],
            query: instanceQuery(directory: profile.normalizedDirectory)
        )
    }

    func listSessions(
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
        sessionID: String,
        directory: String,
        workspace: String?,
        model: OpenCodeModelOption?,
        text: String,
        attachments: [OpenCodePromptAttachment],
        promptID: UUID
    ) async throws {
        let request = try makeSendMessageRequest(
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
        parts.append(
            contentsOf: attachments.map { attachment in
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
        directory: String,
        workspace: String?
    ) async throws -> [String: OpenCodeSessionStatus] {
        try await transport.get(
            ["session", "status"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
    }

    func abortSession(
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
