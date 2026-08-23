import Foundation

struct OpenCodeSSEParser: Sendable {
    static let defaultMaxEventBytes = 8 * 1_024 * 1_024

    private var data = Data()
    private var hasDataField = false
    private var eventBytes = 0
    private let maxEventBytes: Int

    init(maxEventBytes: Int = Self.defaultMaxEventBytes) {
        precondition(maxEventBytes > 0)
        self.maxEventBytes = maxEventBytes
    }

    mutating func ingest(line: String) throws -> Data? {
        if line.isEmpty {
            return dispatch()
        }
        let normalizedLineBytes = line.utf8.count + 1
        guard normalizedLineBytes <= maxEventBytes - eventBytes else {
            discard()
            throw OpenCodeConnectionError.eventRecordTooLarge(maxBytes: maxEventBytes)
        }
        eventBytes += normalizedLineBytes

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        guard field == "data" else {
            return nil
        }
        if hasDataField { data.append(0x0A) }
        data.append(contentsOf: value.utf8)
        hasDataField = true
        return nil
    }

    mutating func discard() {
        data.removeAll(keepingCapacity: true)
        hasDataField = false
        eventBytes = 0
    }

    private mutating func dispatch() -> Data? {
        let result = hasDataField ? data : nil
        defer { discard() }
        return result
    }
}

struct OpenCodeSSELineFramer: Sendable {
    static let defaultMaxLineBytes = 2 * 1_024 * 1_024

    private var lineBytes: [UInt8] = []
    private var bomProbe: [UInt8] = []
    private var checkingBOM = true
    private var swallowLF = false
    private let maxLineBytes: Int

    init(maxLineBytes: Int = Self.defaultMaxLineBytes) {
        precondition(maxLineBytes > 0)
        self.maxLineBytes = maxLineBytes
    }

    mutating func ingest(byte: UInt8) throws -> String? {
        if checkingBOM {
            let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
            if byte == bom[bomProbe.count] {
                bomProbe.append(byte)
                if bomProbe.count == bom.count {
                    bomProbe.removeAll(keepingCapacity: false)
                    checkingBOM = false
                }
                return nil
            }
            checkingBOM = false
            for prefixByte in bomProbe {
                try appendLineByte(prefixByte)
            }
            bomProbe.removeAll(keepingCapacity: false)
        }

        if swallowLF {
            swallowLF = false
            if byte == 0x0A { return nil }
        }

        switch byte {
        case 0x0D:
            swallowLF = true
            return takeLine()
        case 0x0A:
            return takeLine()
        default:
            try appendLineByte(byte)
            return nil
        }
    }

    mutating func discardIncompleteLine() {
        lineBytes.removeAll(keepingCapacity: true)
        bomProbe.removeAll(keepingCapacity: false)
        checkingBOM = false
        swallowLF = false
    }

    private mutating func appendLineByte(_ byte: UInt8) throws {
        guard lineBytes.count < maxLineBytes else {
            discardIncompleteLine()
            throw OpenCodeConnectionError.eventLineTooLong(maxBytes: maxLineBytes)
        }
        lineBytes.append(byte)
    }

    private mutating func takeLine() -> String {
        defer { lineBytes.removeAll(keepingCapacity: true) }
        return String(decoding: lineBytes, as: UTF8.self)
    }
}

struct OpenCodeClient: Sendable {
    static let eventBufferLimit = 16

    let profile: OpenCodeServerProfile
    private let transport: OpenCodeTransport
    private let protocolCache: OpenCodeProtocolCache

    init(
        profile: OpenCodeServerProfile,
        password: String,
        session: URLSession = .shared,
        serverProtocol: OpenCodeServerProtocol? = nil
    ) {
        self.profile = profile
        transport = OpenCodeTransport(
            profile: profile,
            password: password,
            session: session
        )
        protocolCache = OpenCodeProtocolCache(serverProtocol)
    }

    func health() async throws -> OpenCodeHealth {
        try await get(["global", "health"], query: [])
    }

    func experimentalCapabilities() async throws -> OpenCodeCapabilityProbeResult {
        do {
            let capabilities: OpenCodeCapabilities = try await get(
                ["experimental", "capabilities"],
                query: []
            )
            return .available(capabilities)
        } catch let error as OpenCodeConnectionError where error.isUnsupportedRoute {
            return .unavailable
        }
    }

    func probeCompatibility() async throws -> OpenCodeCompatibilitySummary {
        let probe = try await OpenCodeProtocolDetector(client: self).probe()
        protocolCache.store(probe.protocol)
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
        let capabilityProbe = probe.protocol == .v1
            ? try await experimentalCapabilities()
            : .unavailable
        return OpenCodeCompatibilitySummary(
            verdict: verdict,
            health: probe.health,
            capabilityProbe: capabilityProbe
        )
    }

    // Raw JSON probe for protocol detection. Returns the decoded object only
    // when the route answers 2xx with a JSON-parseable object body; a declared
    // non-JSON content type (e.g. the OpenCode 2 web UI's text/html fallback)
    // short-circuits to nil. Used by OpenCodeProtocolDetector only.
    func probeJSON(_ path: [String]) async throws -> [String: Any]? {
        try await transport.probeJSON(path)
    }

    static func isJSONMIME(_ mimeType: String) -> Bool {
        mimeType == "application/json" || mimeType.hasSuffix("+json")
    }

    func listProjects() async throws -> [OpenCodeProject] {
        try await protocolAdapter().listProjects(using: transport, profile: profile)
    }

    func protocolCapabilities() async throws -> OpenCodeProtocolCapabilities {
        let adapter = try await protocolAdapter()
        return adapter.capabilities
    }

    func listSessions(directory: String) async throws -> [OpenCodeSession] {
        try await protocolAdapter().listSessions(
            using: transport,
            directory: directory
        )
    }

    func createSession(directory: String, title: String?) async throws -> OpenCodeSession {
        try await protocolAdapter().createSession(
            using: transport,
            directory: directory,
            title: title
        )
    }

    func connectedProviderModels(
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeProviderModels] {
        try await protocolAdapter().connectedProviderModels(
            using: transport,
            directory: directory,
            workspace: workspace
        )
    }

    func messages(
        sessionID: String,
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeMessageEnvelope] {
        try await protocolAdapter().messages(
            using: transport,
            sessionID: sessionID,
            directory: directory,
            workspace: workspace
        )
    }

    func sendMessage(
        sessionID: String,
        directory: String,
        workspace: String? = nil,
        model: OpenCodeModelOption? = nil,
        text: String,
        attachments: [OpenCodePromptAttachment] = []
    ) async throws {
        try await protocolAdapter().sendMessage(
            using: transport,
            sessionID: sessionID,
            directory: directory,
            workspace: workspace,
            model: model,
            text: text,
            attachments: attachments
        )
    }

    func makeSendMessageRequest(
        sessionID: String,
        directory: String,
        workspace: String? = nil,
        model: OpenCodeModelOption? = nil,
        text: String,
        attachments: [OpenCodePromptAttachment] = []
    ) throws -> URLRequest {
        try OpenCodeV1Adapter().makeSendMessageRequest(
            using: transport,
            sessionID: sessionID,
            directory: directory,
            workspace: workspace,
            model: model,
            text: text,
            attachments: attachments
        )
    }

    func diffs(
        sessionID: String,
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeDiff] {
        try await protocolAdapter().diffs(
            using: transport,
            sessionID: sessionID,
            directory: directory,
            workspace: workspace
        )
    }

    func sessionStatuses(
        directory: String,
        workspace: String? = nil
    ) async throws -> [String: OpenCodeSessionStatus] {
        try await protocolAdapter().sessionStatuses(
            using: transport,
            directory: directory,
            workspace: workspace
        )
    }

    func abortSession(
        sessionID: String,
        directory: String,
        workspace: String? = nil
    ) async throws {
        try await protocolAdapter().abortSession(
            using: transport,
            sessionID: sessionID,
            directory: directory,
            workspace: workspace
        )
    }

    func permissions(
        sessionID: String,
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodePermissionRequest] {
        try await protocolAdapter().permissions(
            using: transport,
            sessionID: sessionID,
            directory: directory,
            workspace: workspace
        )
    }

    func reply(
        to permission: OpenCodePermissionRequest,
        directory: String,
        workspace: String? = nil,
        reply: OpenCodePermissionReply
    ) async throws {
        try await protocolAdapter().reply(
            using: transport,
            to: permission,
            directory: directory,
            workspace: workspace,
            reply: reply
        )
    }

    func questions(
        sessionID: String,
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeQuestionRequest] {
        try await protocolAdapter().questions(
            using: transport,
            sessionID: sessionID,
            directory: directory,
            workspace: workspace
        )
    }

    func answer(
        _ question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String? = nil,
        answers: [[String]]
    ) async throws {
        try await protocolAdapter().answer(
            using: transport,
            question: question,
            directory: directory,
            workspace: workspace,
            answers: answers
        )
    }

    func reject(
        _ question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String? = nil
    ) async throws {
        try await protocolAdapter().reject(
            using: transport,
            question: question,
            directory: directory,
            workspace: workspace
        )
    }

    func events(
        directory: String,
        workspace: String? = nil
    ) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream(
            bufferingPolicy: .bufferingNewest(Self.eventBufferLimit)
        ) { continuation in
            let task = Task {
                do {
                    let route = try await protocolAdapter().eventRoute(
                        directory: directory,
                        workspace: workspace
                    )
                    for try await event in transport.events(
                        path: route.path,
                        query: route.query
                    ) {
                        try Task.checkCancellation()
                        guard try Self.yieldEvent(event, to: continuation) else { return }
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

    func makeRequest(
        path: [String],
        query: [URLQueryItem],
        method: String,
        body: Data?
    ) throws -> URLRequest {
        try transport.makeRequest(
            path: path,
            query: query,
            method: method,
            body: body
        )
    }

    static func yieldEvent(
        _ event: OpenCodeEvent,
        to continuation: AsyncThrowingStream<OpenCodeEvent, Error>.Continuation
    ) throws -> Bool {
        switch continuation.yield(event) {
        case .enqueued:
            return true
        case .dropped:
            throw OpenCodeConnectionError.eventBufferOverflow
        case .terminated:
            return false
        @unknown default:
            throw OpenCodeConnectionError.eventBufferOverflow
        }
    }

    static func validateEventResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeConnectionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenCodeConnectionError.httpStatus(http.statusCode, nil)
        }
        guard http.mimeType?.lowercased() == "text/event-stream" else {
            throw OpenCodeConnectionError.unexpectedEventContentType
        }
    }

    private func get<Response: Decodable>(
        _ path: [String],
        query: [URLQueryItem]
    ) async throws -> Response {
        try await transport.get(path, query: query)
    }

    func validateEmptyResponse(data: Data, response: URLResponse) throws {
        try transport.validateEmptyResponse(data: data, response: response)
    }

    private func protocolAdapter() async throws -> any OpenCodeProtocolAdapting {
        if let cached = protocolCache.read() {
            return OpenCodeProtocolAdapterFactory.adapter(for: cached)
        }
        let probe = try await OpenCodeProtocolDetector(client: self).probe()
        protocolCache.store(probe.protocol)
        return OpenCodeProtocolAdapterFactory.adapter(for: probe.protocol)
    }
}
