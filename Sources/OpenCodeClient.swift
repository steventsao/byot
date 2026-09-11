import Foundation

/// Composition root and normalized service facade. Each instance builds one
/// connection scope; value copies share its negotiation and transport services.
struct OpenCodeClient: Sendable {
    let profile: OpenCodeServerProfile
    let transport: any OpenCodeHTTPTransport
    private let connection: OpenCodeConnection
    private let actions: OpenCodeActions

    init(
        profile: OpenCodeServerProfile,
        password: String,
        session: URLSession = .shared,
        serverProtocol: OpenCodeServerProtocol? = nil
    ) {
        self.init(
            profile: profile,
            transport: OpenCodeTransport(profile: profile, password: password, session: session),
            serverProtocol: serverProtocol
        )
    }

    init(
        profile: OpenCodeServerProfile, transport: any OpenCodeHTTPTransport,
        serverProtocol: OpenCodeServerProtocol? = nil
    ) {
        self.profile = profile
        self.transport = transport
        actions = OpenCodeActions(transport: transport)
        connection = OpenCodeConnection(
            source: OpenCodeLiveConnectionSource(transport: transport, profile: profile),
            serverProtocol: serverProtocol
        )
    }

    func probeServer() async throws -> OpenCodeServerProbe {
        try await connection.probe()
    }

    func health() async throws -> OpenCodeHealth {
        try await transport.get(["global", "health"], query: [])
    }

    func experimentalCapabilities() async throws -> OpenCodeCapabilityProbeResult {
        do {
            let capabilities: OpenCodeCapabilities = try await transport.get(
                ["experimental", "capabilities"],
                query: []
            )
            return .available(capabilities)
        } catch let error as OpenCodeConnectionError where error.isUnsupportedRoute {
            return .unavailable
        }
    }

    func probeCompatibility() async throws -> OpenCodeCompatibilitySummary {
        let probe = try await connection.probe()
        let verdict = OpenCodeCompatibilityEvaluator.evaluate(
            health: probe.health,
            serverProtocol: probe.protocol
        )
        if case .unsupported = verdict {
            return OpenCodeCompatibilitySummary(
                verdict: verdict,
                health: probe.health,
                capabilityProbe: .unavailable
            )
        }
        let capabilityProbe =
            probe.protocol == .v1
            ? try await experimentalCapabilities()
            : .unavailable
        return OpenCodeCompatibilitySummary(
            verdict: verdict,
            health: probe.health,
            capabilityProbe: capabilityProbe
        )
    }

    func capabilities() async throws -> OpenCodeProtocolCapabilities {
        try await connection.adapter().capabilities
    }

    func listProjects() async throws -> [OpenCodeProject] {
        try await connection.adapter().listProjects()
    }

    func listSessions(directory: String) async throws -> [OpenCodeSession] {
        try await connection.adapter().listSessions(directory: directory)
    }

    func createSession(directory: String, title: String?) async throws -> OpenCodeSession {
        try await connection.adapter().createSession(directory: directory, title: title)
    }

    func connectedProviderModels(
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeProviderModels] {
        try await connection.adapter().connectedProviderModels(directory: directory, workspace: workspace)
    }

    func messages(
        sessionID: String,
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeMessageEnvelope] {
        try await connection.adapter().messages(
            sessionID: sessionID, directory: directory, workspace: workspace)
    }

    func sendMessage(
        sessionID: String,
        directory: String,
        workspace: String? = nil,
        model: OpenCodeModelOption? = nil,
        text: String,
        attachments: [OpenCodePromptAttachment] = [],
        promptID: UUID = UUID()
    ) async throws {
        try await connection.adapter().sendMessage(
            sessionID: sessionID, directory: directory, workspace: workspace, model: model, text: text,
            attachments: attachments, promptID: promptID)
    }

    @discardableResult
    func abort(
        sessionID: String,
        directory: String,
        workspace: String? = nil
    ) async throws -> Bool {
        try await connection.adapter().abortSession(
            sessionID: sessionID, directory: directory, workspace: workspace)
    }

    func diffs(
        sessionID: String,
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeDiff] {
        try await connection.adapter().diffs(sessionID: sessionID, directory: directory, workspace: workspace)
    }

    func sessionStatuses(
        directory: String,
        workspace: String? = nil
    ) async throws -> [String: OpenCodeSessionStatus] {
        try await connection.adapter().sessionStatuses(directory: directory, workspace: workspace)
    }

    func permissions(directory: String, workspace: String? = nil) async throws -> [OpenCodePermissionRequest]
    {
        if try await connection.adapter().serverProtocol == .v2 { return [] }
        return try await actions.permissions(directory: directory, workspace: workspace)
    }

    func questions(directory: String, workspace: String? = nil) async throws -> [OpenCodeQuestionRequest] {
        if try await connection.adapter().serverProtocol == .v2 { return [] }
        return try await actions.questions(directory: directory, workspace: workspace)
    }

    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] {
        try await actions.v2Permissions(sessionID: sessionID)
    }

    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] {
        let usesForms = try await connection.adapter().usesForms
        return try await actions.v2Questions(sessionID: sessionID, usesForms: usesForms)
    }

    func reply(
        to permission: OpenCodePermissionRequest, directory: String, workspace: String? = nil,
        reply: OpenCodePermissionReply
    ) async throws {
        try await actions.reply(to: permission, directory: directory, workspace: workspace, reply: reply)
    }

    func answer(
        _ question: OpenCodeQuestionRequest, directory: String, workspace: String? = nil, answers: [[String]]
    ) async throws {
        try await actions.answer(question, directory: directory, workspace: workspace, answers: answers)
    }

    func reject(_ question: OpenCodeQuestionRequest, directory: String, workspace: String? = nil) async throws
    {
        try await actions.reject(question, directory: directory, workspace: workspace)
    }

    func events(
        directory: String,
        workspace: String? = nil
    ) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(OpenCodeEventStream.bufferLimit)) {
            continuation in
            let task = Task {
                do {
                    let route = try await connection.adapter().eventRoute(
                        directory: directory, workspace: workspace)
                    for try await event in transport.events(path: route.path, query: route.query) {
                        try Task.checkCancellation()
                        guard try OpenCodeEventStream.yieldEvent(event, to: continuation) else { return }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

}
