import Foundation

// Swift port of the v2 session event reducers. Two generations of the
// stream are accepted and land on the same transcript shape:
// - opencode2 beta 19242 (anomalyco/opencode packages/client/src/solid/data.ts
//   at e15fb426): session.{step,text,reasoning,tool}.*, session.inbox.* and
//   session.message.content.updated. Text and reasoning edit the last block
//   of their kind; tools are addressed by `id`; time is the envelope `created`.
// - current opencode (packages/schema/src/session-event.ts and
//   packages/core/src/session/message-updater.ts): session.next.*. Blocks are
//   addressed by textID/reasoningID, tools by callID, and time travels in the
//   payload as `timestamp`. Deltas are live-only; *.ended carries the full
//   value, so a missed fragment heals at the block boundary.
struct OpenCodeV2EventReducer: Sendable {
    enum Outcome: Equatable, Sendable {
        /// The transcript changed and should be republished.
        case changed
        /// The event was understood but leaves the transcript as it is.
        case unchanged
        /// The event could not be placed; reconcile from the projection.
        case unresolved
    }

    private static let nextPrefix = "session.next."
    private static let memoryLimit = 4096

    private var seen: Set<String> = []
    private var order: [String] = []
    // Server block IDs (textID, reasoningID) are provider scoped and may
    // repeat, so each ordinal part ID that snapshot normalization also
    // produces remembers the block ID it streamed; fragments then resolve to
    // the latest part with that ID, as upstream's findLast does.
    private var blockIDs: [String: String] = [:]
    private var blockOrder: [String] = []
    // Shell projections, by callID, so shell.ended can fill in the output.
    private var shells: [String: [String: OpenCodeJSONValue]] = [:]

    /// Maps current `session.next.*` names onto the beta names so both
    /// generations share one reducer. Other names pass through unchanged.
    static func canonicalType(_ type: String) -> String {
        guard type.hasPrefix(nextPrefix) else { return type }
        return "session." + type.dropFirst(nextPrefix.count)
    }

    mutating func apply(_ event: OpenCodeEvent, to messages: inout [OpenCodeMessageEnvelope]) -> Outcome {
        guard let sessionID = event.sessionID else { return .unresolved }
        if seen.contains(event.id) { return .unchanged }
        // Bound deduplication independently from transcript length.
        seen.insert(event.id); order.append(event.id)
        if order.count > Self.memoryLimit { seen.remove(order.removeFirst()) }
        let data = event.properties
        let type = Self.canonicalType(event.type)
        let created = data["timestamp"]?.numberValue ?? event.created ?? 0

        switch type {
        case "session.inbox.enqueued":
            guard let item = data["item"]?.objectValue, item["type"] == .string("user"),
                  let id = data["inboxID"]?.stringValue, var payload = item["payload"]?.objectValue else { return .unresolved }
            payload["id"] = .string(id); payload["type"] = .string("user")
            payload["time"] = .object(["created": .number(created)])
            return upsertProjection(payload, sessionID: sessionID, in: &messages)
        case "session.inbox.cancelled":
            let count = messages.count
            messages.removeAll { $0.id == data["inboxID"]?.stringValue }
            return messages.count == count ? .unchanged : .changed
        case "session.prompted":
            guard let id = data["messageID"]?.stringValue, let prompt = data["prompt"]?.objectValue else { return .unresolved }
            var payload: [String: OpenCodeJSONValue] = ["id": .string(id), "type": .string("user"),
                "text": prompt["text"] ?? .string(""), "time": .object(["created": .number(created)])]
            payload["files"] = prompt["files"]
            payload["agents"] = prompt["agents"]
            payload["metadata"] = event.metadata.map(OpenCodeJSONValue.object)
            return upsertProjection(payload, sessionID: sessionID, in: &messages)
        case "session.context.updated", "session.synthetic":
            guard let id = data["messageID"]?.stringValue else { return .unresolved }
            return upsertProjection(["id": .string(id), "type": .string(type == "session.synthetic" ? "synthetic" : "system"),
                "text": data["text"] ?? .string(""), "time": .object(["created": .number(created)])],
                sessionID: sessionID, in: &messages)
        case "session.agent.switched", "session.model.switched":
            guard let id = data["messageID"]?.stringValue else { return .unresolved }
            var payload: [String: OpenCodeJSONValue] = ["id": .string(id), "time": .object(["created": .number(created)])]
            if type == "session.agent.switched" {
                payload["type"] = .string("agent-switched"); payload["agent"] = data["agent"]
            } else {
                payload["type"] = .string("model-switched"); payload["model"] = data["model"]
            }
            return upsertProjection(payload, sessionID: sessionID, in: &messages)
        case "session.shell.started":
            guard let id = data["messageID"]?.stringValue, let callID = data["callID"]?.stringValue else { return .unresolved }
            var payload: [String: OpenCodeJSONValue] = ["id": .string(id), "type": .string("shell"), "callID": .string(callID),
                "command": data["command"] ?? .string(""), "output": .string(""), "time": .object(["created": .number(created)])]
            payload["metadata"] = event.metadata.map(OpenCodeJSONValue.object)
            if shells.count >= Self.memoryLimit { shells.removeAll(keepingCapacity: true) }
            shells[callID] = payload
            return upsertProjection(payload, sessionID: sessionID, in: &messages)
        case "session.shell.ended":
            guard let callID = data["callID"]?.stringValue, var payload = shells.removeValue(forKey: callID),
                  case .object(var time)? = payload["time"] else { return .unresolved }
            time["completed"] = .number(created)
            payload["time"] = .object(time)
            payload["output"] = data["output"] ?? .string("")
            return upsertProjection(payload, sessionID: sessionID, in: &messages)
        case "session.compaction.ended":
            guard let id = data["messageID"]?.stringValue else { return .unresolved }
            return upsertProjection(["id": .string(id), "type": .string("compaction"), "reason": data["reason"] ?? .string("auto"),
                "summary": data["text"] ?? .string(""), "recent": data["recent"] ?? .string(""),
                "time": .object(["created": .number(created)])], sessionID: sessionID, in: &messages)
        case "session.prompt.admitted", "session.moved", "session.retried",
             "session.compaction.started", "session.compaction.delta":
            // Admission, relocation and retries carry no transcript content;
            // compaction becomes a message only once its summary has ended.
            return .unchanged
        default:
            break
        }

        guard let messageID = data["assistantMessageID"]?.stringValue ?? data["messageID"]?.stringValue else { return .unresolved }
        if type == "session.step.started" {
            // A new step supersedes an assistant that never settled (for
            // example an interrupted step), as the projection records it.
            if let open = messages.lastIndex(where: { $0.info.role == "assistant" }),
               messages[open].id != messageID, messages[open].info.time.completed == nil {
                messages[open].info.time = OpenCodeMessageTime(created: messages[open].info.time.created, completed: created)
            }
            let existing = messages.first { $0.id == messageID }
            let model = data["model"]?.objectValue
            let info = OpenCodeMessageInfo(id: messageID, sessionID: sessionID, role: "assistant",
                time: OpenCodeMessageTime(created: existing?.info.time.created ?? created, completed: nil),
                agent: data["agent"]?.stringValue, modelID: model?["id"]?.stringValue,
                providerID: model?["providerID"]?.stringValue, finish: nil, error: nil)
            upsert(OpenCodeMessageEnvelope(info: info, parts: existing?.parts ?? []), in: &messages)
            return .changed
        }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return .unresolved }
        switch type {
        case "session.text.started", "session.reasoning.started":
            let kind = type == "session.reasoning.started" ? "reasoning" : "text"
            // Older beta snapshots include ordinals; otherwise every start opens
            // the next block, even when a provider reuses a block ID.
            let ordinal = data["ordinal"]?.numberValue.map(Int.init) ?? messages[index].parts.filter { $0.type == kind }.count
            let id = OpenCodeV2Normalization.streamPartID(messageID: messageID, kind: kind, ordinal: ordinal)
            rememberBlock(kind: kind, data: data, partID: id)
            guard !messages[index].parts.contains(where: { $0.id == id }) else { return .unchanged }
            messages[index].parts.append(part(id: id, messageID: messageID, sessionID: sessionID, type: kind, text: ""))
            return .changed
        case "session.text.delta", "session.reasoning.delta", "session.text.ended", "session.reasoning.ended":
            let kind = type.hasPrefix("session.reasoning.") ? "reasoning" : "text"
            let partIndex: Int
            if let resolved = blockIndex(kind: kind, data: data, in: messages[index]) {
                partIndex = resolved
                // A block adopted after a refetch keeps streaming by its ID.
                if blockIDs[messages[index].parts[partIndex].id] == nil {
                    rememberBlock(kind: kind, data: data, partID: messages[index].parts[partIndex].id)
                }
            } else if data["ordinal"] == nil {
                // The block start was missed (for example before a reconnect);
                // open the next block here so the fragment still streams in place.
                let ordinal = messages[index].parts.filter { $0.type == kind }.count
                let id = OpenCodeV2Normalization.streamPartID(messageID: messageID, kind: kind, ordinal: ordinal)
                guard !messages[index].parts.contains(where: { $0.id == id }) else { return .unresolved }
                rememberBlock(kind: kind, data: data, partID: id)
                messages[index].parts.append(part(id: id, messageID: messageID, sessionID: sessionID, type: kind, text: ""))
                partIndex = messages[index].parts.count - 1
            } else {
                return .unresolved
            }
            let previous = messages[index].parts[partIndex].text ?? ""
            let text = type.hasSuffix(".delta")
                ? previous + (data["delta"]?.stringValue ?? "")
                : data["text"]?.stringValue ?? ""
            guard text != previous else { return .unchanged }
            messages[index].parts[partIndex].text = text
            return .changed
        case "session.tool.input.started", "session.tool.input.delta", "session.tool.input.ended",
             "session.tool.called", "session.tool.progress", "session.tool.success", "session.tool.failed":
            return applyTool(type: type, data: data, created: created, messageIndex: index, sessionID: sessionID, in: &messages)
        case "session.step.ended", "session.step.failed":
            let old = messages[index].info
            let error = data["error"]?.objectValue.map {
                OpenCodeMessageError(name: $0["type"]?.stringValue ?? "Error", data: $0)
            }
            let finish = data["finish"]?.stringValue ?? (error == nil ? nil : "error")
            messages[index].info = OpenCodeMessageInfo(id: old.id, sessionID: old.sessionID, role: old.role,
                time: OpenCodeMessageTime(created: old.time.created, completed: created), agent: old.agent,
                modelID: old.modelID, providerID: old.providerID, finish: finish, error: error, variant: old.variant,
                cost: data["cost"]?.numberValue ?? old.cost, tokens: OpenCodeTokenUsage(data["tokens"]) ?? old.tokens)
            // step.ended carries the step's accounting and changed files; the
            // projection exposes them on the message, so both paths agree.
            let stepParts = OpenCodeV2Normalization.stepParts(
                messageID: messageID, sessionID: sessionID, finish: data["finish"]?.stringValue,
                cost: data["cost"]?.numberValue, tokens: data["tokens"], files: data["files"])
            messages[index].parts.removeAll(where: OpenCodeV2Normalization.isStepPart)
            messages[index].parts += stepParts
            return .changed
        case "session.message.content.updated":
            let old = messages[index].info
            let object: [String: OpenCodeJSONValue] = ["id": .string(old.id), "type": .string("assistant"), "content": data["content"] ?? .array([])]
            guard let updated = OpenCodeV2Normalization.message(object, sessionID: sessionID) else { return .unresolved }
            // Content snapshots omit step accounting; keep what step.ended added.
            messages[index].parts = updated.parts + messages[index].parts.filter(OpenCodeV2Normalization.isStepPart)
            return .changed
        default:
            return .unresolved
        }
    }

    private mutating func applyTool(
        type: String, data: [String: OpenCodeJSONValue], created: Double, messageIndex index: Int, sessionID: String,
        in messages: inout [OpenCodeMessageEnvelope]
    ) -> Outcome {
        guard let id = data["id"]?.stringValue ?? data["callID"]?.stringValue else { return .unresolved }
        let messageID = messages[index].id
        let previous = messages[index].parts.first { $0.id == id }
        if previous == nil && type != "session.tool.input.started" && type != "session.tool.called" { return .unresolved }
        let old = previous?.state
        var status = old?.status ?? "pending"
        var raw = old?.raw
        var input = old?.input
        var output = old?.output
        var error = old?.error
        var metadata = old?.metadata
        var start = old?.time?.start ?? created
        var end = old?.time?.end
        switch type {
        case "session.tool.input.started":
            raw = raw ?? ""
        case "session.tool.input.delta":
            guard status == "pending" else { return .unchanged }
            raw = (raw ?? "") + (data["delta"]?.stringValue ?? "")
        case "session.tool.input.ended":
            guard status == "pending" else { return .unchanged }
            raw = data["text"]?.stringValue ?? raw
        case "session.tool.called":
            // The projection times a tool from the moment it ran.
            status = "running"; input = data["input"]?.objectValue; raw = nil; start = created
        case "session.tool.progress":
            // Replayable checkpoints of a running tool; show its latest output.
            guard status == "running" else { return .unchanged }
            output = OpenCodeV2Normalization.toolOutputText(data["content"]) ?? output
            metadata = data["structured"]?.objectValue ?? metadata
        case "session.tool.success":
            guard status != "completed" && status != "error" else { return .unchanged }
            status = "completed"; output = OpenCodeV2Normalization.toolOutputText(data["content"]); end = created
            metadata = data["structured"]?.objectValue ?? metadata
        case "session.tool.failed":
            guard status != "completed" && status != "error" else { return .unchanged }
            status = "error"
            error = data["error"]?.objectValue?["message"]?.stringValue ?? data["error"]?.stringValue
            output = OpenCodeV2Normalization.toolOutputText(data["content"]) ?? output
            end = created
        default:
            break
        }
        let state = OpenCodeToolState(status: status, input: input, raw: raw,
            title: data["metadata"]?.objectValue?["title"]?.stringValue ?? old?.title,
            output: output, error: error, time: OpenCodeToolTime(start: start, end: end), metadata: metadata)
        let updated = part(id: id, messageID: messageID, sessionID: sessionID, type: "tool", text: nil,
                           tool: data["name"]?.stringValue ?? data["tool"]?.stringValue ?? previous?.tool, state: state)
        if let i = messages[index].parts.firstIndex(where: { $0.id == id }) {
            guard messages[index].parts[i] != updated else { return .unchanged }
            messages[index].parts[i] = updated
        } else {
            messages[index].parts.append(updated)
        }
        return .changed
    }

    // MARK: Stream blocks

    private static func blockServerID(kind: String, data: [String: OpenCodeJSONValue]) -> String? {
        data[kind == "reasoning" ? "reasoningID" : "textID"]?.stringValue
    }

    private mutating func rememberBlock(kind: String, data: [String: OpenCodeJSONValue], partID: String) {
        guard let serverID = Self.blockServerID(kind: kind, data: data) else { return }
        if blockIDs.updateValue(serverID, forKey: partID) == nil { blockOrder.append(partID) }
        if blockOrder.count > Self.memoryLimit { blockIDs.removeValue(forKey: blockOrder.removeFirst()) }
    }

    /// Resolves a delta or end to its part: explicit ordinal, then the latest
    /// block streamed under that block ID, then the latest block of that kind
    /// unless that block already belongs to a different block ID.
    private func blockIndex(kind: String, data: [String: OpenCodeJSONValue], in message: OpenCodeMessageEnvelope) -> Int? {
        if let ordinal = data["ordinal"]?.numberValue {
            let id = OpenCodeV2Normalization.streamPartID(messageID: message.id, kind: kind, ordinal: Int(ordinal))
            return message.parts.firstIndex { $0.id == id }
        }
        guard let latest = message.parts.lastIndex(where: { $0.type == kind }) else { return nil }
        guard let serverID = Self.blockServerID(kind: kind, data: data) else { return latest }
        if let known = message.parts.lastIndex(where: { $0.type == kind && blockIDs[$0.id] == serverID }) { return known }
        // An unseen block ID whose predecessor streamed under another ID is a
        // block whose start was missed; it must not overwrite that predecessor.
        return blockIDs[message.parts[latest].id] == nil ? latest : nil
    }

    // MARK: Messages

    private func upsertProjection(
        _ object: [String: OpenCodeJSONValue], sessionID: String, in messages: inout [OpenCodeMessageEnvelope]
    ) -> Outcome {
        guard let message = OpenCodeV2Normalization.message(object, sessionID: sessionID) else { return .unresolved }
        guard messages.first(where: { $0.id == message.id }) != message else { return .unchanged }
        upsert(message, in: &messages)
        return .changed
    }

    private func upsert(_ message: OpenCodeMessageEnvelope, in messages: inout [OpenCodeMessageEnvelope]) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) { messages[index] = message }
        else { messages.append(message) }
        messages.sort { $0.info.time.created == $1.info.time.created ? $0.id < $1.id : $0.info.time.created < $1.info.time.created }
    }

    private func part(id: String, messageID: String, sessionID: String, type: String, text: String?, tool: String? = nil, state: OpenCodeToolState? = nil) -> OpenCodePart {
        OpenCodePart(id: id, sessionID: sessionID, messageID: messageID, type: type, text: text,
                     mime: nil, filename: nil, url: nil, callID: type == "tool" ? id : nil, tool: tool, state: state,
                     files: nil, description: nil, agent: nil)
    }
}
