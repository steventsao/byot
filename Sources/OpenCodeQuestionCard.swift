import SwiftUI

struct OpenCodeQuestionCard: View {
    let request: OpenCodeQuestionRequest
    let isWorking: Bool
    let submit: ([[String]]) async -> Void
    let reject: () async -> Void

    @State private var responseState = OpenCodeQuestionResponseState()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Question", systemImage: "questionmark.bubble.fill")
                .font(.cleanBodySemibold)
                .foregroundStyle(BYOTBrand.accent)

            // Direct EnumeratedSequence collection conformance requires iOS 26.
            ForEach(Array(request.questions.enumerated()), id: \.offset) { index, question in
                if request.form?.isVisible(index, answers: responseState.resolvedAnswers(for: request.questions)) != false {
                VStack(alignment: .leading, spacing: 10) {
                    Text(question.header)
                        .font(.cleanCaptionBold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(question.question)
                        .font(.cleanBodySemibold)

                    ForEach(question.options) { option in
                        optionButton(option, question: question, index: index)
                    }

                    if let raw = request.form?.fields[index]["url"]?.stringValue,
                       let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Link("Continue in browser", destination: url)
                    }
                    if question.allowsCustomAnswer {
                        TextField(
                            "Custom answer",
                            text: customAnswerBinding(at: index, question: question),
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                    }
                }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    rejectButton
                    Spacer()
                    submitButton
                }
                VStack(spacing: 10) {
                    submitButton.frame(maxWidth: .infinity)
                    rejectButton.frame(maxWidth: .infinity)
                }
            }
            .disabled(isWorking)
        }
        .padding(16)
        .background(BYOTBrand.elevatedSurface, in: RoundedRectangle(cornerRadius: BYOTBrand.panelRadius))
        .overlay {
            RoundedRectangle(cornerRadius: BYOTBrand.panelRadius)
                .stroke(BYOTBrand.accent.opacity(0.55), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            guard let form = request.form else { return }
            for (index, field) in form.fields.enumerated() {
                guard let value = field["default"] else { continue }
                let values = value.arrayValue?.compactMap(\.stringValue) ?? [value.compactDescription]
                let question = request.questions[index]
                for value in values {
                    if question.options.contains(where: { $0.id == value }) {
                        responseState.toggle(value, at: index, question: question)
                    } else {
                        responseState.setCustomAnswer(value, at: index, question: question)
                    }
                }
            }
        }
    }

    private var rejectButton: some View {
        Button("Reject", systemImage: "xmark", role: .destructive) {
            Task { await reject() }
        }
        .buttonStyle(.bordered)
        .frame(minHeight: 44)
    }

    private var submitButton: some View {
        Button("Submit answers", systemImage: "paperplane") {
            let answers = responseState.resolvedAnswers(for: request.questions)
            Task { await submit(answers) }
        }
        .buttonStyle(.borderedProminent)
        .frame(minHeight: 44)
        .disabled(request.form.map { (try? $0.answer(responseState.resolvedAnswers(for: request.questions))) == nil } ?? !responseState.canSubmit(questions: request.questions))
    }

    private func optionButton(
        _ option: OpenCodeQuestionOption,
        question: OpenCodeQuestion,
        index: Int
    ) -> some View {
        let selected = responseState.isSelected(option.id, at: index)
        return Button {
            responseState.toggle(option.id, at: index, question: question)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? BYOTBrand.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.cleanBodySemibold)
                        .foregroundStyle(.primary)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.cleanCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func customAnswerBinding(
        at index: Int,
        question: OpenCodeQuestion
    ) -> Binding<String> {
        Binding(
            get: { responseState.customAnswer(at: index) },
            set: { responseState.setCustomAnswer($0, at: index, question: question) }
        )
    }
}
