import Foundation

struct OpenCodeQueuedPrompt: Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let model: OpenCodeModelOption?
    let attachments: [OpenCodePromptAttachment]

    let agent: String?
    let variant: String?
    let command: OpenCodeCommandInvocation?
    let remoteReferences: [OpenCodePromptFileReference]

    init(
        id: UUID = UUID(),
        text: String,
        model: OpenCodeModelOption?,
        attachments: [OpenCodePromptAttachment] = [],
        agent: String? = nil,
        variant: String? = nil,
        command: OpenCodeCommandInvocation? = nil,
        remoteReferences: [OpenCodePromptFileReference] = []
    ) {
        self.id = id
        self.text = text
        self.model = model
        self.attachments = attachments
        self.agent = agent
        self.variant = variant
        self.command = command
        self.remoteReferences = remoteReferences
    }
}
