import Foundation

struct OpenCodeQueuedPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let intent: OpenCodeSessionInputIntent
    let model: OpenCodeModelOption?
    let agent: String?
    var text: String { intent.text }
    let attachments: [OpenCodePromptAttachment]

    init(
        id: UUID = UUID(),
        text: String,
        model: OpenCodeModelOption?,
        attachments: [OpenCodePromptAttachment] = []
    ) {
        self.id = id
        intent = .prompt(text)
        self.model = model
        agent = nil
        self.attachments = attachments
    }

    init(
        id: UUID = UUID(),
        intent: OpenCodeSessionInputIntent,
        model: OpenCodeModelOption?,
        agent: String?,
        attachments: [OpenCodePromptAttachment] = []
    ) {
        self.id = id
        self.intent = intent
        self.model = model
        self.agent = agent
        self.attachments = attachments
    }
}
