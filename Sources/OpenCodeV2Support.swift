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

// Normalizes OpenCode 2 (v2) wire shapes into the v1-shaped models the rest
// of the app already consumes. Shapes follow the pinned v2 contract the
// desktop client codes against (packages/app/vendor/opencode-ai-client-
// 1.17.13-v2.tgz in the opencode monorepo); parsing is deliberately lenient
// so contract drift degrades instead of failing.
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
            )
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
            let text = object["text"]?.stringValue ?? ""
            if !text.isEmpty {
                parts.append(
                    textPart(
                        messageID: id,
                        sessionID: sessionID,
                        kind: "text",
                        ordinal: 0,
                        text: text
                    )
                )
            }
            for (index, file) in (object["files"]?.arrayValue ?? []).enumerated() {
                guard let file = file.objectValue else { continue }
                let mime = file["mime"]?.stringValue ?? "application/octet-stream"
                let uri = file["uri"]?.stringValue
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
                    agent: nil,
                    modelID: nil,
                    providerID: nil,
                    finish: nil,
                    error: nil
                ),
                parts: parts
            )
        case "assistant":
            let model = object["model"]?.objectValue
            let error = object["error"]?.objectValue.map {
                OpenCodeMessageError(
                    name: $0["type"]?.stringValue ?? "error",
                    data: $0["message"]?.stringValue.map { ["message": .string($0)] }
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
        default:
            return nil
        }
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
            return OpenCodeToolState(
                status: status,
                input: state["input"]?.objectValue,
                raw: nil,
                title: nil,
                output: nil,
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

    static func providerModels(
        providers: [[String: OpenCodeJSONValue]],
        models: [[String: OpenCodeJSONValue]]
    ) -> [OpenCodeProviderModels] {
        let providerNames = providers.reduce(into: [String: String]()) { result, provider in
            guard let id = provider["id"]?.stringValue,
                  provider["activation"]?.stringValue != "disabled",
                  provider["disabled"] != .bool(true) else { return }
            result[id] = provider["name"]?.stringValue ?? id
        }
        var grouped: [String: [OpenCodeModelOption]] = [:]
        for model in models {
            guard let providerID = model["providerID"]?.stringValue,
                  // The catalog id is canonical (ModelV2.ID) and is what the
                  // session model route expects; modelID is the provider wire
                  // id. Mirrors the desktop catalog build.
                  let modelID = model["id"]?.stringValue ?? model["modelID"]?.stringValue,
                  !modelID.isEmpty,
                  // Only list models of providers the server reports, and skip
                  // deprecated/disabled entries (desktop utils.ts behavior).
                  providerNames[providerID] != nil,
                  model["status"]?.stringValue != "deprecated",
                  model["enabled"] != .bool(false)
            else { continue }
            grouped[providerID, default: []].append(
                OpenCodeModelOption(
                    providerID: providerID,
                    providerName: providerNames[providerID] ?? providerID,
                    modelID: modelID,
                    modelName: model["name"]?.stringValue ?? modelID,
                    status: model["status"]?.stringValue
                )
            )
        }
        return grouped
            .map { providerID, models in
                OpenCodeProviderModels(
                    providerID: providerID,
                    providerName: providerNames[providerID] ?? providerID,
                    models: models.sorted {
                        $0.modelName.localizedStandardCompare($1.modelName) == .orderedAscending
                    },
                    connectionState: .unreported
                )
            }
            .sorted {
                $0.providerName.localizedStandardCompare($1.providerName) == .orderedAscending
            }
    }

    // GET /api/session/active answers {data: {sessionID: {type: "running"}}}.
    static func activeStatuses(
        _ object: [String: OpenCodeJSONValue]
    ) -> [String: OpenCodeSessionStatus] {
        (object["data"]?.objectValue ?? [:]).compactMapValues { value in
            guard let entry = value.objectValue,
                  entry["type"]?.stringValue == "running"
            else { return nil }
            return .busy
        }
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

