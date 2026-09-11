import Foundation

// Ported from packages/app/src/session/requests/session-question-dock.tsx
// (anomalyco/opencode v2 e15fb426): option values are wire values, and answers
// are keyed by field key. Keep field metadata for conditional and typed inputs.
struct OpenCodeForm: Codable, Equatable, Sendable {
    let id: String
    let sessionID: String
    let title: String
    let fields: [[String: OpenCodeJSONValue]]

    var normalized: OpenCodeQuestionRequest {
        OpenCodeQuestionRequest(id: id, sessionID: sessionID, questions: fields.map { field in
            let type = field["type"]?.stringValue
            var options = (field["options"]?.arrayValue ?? []).compactMap { item -> OpenCodeQuestionOption? in
                guard let value = item.objectValue, let key = value["value"]?.stringValue else { return nil }
                return OpenCodeQuestionOption(label: value["label"]?.stringValue ?? key,
                    description: value["description"]?.stringValue ?? "", wireValue: key)
            }
            if type == "boolean" {
                options = [OpenCodeQuestionOption(label: "Yes", description: "", wireValue: "true"),
                           OpenCodeQuestionOption(label: "No", description: "", wireValue: "false")]
            }
            return OpenCodeQuestion(question: field["description"]?.stringValue ?? field["title"]?.stringValue ?? title,
                header: field["title"]?.stringValue ?? field["key"]?.stringValue ?? title,
                options: options, multiple: type == "multiselect",
                custom: type == "boolean" || type == "external" ? false : field["custom"] != .bool(false))
        }, apiVersion: .v2, form: self)
    }

    func values(_ answers: [[String]], validating: Bool = true) throws -> [String: OpenCodeJSONValue] {
        var values: [String: OpenCodeJSONValue] = [:]
        for (index, field) in fields.enumerated() {
            guard let key = field["key"]?.stringValue else { continue }
            let strings = answers.indices.contains(index) ? answers[index] : []
            guard !strings.isEmpty else { continue }
            switch field["type"]?.stringValue {
            case "string": values[key] = .string(strings[0])
            case "multiselect": values[key] = .array(strings.map(OpenCodeJSONValue.string))
            case "boolean":
                guard let bool = Bool(strings[0]) else {
                    if validating { throw invalid(field, "Choose Yes or No.") }; continue
                }
                values[key] = .bool(bool)
            case "number", "integer":
                guard let number = Double(strings[0]), number.isFinite,
                      field["type"] != .string("integer") || number.rounded() == number else {
                    if validating { throw invalid(field, "Enter a valid number.") }; continue
                }
                values[key] = .number(number)
            case "external": continue
            default: throw invalid(field, "This field requires a newer byot version.")
            }
        }
        return values
    }

    func isVisible(_ index: Int, answers: [[String]]) -> Bool {
        guard fields.indices.contains(index) else { return false }
        let values = (try? values(answers, validating: false)) ?? [:]
        return (fields[index]["when"]?.arrayValue ?? []).allSatisfy { condition in
            guard let condition = condition.objectValue, let key = condition["key"]?.stringValue else { return false }
            let equal = values[key] == condition["value"]
            return condition["op"] == .string("neq") ? !equal : equal
        }
    }

    func answer(_ answers: [[String]]) throws -> [String: OpenCodeJSONValue] {
        // Hidden fields must not submit stale choices after their condition changes.
        let visibleAnswers = fields.indices.map { isVisible($0, answers: answers) ? (answers.indices.contains($0) ? answers[$0] : []) : [] }
        let values = try values(visibleAnswers)
        for (index, field) in fields.enumerated() where isVisible(index, answers: answers) {
            guard let key = field["key"]?.stringValue, field["type"] != .string("external") else { continue }
            guard let value = values[key] else {
                if field["required"] == .bool(true) { throw invalid(field, "An answer is required.") }
                continue
            }
            if let number = value.numberValue {
                if let min = field["minimum"]?.numberValue, number < min { throw invalid(field, "The number is below the minimum.") }
                if let max = field["maximum"]?.numberValue, number > max { throw invalid(field, "The number exceeds the maximum.") }
            }
            if let text = value.stringValue {
                if let min = field["minLength"]?.numberValue, Double(text.count) < min { throw invalid(field, "The answer is too short.") }
                if let max = field["maxLength"]?.numberValue, Double(text.count) > max { throw invalid(field, "The answer is too long.") }
            }
            if let items = value.arrayValue {
                if let min = field["minItems"]?.numberValue, Double(items.count) < min { throw invalid(field, "Choose more options.") }
                if let max = field["maxItems"]?.numberValue, Double(items.count) > max { throw invalid(field, "Choose fewer options.") }
            }
        }
        // The server remains authoritative for formats, patterns and custom validators.
        return values
    }

    private func invalid(_ field: [String: OpenCodeJSONValue], _ message: String) -> OpenCodeConnectionError {
        .server("\(field["title"]?.stringValue ?? field["key"]?.stringValue ?? title): \(message)")
    }
}
