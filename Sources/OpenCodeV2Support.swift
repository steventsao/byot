import Foundation

extension OpenCodeJSONValue {
    var objectValue: [String: OpenCodeJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [OpenCodeJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}

// Snapshot normalization paired with the upstream v2 event reducer. Contract:
// opencode2 0.0.0-beta-19242, upstream v2 e15fb426ec593f02f8c6017d78b1c0ec58c8de8a.
enum OpenCodeV2Normalization {
    // Text and reasoning parts carry no server-side ID in v2; they are
    // addressed by (assistantMessageID, kind, ordinal). The same scheme is
    // used for fetched messages and for live stream events so both land on
    // the same part.
    static func streamPartID(messageID: String, kind: String, ordinal: Int) -> String {
        "\(messageID):\(kind):\(ordinal)"
    }

    static func session(_ object: [String: OpenCodeJSONValue]) -> OpenCodeSession? {
        guard let id = object["id"]?.stringValue else { return nil }
        let location = object["location"]?.objectValue
        let time = object["time"]?.objectValue
        return OpenCodeSession(
            id: id,
            slug: object["slug"]?.stringValue ?? id,
            projectID: object["projectID"]?.stringValue ?? "",
            workspaceID: location?["workspaceID"]?.stringValue
                ?? object["workspaceID"]?.stringValue,
            directory: location?["directory"]?.stringValue
                ?? object["directory"]?.stringValue
                ?? "",
            parentID: object["parentID"]?.stringValue,
            summary: nil,
            title: object["title"]?.stringValue ?? "Untitled session",
            agent: object["agent"]?.stringValue,
            version: object["version"]?.stringValue ?? "2",
            time: OpenCodeSessionTime(
                created: time?["created"]?.numberValue ?? 0,
                updated: time?["updated"]?.numberValue ?? 0,
                compacting: time?["compacting"]?.numberValue,
                archived: time?["archived"]?.numberValue
            ),
            forkSourceID: object["fork"]?.objectValue?["sessionID"]?.stringValue
        )
    }

    static func message(
        _ object: [String: OpenCodeJSONValue],
        sessionID: String
    ) -> OpenCodeMessageEnvelope? {
        guard let id = object["id"]?.stringValue,
              let type = object["type"]?.stringValue
        else { return nil }
        let time = object["time"]?.objectValue
        let created = time?["created"]?.numberValue ?? 0

        switch type {
        case "user", "synthetic", "system", "skill":
            var parts: [OpenCodePart] = []
            let metadata = object["metadata"]?.objectValue
            let selectedModel = metadata?["model"]?.objectValue
            let text = metadata?["displayText"]?.stringValue ?? object["text"]?.stringValue ?? ""
            if !text.isEmpty {
                var part = textPart(
                    messageID: id,
                    sessionID: sessionID,
                    kind: "text",
                    ordinal: 0,
                    text: text
                )
                // System context updates and synthetic messages are context
                // OpenCode added for the model, not words the agent wrote.
                if type == "synthetic" || type == "system" { part.synthetic = true }
                parts.append(part)
            }
            // @agent mentions (Prompt.agents) render as the v1 agent part does.
            for (index, agent) in (object["agents"]?.arrayValue ?? []).enumerated() {
                guard let name = agent.objectValue?["name"]?.stringValue, !name.isEmpty else { continue }
                var part = OpenCodePart(
                    id: "\(id):agent:\(index)", sessionID: sessionID, messageID: id, type: "agent", text: nil,
                    mime: nil, filename: nil, url: nil, callID: nil, tool: nil, state: nil, files: nil,
                    description: nil, agent: nil)
                part.name = name
                parts.append(part)
            }
            for (index, file) in (object["files"]?.arrayValue ?? []).enumerated() {
                guard let file = file.objectValue else { continue }
                let mime = file["mime"]?.stringValue ?? "application/octet-stream"
                let uri = file["source"]?.objectValue?["uri"]?.stringValue
                    ?? file["uri"]?.stringValue
                    ?? file["data"]?.stringValue.map { "data:\(mime);base64,\($0)" }
                parts.append(OpenCodePart(
                    id: "\(id):file:\(index)", sessionID: sessionID, messageID: id,
                    type: "file", text: nil, mime: mime, filename: file["name"]?.stringValue,
                    url: uri, callID: nil, tool: nil, state: nil, files: nil, description: nil, agent: nil
                ))
            }
            return OpenCodeMessageEnvelope(
                info: OpenCodeMessageInfo(
                    id: id,
                    sessionID: sessionID,
                    role: type == "user" ? "user" : "assistant",
                    time: OpenCodeMessageTime(created: created, completed: nil),
                    agent: metadata?["agent"]?.stringValue,
                    modelID: selectedModel?["modelID"]?.stringValue ?? selectedModel?["id"]?.stringValue,
                    providerID: selectedModel?["providerID"]?.stringValue,
                    finish: nil,
                    error: nil,
                    variant: selectedModel?["variant"]?.stringValue
                ),
                parts: parts
            )
        case "assistant":
            let model = object["model"]?.objectValue
            let error = object["error"]?.objectValue.map {
                OpenCodeMessageError(
                    name: $0["type"]?.stringValue ?? "error",
                    data: $0
                )
            }
            var parts: [OpenCodePart] = []
            var ordinals: [String: Int] = [:]
            for case .object(let item) in object["content"]?.arrayValue ?? [] {
                guard let kind = item["type"]?.stringValue else { continue }
                switch kind {
                case "text", "reasoning":
                    let ordinal = ordinals[kind, default: 0]
                    ordinals[kind] = ordinal + 1
                    parts.append(
                        textPart(
                            messageID: id,
                            sessionID: sessionID,
                            kind: kind,
                            ordinal: ordinal,
                            text: item["text"]?.stringValue ?? ""
                        )
                    )
                case "tool":
                    guard let callID = item["id"]?.stringValue else { continue }
                    parts.append(
                        OpenCodePart(
                            id: callID,
                            sessionID: sessionID,
                            messageID: id,
                            type: "tool",
                            text: nil,
                            mime: nil,
                            filename: nil,
                            url: nil,
                            callID: callID,
                            tool: item["name"]?.stringValue,
                            state: toolState(
                                item["state"]?.objectValue,
                                time: item["time"]?.objectValue
                            ),
                            files: nil,
                            description: nil,
                            agent: nil
                        )
                    )
                default:
                    continue
                }
            }
            parts += stepParts(messageID: id, sessionID: sessionID, finish: object["finish"]?.stringValue,
                               cost: object["cost"]?.numberValue, tokens: object["tokens"],
                               files: object["snapshot"]?.objectValue?["files"])
            return OpenCodeMessageEnvelope(
                info: OpenCodeMessageInfo(
                    id: id,
                    sessionID: sessionID,
                    role: "assistant",
                    time: OpenCodeMessageTime(
                        created: created,
                        completed: time?["completed"]?.numberValue
                    ),
                    agent: object["agent"]?.stringValue,
                    modelID: model?["id"]?.stringValue,
                    providerID: model?["providerID"]?.stringValue,
                    finish: object["finish"]?.stringValue,
                    error: error
                ),
                parts: parts
            )
        case "compaction", "agent-switched", "model-switched":
            // Conversation markers render as the matching v1 part types.
            let model = object["model"]?.objectValue
            var part = OpenCodePart(
                id: "\(id):\(type)", sessionID: sessionID, messageID: id,
                type: ["agent-switched": "agent", "model-switched": "model"][type] ?? type,
                text: object["summary"]?.stringValue, mime: nil, filename: nil, url: nil, callID: nil, tool: nil,
                state: nil, files: nil, description: nil, agent: nil)
            part.auto = object["reason"]?.stringValue.map { $0 == "auto" }
            part.name = object["agent"]?.stringValue ?? model?["id"]?.stringValue ?? model?["modelID"]?.stringValue
            return OpenCodeMessageEnvelope(info: OpenCodeMessageInfo(id: id, sessionID: sessionID, role: "system",
                time: OpenCodeMessageTime(created: created, completed: nil), agent: nil, modelID: nil, providerID: nil,
                finish: nil, error: nil), parts: [part])
        default:
            let errorObject = object["error"]?.objectValue
            let text = [object["description"]?.stringValue, object["command"]?.stringValue,
                        object["output"]?.stringValue, object["summary"]?.stringValue,
                        errorObject?["message"]?.stringValue].compactMap { $0?.trimmedNonEmpty }.joined(separator: "\n\n")
            let label = type.replacingOccurrences(of: "-", with: " ").capitalized
            let status = object["status"]?.stringValue.map { " (\($0))" } ?? ""
            return OpenCodeMessageEnvelope(info: OpenCodeMessageInfo(id: id, sessionID: sessionID, role: "system",
                time: OpenCodeMessageTime(created: created, completed: time?["completed"]?.numberValue),
                agent: nil, modelID: nil, providerID: nil, finish: nil, error: nil),
                parts: [textPart(messageID: id, sessionID: sessionID, kind: "text", ordinal: 0,
                    text: label + status + (text.isEmpty ? "" : "\n\n" + text))])
        }
    }

    /// Synthetic parts carrying a settled v2 step's accounting and changed
    /// files, in the v1 step-finish and patch shapes. The snapshot projection
    /// and step.ended both produce them, under the same IDs.
    static func stepParts(
        messageID: String, sessionID: String, finish: String?, cost: Double?,
        tokens: OpenCodeJSONValue?, files: OpenCodeJSONValue?
    ) -> [OpenCodePart] {
        var parts: [OpenCodePart] = []
        let paths = files?.arrayValue?.compactMap(\.stringValue) ?? []
        if let usage = OpenCodeTokenUsage(tokens) {
            var part = OpenCodePart(
                id: "\(messageID):step-finish", sessionID: sessionID, messageID: messageID, type: "step-finish",
                text: nil, mime: nil, filename: nil, url: nil, callID: nil, tool: nil, state: nil, files: nil,
                description: nil, agent: nil)
            part.reason = finish; part.cost = cost; part.tokens = usage
            parts.append(part)
        }
        if !paths.isEmpty {
            parts.append(OpenCodePart(
                id: "\(messageID):patch", sessionID: sessionID, messageID: messageID, type: "patch", text: nil,
                mime: nil, filename: nil, url: nil, callID: nil, tool: nil, state: nil, files: paths,
                description: nil, agent: nil))
        }
        return parts
    }

    static func isStepPart(_ part: OpenCodePart) -> Bool {
        part.id == "\(part.messageID):step-finish" || part.id == "\(part.messageID):patch"
    }

    static func toolState(
        _ state: [String: OpenCodeJSONValue]?,
        time: [String: OpenCodeJSONValue]?
    ) -> OpenCodeToolState? {
        guard let state else { return nil }
        let status = state["status"]?.stringValue ?? "pending"
        let toolTime = time.map {
            OpenCodeToolTime(
                start: $0["ran"]?.numberValue ?? $0["created"]?.numberValue ?? 0,
                end: $0["completed"]?.numberValue
            )
        }
        switch status {
        case "streaming":
            return OpenCodeToolState(
                status: "pending",
                input: nil,
                raw: state["input"]?.stringValue,
                title: nil,
                output: nil,
                error: nil,
                time: toolTime
            )
        case "completed", "error":
            return OpenCodeToolState(
                status: status,
                input: state["input"]?.objectValue,
                raw: nil,
                title: nil,
                output: toolOutputText(state["content"]),
                error: state["error"]?.objectValue?["message"]?.stringValue,
                time: toolTime
            )
        default:
            // Current servers project a pending tool's partial input as a
            // string, and a running tool's latest progress checkpoint as content.
            return OpenCodeToolState(
                status: status,
                input: state["input"]?.objectValue,
                raw: state["input"]?.stringValue,
                title: nil,
                output: toolOutputText(state["content"]),
                error: nil,
                time: toolTime
            )
        }
    }

    static func toolOutputText(_ content: OpenCodeJSONValue?) -> String? {
        guard let items = content?.arrayValue else { return nil }
        let texts = items.compactMap { item -> String? in
            guard let object = item.objectValue else { return nil }
            switch object["type"]?.stringValue {
            case "text":
                return object["text"]?.stringValue
            case "file":
                return object["uri"]?.stringValue
            default:
                return nil
            }
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    private static func textPart(
        messageID: String,
        sessionID: String,
        kind: String,
        ordinal: Int,
        text: String
    ) -> OpenCodePart {
        OpenCodePart(
            id: streamPartID(messageID: messageID, kind: kind, ordinal: ordinal),
            sessionID: sessionID,
            messageID: messageID,
            type: kind,
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
}
