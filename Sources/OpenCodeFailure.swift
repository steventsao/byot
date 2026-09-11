import Foundation

/// Reduces provider and server envelopes to the message a person can act on.
struct OpenCodeFailure: Equatable, Sendable {
    let message: String
    let isModelUnavailable: Bool

    init(message raw: String, details: [String: OpenCodeJSONValue]? = nil) {
        let object = details.map { OpenCodeJSONValue.object($0) }
        let detail = object.flatMap { Self.readable($0, depth: 0) }
        let readable = detail ?? Self.readable(.string(raw), depth: 0) ?? "The request failed."
        let description = (raw + " " + readable).lowercased()
        // Current v2 deliberately drops the provider response body. Its
        // provider.invalid-request + status:410 still identifies a gone model.
        let status = details?["status"]?.numberValue ?? details?["statusCode"]?.numberValue
        let providerGone = status == 410 && (raw.hasPrefix("provider.") || ["APIError", "APICallError"].contains(raw))
        isModelUnavailable = providerGone || description.contains("modelnotfound")
            || (description.contains("model") && [
                "end of life", "no longer available", "not found", "does not exist",
                "retired", "unavailable", "not available", "decommissioned"
            ].contains(where: description.contains))
        message = providerGone && !readable.lowercased().contains("model")
            ? "The selected model is no longer available."
            : String(readable.prefix(1_000))
    }

    private static func readable(_ value: OpenCodeJSONValue, depth: Int) -> String? {
        guard depth < 6 else { return nil }
        if let object = value.objectValue {
            // The response body often has the useful detail; the outer message
            // can be only “Gone” or “API request failed”. Ignore other payloads.
            for key in ["detail", "responseBody", "error", "data", "message", "title"] {
                if let nested = object[key], let result = readable(nested, depth: depth + 1) {
                    return result
                }
            }
            return nil
        }
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        if text.utf8.count <= 65_536, let start = text.firstIndex(of: "{") {
            let json = String(text[start...])
            if let decoded = try? JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(json.utf8)) {
                return readable(decoded, depth: depth + 1)
            }
        }
        return text
    }
}
