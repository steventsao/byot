import Foundation

struct OpenCodeQueuedPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let model: OpenCodeModelOption?
    let attachments: [OpenCodePromptAttachment]

    init(
        id: UUID = UUID(),
        text: String,
        model: OpenCodeModelOption?,
        attachments: [OpenCodePromptAttachment] = []
    ) {
        self.id = id
        self.text = text
        self.model = model
        self.attachments = attachments
    }
}
