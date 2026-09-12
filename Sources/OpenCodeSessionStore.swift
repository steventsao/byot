import Combine
import Foundation

private struct OpenCodeRecoverablePrompt: Sendable {
    let messageID: String
    let text: String
    let attachments: [OpenCodePromptAttachment]
    let model: OpenCodeModelOption?
    let agent: String?
    let variant: String?
    let command: OpenCodeCommandInvocation?
    let remoteReferences: [OpenCodePromptFileReference]
}

@MainActor
final class OpenCodeSessionStore: ObservableObject {
    @Published private(set) var messages: [OpenCodeMessageEnvelope] = []
    @Published private(set) var permissions: [OpenCodePermissionRequest] = []
    @Published private(set) var questions: [OpenCodeQuestionRequest] = []
    @Published private(set) var diffs: [OpenCodeDiff] = []
    @Published private(set) var protocolCapabilities: OpenCodeProtocolCapabilities?
    var diffPresentation: OpenCodeSessionDiffPresentation {
        OpenCodeSessionDiffPresentation(diffs: diffs, support: protocolCapabilities?.sessionDiff)
    }
    @Published private(set) var status: OpenCodeSessionStatus = .idle
    @Published private(set) var isStatusReady = false
    @Published private(set) var isLoading = false
    @Published private(set) var isSending = false
    @Published private(set) var isEventConnected = false
    @Published private(set) var eventErrorMessage: String?
    @Published private(set) var actionErrorMessage: String?
    @Published private(set) var actionInFlightID: String?
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var providerModels: [OpenCodeProviderModels] = []
    @Published private(set) var selectedModel: OpenCodeModelOption?
    @Published private(set) var composerCatalog = OpenCodeComposerCatalog()
    @Published private(set) var selectedAgentID: String?
    @Published private(set) var selectedVariant: String?
    @Published private(set) var composerErrorMessage: String?
    @Published private(set) var queuedPrompts: [OpenCodeQueuedPrompt] = []
    @Published private(set) var queueAnnouncementRevision = 0
    @Published private(set) var isAwaitingFirstVisibleOutput = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelErrorMessage: String?
    @Published private(set) var isStoppingTurn = false
    @Published private(set) var hasRecoverableUnansweredPrompt = false
    @Published var errorMessage: String?

    @Published private(set) var session: OpenCodeSession
    @Published private(set) var sessionFeatures = OpenCodeSessionFeatureSupport()
    @Published private(set) var todoProgress = OpenCodeTodoProgress()
    @Published private(set) var revertMessageID: String?
    @Published private(set) var restoredPrompt: OpenCodeRestoredPrompt?
    @Published private(set) var forkedSession: OpenCodeSession?
    @Published private(set) var childSessions: [OpenCodeSession] = []
    @Published private(set) var parentSession: OpenCodeSession?
    @Published private(set) var sessionDetailsError: String?
    @Published private(set) var isPerformingSessionAction = false
    @Published private(set) var isLoadingRelatedSessions = false
    @Published private(set) var didDeleteSession = false
    private let featureService: (any OpenCodeSessionFeatureServicing)?
    private var featureRefreshGeneration = 0
    private var featureMutationGeneration = 0
    private var todoMutationGeneration = 0
    private var revertedUserMessages: [OpenCodeMessageEnvelope] = []
    let directory: String
    let remoteFiles: OpenCodeRemoteFileStore?
    let serverID: UUID
    private let workspace: String?
    private let service: any OpenCodeSessionServicing
    private let defaults: UserDefaults
    private let modelSelectionKey: String
    private let serverDefaultModelKey: String
    private let agentSelectionKey: String
    private let serverDefaultAgentKey: String
    private var submittedPrompts: [String: OpenCodeQueuedPrompt] = [:]
    private var persistedModelID: String?
    private var transcript = OpenCodeTranscriptReducer()
    private var promptQueue = OpenCodePromptQueue()
    private var eventTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var messageRefreshTask: Task<Void, Never>?
    private var actionRefreshTask: Task<Void, Never>?
    private var modelTask: Task<Void, Never>?
    private var promptDispatchTask: Task<Void, Never>?
    private var promptDispatchID: UUID?
    private var inFlightPrompt: OpenCodeQueuedPrompt?
    private var currentTurnActivityBaseline: Set<String>?
    private var recoverableUnansweredPrompt: OpenCodeRecoverablePrompt?
    private var dismissedUnansweredMessageID: String?
    private var recoveryIdleUserMessageID: String?
    private var didStatusProbeFailWithFreshTranscript = false
    private var queueRecoveryTask: Task<Void, Never>?
    private var queueRecoveryID: UUID?
    private var refreshGeneration = 0
    private var messageRequestGeneration = 0
    private var actionRequestGeneration = 0
    private var transcriptMutationGeneration = 0
    private var actionMutationGeneration = 0
    private var diffMutationGeneration = 0
    private var statusMutationGeneration = 0
    private var messageRefreshPending = false
    private var actionRefreshPending = false
    private var isRunning = false
    private var lifecycleGeneration = 0

    init(
        service: any OpenCodeSessionServicing,
        serverID: UUID,
        session: OpenCodeSession,
        directory: String,
        defaults: UserDefaults = .standard,
        remoteFiles: OpenCodeRemoteFileStore? = nil
    ) {
        self.service = service
        self.serverID = serverID
        featureService = service as? any OpenCodeSessionFeatureServicing
        self.session = session
        self.directory = directory
        self.defaults = defaults
        self.remoteFiles = remoteFiles
        modelSelectionKey = "byot.opencode.model.\(serverID.uuidString).\(session.id)"
        serverDefaultModelKey = "byot.opencode.model.default.\(serverID.uuidString)"
        persistedModelID = defaults.string(forKey: modelSelectionKey)
        workspace = session.workspaceID
        agentSelectionKey = "byot.opencode.agent.\(serverID.uuidString).\(session.id)"
        serverDefaultAgentKey = "byot.opencode.agent.default.\(serverID.uuidString)"
        selectedAgentID = defaults.string(forKey: agentSelectionKey)?.trimmedNonEmpty
    }

    deinit {
        eventTask?.cancel()
        reconciliationTask?.cancel()
        messageRefreshTask?.cancel()
        actionRefreshTask?.cancel()
        modelTask?.cancel()
        promptDispatchTask?.cancel()
        queueRecoveryTask?.cancel()
    }

    var pendingActionCount: Int {
        permissions.count + questions.count
    }

    var willQueueNextPrompt: Bool {
        if revertMessageID != nil, !status.isActive, !isSending { return false }
        return status.isActive || isSending || promptQueue.shouldQueueNextPrompt
    }

    var canSubmitPrompt: Bool {
        isRunning && isStatusReady && isStoppingTurn == false && !isPerformingSessionAction && !didDeleteSession
    }

    var modelFailure: OpenCodeMessageError? {
        guard let userIndex = messages.lastIndex(where: { $0.info.role == "user" }),
              let assistant = messages.suffix(from: userIndex + 1).last(where: { $0.info.role == "assistant" }),
              let error = assistant.info.error, error.failure.isModelUnavailable
        else { return nil }
        return error
    }

    private var modelFailurePrompt: OpenCodeRecoverablePrompt? {
        guard modelFailure != nil,
              let userIndex = messages.lastIndex(where: { $0.info.role == "user" }),
              messages[userIndex].id != dismissedUnansweredMessageID
        else { return nil }
        // Offer replay only when this turn produced no usable assistant output
        // or tool calls. A partially executed turn can still select a new model.
        guard messages.suffix(from: userIndex + 1).allSatisfy({ message in
            message.parts.allSatisfy { part in
                part.type != "tool" && (part.text?.trimmedNonEmpty == nil)
            }
        }) else { return nil }
        return recoverablePrompt(in: [messages[userIndex]])
    }

    var canRetryWithSelectedModel: Bool {
        guard canSubmitPrompt, !status.isActive, !isSending,
              let selectedModel, modelFailurePrompt != nil else { return false }
        let failed = messages.last(where: { $0.info.role == "assistant" })?.info
        return failed?.providerID != selectedModel.providerID || failed?.modelID != selectedModel.modelID
    }

    @discardableResult
    func retryWithSelectedModel() -> Bool {
        guard canRetryWithSelectedModel, let original = modelFailurePrompt,
              let prompt = promptQueue.beginExplicitDispatch(
                text: original.text, model: selectedModel, attachments: original.attachments,
                agent: original.agent, variant: selectedVariant,
                command: original.command, remoteReferences: original.remoteReferences
              ) else { return false }
        dismissedUnansweredMessageID = original.messageID
        publishPromptQueue()
        schedulePromptDispatch(prompt)
        return true
    }

    var canRetryFirstQueuedPrompt: Bool {
        canSubmitPrompt
            && status.isActive == false
            && isSending == false
            && promptQueue.isPaused
    }

    var canStopTurn: Bool {
        isRunning && !isPerformingSessionAction
            && isStoppingTurn == false
            && (
                status.isActive
                    || (
                        didStatusProbeFailWithFreshTranscript
                            && hasUnansweredLatestUserMessageWithoutAssistantEnvelope
                    )
            )
    }

    var canRetryUnansweredPrompt: Bool {
        isRunning && !isPerformingSessionAction && revertMessageID == nil
            && isStatusReady
            && status.isActive == false
            && isSending == false
            && isStoppingTurn == false
            && recoverableUnansweredPrompt != nil
    }

    func start() async {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isRunning = true
        isStatusReady = false
        didStatusProbeFailWithFreshTranscript = false
        recoveryIdleUserMessageID = nil
        connectEvents()
        modelTask?.cancel()
        modelTask = Task { [weak self] in
            await self?.reloadModels()
        }
        await refresh(showLoading: true)
        if Task.isCancelled, generation == lifecycleGeneration { stop() }
    }

    func stop() {
        lifecycleGeneration &+= 1
        featureRefreshGeneration &+= 1
        isRunning = false
        isStatusReady = false
        didStatusProbeFailWithFreshTranscript = false
        recoveryIdleUserMessageID = nil
        statusMutationGeneration &+= 1
        status = .idle
        refreshGeneration &+= 1
        eventTask?.cancel()
        eventTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        messageRefreshTask?.cancel()
        messageRefreshTask = nil
        actionRefreshTask?.cancel()
        actionRefreshTask = nil
        modelTask?.cancel()
        modelTask = nil
        promptDispatchTask?.cancel()
        promptDispatchTask = nil
        promptDispatchID = nil
        if let inFlightPrompt {
            promptQueue.dispatchFailed(inFlightPrompt, requeue: true)
        } else {
            promptQueue.pausePendingPrompts()
        }
        self.inFlightPrompt = nil
        queueRecoveryTask?.cancel()
        queueRecoveryTask = nil
        queueRecoveryID = nil
        publishPromptQueue()
        messageRefreshPending = false
        actionRefreshPending = false
        isSending = false
        isStoppingTurn = false
        finishCurrentTurnActivityTracking()
        isEventConnected = false
    }

    func refresh(showLoading: Bool = false) async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        messageRequestGeneration &+= 1
        let messageGeneration = messageRequestGeneration
        actionRequestGeneration &+= 1
        let actionGeneration = actionRequestGeneration
        let transcriptBaseline = transcriptMutationGeneration
        let actionBaseline = actionMutationGeneration
        let diffBaseline = diffMutationGeneration
        let statusBaseline = statusMutationGeneration
        async let featureRefresh: Void = refreshSessionFeatures()
        if showLoading { isLoading = true }
        defer {
            if generation == refreshGeneration { isLoading = false }
        }
        do {
            protocolCapabilities = try await service.capabilities()
            let actionClient = service
            let actionDirectory = directory
            let actionWorkspace = workspace
            let actionSessionID = session.id
            async let messageResult = Self.capture {
                try await actionClient.messages(
                    sessionID: actionSessionID,
                    directory: actionDirectory,
                    workspace: actionWorkspace
                )
            }
            async let permissionResult = Self.capture {
                try await actionClient.permissions(
                    directory: actionDirectory,
                    workspace: actionWorkspace
                )
            }
            async let v2PermissionResult = Self.capture {
                try await actionClient.v2Permissions(sessionID: actionSessionID)
            }
            async let questionResult = Self.capture {
                try await actionClient.questions(
                    directory: actionDirectory,
                    workspace: actionWorkspace
                )
            }
            async let v2QuestionResult = Self.capture {
                try await actionClient.v2Questions(sessionID: actionSessionID)
            }
            async let diffResult = Self.capture {
                try await actionClient.diffs(
                    sessionID: actionSessionID,
                    directory: actionDirectory,
                    workspace: actionWorkspace
                )
            }
            async let statusResult = Self.capture {
                try await actionClient.sessionStatuses(
                    directory: actionDirectory,
                    workspace: actionWorkspace
                )
            }

            let results = await (
                messageResult,
                permissionResult,
                v2PermissionResult,
                questionResult,
                v2QuestionResult,
                diffResult,
                statusResult
            )
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }

            var coreErrors: [Error] = []
            var didApplyFreshMessages = false
            switch results.0 {
            case .success(let messages):
                if messageGeneration == messageRequestGeneration,
                   transcriptBaseline == transcriptMutationGeneration {
                    transcript.replace(with: messages)
                    publishTranscript()
                    didApplyFreshMessages = true
                }
            case .failure(let error):
                if messageGeneration == messageRequestGeneration {
                    coreErrors.append(error)
                }
            }
            switch results.5 {
            case .success(let diffs):
                if OpenCodeSessionDiffReconciliation.shouldApplyFetchedSnapshot(support: protocolCapabilities?.sessionDiff, mutationBaseline: diffBaseline, currentMutation: diffMutationGeneration) { self.diffs = diffs }
            case .failure(let error):
                coreErrors.append(error)
            }
            switch results.6 {
            case .success(let statuses):
                if statusBaseline == statusMutationGeneration {
                    didStatusProbeFailWithFreshTranscript = false
                    applyReconciledStatus(statuses[session.id] ?? .idle)
                }
            case .failure(let error):
                if statusBaseline == statusMutationGeneration {
                    didStatusProbeFailWithFreshTranscript = didApplyFreshMessages
                    if didApplyFreshMessages {
                        isStatusReady = false
                        recoveryIdleUserMessageID = nil
                        clearUnansweredPromptRecovery()
                    }
                }
                coreErrors.append(error)
            }
            errorMessage = coreErrors.first?.localizedDescription

            if actionGeneration == actionRequestGeneration,
               actionBaseline == actionMutationGeneration {
                applyPendingActionResults(
                    permissionResult: results.1,
                    v2PermissionResult: results.2,
                    questionResult: results.3,
                    v2QuestionResult: results.4
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            errorMessage = error.localizedDescription
        }
        await featureRefresh
    }

    func refreshSessionFeatures() async {
        guard let featureService else { return }
        featureRefreshGeneration &+= 1
        let generation = featureRefreshGeneration
        let mutation = featureMutationGeneration
        let todoMutation = todoMutationGeneration
        do {
            let support = try await featureService.sessionFeatureSupport()
            try Task.checkCancellation()
            guard generation == featureRefreshGeneration else { return }
            sessionFeatures = support
            let sessionID = session.id, directory = directory, workspace = workspace
            async let detailsResult = Self.capture { () -> OpenCodeSessionDetails? in
                guard support.details else { return nil }
                return try await featureService.sessionDetails(sessionID: sessionID, directory: directory, workspace: workspace)
            }
            async let todosResult = Self.capture {
                try await featureService.sessionTodos(sessionID: sessionID, directory: directory, workspace: workspace)
            }
            let (details, todos) = await (detailsResult, todosResult)
            try Task.checkCancellation()
            guard generation == featureRefreshGeneration else { return }
            if mutation == featureMutationGeneration {
                switch details {
                case .success(let details):
                    if let details {
                        session = details.session
                        revertMessageID = details.revertMessageID
                        publishTranscript()
                    }
                    sessionDetailsError = nil
                case .failure(let error): sessionDetailsError = error.localizedDescription
                }
            }
            if todoMutation == todoMutationGeneration {
                switch todos {
                case .success(let snapshot):
                    if let snapshot {
                        todoProgress = OpenCodeTodoProgress(items: snapshot)
                    }
                case .failure(let error):
                    todoProgress.error = error.localizedDescription
                    todoProgress.isStale = todoProgress.items != nil
                }
            }
        } catch is CancellationError {} catch {
            guard generation == featureRefreshGeneration else { return }
            sessionDetailsError = error.localizedDescription
        }
    }

    private func markTasksStale() {
        if todoProgress.items != nil { todoProgress.isStale = true }
    }

    private func handleSessionFeatureEvent(_ event: OpenCodeEvent) -> Bool {
        if event.type == "todo.updated", event.sessionID == session.id {
            if let todos: [OpenCodeTodo] = decode(event.properties["todos"]) {
                todoMutationGeneration &+= 1
                todoProgress = OpenCodeTodoProgress(items: todos)
            }
            return true
        }
        if event.type == "session.revert.staged", event.sessionID == session.id {
            featureMutationGeneration &+= 1
            revertMessageID = event.properties["revert"]?.objectValue?["messageID"]?.stringValue
            promptQueue.pausePendingPrompts()
            publishPromptQueue()
            publishTranscript()
            return true
        }
        if event.type == "session.revert.committed", event.sessionID == session.id {
            if let boundary = event.properties["to"]?.stringValue ?? revertMessageID {
                commitHistoryLocally(before: boundary)
            }
            scheduleReconciliation()
            return true
        }
        if event.type == "session.revert.cleared", event.sessionID == session.id {
            featureMutationGeneration &+= 1
            revertMessageID = nil
            publishTranscript()
            scheduleReconciliation()
            return true
        }
        if event.type == "session.updated", let info = event.properties["info"],
           let updated: OpenCodeSession = decode(info), updated.id == session.id {
            featureMutationGeneration &+= 1
            session = updated
            revertMessageID = info.objectValue?["revert"]?.objectValue?["messageID"]?.stringValue
            if revertMessageID != nil { promptQueue.pausePendingPrompts(); publishPromptQueue() }
            publishTranscript()
            return true
        }
        if event.type == "session.renamed", event.sessionID == session.id {
            scheduleReconciliation()
            return true
        }
        return false
    }

    func actionUnavailableReason(_ action: OpenCodeSessionAction) -> String? {
        let supported: Bool
        switch action {
        case .undo: supported = sessionFeatures.undo
        case .redo: supported = sessionFeatures.redo
        case .compact: supported = sessionFeatures.compact
        case .fork: supported = sessionFeatures.fork
        }
        if !supported { return "This server does not support this action." }
        if !isRunning || !isStatusReady { return "Wait for the session to connect." }
        if isPerformingSessionAction || isSending || isStoppingTurn { return "Wait for the current request to finish." }
        if status.isActive { return "Stop the current turn before changing its history." }
        if action == .undo && !messages.contains(where: { $0.info.role == "user" }) { return "No turn to undo." }
        if action == .redo && revertMessageID == nil { return "No undone turn to restore." }
        if action == .compact && sessionFeatures.compactRequiresModel && selectedModel == nil { return "Choose a model before compacting." }
        if action == .compact && revertMessageID != nil { return "Redo or send your revised prompt before compacting." }
        return nil
    }

    func consumeRestoredPrompt() { restoredPrompt = nil }
    func consumeForkedSession() { forkedSession = nil }

    func performSessionAction(_ action: OpenCodeSessionAction, messageID: String? = nil) async {
        guard let featureService else { return }
        if let reason = actionUnavailableReason(action) { actionErrorMessage = reason; return }
        let generation = lifecycleGeneration
        isPerformingSessionAction = true
        featureMutationGeneration &+= 1
        // These prompts were composed against the old history. Preserve them
        // for manual review; idle events must never send them automatically.
        promptQueue.pausePendingPrompts()
        publishPromptQueue()
        cancelQueueRecovery()
        defer { isPerformingSessionAction = false }
        do {
            switch action {
            case .undo:
                // A refresh already in flight may publish the old unreverted
                // snapshot while staging. Keep the recovery boundaries local
                // until the server confirms the new boundary.
                let userHistory = revertedUserMessages.isEmpty
                    ? transcript.messages.filter { $0.info.role == "user" }
                    : revertedUserMessages
                guard let target = messages.last(where: { $0.info.role == "user" && (messageID == nil || $0.id == messageID) }) else { return }
                try await featureService.stageSessionRevert(sessionID: session.id, directory: directory, workspace: workspace, messageID: target.id)
                guard generation == lifecycleGeneration, isRunning else { return }
                revertMessageID = target.id
                revertedUserMessages = userHistory
                restoredPrompt = OpenCodeRestoredPrompt(message: target)
                dismissUnansweredPromptRecovery()
            case .redo:
                guard let boundary = revertMessageID else { return }
                let fetchedUsers = transcript.messages.filter { $0.info.role == "user" }
                let users = fetchedUsers.contains(where: { $0.id == boundary }) ? fetchedUsers : revertedUserMessages
                let index = users.firstIndex { $0.id == boundary }
                let next = index.flatMap { users.dropFirst($0 + 1).first }
                if let next {
                    try await featureService.stageSessionRevert(sessionID: session.id, directory: directory, workspace: workspace, messageID: next.id)
                    guard generation == lifecycleGeneration, isRunning else { return }
                    revertMessageID = next.id
                    restoredPrompt = OpenCodeRestoredPrompt(message: next)
                } else {
                    try await featureService.clearSessionRevert(sessionID: session.id, directory: directory, workspace: workspace)
                    guard generation == lifecycleGeneration, isRunning else { return }
                    revertMessageID = nil
                    if let previous = index.map({ users[$0] }) {
                        restoredPrompt = OpenCodeRestoredPrompt(message: OpenCodeMessageEnvelope(info: previous.info, parts: []))
                    }
                }
            case .compact:
                try await featureService.compactSession(sessionID: session.id, directory: directory, workspace: workspace, model: selectedModel)
                guard generation == lifecycleGeneration, isRunning else { return }
            case .fork:
                let fork = try await featureService.forkSession(sessionID: session.id, directory: directory, workspace: workspace, beforeMessageID: messageID ?? revertMessageID)
                guard generation == lifecycleGeneration, isRunning else { return }
                forkedSession = fork
            }
            guard generation == lifecycleGeneration, isRunning else { return }
            actionErrorMessage = nil
            featureMutationGeneration &+= 1
            transcriptMutationGeneration &+= 1
            publishTranscript()
            await refresh()
        } catch is CancellationError {} catch {
            guard generation == lifecycleGeneration, isRunning else { return }
            actionErrorMessage = error.localizedDescription
        }
    }

    func loadRelatedSessions() async {
        guard let featureService, !isLoadingRelatedSessions else { return }
        isLoadingRelatedSessions = true
        defer { isLoadingRelatedSessions = false }
        do {
            if sessionFeatures.children {
                childSessions = try await featureService.childSessions(sessionID: session.id, directory: directory, workspace: workspace)
            }
            if let parentID = session.parentID ?? session.forkSourceID, sessionFeatures.details {
                parentSession = try await featureService.sessionDetails(sessionID: parentID, directory: directory, workspace: workspace).session
            }
            sessionDetailsError = nil
        } catch { sessionDetailsError = error.localizedDescription }
    }

    func renameSession(_ title: String) async -> Bool {
        guard let featureService, sessionFeatures.rename, !isPerformingSessionAction else { return false }
        isPerformingSessionAction = true
        featureMutationGeneration &+= 1
        defer { isPerformingSessionAction = false }
        do {
            session = try await featureService.renameSession(sessionID: session.id, directory: directory, workspace: workspace, title: title).session
            // Reject a stale details snapshot requested while rename awaited
            // the server, even if it completes after the confirmed new title.
            featureMutationGeneration &+= 1
            sessionDetailsError = nil
            return true
        } catch { sessionDetailsError = error.localizedDescription; return false }
    }

    func deleteSession() async -> Bool {
        guard let featureService, sessionFeatures.delete, !isPerformingSessionAction, !status.isActive, !isSending else { return false }
        isPerformingSessionAction = true
        promptQueue.pausePendingPrompts()
        publishPromptQueue()
        defer { isPerformingSessionAction = false }
        do {
            try await featureService.deleteSession(sessionID: session.id, directory: directory, workspace: workspace)
            didDeleteSession = true
            stop()
            return true
        } catch { sessionDetailsError = error.localizedDescription; return false }
    }

    func send(
        _ text: String,
        attachments: [OpenCodePromptAttachment] = [],
        remoteReferences: [OpenCodePromptFileReference] = []
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !attachments.isEmpty || !remoteReferences.isEmpty), canSubmitPrompt else { return false }
        guard remoteReferences.allSatisfy({ $0.matches(serverID: serverID, projectID: session.projectID,
            directory: directory, workspaceID: workspace) }) else {
            errorMessage = "File context belongs to a different project. Select the file again."
            return false
        }
        do {
            try OpenCodePromptAttachment.validate(attachments)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        didStatusProbeFailWithFreshTranscript = false
        recoveryIdleUserMessageID = nil
        dismissUnansweredPromptRecovery()
        if revertMessageID != nil, !status.isActive, !isSending,
           let prompt = promptQueue.beginExplicitDispatch(text: trimmed, model: selectedModel, attachments: attachments,
               agent: effectiveAgentID, variant: selectedVariant,
               command: OpenCodeCommandInvocation.parse(trimmed, catalog: composerCatalog.commands),
               remoteReferences: remoteReferences) {
            publishPromptQueue()
            schedulePromptDispatch(prompt)
            return true
        }
        let submission = promptQueue.accept(
            text: trimmed,
            model: selectedModel,
            attachments: attachments,
            agent: effectiveAgentID, variant: selectedVariant,
            command: OpenCodeCommandInvocation.parse(trimmed, catalog: composerCatalog.commands),
            remoteReferences: remoteReferences,
            serverIsActive: status.isActive || isSending
        )
        publishPromptQueue()
        switch submission {
        case .queued:
            queueAnnouncementRevision &+= 1
            scheduleQueueRecoveryIfNeeded()
            return true
        case .dispatch(let prompt):
            schedulePromptDispatch(prompt)
            return true
        }
    }

    func removeQueuedPrompt(_ id: UUID) {
        promptQueue.remove(id)
        publishPromptQueue()
    }

    func retryQueuedPrompt(_ id: UUID) {
        guard canRetryFirstQueuedPrompt,
              let prompt = promptQueue.retry(id)
        else { return }
        publishPromptQueue()
        schedulePromptDispatch(prompt)
    }

    @discardableResult
    func retryUnansweredPrompt() async -> Bool {
        guard canRetryUnansweredPrompt,
              let prompt = recoverableUnansweredPrompt
        else { return false }

        let generation = lifecycleGeneration
        isStoppingTurn = true
        defer {
            if generation == lifecycleGeneration {
                isStoppingTurn = false
            }
        }

        do {
            let didAbort = try await service.abort(
                sessionID: session.id,
                directory: directory,
                workspace: workspace
            )
            try Task.checkCancellation()
            guard generation == lifecycleGeneration, isRunning else { return false }
            guard didAbort else {
                errorMessage = "OpenCode did not confirm that the stalled turn was stopped."
                return false
            }

            errorMessage = nil
            let stillUnanswered =
                Self.latestUserMessageIDWithoutAssistantEnvelope(in: messages) == prompt.messageID
            settleTurnLocally(dismissingUnansweredPrompt: true)
            guard stillUnanswered else {
                scheduleMessageRefresh()
                return false
            }
            guard let dispatchPrompt = promptQueue.beginExplicitDispatch(
                text: prompt.text,
                model: prompt.model,
                attachments: prompt.attachments,
                agent: prompt.agent, variant: prompt.variant,
                command: prompt.command, remoteReferences: prompt.remoteReferences
            ) else {
                dismissedUnansweredMessageID = nil
                updateUnansweredPromptRecovery()
                return false
            }
            publishPromptQueue()
            schedulePromptDispatch(dispatchPrompt)
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == lifecycleGeneration, isRunning else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func stopTurn() async {
        guard canStopTurn else { return }
        let generation = lifecycleGeneration
        isStoppingTurn = true
        defer {
            if generation == lifecycleGeneration {
                isStoppingTurn = false
            }
        }
        // Pause before aborting so the idle transition the abort triggers does
        // not immediately auto-dispatch the next queued prompt — stopping means
        // the user wants to steer, and paused prompts keep their manual
        // send-now affordance.
        promptQueue.pausePendingPrompts()
        publishPromptQueue()
        do {
            let didAbort = try await service.abort(
                sessionID: session.id,
                directory: directory,
                workspace: workspace
            )
            try Task.checkCancellation()
            guard generation == lifecycleGeneration, isRunning else { return }
            guard didAbort else {
                errorMessage = "OpenCode did not confirm that the turn was stopped."
                return
            }

            errorMessage = nil
            settleTurnLocally(dismissingUnansweredPrompt: true)
            scheduleMessageRefresh()
        } catch is CancellationError {
            return
        } catch {
            guard generation == lifecycleGeneration, isRunning else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func prepareHistoryForPromptDispatch() async throws {
        guard let boundary = revertMessageID, let featureService else { return }
        let generation = lifecycleGeneration
        let didCommit = try await featureService.commitSessionRevert(sessionID: session.id, directory: directory, workspace: workspace)
        try Task.checkCancellation()
        guard generation == lifecycleGeneration, isRunning else { throw CancellationError() }
        if didCommit { commitHistoryLocally(before: boundary) }
    }

    private func commitHistoryLocally(before boundary: String) {
        if let index = transcript.messages.firstIndex(where: { $0.id == boundary }) {
            transcript.replace(with: Array(transcript.messages.prefix(index)))
        }
        revertMessageID = nil
        revertedUserMessages = []
        featureMutationGeneration &+= 1
        transcriptMutationGeneration &+= 1
        messageRequestGeneration &+= 1
        publishTranscript()
    }

    private func runPromptDispatch(
        _ prompt: OpenCodeQueuedPrompt,
        dispatchID: UUID
    ) async {
        guard isCurrentPromptDispatch(dispatchID), !Task.isCancelled else { return }
        do {
            guard prompt.remoteReferences.allSatisfy({ $0.matches(serverID: serverID,
                projectID: session.projectID, directory: directory, workspaceID: workspace) }) else {
                throw OpenCodeConnectionError.server("File context belongs to a different project. Remove this queued prompt and select the file again.")
            }
            try await prepareHistoryForPromptDispatch()
            try Task.checkCancellation()
            guard isCurrentPromptDispatch(dispatchID) else { return }
            submittedPrompts[prompt.messageID] = prompt
            try await service.sendPrompt(sessionID: session.id, directory: directory,
                                         workspace: workspace, prompt: prompt)
            try Task.checkCancellation()
            guard isCurrentPromptDispatch(dispatchID) else { return }
            let observedServerActivity = promptQueue.hasObservedServerActivity
            statusMutationGeneration &+= 1
            let nextPrompt = promptQueue.dispatchSucceeded()
            publishPromptQueue()
            finishPromptDispatch(dispatchID)
            scheduleMessageRefresh()
            if let nextPrompt {
                schedulePromptDispatch(nextPrompt)
            } else if observedServerActivity == false || isEventConnected == false {
                scheduleQueueRecoveryIfNeeded()
            }
        } catch is CancellationError {
            guard isCurrentPromptDispatch(dispatchID) else { return }
            let serverConfirmedActivity = promptQueue.hasObservedServerActivity
            promptQueue.dispatchFailed(prompt, requeue: true)
            publishPromptQueue()
            finishPromptDispatch(dispatchID)
            if serverConfirmedActivity == false {
                clearOptimisticBusy()
            }
        } catch {
            guard isCurrentPromptDispatch(dispatchID) else { return }
            let serverConfirmedActivity = promptQueue.hasObservedServerActivity
            promptQueue.dispatchFailed(prompt, requeue: true)
            publishPromptQueue()
            finishPromptDispatch(dispatchID)
            if serverConfirmedActivity == false {
                clearOptimisticBusy()
            }
            errorMessage = prompt.command?.kind == .command
                ? "The command may have run before the connection failed. Review the session before choosing Run again. " + error.localizedDescription
                : error.localizedDescription
        }
    }

    func reloadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let providers = try await service.connectedProviderModels(
                directory: directory,
                workspace: workspace
            )
            try Task.checkCancellation()
            providerModels = providers
            let availableModels = providers.flatMap(\.models)
            if let persistedModelID {
                selectedModel = availableModels.first { $0.qualifiedID == persistedModelID }
                // A beta catalog may precede plugin settlement. Preserve this session's
                // saved identity across incomplete snapshots; an explicit choice replaces it.
            } else if let selectedModel,
                      !availableModels.contains(where: { $0.id == selectedModel.id }) {
                self.selectedModel = nil
            }
            // Sessions without their own saved choice inherit the last model
            // picked anywhere on this server. The server default is kept even
            // when the model is temporarily unavailable so a provider outage
            // does not erase it.
            if selectedModel == nil,
               let serverDefaultID = defaults.string(forKey: serverDefaultModelKey) {
                selectedModel = availableModels.first { $0.qualifiedID == serverDefaultID }
            }
            modelErrorMessage = nil
            await reloadComposerCatalog()
            restoreVariant()
        } catch is CancellationError {
            return
        } catch {
            modelErrorMessage = error.localizedDescription
        }
    }

    func selectModel(_ model: OpenCodeModelOption?) {
        selectedModel = model
        persistedModelID = model?.qualifiedID
        if let model {
            defaults.set(model.qualifiedID, forKey: modelSelectionKey)
            defaults.set(model.qualifiedID, forKey: serverDefaultModelKey)
        } else {
            defaults.removeObject(forKey: modelSelectionKey)
            defaults.removeObject(forKey: serverDefaultModelKey)
        }
        restoreVariant()
    }

    func reloadComposerCatalog() async {
        do {
            let catalog = try await service.composerCatalog(sessionID: session.id, directory: directory, workspace: workspace)
            try Task.checkCancellation()
            composerCatalog = catalog
            composerErrorMessage = catalog.unavailableReason
            // Existing sessions keep their actual server choices unless this session has a saved override.
            if persistedModelID == nil, let inherited = catalog.inheritedModelID {
                selectedModel = providerModels.flatMap(\.models).first { $0.qualifiedID == inherited }
            }
            if catalog.unavailableReason == nil, let selectedAgentID,
               !catalog.agents.contains(where: { $0.id == selectedAgentID }) {
                self.selectedAgentID = nil
                defaults.removeObject(forKey: agentSelectionKey)
            }
            if selectedAgentID == nil, defaults.object(forKey: agentSelectionKey) == nil,
               catalog.inheritedAgent == nil, session.agent == nil,
               let preferred = defaults.string(forKey: serverDefaultAgentKey),
               catalog.agents.contains(where: { $0.id == preferred }) { selectedAgentID = preferred }
        } catch is CancellationError { return }
        catch { composerErrorMessage = error.localizedDescription }
    }

    var effectiveAgentID: String? { selectedAgentID ?? composerCatalog.inheritedAgent ?? session.agent }

    var selectedAgentName: String {
        if let selectedAgentID {
            return composerCatalog.agents.first { $0.id == selectedAgentID }?.name ?? selectedAgentID
        }
        let inherited = composerCatalog.inheritedAgent ?? session.agent
        return inherited.map { "Default (\($0))" } ?? "Default agent"
    }

    func selectAgent(_ id: String?) {
        guard id == nil || composerCatalog.agents.contains(where: { $0.id == id }) else { return }
        selectedAgentID = id
        defaults.set(id ?? "", forKey: agentSelectionKey)
        if let id { defaults.set(id, forKey: serverDefaultAgentKey) }
        else { defaults.removeObject(forKey: serverDefaultAgentKey) }
    }

    var availableVariants: [String] { selectedModel?.variants ?? [] }

    var variantLabel: String {
        if let selectedVariant { return selectedVariant }
        return "Default"
    }

    private var variantSelectionKey: String? {
        selectedModel.map { "byot.opencode.variant.\(serverID.uuidString).\(session.id).\($0.qualifiedID)" }
    }

    private var defaultVariantKey: String? {
        selectedModel.map { "byot.opencode.variant.default.\(serverID.uuidString).\($0.qualifiedID)" }
    }

    func selectVariant(_ variant: String?) {
        guard variant == nil || availableVariants.contains(variant!) else { return }
        selectedVariant = variant
        if let key = variantSelectionKey { defaults.set(variant ?? "", forKey: key) }
        if let key = defaultVariantKey { defaults.set(variant ?? "", forKey: key) }
    }

    private func restoreVariant() {
        guard let key = variantSelectionKey else { selectedVariant = nil; return }
        // An empty saved value is an explicit Default, distinct from no preference.
        let preferred: String?
        if let saved = defaults.string(forKey: key) { preferred = saved.trimmedNonEmpty }
        else if selectedModel?.qualifiedID == composerCatalog.inheritedModelID {
            preferred = composerCatalog.inheritedVariant
        } else { preferred = defaultVariantKey.flatMap { defaults.string(forKey: $0)?.trimmedNonEmpty } }
        selectedVariant = preferred.flatMap { availableVariants.contains($0) ? $0 : nil }
    }

    func reply(
        to permission: OpenCodePermissionRequest,
        with reply: OpenCodePermissionReply
    ) async {
        guard actionInFlightID == nil else { return }
        actionInFlightID = permission.presentationID
        defer {
            if actionInFlightID == permission.presentationID { actionInFlightID = nil }
        }
        do {
            try await service.reply(
                to: permission,
                directory: directory,
                workspace: workspace,
                reply: reply
            )
            await refreshPendingActions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func answer(_ question: OpenCodeQuestionRequest, answers: [[String]]) async {
        guard actionInFlightID == nil else { return }
        actionInFlightID = question.presentationID
        defer {
            if actionInFlightID == question.presentationID { actionInFlightID = nil }
        }
        do {
            try await service.answer(
                question,
                directory: directory,
                workspace: workspace,
                answers: answers
            )
            await refreshPendingActions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reject(_ question: OpenCodeQuestionRequest) async {
        guard actionInFlightID == nil else { return }
        actionInFlightID = question.presentationID
        defer {
            if actionInFlightID == question.presentationID { actionInFlightID = nil }
        }
        do {
            try await service.reject(
                question,
                directory: directory,
                workspace: workspace
            )
            await refreshPendingActions()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func connectEvents() {
        guard eventTask == nil else { return }
        let service = service
        let directory = directory
        let workspace = workspace
        eventTask = Task { [weak self] in
            var retryDelay: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                do {
                    for try await event in service.events(
                        directory: directory,
                        workspace: workspace
                    ) {
                        try Task.checkCancellation()
                        guard let store = self else { return }
                        store.isEventConnected = true
                        store.eventErrorMessage = nil
                        retryDelay = 1_000_000_000
                        store.handle(event)
                    }
                    if !Task.isCancelled {
                        self?.isEventConnected = false
                        self?.markTasksStale()
                        self?.eventErrorMessage =
                            "Live updates ended. Reconnecting automatically."
                        self?.scheduleQueueRecoveryIfNeeded()
                    }
                } catch is CancellationError {
                    break
                } catch let error as OpenCodeConnectionError
                    where Self.requiresEventReconciliation(error) {
                    self?.isEventConnected = false
                    self?.markTasksStale()
                    self?.eventErrorMessage = Self.eventReconciliationMessage(for: error)
                    self?.scheduleReconciliation()
                    self?.scheduleQueueRecoveryIfNeeded()
                } catch {
                    self?.isEventConnected = false
                    self?.markTasksStale()
                    self?.eventErrorMessage = Self.eventConnectionMessage(for: error)
                    self?.scheduleQueueRecoveryIfNeeded()
                }
                guard !Task.isCancelled else { break }
                try? await Task.sleep(for: .nanoseconds(Int64(retryDelay)))
                retryDelay = min(retryDelay * 2, 15_000_000_000)
            }
        }
    }

    nonisolated static func eventConnectionMessage(for error: Error) -> String {
        "Live updates disconnected: \(error.localizedDescription) Reconnecting automatically."
    }

    nonisolated static func capture<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> Result<Value, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    nonisolated static func requiresEventReconciliation(
        _ error: OpenCodeConnectionError
    ) -> Bool {
        switch error {
        case .eventBufferOverflow, .eventLineTooLong, .eventRecordTooLarge:
            true
        default:
            false
        }
    }

    nonisolated static func eventReconciliationMessage(
        for error: OpenCodeConnectionError
    ) -> String {
        switch error {
        case .eventBufferOverflow:
            "Live updates fell behind. Reconnecting and reconciling with OpenCode."
        case .eventLineTooLong, .eventRecordTooLarge:
            "Live updates exceeded the safe event size. Reconnecting and reconciling with OpenCode."
        default:
            "Live updates disconnected. Reconnecting and reconciling with OpenCode."
        }
    }

    nonisolated static func mergePermissions(
        legacy: [OpenCodePermissionRequest],
        v2: [OpenCodePermissionRequest],
        sessionID: String
    ) -> [OpenCodePermissionRequest] {
        var seen = Set<String>()
        return (legacy + v2).filter { request in
            request.sessionID == sessionID && seen.insert(request.presentationID).inserted
        }
    }

    nonisolated static func mergeQuestions(
        legacy: [OpenCodeQuestionRequest],
        v2: [OpenCodeQuestionRequest],
        sessionID: String
    ) -> [OpenCodeQuestionRequest] {
        var seen = Set<String>()
        return (legacy + v2).filter { request in
            request.sessionID == sessionID && seen.insert(request.presentationID).inserted
        }
    }

    nonisolated static func recoverActionValues<Value: Sendable>(
        from result: Result<[Value], Error>,
        fallback: [Value]
    ) -> (values: [Value], error: Error?) {
        switch result {
        case .success(let values):
            (values, nil)
        case .failure(let error):
            (fallback, error)
        }
    }

    nonisolated static func isPendingActionEventType(_ type: String) -> Bool {
        switch type {
        case "permission.asked", "permission.replied",
             "permission.v2.asked", "permission.v2.replied",
             "question.asked", "question.replied", "question.rejected",
             "question.v2.asked", "question.v2.replied", "question.v2.rejected",
             "form.created", "form.replied", "form.cancelled":
            true
        default:
            false
        }
    }

    func handle(_ event: OpenCodeEvent) {
        if let eventSessionID = event.sessionID, eventSessionID != session.id {
            return
        }
        if handleSessionFeatureEvent(event) { return }
        if event.isV2 && event.type.hasPrefix("session.") {
            handleV2(event)
            return
        }
        switch event.type {
        case "server.connected":
            scheduleReconciliation()
        case "message.updated", "message.removed", "message.part.updated",
             "message.part.removed", "message.part.delta":
            if transcript.apply(event) {
                transcriptMutationGeneration &+= 1
                publishTranscript()
            } else {
                scheduleMessageRefresh()
            }
        case "session.diff":
            if let value: [OpenCodeDiff] = decode(event.properties["diff"]) {
                diffMutationGeneration &+= 1
                diffs = value
            }
        case "session.status":
            if let value: OpenCodeSessionStatus = decode(event.properties["status"]) {
                statusMutationGeneration &+= 1
                applyEventStatus(value)
            }
        case "session.idle":
            statusMutationGeneration &+= 1
            applyEventStatus(.idle)
            scheduleMessageRefresh()
        case "session.error":
            if let sessionError: OpenCodeMessageError = decode(event.properties["error"]) {
                errorMessage = sessionError.displayMessage
            }
            // OpenCode normally follows session.error with idle, but clients
            // cannot depend on that event arriving. Pause queued work before
            // settling so a failed turn never auto-dispatches its follow-up.
            settleTurnLocally(dismissingUnansweredPrompt: false)
            scheduleMessageRefresh()
        case let type where Self.isPendingActionEventType(type):
            actionMutationGeneration &+= 1
            scheduleActionRefresh()
        default:
            break
        }
    }

    private func handleV2(_ event: OpenCodeEvent) {
        switch event.type {
        case "session.execution.started":
            statusMutationGeneration &+= 1
            applyEventStatus(.busy)
        case "session.execution.succeeded":
            statusMutationGeneration &+= 1
            applyEventStatus(.idle)
            scheduleMessageRefresh()
        case "session.execution.failed", "session.execution.interrupted":
            if event.type == "session.execution.failed" {
                errorMessage = OpenCodeFailure(message: "The turn failed.", details: event.properties["error"]?.objectValue).message
            }
            settleTurnLocally(dismissingUnansweredPrompt: false)
            scheduleMessageRefresh()
        case "session.retry.scheduled":
            statusMutationGeneration &+= 1
            applyEventStatus(.retry(attempt: Int(event.properties["attempt"]?.numberValue ?? 1),
                message: event.properties["error"]?.objectValue?["message"]?.stringValue ?? "Retrying", next: event.properties["at"]?.numberValue ?? 0))
        default:
            if transcript.apply(event) {
                transcriptMutationGeneration &+= 1
                publishTranscript()
            } else {
                // Unrecognized or out-of-order beta events reconcile from projection.
                scheduleMessageRefresh()
            }
        }
    }

    private func publishTranscript() {
        if revertMessageID == nil { revertedUserMessages = [] }
        if let revertMessageID, let boundary = transcript.messages.firstIndex(where: { $0.id == revertMessageID }) {
            messages = Array(transcript.messages.prefix(boundary))
        } else {
            messages = transcript.messages
        }
        updateCurrentTurnActivityTracking()
        updateUnansweredPromptRecovery()
        transcriptRevision &+= 1
    }

    private func applyReconciledStatus(_ value: OpenCodeSessionStatus) {
        status = value
        isStatusReady = true
        didStatusProbeFailWithFreshTranscript = false
        if value.isActive {
            recoveryIdleUserMessageID = nil
            clearUnansweredPromptRecovery()
            promptQueue.serverBecameActive()
            publishPromptQueue()
            if isEventConnected == false {
                scheduleQueueRecoveryIfNeeded()
            }
            return
        }
        finishCurrentTurnActivityTracking()
        recoveryIdleUserMessageID = Self.latestUserMessageID(in: messages)
        if isPerformingSessionAction { promptQueue.pausePendingPrompts() }
        let nextPrompt = promptQueue.reconciledServerIdle()
        publishPromptQueue()
        if let nextPrompt {
            schedulePromptDispatch(nextPrompt)
        }
        updateUnansweredPromptRecovery()
    }

    private func applyEventStatus(_ value: OpenCodeSessionStatus) {
        status = value
        isStatusReady = true
        didStatusProbeFailWithFreshTranscript = false
        if value.isActive {
            recoveryIdleUserMessageID = nil
            clearUnansweredPromptRecovery()
            promptQueue.serverBecameActive()
            publishPromptQueue()
            if isEventConnected {
                cancelQueueRecovery()
            }
            return
        }
        finishCurrentTurnActivityTracking()
        recoveryIdleUserMessageID = Self.latestUserMessageID(in: messages)
        if isPerformingSessionAction { promptQueue.pausePendingPrompts() }
        let nextPrompt = promptQueue.serverBecameIdle()
        publishPromptQueue()
        if let nextPrompt {
            schedulePromptDispatch(nextPrompt)
        } else if promptQueue.needsServerReconciliation == false {
            cancelQueueRecovery()
        }
        updateUnansweredPromptRecovery()
    }

    private func publishPromptQueue() {
        queuedPrompts = promptQueue.prompts
    }

    private func markOptimisticBusy() {
        statusMutationGeneration &+= 1
        status = .busy
        recoveryIdleUserMessageID = nil
        didStatusProbeFailWithFreshTranscript = false
        clearUnansweredPromptRecovery()
    }

    private func clearOptimisticBusy() {
        statusMutationGeneration &+= 1
        status = .idle
        recoveryIdleUserMessageID = nil
        finishCurrentTurnActivityTracking()
        updateUnansweredPromptRecovery()
    }

    private var hasUnansweredLatestUserMessageWithoutAssistantEnvelope: Bool {
        guard let messageID = Self.latestUserMessageIDWithoutAssistantEnvelope(in: messages)
        else { return false }
        return messageID != dismissedUnansweredMessageID
    }

    private func settleTurnLocally(dismissingUnansweredPrompt: Bool) {
        if dismissingUnansweredPrompt {
            dismissUnansweredPromptRecovery()
        }
        promptQueue.pausePendingPrompts()
        let dispatchTask = invalidatePromptDispatch()
        cancelQueueRecovery()
        reconciliationTask?.cancel()
        reconciliationTask = nil
        statusMutationGeneration &+= 1
        status = .idle
        isStatusReady = true
        didStatusProbeFailWithFreshTranscript = false
        recoveryIdleUserMessageID = Self.latestUserMessageID(in: messages)
        finishCurrentTurnActivityTracking()
        dispatchTask?.cancel()
        publishPromptQueue()
        updateUnansweredPromptRecovery()
    }

    private func updateUnansweredPromptRecovery() {
        guard isRunning,
              isStatusReady,
              status.isActive == false,
              isSending == false,
              let prompt = recoverablePrompt(in: messages),
              prompt.messageID == recoveryIdleUserMessageID,
              prompt.messageID != dismissedUnansweredMessageID
        else {
            clearUnansweredPromptRecovery()
            return
        }
        recoverableUnansweredPrompt = prompt
        hasRecoverableUnansweredPrompt = true
    }

    private func dismissUnansweredPromptRecovery() {
        if let messageID = recoverableUnansweredPrompt?.messageID
            ?? recoverablePrompt(in: messages)?.messageID {
            dismissedUnansweredMessageID = messageID
        }
        clearUnansweredPromptRecovery()
    }

    private func clearUnansweredPromptRecovery() {
        recoverableUnansweredPrompt = nil
        hasRecoverableUnansweredPrompt = false
    }

    private func recoverablePrompt(
        in messages: [OpenCodeMessageEnvelope]
    ) -> OpenCodeRecoverablePrompt? {
        guard let latestUserIndex = messages.lastIndex(where: { message in
            message.info.role.lowercased() == "user"
        }) else { return nil }

        let messagesAfterUser = messages.suffix(
            from: messages.index(after: latestUserIndex)
        )
        let hasAssistantEnvelope = messagesAfterUser.contains { message in
            message.info.role.lowercased() == "assistant"
        }
        guard hasAssistantEnvelope == false else { return nil }

        let userMessage = messages[latestUserIndex]
        let fileParts = userMessage.parts.filter { $0.type.lowercased() == "file" }
        let remoteReferences = OpenCodePromptFileReference.restored(from: userMessage, serverID: serverID,
            projectID: session.projectID, directory: directory, workspaceID: workspace)
        let remoteParts = fileParts.filter { $0.url?.hasPrefix("file:") == true }
        guard remoteParts.count == remoteReferences.count else { return nil }
        var attachments: [OpenCodePromptAttachment] = []
        for part in fileParts where part.url?.hasPrefix("file:") != true {
            guard let filename = part.filename,
                  let mimeType = part.mime,
                  let dataURL = part.url,
                  let data = Self.decodeBase64DataURL(dataURL, mimeType: mimeType)
            else { return nil }
            attachments.append(
                OpenCodePromptAttachment(
                    filename: filename,
                    mimeType: mimeType,
                    data: data
                )
            )
        }
        guard (try? OpenCodePromptAttachment.validate(attachments)) != nil
        else { return nil }
        let text = userMessage.parts
            .filter { $0.type.lowercased() == "text" }
            .compactMap(\.text)
            .joined(separator: "\n\n")
        guard text.trimmedNonEmpty != nil || !attachments.isEmpty || !remoteReferences.isEmpty else { return nil }
        let original = submittedPrompts[userMessage.id]
        let restoredModel = providerModels.flatMap(\.models).first {
            $0.providerID == userMessage.info.providerID && $0.modelID == userMessage.info.modelID
        }
        return OpenCodeRecoverablePrompt(
            messageID: userMessage.id,
            text: text,
            attachments: attachments,
            model: original != nil ? original?.model : restoredModel,
            agent: original != nil ? original?.agent : userMessage.info.agent,
            variant: original != nil ? original?.variant : userMessage.info.variant,
            command: original?.command,
            remoteReferences: original?.remoteReferences ?? remoteReferences
        )
    }

    private static func decodeBase64DataURL(
        _ dataURL: String,
        mimeType: String
    ) -> Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let header = dataURL[..<comma].lowercased()
        guard header == "data:\(mimeType.lowercased());base64" else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }

    private static func latestUserMessageID(
        in messages: [OpenCodeMessageEnvelope]
    ) -> String? {
        messages.last { $0.info.role.lowercased() == "user" }?.id
    }

    private static func latestUserMessageIDWithoutAssistantEnvelope(
        in messages: [OpenCodeMessageEnvelope]
    ) -> String? {
        guard let latestUserIndex = messages.lastIndex(where: { message in
            message.info.role.lowercased() == "user"
        }) else { return nil }
        let hasAssistantEnvelope = messages.suffix(
            from: messages.index(after: latestUserIndex)
        ).contains { message in
            message.info.role.lowercased() == "assistant"
        }
        return hasAssistantEnvelope ? nil : messages[latestUserIndex].id
    }

    var hasVisibleAssistantActivityAfterLatestUserMessage: Bool {
        Self.hasVisibleAssistantActivityAfterLatestUserMessage(in: messages)
    }

    static func hasVisibleAssistantActivityAfterLatestUserMessage(
        in messages: [OpenCodeMessageEnvelope]
    ) -> Bool {
        guard let latestUserIndex = messages.lastIndex(where: { message in
            message.info.role.lowercased() == "user"
        }) else { return false }

        return messages.suffix(from: messages.index(after: latestUserIndex)).contains { message in
            message.info.role.lowercased() == "assistant"
                && visibleAssistantActivityIDs(in: message).isEmpty == false
        }
    }

    private func beginCurrentTurnActivityTracking() {
        currentTurnActivityBaseline = Self.visibleAssistantActivityIDs(in: messages)
        isAwaitingFirstVisibleOutput = true
    }

    private func updateCurrentTurnActivityTracking() {
        guard isAwaitingFirstVisibleOutput,
              let currentTurnActivityBaseline
        else { return }
        let currentActivity = Self.visibleAssistantActivityIDs(in: messages)
        if currentActivity.subtracting(currentTurnActivityBaseline).isEmpty == false {
            isAwaitingFirstVisibleOutput = false
        }
    }

    private func finishCurrentTurnActivityTracking() {
        currentTurnActivityBaseline = nil
        isAwaitingFirstVisibleOutput = false
    }

    static func visibleAssistantActivityIDs(
        in messages: [OpenCodeMessageEnvelope]
    ) -> Set<String> {
        Set<String>(messages.flatMap { message -> [String] in
            guard message.info.role.lowercased() == "assistant" else { return [] }
            return visibleAssistantActivityIDs(in: message)
        })
    }

    private static func visibleAssistantActivityIDs(
        in message: OpenCodeMessageEnvelope
    ) -> [String] {
        message.parts.compactMap { part in
            let isVisible: Bool
            switch part.type.lowercased() {
            case "text", "reasoning":
                isVisible = part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            case "tool":
                isVisible = part.state != nil
            default:
                isVisible = false
            }
            return isVisible ? "\(message.id):\(part.id)" : nil
        }
    }

    private func schedulePromptDispatch(_ prompt: OpenCodeQueuedPrompt) {
        guard isRunning, promptDispatchTask == nil else {
            promptQueue.dispatchFailed(prompt, requeue: true)
            publishPromptQueue()
            return
        }
        cancelQueueRecovery()
        errorMessage = nil
        recoveryIdleUserMessageID = nil
        didStatusProbeFailWithFreshTranscript = false
        beginCurrentTurnActivityTracking()
        markOptimisticBusy()
        isSending = true
        let dispatchID = UUID()
        promptDispatchID = dispatchID
        inFlightPrompt = prompt
        promptDispatchTask = Task { [weak self] in
            await self?.runPromptDispatch(prompt, dispatchID: dispatchID)
        }
    }

    private func isCurrentPromptDispatch(_ id: UUID) -> Bool {
        isRunning && promptDispatchID == id
    }

    private func finishPromptDispatch(_ id: UUID) {
        guard promptDispatchID == id else { return }
        promptDispatchTask = nil
        promptDispatchID = nil
        inFlightPrompt = nil
        isSending = false
    }

    private func invalidatePromptDispatch() -> Task<Void, Never>? {
        let task = promptDispatchTask
        promptDispatchID = nil
        promptDispatchTask = nil
        inFlightPrompt = nil
        isSending = false
        return task
    }

    private func scheduleQueueRecoveryIfNeeded() {
        guard isRunning,
              promptQueue.needsServerReconciliation,
              queueRecoveryTask == nil
        else { return }
        let recoveryID = UUID()
        queueRecoveryID = recoveryID
        queueRecoveryTask = Task { [weak self] in
            await self?.runQueueRecovery(recoveryID: recoveryID)
        }
    }

    private func runQueueRecovery(recoveryID: UUID) async {
        defer { finishQueueRecovery(recoveryID) }
        var delay = Duration.seconds(2)
        while isCurrentQueueRecovery(recoveryID),
              promptQueue.needsServerReconciliation {
            do {
                try await Task.sleep(for: delay)
                guard isCurrentQueueRecovery(recoveryID),
                      promptQueue.needsServerReconciliation
                else { return }
                let baseline = statusMutationGeneration
                let statuses = try await service.sessionStatuses(
                    directory: directory,
                    workspace: workspace
                )
                try Task.checkCancellation()
                guard isCurrentQueueRecovery(recoveryID),
                      baseline == statusMutationGeneration
                else { continue }
                let reconciledStatus = statuses[session.id] ?? .idle
                statusMutationGeneration &+= 1
                status = reconciledStatus
                isStatusReady = true
                didStatusProbeFailWithFreshTranscript = false
                if reconciledStatus.isActive {
                    recoveryIdleUserMessageID = nil
                    clearUnansweredPromptRecovery()
                    promptQueue.serverBecameActive()
                    publishPromptQueue()
                } else if promptQueue.isAwaitingActivity {
                    let hadQueuedFollowUps = promptQueue.prompts.isEmpty == false
                    promptQueue.pauseAwaitingActivity()
                    publishPromptQueue()
                    if hadQueuedFollowUps {
                        errorMessage =
                            "Live session activity could not be confirmed. Your queued message is paused to avoid sending it twice."
                    }
                    await refreshMessages()
                    guard isCurrentQueueRecovery(recoveryID), status.isActive == false
                    else { return }
                    recoveryIdleUserMessageID = Self.latestUserMessageID(in: messages)
                    updateUnansweredPromptRecovery()
                    return
                } else {
                    recoveryIdleUserMessageID = Self.latestUserMessageID(in: messages)
                    if isPerformingSessionAction { promptQueue.pausePendingPrompts() }
                    let nextPrompt = promptQueue.reconciledServerIdle()
                    publishPromptQueue()
                    if let nextPrompt {
                        finishQueueRecovery(recoveryID)
                        schedulePromptDispatch(nextPrompt)
                        return
                    }
                    updateUnansweredPromptRecovery()
                }
                delay = min(delay * 2, .seconds(15))
            } catch is CancellationError {
                return
            } catch {
                guard isCurrentQueueRecovery(recoveryID) else { return }
                eventErrorMessage =
                    "Queued message is waiting for session status: \(error.localizedDescription)"
                delay = min(delay * 2, .seconds(15))
            }
        }
    }

    private func isCurrentQueueRecovery(_ id: UUID) -> Bool {
        isRunning && queueRecoveryID == id
    }

    private func finishQueueRecovery(_ id: UUID) {
        guard queueRecoveryID == id else { return }
        queueRecoveryTask = nil
        queueRecoveryID = nil
    }

    private func cancelQueueRecovery() {
        queueRecoveryTask?.cancel()
        queueRecoveryTask = nil
        queueRecoveryID = nil
    }

    private func refreshMessages() async {
        messageRequestGeneration &+= 1
        let requestGeneration = messageRequestGeneration
        let mutationBaseline = transcriptMutationGeneration
        do {
            let messages = try await service.messages(
                sessionID: session.id,
                directory: directory,
                workspace: workspace
            )
            guard requestGeneration == messageRequestGeneration,
                  mutationBaseline == transcriptMutationGeneration
            else { return }
            transcript.replace(with: messages)
            publishTranscript()
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == messageRequestGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func refreshPendingActions() async {
        actionRequestGeneration &+= 1
        let requestGeneration = actionRequestGeneration
        let mutationBaseline = actionMutationGeneration
        do {
            let actionClient = service
            let actionDirectory = directory
            let actionWorkspace = workspace
            let actionSessionID = session.id
            async let permissionResult = Self.capture {
                try await actionClient.permissions(
                    directory: actionDirectory,
                    workspace: actionWorkspace
                )
            }
            async let v2PermissionResult = Self.capture {
                try await actionClient.v2Permissions(sessionID: actionSessionID)
            }
            async let questionResult = Self.capture {
                try await actionClient.questions(
                    directory: actionDirectory,
                    workspace: actionWorkspace
                )
            }
            async let v2QuestionResult = Self.capture {
                try await actionClient.v2Questions(sessionID: actionSessionID)
            }
            let results = await (
                permissionResult,
                v2PermissionResult,
                questionResult,
                v2QuestionResult
            )
            try Task.checkCancellation()
            guard requestGeneration == actionRequestGeneration,
                  mutationBaseline == actionMutationGeneration
            else { return }
            applyPendingActionResults(
                permissionResult: results.0,
                v2PermissionResult: results.1,
                questionResult: results.2,
                v2QuestionResult: results.3
            )
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == actionRequestGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func applyPendingActionResults(
        permissionResult: Result<[OpenCodePermissionRequest], Error>,
        v2PermissionResult: Result<[OpenCodePermissionRequest], Error>,
        questionResult: Result<[OpenCodeQuestionRequest], Error>,
        v2QuestionResult: Result<[OpenCodeQuestionRequest], Error>
    ) {
        var errors: [Error] = []
        let legacyPermissionOutcome = Self.recoverActionValues(
            from: permissionResult,
            fallback: permissions.filter { $0.resolvedAPIVersion == .legacy }
        )
        let v2PermissionOutcome = Self.recoverActionValues(
            from: v2PermissionResult,
            fallback: permissions.filter { $0.resolvedAPIVersion == .v2 }
        )
        let legacyQuestionOutcome = Self.recoverActionValues(
            from: questionResult,
            fallback: questions.filter { $0.resolvedAPIVersion == .legacy }
        )
        let v2QuestionOutcome = Self.recoverActionValues(
            from: v2QuestionResult,
            fallback: questions.filter { $0.resolvedAPIVersion == .v2 }
        )
        errors.append(contentsOf: [
            legacyPermissionOutcome.error,
            v2PermissionOutcome.error,
            legacyQuestionOutcome.error,
            v2QuestionOutcome.error,
        ].compactMap { $0 })
        permissions = Self.mergePermissions(
            legacy: legacyPermissionOutcome.values,
            v2: v2PermissionOutcome.values,
            sessionID: session.id
        )
        questions = Self.mergeQuestions(
            legacy: legacyQuestionOutcome.values,
            v2: v2QuestionOutcome.values,
            sessionID: session.id
        )
        if let firstError = errors.first {
            actionErrorMessage =
                "Some OpenCode actions could not be refreshed: \(firstError.localizedDescription)"
        } else {
            actionErrorMessage = nil
        }
    }

    private func scheduleReconciliation() {
        guard reconciliationTask == nil else { return }
        reconciliationTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let store = self else { return }
            await store.refresh()
            store.reconciliationTask = nil
        }
    }

    private func scheduleMessageRefresh() {
        messageRefreshPending = true
        guard messageRefreshTask == nil else { return }
        messageRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let store = self else { return }
                store.messageRefreshPending = false
                await store.refreshMessages()
                if !store.messageRefreshPending {
                    store.messageRefreshTask = nil
                    return
                }
            }
        }
    }

    private func scheduleActionRefresh() {
        actionRefreshPending = true
        guard actionRefreshTask == nil else { return }
        actionRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let store = self else { return }
                store.actionRefreshPending = false
                await store.refreshPendingActions()
                if !store.actionRefreshPending {
                    store.actionRefreshTask = nil
                    return
                }
            }
        }
    }

    private func decode<Value: Decodable>(_ value: OpenCodeJSONValue?) -> Value? {
        guard let value,
              let data = try? JSONEncoder().encode(value)
        else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

#if DEBUG
    func prepareForAttachmentScreenshot() {
        isRunning = true
        isStatusReady = true
        status = .idle
        errorMessage = nil
    }
#endif
}
