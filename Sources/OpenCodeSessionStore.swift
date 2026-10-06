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
    @Published private(set) var status: OpenCodeSessionStatus = .idle {
        didSet { recordTurnCompletionIfNeeded(from: oldValue) }
    }
    @Published private(set) var isStatusReady = false
    @Published private(set) var isLoading = false
    /// Message loading ends independently of slower status, permission and feature requests.
    /// Start true so the first frame does not flash an empty conversation.
    @Published private(set) var isLoadingTranscript = true
    @Published private(set) var isSending = false
    @Published private(set) var isEventConnected = false
    @Published private(set) var eventErrorMessage: String?
    @Published private(set) var actionErrorMessage: String?
    @Published private(set) var actionInFlightID: String?
    @Published private(set) var transcriptRevision = 0
    @Published private(set) var providerModels: [OpenCodeProviderModels] = [] {
        didSet {
            catalogModels = providerModels.flatMap(\.models)
            modelContextLimits = Dictionary(
                catalogModels.compactMap { model in model.contextLimit.map { (model.qualifiedID, $0) } },
                uniquingKeysWith: { first, _ in first })
            updateUsage()
        }
    }
    /// Context and spend, recomputed as the transcript and model catalog change.
    @Published private(set) var usage = OpenCodeSessionUsage()
    /// Context windows by `provider/model`, for per-step context shares.
    private(set) var modelContextLimits: [String: Int] = [:]
    private var catalogModels: [OpenCodeModelOption] = []
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
    /// The turn byot asked for most recently, for the anonymous
    /// `turn_completed` event. Turns started elsewhere are not reported.
    private var telemetryTurn: BYOTTelemetryTurn?
    /// What byot asks for after this turn finished well, if anything.
    @Published private(set) var nudge: BYOTNudgeAsk?
    private let nudgeGate: BYOTNudgeGate
    @Published var errorMessage: String?

    @Published private(set) var session: OpenCodeSession
    @Published private(set) var sessionFeatures = OpenCodeSessionFeatureSupport()
    @Published private(set) var todoProgress = OpenCodeTodoProgress()
    @Published private(set) var revertMessageID: String?
    @Published private(set) var restoredPrompt: OpenCodeRestoredPrompt?
    @Published private(set) var forkedSession: OpenCodeSession?
    @Published private(set) var childSessions: [OpenCodeSession] = []
    @Published private(set) var parentSession: OpenCodeSession?
    /// Children of this session's parent, including this one, when this is a
    /// subagent session.
    @Published private(set) var siblingSessions: [OpenCodeSession] = []
    /// Live status of the subagent sessions this conversation started.
    @Published private(set) var subagents = OpenCodeSubagentTracker()
    @Published private(set) var openingSubagentID: String?
    @Published private(set) var sessionDetailsError: String?
    @Published private(set) var isPerformingSessionAction = false
    @Published private(set) var isLoadingRelatedSessions = false
    @Published private(set) var didDeleteSession = false
    /// The latest `vcs.branch.updated` event; `nil` until the server reports a switch.
    @Published private(set) var reportedBranch: OpenCodeReportedBranch?
    /// Set while `messages` shows the transcript saved on this device, before the
    /// server's transcript arrives.
    @Published private(set) var offlineTranscript: OpenCodeOfflineTranscriptInfo?
    /// The shell command sent from this device, until the transcript shows it.
    @Published private(set) var localShell: OpenCodeLocalShell?
    /// A command OpenCode did not run, for the composer to take back.
    @Published private(set) var restoredShellCommand: String?
    @Published private(set) var didLoadSessionFeatures = false
    /// The server's `share` config; nil until read, and after a failed read.
    @Published private(set) var sharePolicy: OpenCodeSessionSharePolicy?
    @Published private(set) var isUpdatingShare = false
    @Published private(set) var shareErrorMessage: String?
    private let featureService: (any OpenCodeSessionFeatureServicing)?
    private let shellService: (any OpenCodeShellServicing)?
    private var shellTask: Task<Void, Never>?
    private var featureRefreshGeneration = 0
    private var featureMutationGeneration = 0
    private var todoMutationGeneration = 0
    private var revertedUserMessages: [OpenCodeMessageEnvelope] = []
    // The server's active context and the newest message when it was read;
    // a transcript that has moved on makes it stale.
    private var serverContextWindow: (anchor: String?, messages: [OpenCodeMessageEnvelope])?
    let directory: String
    let remoteFiles: OpenCodeRemoteFileStore?
    let serverID: UUID
    private let workspace: String?
    let durableQueue: BYOTDurableQueue?
    private let offlineCache: OpenCodeOfflineCacheScope?
    private var cachedMessages: [OpenCodeMessageEnvelope]?
    /// The reducer holds a transcript loaded from the server, not only streamed parts.
    private var hasServerTranscript = false
    private var savedMessages: [OpenCodeMessageEnvelope]?
    private var offlineRestoreTask: Task<Void, Never>?
    private var offlineSaveTask: Task<Void, Never>?
    private var offlineSavePendingSince: ContinuousClock.Instant?
    private var queueObservation: AnyCancellable?
    private let service: any OpenCodeSessionServicing
    private let defaults: UserDefaults
    private let modelSelectionKey: String
    private let serverDefaultModelKey: String
    private let agentSelectionKey: String
    private let serverDefaultAgentKey: String
    /// False while `selectedAgentID` only carries the server-wide preference
    /// seeded for a session without its own pick; the session's own agent
    /// history then outranks it.
    private var isAgentSelectionExplicit: Bool
    /// The completed `plan_exit` call this store already followed.
    private var followedPlanExitPartID: String?
    private var submittedPrompts: [String: OpenCodeQueuedPrompt] = [:]
    private var persistedModelID: String?
    private var transcript = OpenCodeTranscriptReducer()
    private var promptQueue = OpenCodePromptQueue()
    private var eventTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var messageRefreshTask: Task<Void, Never>?
    private var turnSettlementTask: Task<Void, Never>?
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
        offlineCache: OpenCodeOfflineCacheScope? = nil,
        remoteFiles: OpenCodeRemoteFileStore? = nil,
        durableQueue: BYOTDurableQueue? = nil
    ) {
        self.durableQueue = durableQueue
        self.offlineCache = offlineCache
        self.service = service
        self.serverID = serverID
        featureService = service as? any OpenCodeSessionFeatureServicing
        shellService = service as? any OpenCodeShellServicing
        self.session = session
        self.directory = directory
        self.defaults = defaults
        self.remoteFiles = remoteFiles
        nudgeGate = BYOTNudgeGate(defaults: defaults)
        modelSelectionKey = "byot.opencode.model.\(serverID.uuidString).\(session.id)"
        serverDefaultModelKey = Self.serverDefaultModelKey(serverID)
        persistedModelID = defaults.string(forKey: modelSelectionKey)
        workspace = session.workspaceID
        agentSelectionKey = "byot.opencode.agent.\(serverID.uuidString).\(session.id)"
        serverDefaultAgentKey = Self.serverDefaultAgentKey(serverID)
        let savedAgentID = defaults.string(forKey: agentSelectionKey)?.trimmedNonEmpty
        selectedAgentID = savedAgentID
        isAgentSelectionExplicit = savedAgentID != nil
        queueObservation = durableQueue?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    deinit {
        eventTask?.cancel()
        reconciliationTask?.cancel()
        messageRefreshTask?.cancel()
        turnSettlementTask?.cancel()
        actionRefreshTask?.cancel()
        modelTask?.cancel()
        promptDispatchTask?.cancel()
        queueRecoveryTask?.cancel()
        offlineRestoreTask?.cancel()
        offlineSaveTask?.cancel()
        shellTask?.cancel()
    }

    var pendingActionCount: Int {
        permissions.count + questions.count
    }

    var willQueueNextPrompt: Bool {
        if durableQueue?.enabled == true { return true }
        if revertMessageID != nil, !status.isActive, !isSending, !isShellSending { return false }
        return status.isActive || isSending || isShellSending || promptQueue.shouldQueueNextPrompt
    }

    var isShellSending: Bool { localShell?.isSending == true }

    /// Hidden, not an error, when the server lacks a shell operation.
    var supportsShell: Bool { shellService != nil && sessionFeatures.shell }

    /// False until the server's session features load, so a draft saved in
    /// shell mode can wait for them instead of being read as a message.
    var isShellSupportKnown: Bool { shellService == nil || featureService == nil || didLoadSessionFeatures }

    /// Why shell mode can't run a command right now. The command stays in the
    /// composer; shell runs are never queued behind a turn, as in OpenCode.
    var shellUnavailableReason: String? {
        guard supportsShell else { return OpenCodeShellError.unsupported.localizedDescription }
        if !canSubmitPrompt { return String(localized: "Wait for the session to connect.") }
        if isShellSending { return String(localized: "Wait for the current command to finish.") }
        if status.isActive || isSending || promptQueue.isTurnActive {
            return String(localized: "Shell commands run while OpenCode is idle. Stop the turn or wait for it to finish.")
        }
        return nil
    }

    var canSubmitPrompt: Bool {
        isRunning && (isStatusReady || durableQueue?.enabled == true) && isStoppingTurn == false && !isPerformingSessionAction && !didDeleteSession
    }

    /// Why a message can't be sent right now, for the dimmed send button.
    var promptUnavailableReason: String? {
        guard !canSubmitPrompt else { return nil }
        if isRunning, isStoppingTurn || isPerformingSessionAction {
            return String(localized: "Wait for the current request to finish.")
        }
        return String(localized: "Wait for the session to connect.")
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
                part.type != "tool" && (part.synthetic == true || part.text?.trimmedNonEmpty == nil)
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
        durableQueue?.start()
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isRunning = true
        isStatusReady = false
        didStatusProbeFailWithFreshTranscript = false
        recoveryIdleUserMessageID = nil
        restoreOfflineTranscript()
        connectEvents()
        modelTask?.cancel()
        modelTask = Task { [weak self] in
            await self?.reloadModels()
        }
        await refresh(showLoading: true)
        if generation == lifecycleGeneration, isRunning,
           session.parentID != nil || OpenCodeSubagentTask.containsTask(in: transcript.messages) {
            await loadRelatedSessions()
        }
        if Task.isCancelled, generation == lifecycleGeneration { stop() }
    }

    func refreshAfterForeground() {
        guard isRunning else { return }
        // Reconcile missed events without interrupting an in-flight submission.
        scheduleReconciliation()
    }

    func stop() {
        durableQueue?.stop()
        offlineRestoreTask?.cancel()
        offlineRestoreTask = nil
        saveOfflineTranscriptNow()
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
        isLoading = false
        isLoadingTranscript = false
        eventTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        messageRefreshTask?.cancel()
        messageRefreshTask = nil
        cancelTurnSettlement()
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
        // Leaving does not stop a server-side command; reopening shows its record.
        shellTask?.cancel()
        shellTask = nil
        localShell = nil
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
        if showLoading {
            isLoading = true
            // A background reconciliation must not bring the loader back
            // over a session that has no messages yet.
            isLoadingTranscript = true
        }
        defer {
            if generation == refreshGeneration {
                isLoading = false
                isLoadingTranscript = false
            }
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

            // Render the transcript as soon as it arrives. A slow auxiliary
            // endpoint must not hold already downloaded messages behind a loader.
            let loadedMessages = await messageResult
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }

            var coreErrors: [Error] = []
            var didApplyFreshMessages = false
            switch loadedMessages {
            case .success(let messages):
                if messageGeneration == messageRequestGeneration,
                   transcriptBaseline == transcriptMutationGeneration {
                    transcript.replace(with: messages)
                    didLoadServerTranscript()
                    publishTranscript()
                    didApplyFreshMessages = true
                }
            case .failure(let error):
                if messageGeneration == messageRequestGeneration {
                    coreErrors.append(error)
                    errorMessage = error.localizedDescription
                }
            }
            isLoadingTranscript = false

            let results = await (
                permissionResult,
                v2PermissionResult,
                questionResult,
                v2QuestionResult,
                diffResult,
                statusResult
            )
            try Task.checkCancellation()
            guard generation == refreshGeneration else { return }
            switch results.4 {
            case .success(let diffs):
                if OpenCodeSessionDiffReconciliation.shouldApplyFetchedSnapshot(support: protocolCapabilities?.sessionDiff, mutationBaseline: diffBaseline, currentMutation: diffMutationGeneration) { self.diffs = diffs }
            case .failure(let error):
                coreErrors.append(error)
            }
            switch results.5 {
            case .success(let statuses):
                if statusBaseline == statusMutationGeneration {
                    didStatusProbeFailWithFreshTranscript = false
                    applyReconciledStatus(statuses[session.id] ?? .idle)
                }
                applySubagentStatuses(statuses)
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
                    permissionResult: results.0,
                    v2PermissionResult: results.1,
                    questionResult: results.2,
                    v2QuestionResult: results.3
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            errorMessage = error.localizedDescription
            isLoadingTranscript = false
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
            didLoadSessionFeatures = true
            let sessionID = session.id, directory = directory, workspace = workspace
            async let detailsResult = Self.capture { () -> OpenCodeSessionDetails? in
                guard support.details else { return nil }
                return try await featureService.sessionDetails(sessionID: sessionID, directory: directory, workspace: workspace)
            }
            async let todosResult = Self.capture {
                try await featureService.sessionTodos(sessionID: sessionID, directory: directory, workspace: workspace)
            }
            // Config rarely changes, so read it once; a failed read leaves
            // publishing offered and is retried on the next refresh.
            let needsSharePolicy = support.share && sharePolicy == nil
            async let sharePolicyResult = Self.capture { () -> OpenCodeSessionSharePolicy? in
                guard needsSharePolicy else { return nil }
                return try await featureService.sessionSharePolicy(directory: directory, workspace: workspace)
            }
            let (details, todos, policy) = await (detailsResult, todosResult, sharePolicyResult)
            try Task.checkCancellation()
            guard generation == featureRefreshGeneration else { return }
            if case .success(let policy?) = policy { sharePolicy = policy }
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
        // Current v2 servers publish revert events as session.next.revert.*.
        let type = OpenCodeV2EventReducer.canonicalType(event.type)
        if event.type == "todo.updated", event.sessionID == session.id {
            if let todos: [OpenCodeTodo] = decode(event.properties["todos"]) {
                todoMutationGeneration &+= 1
                todoProgress = OpenCodeTodoProgress(items: todos)
            }
            return true
        }
        if type == "session.revert.staged", event.sessionID == session.id {
            featureMutationGeneration &+= 1
            revertMessageID = event.properties["revert"]?.objectValue?["messageID"]?.stringValue
            promptQueue.pausePendingPrompts()
            publishPromptQueue()
            publishTranscript()
            return true
        }
        if type == "session.revert.committed", event.sessionID == session.id {
            if let boundary = event.properties["to"]?.stringValue ?? event.properties["messageID"]?.stringValue ?? revertMessageID {
                commitHistoryLocally(before: boundary)
            }
            scheduleReconciliation()
            return true
        }
        if type == "session.revert.cleared", event.sessionID == session.id {
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
        // Another client (TUI, web, `plan_exit`) switched this v2 session's agent.
        if event.type == "session.agent.switched" || event.type == "session.next.agent.switched",
           event.sessionID == session.id, let agent = event.properties["agent"]?.stringValue {
            composerCatalog.inheritedAgent = agent
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
        if !supported { return String(localized: "This server does not support this action.") }
        if !isRunning || !isStatusReady { return String(localized: "Wait for the session to connect.") }
        if isPerformingSessionAction || isSending || isStoppingTurn { return String(localized: "Wait for the current request to finish.") }
        if status.isActive || durableQueue?.pending.contains(where: { ["claimed", "submitted"].contains($0.state) }) == true { return String(localized: "Stop the current turn before changing its history.") }
        if action == .undo && !messages.contains(where: { $0.info.role == "user" }) { return String(localized: "No turn to undo.") }
        if action == .redo && revertMessageID == nil { return String(localized: "No undone turn to restore.") }
        if action == .compact && sessionFeatures.compactRequiresModel && selectedModel == nil { return String(localized: "Choose a model before compacting.") }
        if action == .compact && revertMessageID != nil { return String(localized: "Redo or send your revised prompt before compacting.") }
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
            if let queue = durableQueue, queue.enabled {
                try await queue.setPaused(true)
                try await queue.refresh()
                guard !queue.pending.contains(where: { ["claimed", "submitted"].contains($0.state) }) else {
                    throw BYOTQueueError.message(String(localized: "A queued message has started. Stop that turn before changing session history."))
                }
            }
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
        let sessionID = session.id, directory = directory, workspace = workspace
        var errors: [Error] = []
        if sessionFeatures.children {
            do {
                childSessions = OpenCodeSubagentFamily.ordered(
                    try await featureService.childSessions(sessionID: sessionID, directory: directory, workspace: workspace))
                trackSubagents(childSessions.map(\.id))
            } catch { errors.append(error) }
        }
        if let parentID = session.parentID ?? session.forkSourceID, sessionFeatures.details {
            do {
                parentSession = try await featureService.sessionDetails(sessionID: parentID, directory: directory, workspace: workspace).session
            } catch { errors.append(error) }
        }
        // A subagent steps between its siblings: the parent's other children.
        if let parentID = session.parentID, sessionFeatures.children {
            do {
                siblingSessions = try await featureService.childSessions(sessionID: parentID, directory: directory, workspace: workspace)
            } catch { errors.append(error) }
        }
        sessionDetailsError = errors.first?.localizedDescription
        // Children found here may have started before this screen opened.
        if !subagents.activity.isEmpty,
           let statuses = try? await service.sessionStatuses(directory: directory, workspace: workspace) {
            applySubagentStatuses(statuses)
        }
    }

    /// The session behind a subagent link: a known relative, or the server's
    /// record of it. nil, with an explanation, when neither is available.
    func relatedSession(_ sessionID: String) async -> OpenCodeSession? {
        let known = childSessions + siblingSessions + [parentSession].compactMap { $0 }
        if let session = known.first(where: { $0.id == sessionID }) { return session }
        guard let featureService, sessionFeatures.details else {
            actionErrorMessage = String(localized: "This server can’t open subagent sessions.")
            return nil
        }
        guard openingSubagentID == nil else { return nil }
        openingSubagentID = sessionID
        defer { openingSubagentID = nil }
        do {
            return try await featureService.sessionDetails(sessionID: sessionID, directory: directory, workspace: workspace).session
        } catch is CancellationError {
            return nil
        } catch {
            actionErrorMessage = String(localized: "Couldn’t open the subagent session: \(error.localizedDescription)")
            return nil
        }
    }

    /// This session among its siblings, when it is a subagent.
    var subagentFamily: OpenCodeSubagentFamily? {
        OpenCodeSubagentFamily(session: session, parent: parentSession, siblings: siblingSessions)
    }

    private func trackSubagents<IDs: Sequence>(_ ids: IDs) where IDs.Element == String {
        let new = ids.filter { !subagents.isTracking($0) }
        guard !new.isEmpty else { return }
        subagents.track(new)
    }

    private func applySubagentStatuses(_ statuses: [String: OpenCodeSessionStatus]) {
        var next = subagents
        next.applyStatuses(statuses)
        if next != subagents { subagents = next }
    }

    /// Events about other sessions: this one's subagents, its siblings, and
    /// its parent. Returns true when the event belongs to another session.
    private func handleRelatedSessionEvent(_ event: OpenCodeEvent) -> Bool {
        if ["session.created", "session.updated", "session.deleted"].contains(event.type),
           let info: OpenCodeSession = decode(event.properties["info"]) {
            guard info.id != session.id else { return false }
            applyRelatedSession(info, removed: event.type == "session.deleted")
            return true
        }
        let properties = event.properties
        guard let sessionID = event.sessionID ?? properties["part"]?.objectValue?["sessionID"]?.stringValue,
              sessionID != session.id else { return false }
        if subagents.isTracking(sessionID) {
            var next = subagents
            if next.apply(event) { subagents = next }
        }
        return true
    }

    private func applyRelatedSession(_ info: OpenCodeSession, removed: Bool) {
        let gone = removed || info.time.archived != nil
        if info.parentID == session.id {
            let next = Self.upsert(info, into: childSessions, removing: gone)
            if next != childSessions { childSessions = next }
            if !gone { trackSubagents([info.id]) }
        }
        guard let parentID = session.parentID else { return }
        if info.parentID == parentID {
            let next = Self.upsert(info, into: siblingSessions, removing: gone)
            if next != siblingSessions { siblingSessions = next }
        }
        if info.id == parentID, !removed, info != parentSession { parentSession = info }
    }

    nonisolated static func upsert(_ session: OpenCodeSession, into sessions: [OpenCodeSession], removing: Bool) -> [OpenCodeSession] {
        var next = sessions.filter { $0.id != session.id }
        if !removing { next.append(session) }
        return OpenCodeSubagentFamily.ordered(next)
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

    var sharePresentation: OpenCodeSessionSharePresentation {
        OpenCodeSessionSharePresentation(
            link: session.share?.link,
            isSupported: featureService != nil && sessionFeatures.share,
            policy: sharePolicy,
            isUpdating: isUpdatingShare
        )
    }

    /// Publishes a read-only web copy of this conversation. Only an explicit
    /// user action calls this; the link shown is always the server's own.
    func publishShareLink() async -> Bool {
        guard let featureService, sharePresentation.canPublish else { return false }
        let published = await updateShare {
            try await featureService.shareSession(sessionID: $0, directory: $1, workspace: $2)
        }
        guard published else {
            await recheckSharePolicy(after: featureService)
            return false
        }
        guard session.share?.link != nil else {
            shareErrorMessage = String(localized: "OpenCode didn’t return a link for this session. Sharing may be turned off on the server.")
            return false
        }
        return true
    }

    func unpublishShareLink() async -> Bool {
        guard let featureService, sharePresentation.canUnpublish else { return false }
        return await updateShare {
            try await featureService.unshareSession(sessionID: $0, directory: $1, workspace: $2)
        }
    }

    func clearShareError() { shareErrorMessage = nil }

    /// OpenCode rejects a publish on a server whose config says `share:
    /// "disabled"` with an opaque server error. The config may have changed
    /// since it was read, so read it again and explain rather than repeat it.
    private func recheckSharePolicy(after featureService: any OpenCodeSessionFeatureServicing) async {
        guard shareErrorMessage != nil,
              let policy = try? await featureService.sessionSharePolicy(directory: directory, workspace: workspace)
        else { return }
        sharePolicy = policy
        if policy == .disabled {
            shareErrorMessage = String(localized: "Sharing is turned off in this server’s OpenCode config.")
        }
    }

    /// Sharing never touches history, so it leaves the composer and session
    /// actions available and only guards itself against a second request.
    private func updateShare(
        _ request: (String, String, String?) async throws -> OpenCodeSession
    ) async -> Bool {
        guard !isUpdatingShare else { return false }
        isUpdatingShare = true
        shareErrorMessage = nil
        featureMutationGeneration &+= 1
        defer { isUpdatingShare = false }
        let sessionID = session.id
        do {
            let updated = try await request(sessionID, directory, workspace)
            guard updated.id == session.id else { return false }
            session = updated
            // Reject a details snapshot requested before the server confirmed.
            featureMutationGeneration &+= 1
            return true
        } catch is CancellationError {
            return false
        } catch {
            shareErrorMessage = error.localizedDescription
            return false
        }
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
            offlineCache?.removeTranscript(sessionID: session.id, directory: directory, workspace: workspace)
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
            errorMessage = String(localized: "File context belongs to a different project. Select the file again.")
            return false
        }
        do {
            try OpenCodePromptAttachment.validate(attachments)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        if let queue = durableQueue, queue.enabled {
            guard revertMessageID == nil else { errorMessage = String(localized: "Redo the conversation before adding work to the computer queue."); return false }
            guard queuedPrompts.isEmpty else { errorMessage = String(localized: "Send or remove the existing local queued messages first."); return false }
            do {
                let prompt = OpenCodeQueuedPrompt(text: trimmed, model: selectedModel, attachments: attachments,
                    agent: effectiveAgentID, variant: selectedVariant,
                    command: OpenCodeCommandInvocation.parse(trimmed, catalog: composerCatalog.commands), remoteReferences: remoteReferences)
                try queue.enqueue(prompt)
                queueAnnouncementRevision &+= 1
                BYOTTelemetry.shared.record(.turnRequested, BYOTTelemetryOpenCode.turnRequested(prompt, delivery: .computerQueue))
                return true
            } catch { errorMessage = error.localizedDescription; return false }
        }
        didStatusProbeFailWithFreshTranscript = false
        recoveryIdleUserMessageID = nil
        dismissUnansweredPromptRecovery()
        if localShell?.isSending == false { localShell = nil }
        if revertMessageID != nil, !status.isActive, !isSending, !isShellSending,
           let prompt = promptQueue.beginExplicitDispatch(text: trimmed, model: selectedModel, attachments: attachments,
               agent: effectiveAgentID, variant: selectedVariant,
               command: OpenCodeCommandInvocation.parse(trimmed, catalog: composerCatalog.commands),
               remoteReferences: remoteReferences) {
            publishPromptQueue()
            BYOTTelemetry.shared.record(.turnRequested, BYOTTelemetryOpenCode.turnRequested(prompt, delivery: .now))
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
            serverIsActive: status.isActive || isSending || isShellSending
        )
        publishPromptQueue()
        switch submission {
        case .queued(let prompt):
            queueAnnouncementRevision &+= 1
            scheduleQueueRecoveryIfNeeded()
            BYOTTelemetry.shared.record(.turnRequested, BYOTTelemetryOpenCode.turnRequested(prompt, delivery: .queued))
            return true
        case .dispatch(let prompt):
            BYOTTelemetry.shared.record(.turnRequested, BYOTTelemetryOpenCode.turnRequested(prompt, delivery: .now))
            schedulePromptDispatch(prompt)
            return true
        }
    }

    /// Runs `text` as a shell command in this session's directory. Returns
    /// false, leaving the command with the caller, when it can't be sent now.
    @discardableResult
    func runShell(_ text: String) -> Bool {
        let command = OpenCodeShellInput.normalized(text)
        guard !command.isEmpty, shellUnavailableReason == nil, let shellService else { return false }
        let shell = OpenCodeShellCommand(command: command, agent: currentAgentID, model: selectedModel)
        let local = OpenCodeLocalShell(id: UUID(), command: command, baselineMessageIDs: Set(transcript.messages.map(\.id)))
        localShell = local
        restoredShellCommand = nil
        BYOTTelemetry.shared.record(.turnRequested, BYOTTelemetryOpenCode.shellRequested())
        errorMessage = nil
        dismissUnansweredPromptRecovery()
        let generation = lifecycleGeneration
        shellTask = Task { [weak self] in
            await self?.performShell(shell, local: local, service: shellService, generation: generation)
        }
        return true
    }

    func dismissShellFailure() {
        guard localShell?.isSending == false else { return }
        localShell = nil
    }

    func consumeRestoredShellCommand() { restoredShellCommand = nil }

    /// The command behind a v1 shell turn, so undoing that turn restores it in
    /// shell mode instead of the server's bookkeeping text.
    /// Redo past the last turn restores a partless message to clear the
    /// composer, so only a message that still carries its parts is a run.
    func shellCommand(restoring message: OpenCodeMessageEnvelope) -> String? {
        guard !message.parts.isEmpty else { return nil }
        return OpenCodeShellTranscript.command(forMarker: message.id, in: transcript.messages)
    }

    private func performShell(_ shell: OpenCodeShellCommand, local: OpenCodeLocalShell,
                              service: any OpenCodeShellServicing, generation: Int) async {
        var failure: Error?
        do {
            try await prepareHistoryForPromptDispatch()
            try Task.checkCancellation()
            try await service.runShell(sessionID: session.id, directory: directory, workspace: workspace, shell: shell)
        } catch is CancellationError {
            return
        } catch { failure = error }
        guard generation == lifecycleGeneration, isRunning, localShell?.id == local.id else { return }
        shellTask = nil
        if let failure {
            let message = OpenCodeShellError.failureMessage(for: failure)
            localShell?.phase = OpenCodeShellError.certainlyDidNotRun(failure) ? .failed(message) : .unconfirmed(message)
            restoredShellCommand = local.command
        } else {
            localShell = nil
        }
        // Prompts sent during the run waited behind it. A v1 run reports its
        // own busy/idle status; release them here when no turn is running.
        if !status.isActive, promptDispatchTask == nil, let next = promptQueue.reconciledServerIdle() {
            publishPromptQueue()
            schedulePromptDispatch(next)
        }
        scheduleMessageRefresh()
        // v1 clears an undone boundary when it accepts the run.
        if revertMessageID != nil { await refreshSessionFeatures() }
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
            if let queue = durableQueue, queue.enabled { try await queue.setPaused(true) }
            let didAbort = try await service.abort(
                sessionID: session.id,
                directory: directory,
                workspace: workspace
            )
            try Task.checkCancellation()
            guard generation == lifecycleGeneration, isRunning else { return false }
            guard didAbort else {
                errorMessage = String(localized: "OpenCode did not confirm that the stalled turn was stopped.")
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
                errorMessage = String(localized: "OpenCode did not confirm that the turn was stopped.")
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
                throw OpenCodeConnectionError.server(String(localized: "File context belongs to a different project. Remove this queued prompt and select the file again."))
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
                // Nothing reached the server, so there is no turn to report.
                telemetryTurn = nil
                clearOptimisticBusy()
            }
        } catch {
            guard isCurrentPromptDispatch(dispatchID) else { return }
            let serverConfirmedActivity = promptQueue.hasObservedServerActivity
            promptQueue.dispatchFailed(prompt, requeue: true)
            publishPromptQueue()
            finishPromptDispatch(dispatchID)
            if serverConfirmedActivity == false {
                // Nothing reached the server, so there is no turn to report.
                telemetryTurn = nil
                clearOptimisticBusy()
            }
            BYOTTelemetry.shared.record(.errorOccurred, BYOTTelemetryOpenCode.errorOccurred(error, surface: .send))
            errorMessage = prompt.command?.kind == .command
                ? String(localized: "The command may have run before the connection failed. Review the session before choosing Run again. \(error.localizedDescription)")
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
                isAgentSelectionExplicit = false
                defaults.removeObject(forKey: agentSelectionKey)
            }
            if selectedAgentID == nil, defaults.object(forKey: agentSelectionKey) == nil,
               catalog.inheritedAgent == nil, session.agent == nil,
               let preferred = defaults.string(forKey: serverDefaultAgentKey),
               catalog.agents.contains(where: { $0.id == preferred }) {
                selectedAgentID = preferred
                isAgentSelectionExplicit = false
            }
            // Commands and agent pickers can refresh this catalog directly.
            // An inherited model change must also reconcile its variant, using
            // the new model's saved preference or explicit Default.
            restoreVariant()
        } catch is CancellationError { return }
        catch { composerErrorMessage = error.localizedDescription }
    }

    /// The agent sent with the next prompt. Without an explicit pick the
    /// session keeps the agent it last ran, as the TUI does on entering a
    /// session and after `plan_exit`; `nil` lets the server choose its default.
    var effectiveAgentID: String? {
        if isAgentSelectionExplicit, let selectedAgentID { return selectedAgentID }
        return composerCatalog.inheritedAgent ?? session.agent ?? transcriptAgentID ?? selectedAgentID
    }

    /// The agent this session's composer shows and cycles from.
    var currentAgentID: String? { effectiveAgentID ?? composerCatalog.defaultAgentID }

    /// This session's pick, excluding the server-wide preference seeded into it.
    var explicitAgentID: String? { isAgentSelectionExplicit ? selectedAgentID : nil }

    var currentAgent: OpenCodeAgentOption? {
        composerCatalog.agents.first { $0.id == currentAgentID }
    }

    var currentAgentName: String {
        if let currentAgent { return currentAgent.displayName }
        return currentAgentID.map { OpenCodeAgentOption(id: $0, name: $0, description: nil).displayName } ?? String(localized: "Default agent")
    }

    /// Where the next cycle lands, for the toggle's VoiceOver hint.
    var nextAgentInCycle: OpenCodeAgentOption? {
        guard composerCatalog.agents.count > 1 else { return nil }
        return OpenCodeAgentCycle.next(after: currentAgentID, in: composerCatalog.agents)
    }

    // The latest user turn names the primary agent that last ran. Subagent
    // names are ignored, matching the TUI's session sync.
    private var transcriptAgentID: String? {
        messages.last { message in
            message.info.role == "user" && composerCatalog.agents.contains { $0.id == message.info.agent }
        }?.info.agent
    }

    func selectAgent(_ id: String?) {
        guard id == nil || composerCatalog.agents.contains(where: { $0.id == id }) else { return }
        selectedAgentID = id
        isAgentSelectionExplicit = id != nil
        defaults.set(id ?? "", forKey: agentSelectionKey)
        if let id { defaults.set(id, forKey: serverDefaultAgentKey) }
        else { defaults.removeObject(forKey: serverDefaultAgentKey) }
    }

    /// The TUI switches to build when `plan_exit` completes. An earlier pick on
    /// this device yields, so the chip and the next prompt follow the approved
    /// plan's build turn instead of sending the plan agent back.
    private func followCompletedPlanExit(_ event: OpenCodeEvent) {
        guard event.type == "message.part.updated", let part = event.properties["part"]?.objectValue,
              part["sessionID"]?.stringValue == session.id, part["tool"]?.stringValue == "plan_exit",
              part["state"]?.objectValue?["status"]?.stringValue == "completed",
              let id = part["id"]?.stringValue, id != followedPlanExitPartID else { return }
        followedPlanExitPartID = id
        guard isAgentSelectionExplicit, selectedAgentID != "build" else { return }
        selectedAgentID = nil
        isAgentSelectionExplicit = false
        defaults.set("", forKey: agentSelectionKey)
    }

    /// One-tap build/plan toggle: Tab-style cycling through primary agents.
    func cycleAgent(_ direction: OpenCodeAgentCycle.Direction = .forward) {
        guard composerCatalog.agents.count > 1,
              let next = OpenCodeAgentCycle.next(after: currentAgentID, in: composerCatalog.agents,
                                                 direction: direction) else { return }
        selectAgent(next.id)
    }

    var availableVariants: [String] { selectedModel?.variants ?? [] }

    var variantLabel: String {
        if let selectedVariant { return selectedVariant }
        return String(localized: "Default")
    }

    private var variantSelectionKey: String? {
        selectedModel.map { "byot.opencode.variant.\(serverID.uuidString).\(session.id).\($0.qualifiedID)" }
    }

    private var defaultVariantKey: String? {
        selectedModel.map { Self.serverDefaultVariantKey(serverID, model: $0) }
    }

    /// The last model, agent and variant picked anywhere on a server. New
    /// sessions, including ones started from Siri and Shortcuts, inherit them.
    nonisolated static func serverDefaultModelKey(_ serverID: UUID) -> String {
        "byot.opencode.model.default.\(serverID.uuidString)"
    }

    nonisolated static func serverDefaultAgentKey(_ serverID: UUID) -> String {
        "byot.opencode.agent.default.\(serverID.uuidString)"
    }

    nonisolated static func serverDefaultVariantKey(_ serverID: UUID, model: OpenCodeModelOption) -> String {
        "byot.opencode.variant.default.\(serverID.uuidString).\(model.qualifiedID)"
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
                            String(localized: "Live updates ended. Reconnecting automatically.")
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
        String(localized: "Live updates disconnected: \(error.localizedDescription) Reconnecting automatically.")
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
            String(localized: "Live updates fell behind. Reconnecting and reconciling with OpenCode.")
        case .eventLineTooLong, .eventRecordTooLarge:
            String(localized: "Live updates exceeded the safe event size. Reconnecting and reconciling with OpenCode.")
        default:
            String(localized: "Live updates disconnected. Reconnecting and reconciling with OpenCode.")
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
        if handleRelatedSessionEvent(event) { return }
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
            followCompletedPlanExit(event)
            if transcript.apply(event) {
                transcriptMutationGeneration &+= 1
                publishTranscript()
            } else {
                scheduleMessageRefresh()
            }
        case "vcs.branch.updated":
            // v1 streams only this location's events; v2's `/api/event` streams every project's.
            if !event.isV2 || event.location == .init(directory: directory, workspaceID: workspace) {
                reportedBranch = OpenCodeReportedBranch(
                    name: event.properties["branch"]?.stringValue?.trimmedNonEmpty, eventID: event.id)
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
                BYOTTelemetry.shared.record(.errorOccurred, BYOTTelemetryOpenCode.turnFailed(sessionError))
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
                errorMessage = OpenCodeFailure(message: String(localized: "The turn failed."), details: event.properties["error"]?.objectValue).message
                BYOTTelemetry.shared.record(.errorOccurred, BYOTTelemetryOpenCode.turnFailed(details: event.properties["error"]?.objectValue))
            }
            settleTurnLocally(dismissingUnansweredPrompt: false)
            scheduleMessageRefresh()
        case "session.retry.scheduled", "session.next.retried":
            statusMutationGeneration &+= 1
            applyEventStatus(.retry(attempt: Int(event.properties["attempt"]?.numberValue ?? 1),
                message: event.properties["error"]?.objectValue?["message"]?.stringValue ?? String(localized: "Retrying"), next: event.properties["at"]?.numberValue ?? 0))
        case "session.next.step.started":
            // Current v2 has no execution events on /api/event; a step is the
            // first sign of work and a new step supersedes any pending settle.
            // Apply it even over an optimistic busy so the prompt queue records
            // server activity and dispatches its follow-up when the turn ends.
            cancelTurnSettlement()
            statusMutationGeneration &+= 1
            applyEventStatus(.busy)
            applyV2Transcript(event)
        case "session.next.step.ended", "session.next.step.failed":
            applyV2Transcript(event)
            // Any step can be the last one: tool calls stop continuing after a
            // provider error or the agent's step limit. The next step.started
            // cancels the probe while the server still owns the drain.
            scheduleTurnSettlement(afterFailure: event.type == "session.next.step.failed")
        default:
            applyV2Transcript(event)
        }
    }

    private func applyV2Transcript(_ event: OpenCodeEvent) {
        switch transcript.applyV2(event) {
        case .changed:
            transcriptMutationGeneration &+= 1
            publishTranscript()
        case .unchanged:
            break
        case .unresolved:
            // Unrecognized or out-of-order events reconcile from projection.
            scheduleMessageRefresh()
        }
    }

    /// Current v2 servers report no idle event, so after each step the store
    /// asks the authoritative active-session list with a short backoff, then
    /// keeps checking at the last interval until the drain ends. A failed
    /// final step settles like session.error so queued prompts stay paused.
    private func scheduleTurnSettlement(afterFailure: Bool) {
        cancelTurnSettlement()
        let baseline = statusMutationGeneration
        turnSettlementTask = Task { [weak self] in
            var attempt = 0
            while true {
                let delays = Self.turnSettlementDelays
                try? await Task.sleep(for: delays[min(attempt, delays.count - 1)])
                attempt += 1
                guard !Task.isCancelled, let store = self, store.isRunning else { return }
                // Another path (reconciliation, Stop) already settled the turn.
                guard store.status.isActive, baseline == store.statusMutationGeneration else {
                    store.turnSettlementTask = nil
                    return
                }
                guard let statuses = try? await store.service.sessionStatuses(
                    directory: store.directory, workspace: store.workspace
                ) else { continue }
                guard !Task.isCancelled, baseline == store.statusMutationGeneration else { return }
                guard statuses[store.session.id]?.isActive != true else { continue }
                store.turnSettlementTask = nil
                if afterFailure {
                    store.settleTurnLocally(dismissingUnansweredPrompt: false)
                } else {
                    store.statusMutationGeneration &+= 1
                    store.applyEventStatus(.idle)
                }
                store.scheduleMessageRefresh()
                return
            }
        }
    }

    private func cancelTurnSettlement() {
        turnSettlementTask?.cancel()
        turnSettlementTask = nil
    }

    nonisolated static let turnSettlementDelays: [Duration] = [
        .milliseconds(150), .milliseconds(400), .seconds(1), .seconds(2), .seconds(4),
    ]

    private func publishTranscript() {
        if revertMessageID == nil { revertedUserMessages = [] }
        // The saved transcript stands in until the server's arrives. Events streamed
        // before then update it rather than replace it, so history stays in view.
        let source = cachedMessages.map { Self.overlay(transcript.messages, on: $0) } ?? transcript.messages
        if let revertMessageID, let boundary = source.firstIndex(where: { $0.id == revertMessageID }) {
            messages = Array(source.prefix(boundary))
        } else {
            messages = source
        }
        updateCurrentTurnActivityTracking()
        updateUnansweredPromptRecovery()
        updateUsage()
        trackSubagents(OpenCodeSubagentTask.sessionIDs(in: transcript.messages))
        transcriptRevision &+= 1
        if hasServerTranscript { scheduleOfflineTranscriptSave() }
    }

    // MARK: Offline transcript

    /// Shows the saved transcript while the server's loads. It never enters the
    /// reducer, so streamed events and the server's snapshot reconcile exactly as
    /// they would without it.
    private func restoreOfflineTranscript() {
        guard let offlineCache, !hasServerTranscript, cachedMessages == nil else { return }
        let sessionID = session.id, directory = self.directory, workspace = self.workspace
        offlineRestoreTask?.cancel()
        offlineRestoreTask = Task { [weak self] in
            let saved = await offlineCache.transcript(sessionID: sessionID, directory: directory, workspace: workspace)
            guard let self, !Task.isCancelled, let saved, !saved.messages.isEmpty, isRunning,
                  !hasServerTranscript else { return }
            cachedMessages = saved.messages
            savedMessages = saved.messages
            offlineTranscript = OpenCodeOfflineTranscriptInfo(savedAt: saved.savedAt, isTruncated: saved.isTruncated)
            publishTranscript()
        }
    }

    private func didLoadServerTranscript() {
        hasServerTranscript = true
        discardOfflineTranscript()
    }

    private func discardOfflineTranscript() {
        offlineRestoreTask?.cancel()
        offlineRestoreTask = nil
        cachedMessages = nil
        if offlineTranscript != nil { offlineTranscript = nil }
    }

    /// Streamed messages, applied over the saved ones: a message both hold keeps its
    /// saved parts and takes the streamed ones, and a new message joins in order.
    nonisolated static func overlay(
        _ live: [OpenCodeMessageEnvelope], on saved: [OpenCodeMessageEnvelope]
    ) -> [OpenCodeMessageEnvelope] {
        guard !live.isEmpty else { return saved }
        var merged = saved
        for message in live {
            guard let index = merged.firstIndex(where: { $0.id == message.id }) else {
                merged.append(message)
                continue
            }
            var parts = merged[index].parts
            for part in message.parts {
                if let partIndex = parts.firstIndex(where: { $0.id == part.id }) {
                    parts[partIndex] = part
                } else {
                    parts.append(part)
                }
            }
            merged[index] = OpenCodeMessageEnvelope(info: message.info, parts: parts)
        }
        return merged.sorted { ($0.info.time.created, $0.id) < ($1.info.time.created, $1.id) }
    }

    /// Streaming updates the transcript many times a second. Save once it has been
    /// quiet for 2 seconds, and at least every 30 seconds while a long reply streams.
    private func scheduleOfflineTranscriptSave() {
        guard offlineCache != nil else { return }
        let now = ContinuousClock.now
        let pendingSince = offlineSavePendingSince ?? now
        offlineSavePendingSince = pendingSince
        let delay = max(.zero, min(.seconds(2), pendingSince + .seconds(30) - now))
        offlineSaveTask?.cancel()
        offlineSaveTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.saveOfflineTranscriptNow()
        }
    }

    /// Saves pending transcript changes right away, for example before the app
    /// leaves the foreground.
    func saveOfflineTranscriptNow() {
        offlineSaveTask?.cancel()
        offlineSaveTask = nil
        offlineSavePendingSince = nil
        guard let offlineCache, hasServerTranscript, !didDeleteSession, transcript.messages != savedMessages else { return }
        savedMessages = transcript.messages
        if transcript.messages.isEmpty {
            // Nothing to show offline; an older copy would only mislead.
            offlineCache.removeTranscript(sessionID: session.id, directory: directory, workspace: workspace)
        } else {
            offlineCache.saveTranscript(transcript.messages, sessionID: session.id, directory: directory, workspace: workspace)
        }
    }

    private func updateUsage() {
        var next = OpenCodeSessionUsage(messages: messages, models: catalogModels, session: session)
        if let window = serverContextWindow, window.anchor == messages.last?.id {
            next = next.reconciled(activeContext: window.messages)
        }
        // Streaming republishes the transcript per token; only real changes publish.
        if next != usage { usage = next }
    }

    /// Reads the server's own active context where it offers one. Failure is
    /// quiet: the transcript's last compaction already answers the question.
    func refreshContextWindow() async {
        guard let featureService, sessionFeatures.contextWindow else { return }
        let anchor = messages.last?.id
        do {
            guard let window = try await featureService.sessionContextMessages(
                sessionID: session.id, directory: directory, workspace: workspace),
                anchor == messages.last?.id else { return }
            serverContextWindow = (anchor, window)
            updateUsage()
        } catch {}
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
            message.info.role.lowercased() == "assistant" && !message.isSyntheticContext
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
            .filter(\.isAuthoredText)
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
            message.info.role.lowercased() == "assistant" && !message.isSyntheticContext
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

    /// Reports a byot-requested turn once it goes idle. A turn the view left
    /// behind (`stop()`) may still be running on the server, so it is dropped
    /// rather than guessed at.
    private func recordTurnCompletionIfNeeded(from previous: OpenCodeSessionStatus) {
        guard previous.isActive, status.isActive == false, let turn = telemetryTurn else { return }
        telemetryTurn = nil
        guard isRunning else { return }
        let result = if isStoppingTurn {
            "stopped"
        } else if errorMessage != nil || BYOTTelemetryOpenCode.replyFailed(in: messages, after: turn.prompt.messageID) {
            "failed"
        } else {
            "completed"
        }
        BYOTTelemetry.shared.record(.turnCompleted, BYOTTelemetryOpenCode.turnCompleted(
            turn, result: result, messages: messages, now: .now))
        // A finished turn is the value moment the star or review ask waits for.
        if result == "completed", nudge == nil, let ask = nudgeGate.recordValueMoment() {
            nudge = ask
            BYOTTelemetry.shared.record(.nudgeOutcome, nudgeGate.outcome(ask, "shown"))
        }
    }

    enum NudgeAnswer { case starred, later, reviewRequested }

    func answerNudge(_ answer: NudgeAnswer) {
        guard let ask = nudge else { return }
        nudge = nil
        switch answer {
        case .starred:
            nudgeGate.recordStarred()
            BYOTTelemetry.shared.record(.nudgeOutcome, nudgeGate.outcome(ask, "starred"))
        case .later:
            nudgeGate.recordLater()
            BYOTTelemetry.shared.record(.nudgeOutcome, nudgeGate.outcome(ask, "later"))
        case .reviewRequested:
            BYOTTelemetry.shared.record(.nudgeOutcome, nudgeGate.outcome(ask, "requested"))
        }
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
                // Context OpenCode injects for the model is not a reply.
                isVisible = part.synthetic != true
                    && part.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
        telemetryTurn = BYOTTelemetryTurn(prompt: prompt, startedAt: .now)
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
                            String(localized: "Live session activity could not be confirmed. Your queued message is paused to avoid sending it twice.")
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
                    String(localized: "Queued message is waiting for session status: \(error.localizedDescription)")
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
            didLoadServerTranscript()
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
        // The legacy lists cover the whole directory, so they also say which
        // subagents are waiting on the user. v2 lists are per session; for
        // those, the tracker follows asked and replied events instead.
        if !subagents.activity.isEmpty, case .success(let legacyPermissions) = permissionResult,
           case .success(let legacyQuestions) = questionResult {
            var next = subagents
            next.applyPendingRequests(legacyPermissions.map { ($0.sessionID, $0.id) }
                + legacyQuestions.map { ($0.sessionID, $0.id) })
            if next != subagents { subagents = next }
        }
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
                String(localized: "Some OpenCode actions could not be refreshed: \(firstError.localizedDescription)")
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
    /// Seeds the screenshot harness. `withCatalog` adds the agent and effort
    /// options a real server supplies, so the composer's single control row can
    /// be checked with every knob present. `crowded` gives that row the most it
    /// has to hold: a long model name and the shell toggle.
    func prepareForAttachmentScreenshot(withCatalog: Bool = false, crowded: Bool = false) {
        isRunning = true
        isStatusReady = true
        status = .idle
        errorMessage = nil
        guard withCatalog else { return }
        if crowded { sessionFeatures.shell = true }
        let model = OpenCodeModelOption(
            providerID: "byot", providerName: "BYOT Fixture", modelID: "muse-spark",
            modelName: crowded ? "Muse Spark 1.3 Free Preview" : "Muse Spark 1.3", status: nil,
            variants: ["byot-careful"])
        providerModels = [OpenCodeProviderModels(
            providerID: model.providerID, providerName: model.providerName, models: [model])]
        composerCatalog = OpenCodeComposerCatalog(
            agents: [OpenCodeAgentOption(id: "build", name: "build", description: nil),
                     OpenCodeAgentOption(id: "plan", name: "plan", description: nil)],
            inheritedAgent: "build", supportsVariants: true)
        selectModel(model)
        selectVariant("byot-careful")
    }
#endif
}
