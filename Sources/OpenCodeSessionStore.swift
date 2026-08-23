import Combine
import Foundation

@MainActor
final class OpenCodeSessionStore: ObservableObject {
    @Published private(set) var messages: [OpenCodeMessageEnvelope] = []
    @Published private(set) var permissions: [OpenCodePermissionRequest] = []
    @Published private(set) var questions: [OpenCodeQuestionRequest] = []
    @Published private(set) var diffs: [OpenCodeDiff] = []
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
    @Published private(set) var queuedPrompts: [OpenCodeQueuedPrompt] = []
    @Published private(set) var queueAnnouncementRevision = 0
    @Published private(set) var isAwaitingFirstVisibleOutput = false
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelErrorMessage: String?
    @Published var errorMessage: String?

    let session: OpenCodeSession
    let directory: String
    private let workspace: String?
    private let client: OpenCodeClient
    private let defaults: UserDefaults
    private let modelSelectionKey: String
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
        client: OpenCodeClient,
        session: OpenCodeSession,
        directory: String,
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.session = session
        self.directory = directory
        self.defaults = defaults
        modelSelectionKey = "byot.opencode.model.\(client.profile.id.uuidString).\(session.id)"
        persistedModelID = defaults.string(forKey: modelSelectionKey)
        workspace = session.workspaceID
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
        status.isActive || isSending || promptQueue.shouldQueueNextPrompt
    }

    var canSubmitPrompt: Bool {
        isRunning && isStatusReady
    }

    var canRetryFirstQueuedPrompt: Bool {
        canSubmitPrompt
            && status.isActive == false
            && isSending == false
            && promptQueue.isPaused
    }

    func start() async {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        isRunning = true
        isStatusReady = false
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
        isRunning = false
        isStatusReady = false
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
        if showLoading { isLoading = true }
        defer {
            if generation == refreshGeneration { isLoading = false }
        }
        do {
            let actionClient = client
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
            switch results.0 {
            case .success(let messages):
                if messageGeneration == messageRequestGeneration,
                   transcriptBaseline == transcriptMutationGeneration {
                    transcript.replace(with: messages)
                    publishTranscript()
                }
            case .failure(let error):
                if messageGeneration == messageRequestGeneration {
                    coreErrors.append(error)
                }
            }
            switch results.5 {
            case .success(let diffs):
                if diffBaseline == diffMutationGeneration { self.diffs = diffs }
            case .failure(let error):
                coreErrors.append(error)
            }
            switch results.6 {
            case .success(let statuses):
                if statusBaseline == statusMutationGeneration {
                    applyReconciledStatus(statuses[session.id] ?? .idle)
                }
            case .failure(let error):
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
    }

    func send(
        _ text: String,
        attachments: [OpenCodePromptAttachment] = []
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!trimmed.isEmpty || !attachments.isEmpty), canSubmitPrompt else { return false }
        do {
            try OpenCodePromptAttachment.validate(attachments)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        let submission = promptQueue.accept(
            text: trimmed,
            model: selectedModel,
            attachments: attachments,
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

    private func runPromptDispatch(
        _ prompt: OpenCodeQueuedPrompt,
        dispatchID: UUID
    ) async {
        guard isCurrentPromptDispatch(dispatchID), !Task.isCancelled else { return }
        beginCurrentTurnActivityTracking()
        markOptimisticBusy()
        isSending = true
        do {
            try await client.sendMessage(
                sessionID: session.id,
                directory: directory,
                workspace: workspace,
                model: prompt.model,
                text: prompt.text,
                attachments: prompt.attachments
            )
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
            errorMessage = error.localizedDescription
        }
    }

    func reloadModels() async {
        guard !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let providers = try await client.connectedProviderModels(
                directory: directory,
                workspace: workspace
            )
            try Task.checkCancellation()
            providerModels = providers
            let availableModels = providers.flatMap(\.models)
            if let persistedModelID {
                selectedModel = availableModels.first { $0.qualifiedID == persistedModelID }
                if selectedModel == nil {
                    self.persistedModelID = nil
                    defaults.removeObject(forKey: modelSelectionKey)
                }
            } else if let selectedModel,
                      !availableModels.contains(where: { $0.id == selectedModel.id }) {
                self.selectedModel = nil
            }
            modelErrorMessage = nil
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
        } else {
            defaults.removeObject(forKey: modelSelectionKey)
        }
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
            try await client.reply(
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
            try await client.answer(
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
            try await client.reject(
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
        let client = client
        let directory = directory
        let workspace = workspace
        eventTask = Task { [weak self] in
            var retryDelay: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                do {
                    for try await event in client.events(
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
                        self?.eventErrorMessage =
                            "Live updates ended. Reconnecting automatically."
                        self?.scheduleQueueRecoveryIfNeeded()
                    }
                } catch is CancellationError {
                    break
                } catch let error as OpenCodeConnectionError
                    where Self.requiresEventReconciliation(error) {
                    self?.isEventConnected = false
                    self?.eventErrorMessage = Self.eventReconciliationMessage(for: error)
                    self?.scheduleReconciliation()
                    self?.scheduleQueueRecoveryIfNeeded()
                } catch {
                    self?.isEventConnected = false
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
        OpenCodeEventSemantics.effect(for: type) == .pendingActions
    }

    private func handle(_ event: OpenCodeEvent) {
        if let eventSessionID = event.sessionID, eventSessionID != session.id {
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
            scheduleMessageRefresh()
        case let type where Self.isPendingActionEventType(type):
            actionMutationGeneration &+= 1
            scheduleActionRefresh()
        default:
            switch OpenCodeEventSemantics.effect(for: event.type) {
            case .messages:
                scheduleMessageRefresh()
            case .busyAndMessages:
                statusMutationGeneration &+= 1
                applyEventStatus(.busy)
                scheduleMessageRefresh()
            case .idleAndMessages:
                statusMutationGeneration &+= 1
                applyEventStatus(.idle)
                scheduleMessageRefresh()
            case .pendingActions:
                actionMutationGeneration &+= 1
                scheduleActionRefresh()
            case .none:
                break
            }
        }
    }

    private func publishTranscript() {
        messages = transcript.messages
        updateCurrentTurnActivityTracking()
        transcriptRevision &+= 1
    }

    private func applyReconciledStatus(_ value: OpenCodeSessionStatus) {
        status = value
        isStatusReady = true
        if value.isActive {
            promptQueue.serverBecameActive()
            publishPromptQueue()
            if isEventConnected == false {
                scheduleQueueRecoveryIfNeeded()
            }
            return
        }
        finishCurrentTurnActivityTracking()
        let nextPrompt = promptQueue.reconciledServerIdle()
        publishPromptQueue()
        if let nextPrompt {
            schedulePromptDispatch(nextPrompt)
        }
    }

    private func applyEventStatus(_ value: OpenCodeSessionStatus) {
        status = value
        isStatusReady = true
        if value.isActive {
            promptQueue.serverBecameActive()
            publishPromptQueue()
            if isEventConnected {
                cancelQueueRecovery()
            }
            return
        }
        finishCurrentTurnActivityTracking()
        let nextPrompt = promptQueue.serverBecameIdle()
        publishPromptQueue()
        if let nextPrompt {
            schedulePromptDispatch(nextPrompt)
        } else if promptQueue.needsServerReconciliation == false {
            cancelQueueRecovery()
        }
    }

    private func publishPromptQueue() {
        queuedPrompts = promptQueue.prompts
    }

    private func markOptimisticBusy() {
        statusMutationGeneration &+= 1
        status = .busy
    }

    private func clearOptimisticBusy() {
        statusMutationGeneration &+= 1
        status = .idle
        finishCurrentTurnActivityTracking()
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
                let statuses = try await client.sessionStatuses(
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
                if reconciledStatus.isActive {
                    promptQueue.serverBecameActive()
                    publishPromptQueue()
                } else if promptQueue.isAwaitingActivity {
                    promptQueue.pauseAwaitingActivity()
                    publishPromptQueue()
                    errorMessage =
                        "Live session activity could not be confirmed. Your queued message is paused to avoid sending it twice."
                } else {
                    let nextPrompt = promptQueue.reconciledServerIdle()
                    publishPromptQueue()
                    if let nextPrompt {
                        finishQueueRecovery(recoveryID)
                        schedulePromptDispatch(nextPrompt)
                        return
                    }
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
            let messages = try await client.messages(
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
            let actionClient = client
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
