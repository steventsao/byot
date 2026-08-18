enum OpenCodePromptSubmission: Equatable, Sendable {
    case dispatch(OpenCodeQueuedPrompt)
    case queued(OpenCodeQueuedPrompt)
}
