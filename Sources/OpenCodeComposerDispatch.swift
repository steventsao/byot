import Foundation

extension OpenCodeClient {
    /// Called only when the local queue reaches this prompt. Merely picking or queueing
    /// a model must never mutate the settings of the running server session.
    func sendPrompt(sessionID: String, directory: String, workspace: String?, prompt: OpenCodeQueuedPrompt) async throws {
        let context = try await featureContext()
        try await OpenCodeComposerDispatch(context: context).send(
            sessionID: sessionID, directory: directory, workspace: workspace, prompt: prompt)
    }
}

struct OpenCodeComposerDispatch {
    let context: OpenCodeFeatureContext

    func send(sessionID: String, directory: String, workspace: String?, prompt: OpenCodeQueuedPrompt) async throws {
        try OpenCodePromptAttachment.validate(prompt.attachments)
        guard prompt.remoteReferences.allSatisfy({
            $0.serverID == context.profile.id && $0.directory == directory && $0.workspaceID == workspace
        }) else { throw OpenCodeConnectionError.server("This file context belongs to a different server or workspace. Remove it and select the file again.") }
        if let variant = prompt.variant {
            guard context.supportsModelVariants, prompt.model?.variants.contains(variant) == true else {
                throw OpenCodeConnectionError.server("The selected model no longer advertises that variant. Choose Default or refresh models.")
            }
        }
        if context.serverProtocol == .v1 {
            try await sendV1(sessionID: sessionID, directory: directory, workspace: workspace, prompt: prompt)
        } else {
            try await sendV2(sessionID: sessionID, prompt: prompt)
        }
    }

    func v1Body(_ prompt: OpenCodeQueuedPrompt) -> OpenCodeJSONValue {
        var parts: [OpenCodeJSONValue] = []
        if prompt.command == nil, !prompt.text.isEmpty {
            parts.append(.object(["type": .string("text"), "text": .string(prompt.text)]))
        }
        parts += prompt.attachments.map { .object(["type": .string("file"), "mime": .string($0.mimeType),
                                                  "filename": .string($0.filename), "url": .string($0.dataURL)]) }
        parts += prompt.remoteReferences.map { .object(["type": .string("file"), "mime": .string($0.mimeType),
                                                       "filename": .string($0.filename), "url": .string($0.v1URL)]) }
        var body: [String: OpenCodeJSONValue] = ["parts": .array(parts), "messageID": .string(prompt.messageID)]
        if let agent = prompt.agent { body["agent"] = .string(agent) }
        if let variant = prompt.variant { body["variant"] = .string(variant) }
        if let command = prompt.command {
            body["command"] = .string(command.name)
            body["arguments"] = .string(command.arguments)
            if let model = prompt.model { body["model"] = .string(model.qualifiedID) }
        } else if let model = prompt.model {
            body["model"] = .object(["providerID": .string(model.providerID), "modelID": .string(model.modelID)])
        }
        return .object(body)
    }

    private func sendV1(sessionID: String, directory: String, workspace: String?, prompt: OpenCodeQueuedPrompt) async throws {
        guard prompt.command?.kind != .skill else {
            throw OpenCodeConnectionError.server("This server does not support slash skill attachments.")
        }
        try await context.transport.postExpectingEmptyResponse(
            ["session", sessionID, prompt.command == nil ? "prompt_async" : "command"],
            query: context.composerQuery(directory: directory, workspace: workspace), body: v1Body(prompt))
    }

    func v2Body(_ prompt: OpenCodeQueuedPrompt) throws -> OpenCodeJSONValue {
        let command = prompt.command?.kind == .command ? prompt.command : nil
        let path = command == nil ? "/api/session/{sessionID}/prompt" : "/api/session/{sessionID}/command"
        let properties = context.composerSchemaProperties(path)
        guard context.supports(path, method: "post") else {
            throw OpenCodeConnectionError.server("This server does not support sending this kind of input.")
        }
        let files: [OpenCodeJSONValue] = prompt.attachments.map {
            .object(["uri": .string($0.dataURL), "name": .string($0.filename)])
        } + prompt.remoteReferences.map {
            .object(["uri": .string($0.v2URI), "name": .string($0.filename)])
        }
        var content: [String: OpenCodeJSONValue] = [
            "text": .string(prompt.command?.arguments ?? prompt.text)
        ]
        if !files.isEmpty { content["files"] = .array(files) }
        if let skill = prompt.command, skill.kind == .skill {
            guard properties["skills"] != nil else {
                throw OpenCodeConnectionError.server("This server does not support slash skill attachments.")
            }
            content["skills"] = .array([.object(["id": .string(skill.name)])])
        }
        var body: [String: OpenCodeJSONValue] = ["delivery": .string("queue")]
        if let command {
            body["command"] = .string(command.name)
            // The shipped betas do not offer a command admission id. Never fabricate one.
        } else {
            body["id"] = .string(prompt.messageID)
            if properties["metadata"] != nil {
                var metadata: [String: OpenCodeJSONValue] = ["displayText": .string(prompt.text)]
                if let agent = prompt.agent { metadata["agent"] = .string(agent) }
                if let model = prompt.model {
                    var modelValue: [String: OpenCodeJSONValue] = ["modelID": .string(model.modelID), "providerID": .string(model.providerID)]
                    if let variant = prompt.variant { modelValue["variant"] = .string(variant) }
                    metadata["model"] = .object(modelValue)
                }
                body["metadata"] = .object(metadata)
            }
        }
        if properties["text"] != nil { body.merge(content) { _, new in new } }
        else if properties["prompt"] != nil { body["prompt"] = .object(content) }
        else { throw OpenCodeConnectionError.server("This server exposes an unsupported command or prompt shape.") }
        return .object(body)
    }

    private func sendV2(sessionID: String, prompt: OpenCodeQueuedPrompt) async throws {
        // Validate the whole request before applying any session configuration.
        let body = try v2Body(prompt)
        if prompt.agent != nil || prompt.model != nil {
            let active: OpenCodeJSONValue = try await context.transport.get(["api", "session", "active"], query: [])
            guard let activeSessions = active.objectValue?["data"]?.objectValue else {
                throw OpenCodeConnectionError.invalidResponse
            }
            guard activeSessions[sessionID] == nil else {
                throw OpenCodeConnectionError.server("The session became active before this message was sent. Its selections are saved; retry when the current turn finishes.")
            }
        }
        if let agent = prompt.agent {
            guard context.supports("/api/session/{sessionID}/agent", method: "post") else {
                throw OpenCodeConnectionError.server("This server does not support changing the primary agent.")
            }
            try await context.transport.postExpectingEmptyResponse(["api", "session", sessionID, "agent"],
                body: OpenCodeJSONValue.object(["agent": .string(agent)]))
        }
        if let model = prompt.model {
            var reference: [String: OpenCodeJSONValue] = ["id": .string(model.modelID), "providerID": .string(model.providerID)]
            if let variant = prompt.variant { reference["variant"] = .string(variant) }
            try await context.transport.postExpectingEmptyResponse(["api", "session", sessionID, "model"],
                body: OpenCodeJSONValue.object(["model": .object(reference)]))
        }
        if prompt.command?.kind == .command {
            try await context.transport.postExpectingEmptyResponse(["api", "session", sessionID, "command"], body: body)
        } else {
            let response: OpenCodeJSONValue = try await context.transport.post(["api", "session", sessionID, "prompt"], body: body)
            guard response.objectValue?["data"]?.objectValue?["sessionID"]?.stringValue == sessionID else {
                throw OpenCodeConnectionError.invalidResponse
            }
        }
    }
}

extension OpenCodeQueuedPrompt {
    var messageID: String { "msg_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
}
