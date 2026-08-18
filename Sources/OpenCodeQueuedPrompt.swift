import Foundation

struct OpenCodeQueuedPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let model: OpenCodeModelOption?

    init(
        id: UUID = UUID(),
        text: String,
        model: OpenCodeModelOption?
    ) {
        self.id = id
        self.text = text
        self.model = model
    }
}
