import Foundation

struct OpenCodeTranscriptReducer: Sendable {
    private(set) var messages: [OpenCodeMessageEnvelope] = []
    private var orphanParts: [String: [OpenCodePart]] = [:]
    private var pendingText: [PartKey: String] = [:]

    mutating func replace(with messages: [OpenCodeMessageEnvelope]) {
        self.messages = messages.sorted(by: messageOrder)
        orphanParts.removeAll(keepingCapacity: true)
        pendingText.removeAll(keepingCapacity: true)
    }

    mutating func apply(_ event: OpenCodeEvent) -> Bool {
        switch event.type {
        case "message.updated":
            return applyMessageUpdated(event)
        case "message.removed":
            return applyMessageRemoved(event)
        case "message.part.updated":
            return applyPartUpdated(event)
        case "message.part.removed":
            return applyPartRemoved(event)
        case "message.part.delta":
            return applyPartDelta(event)
        default:
            return false
        }
    }

    private mutating func applyMessageUpdated(_ event: OpenCodeEvent) -> Bool {
        guard let info: OpenCodeMessageInfo = decode(event.properties["info"]) else {
            return false
        }
        if let index = messages.firstIndex(where: { $0.id == info.id }) {
            messages[index].info = info
        } else {
            let parts = orphanParts.removeValue(forKey: info.id) ?? []
            messages.append(OpenCodeMessageEnvelope(info: info, parts: parts))
            messages.sort(by: messageOrder)
        }
        return true
    }

    private mutating func applyMessageRemoved(_ event: OpenCodeEvent) -> Bool {
        guard let messageID = event.properties["messageID"]?.stringValue else { return false }
        let originalCount = messages.count
        messages.removeAll { $0.id == messageID }
        orphanParts.removeValue(forKey: messageID)
        pendingText = pendingText.filter { $0.key.messageID != messageID }
        return messages.count != originalCount
    }

    private mutating func applyPartUpdated(_ event: OpenCodeEvent) -> Bool {
        guard var part: OpenCodePart = decode(event.properties["part"]) else { return false }
        let key = PartKey(messageID: part.messageID, partID: part.id)
        if let buffered = pendingText.removeValue(forKey: key),
           (part.text ?? "").isEmpty {
            part.text = buffered
        }

        if let messageIndex = messages.firstIndex(where: { $0.id == part.messageID }) {
            if let partIndex = messages[messageIndex].parts.firstIndex(where: { $0.id == part.id }) {
                messages[messageIndex].parts[partIndex] = part
            } else {
                messages[messageIndex].parts.append(part)
            }
        } else {
            var parts = orphanParts[part.messageID] ?? []
            if let index = parts.firstIndex(where: { $0.id == part.id }) {
                parts[index] = part
            } else {
                parts.append(part)
            }
            orphanParts[part.messageID] = parts
        }
        return true
    }

    private mutating func applyPartRemoved(_ event: OpenCodeEvent) -> Bool {
        guard let messageID = event.properties["messageID"]?.stringValue,
              let partID = event.properties["partID"]?.stringValue
        else { return false }
        let key = PartKey(messageID: messageID, partID: partID)
        pendingText.removeValue(forKey: key)

        if let messageIndex = messages.firstIndex(where: { $0.id == messageID }) {
            let originalCount = messages[messageIndex].parts.count
            messages[messageIndex].parts.removeAll { $0.id == partID }
            return originalCount != messages[messageIndex].parts.count
        }
        guard var parts = orphanParts[messageID] else { return false }
        let originalCount = parts.count
        parts.removeAll { $0.id == partID }
        orphanParts[messageID] = parts
        return originalCount != parts.count
    }

    private mutating func applyPartDelta(_ event: OpenCodeEvent) -> Bool {
        guard event.properties["field"]?.stringValue == "text",
              let messageID = event.properties["messageID"]?.stringValue,
              let partID = event.properties["partID"]?.stringValue,
              let delta = event.properties["delta"]?.stringValue
        else { return false }
        let key = PartKey(messageID: messageID, partID: partID)

        if let messageIndex = messages.firstIndex(where: { $0.id == messageID }),
           let partIndex = messages[messageIndex].parts.firstIndex(where: { $0.id == partID }) {
            messages[messageIndex].parts[partIndex].text =
                (messages[messageIndex].parts[partIndex].text ?? "") + delta
            return true
        }
        if var parts = orphanParts[messageID],
           let partIndex = parts.firstIndex(where: { $0.id == partID }) {
            parts[partIndex].text = (parts[partIndex].text ?? "") + delta
            orphanParts[messageID] = parts
            return true
        }
        pendingText[key, default: ""] += delta
        return true
    }

    private func decode<Value: Decodable>(_ value: OpenCodeJSONValue?) -> Value? {
        guard let value,
              let data = try? JSONEncoder().encode(value)
        else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func messageOrder(
        _ lhs: OpenCodeMessageEnvelope,
        _ rhs: OpenCodeMessageEnvelope
    ) -> Bool {
        if lhs.info.time.created == rhs.info.time.created {
            return lhs.id < rhs.id
        }
        return lhs.info.time.created < rhs.info.time.created
    }
}

private struct PartKey: Hashable, Sendable {
    let messageID: String
    let partID: String
}
