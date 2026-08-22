import Foundation

struct OpenCodeQuestionResponseState: Equatable, Sendable {
    private(set) var selections: [Int: Set<String>] = [:]
    private(set) var customAnswers: [Int: String] = [:]

    mutating func toggle(_ label: String, at index: Int, question: OpenCodeQuestion) {
        if question.multiple == true {
            var values = selections[index] ?? []
            if values.contains(label) {
                values.remove(label)
            } else {
                values.insert(label)
            }
            selections[index] = values
        } else {
            selections[index] = isSelected(label, at: index) ? [] : [label]
            customAnswers[index] = ""
        }
    }

    mutating func setCustomAnswer(
        _ answer: String,
        at index: Int,
        question: OpenCodeQuestion
    ) {
        customAnswers[index] = answer
        if question.multiple != true,
           !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selections[index] = []
        }
    }

    func isSelected(_ label: String, at index: Int) -> Bool {
        selections[index]?.contains(label) == true
    }

    func customAnswer(at index: Int) -> String {
        customAnswers[index] ?? ""
    }

    func resolvedAnswers(for questions: [OpenCodeQuestion]) -> [[String]] {
        questions.indices.map { index in
            let custom = customAnswer(at: index)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if questions[index].multiple == true {
                var values = Array(selections[index] ?? []).sorted()
                if !custom.isEmpty { values.append(custom) }
                return values
            }
            if !custom.isEmpty { return [custom] }
            return Array(selections[index] ?? []).sorted()
        }
    }

    func canSubmit(questions: [OpenCodeQuestion]) -> Bool {
        resolvedAnswers(for: questions).allSatisfy { !$0.isEmpty }
    }
}
