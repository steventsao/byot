import Foundation

// Swift port of the session event reducers in anomalyco/opencode
// packages/client/src/solid/data.ts at e15fb426ec593f02f8c6017d78b1c0ec58c8de8a.
// Text/reasoning events edit the last block of that kind; tool events use IDs.
struct OpenCodeV2EventReducer: Sendable {
    private var seen: Set<String> = []
    private var order: [String] = []

    mutating func apply(_ event: OpenCodeEvent, to messages: inout [OpenCodeMessageEnvelope]) -> Bool {
        guard let sessionID = event.sessionID else { return false }
        if seen.contains(event.id) { return true }
        // Bound deduplication independently from transcript length.
        seen.insert(event.id); order.append(event.id)
        if order.count > 4096 { seen.remove(order.removeFirst()) }
        let data = event.properties
        let created = event.created ?? 0
        let messageID = data["assistantMessageID"]?.stringValue ?? data["messageID"]?.stringValue
        if event.type == "session.inbox.enqueued" {
            guard let item = data["item"]?.objectValue, item["type"] == .string("user"),
                  let id = data["inboxID"]?.stringValue, var payload = item["payload"]?.objectValue else { return false }
            payload["id"] = .string(id); payload["type"] = .string("user")
            payload["time"] = .object(["created": .number(created)])
            guard let message = OpenCodeV2Normalization.message(payload, sessionID: sessionID) else { return false }
            upsert(message, in: &messages)
            return true
        }
        if event.type == "session.inbox.cancelled" {
            messages.removeAll { $0.id == data["inboxID"]?.stringValue }
            return true
        }
        guard let messageID else { return false }
        if event.type == "session.step.started" {
            let existing = messages.first { $0.id == messageID }
            let model = data["model"]?.objectValue
            let info = OpenCodeMessageInfo(id: messageID, sessionID: sessionID, role: "assistant",
                time: OpenCodeMessageTime(created: existing?.info.time.created ?? created, completed: nil),
                agent: data["agent"]?.stringValue, modelID: model?["id"]?.stringValue,
                providerID: model?["providerID"]?.stringValue, finish: nil, error: nil)
            upsert(OpenCodeMessageEnvelope(info: info, parts: existing?.parts ?? []), in: &messages)
            return true
        }
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        switch event.type {
        case "session.text.started", "session.reasoning.started":
            let kind = event.type.contains("reasoning") ? "reasoning" : "text"
            // Older beta snapshots include ordinals; the current beta follows last-of-kind.
            let ordinal = data["ordinal"]?.numberValue.map(Int.init) ?? messages[index].parts.filter { $0.type == kind }.count
            let id = OpenCodeV2Normalization.streamPartID(messageID: messageID, kind: kind, ordinal: ordinal)
            if !messages[index].parts.contains(where: { $0.id == id }) {
                messages[index].parts.append(part(id: id, messageID: messageID, sessionID: sessionID, type: kind, text: ""))
            }
        case "session.text.delta", "session.reasoning.delta", "session.text.ended", "session.reasoning.ended":
            let kind = event.type.contains("reasoning") ? "reasoning" : "text"
            let partIndex: Int?
            if let ordinal = data["ordinal"]?.numberValue {
                let id = OpenCodeV2Normalization.streamPartID(messageID: messageID, kind: kind, ordinal: Int(ordinal))
                partIndex = messages[index].parts.firstIndex { $0.id == id }
            } else { partIndex = messages[index].parts.lastIndex { $0.type == kind } }
            guard let partIndex else { return false }
            if event.type.hasSuffix(".delta") {
                messages[index].parts[partIndex].text = (messages[index].parts[partIndex].text ?? "") + (data["delta"]?.stringValue ?? "")
            } else { messages[index].parts[partIndex].text = data["text"]?.stringValue ?? "" }
        case "session.tool.input.started", "session.tool.input.delta", "session.tool.input.ended",
             "session.tool.called", "session.tool.progress", "session.tool.success", "session.tool.failed":
            guard let id = data["id"]?.stringValue ?? data["callID"]?.stringValue else { return false }
            let previous = messages[index].parts.first { $0.id == id }
            if previous == nil && event.type != "session.tool.input.started" && event.type != "session.tool.called" { return false }
            let old = previous?.state
            var status = old?.status ?? "pending"
            var raw = old?.raw
            var input = old?.input
            var output = old?.output
            var error = old?.error
            var end = old?.time?.end
            switch event.type {
            case "session.tool.input.started": raw = raw ?? ""
            case "session.tool.input.delta": raw = (raw ?? "") + (data["delta"]?.stringValue ?? "")
            case "session.tool.input.ended": raw = data["text"]?.stringValue
            case "session.tool.called": status = "running"; input = data["input"]?.objectValue; raw = nil
            case "session.tool.success": status = "completed"; output = OpenCodeV2Normalization.toolOutputText(data["content"]); end = created
            case "session.tool.failed":
                status = "error"; error = data["error"]?.objectValue?["message"]?.stringValue ?? data["error"]?.stringValue
                output = OpenCodeV2Normalization.toolOutputText(data["content"]); end = created
            default: break
            }
            let state = OpenCodeToolState(status: status, input: input, raw: raw,
                title: data["metadata"]?.objectValue?["title"]?.stringValue ?? old?.title,
                output: output, error: error, time: OpenCodeToolTime(start: old?.time?.start ?? created, end: end))
            let updated = part(id: id, messageID: messageID, sessionID: sessionID, type: "tool", text: nil,
                               tool: data["name"]?.stringValue ?? previous?.tool, state: state)
            if let i = messages[index].parts.firstIndex(where: { $0.id == id }) { messages[index].parts[i] = updated }
            else { messages[index].parts.append(updated) }
        case "session.step.ended", "session.step.failed":
            let old = messages[index].info
            let error = data["error"]?.objectValue.map {
                OpenCodeMessageError(name: $0["type"]?.stringValue ?? "Error", data: $0)
            }
            messages[index].info = OpenCodeMessageInfo(id: old.id, sessionID: old.sessionID, role: old.role,
                time: OpenCodeMessageTime(created: old.time.created, completed: created), agent: old.agent,
                modelID: old.modelID, providerID: old.providerID, finish: data["finish"]?.stringValue ?? (error == nil ? nil : "error"), error: error)
        case "session.message.content.updated":
            let old = messages[index].info
            let object: [String: OpenCodeJSONValue] = ["id": .string(old.id), "type": .string("assistant"), "content": data["content"] ?? .array([])]
            guard let updated = OpenCodeV2Normalization.message(object, sessionID: sessionID) else { return false }
            messages[index].parts = updated.parts
        default: return false
        }
        return true
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
