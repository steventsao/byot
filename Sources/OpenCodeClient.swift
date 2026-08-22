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

private struct OpenCodeDataResponse<Value: Decodable>: Decodable {
    let data: Value
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
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodePermissionRequest] {
        let requests: [OpenCodePermissionRequest] = try await get(
            ["permission"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
        return requests.map { request in
            var request = request
            request.apiVersion = .legacy
            return request
        }
    }

    func reply(
        to permission: OpenCodePermissionRequest,
        directory: String,
        workspace: String? = nil,
        reply: OpenCodePermissionReply
    ) async throws {
        struct Body: Encodable { let reply: OpenCodePermissionReply }
        switch permission.resolvedAPIVersion {
        case .legacy:
            let _: Bool = try await post(
                ["permission", permission.id, "reply"],
                query: instanceQuery(directory: directory, workspace: workspace),
                body: Body(reply: reply)
            )
        case .v2:
            try await postExpectingEmptyResponse(
                ["api", "session", permission.sessionID, "permission", permission.id, "reply"],
                body: Body(reply: reply)
            )
        }
    }

    func questions(
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeQuestionRequest] {
        let requests: [OpenCodeQuestionRequest] = try await get(
            ["question"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
        return requests.map { request in
            var request = request
            request.apiVersion = .legacy
            return request
        }
    }

    func v2Permissions(sessionID: String) async throws -> [OpenCodePermissionRequest] {
        do {
            let response: OpenCodeDataResponse<[OpenCodePermissionV2Request]> = try await get(
                ["api", "session", sessionID, "permission"],
                query: []
            )
            return response.data.map(\.normalized)
        } catch let error as OpenCodeConnectionError {
            if error.isUnsupportedV2ListRoute { return [] }
            throw error
        }
    }

    func v2Questions(sessionID: String) async throws -> [OpenCodeQuestionRequest] {
        do {
            let response: OpenCodeDataResponse<[OpenCodeQuestionRequest]> = try await get(
                ["api", "session", sessionID, "question"],
                query: []
            )
            return response.data.map { request in
                var request = request
                request.apiVersion = .v2
                return request
            }
        } catch let error as OpenCodeConnectionError {
            if error.isUnsupportedV2ListRoute { return [] }
            throw error
        }
    }

    func answer(
        _ question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String? = nil,
        answers: [[String]]
    ) async throws {
        struct Body: Encodable { let answers: [[String]] }
        switch question.resolvedAPIVersion {
        case .legacy:
            let _: Bool = try await post(
                ["question", question.id, "reply"],
                query: instanceQuery(directory: directory, workspace: workspace),
                body: Body(answers: answers)
            )
        case .v2:
            try await postExpectingEmptyResponse(
                ["api", "session", question.sessionID, "question", question.id, "reply"],
                body: Body(answers: answers)
            )
        }
    }

    func reject(
        _ question: OpenCodeQuestionRequest,
        directory: String,
        workspace: String? = nil
    ) async throws {
        switch question.resolvedAPIVersion {
        case .legacy:
            let _: Bool = try await postWithoutBody(
                ["question", question.id, "reject"],
                query: instanceQuery(directory: directory, workspace: workspace)
            )
        case .v2:
            let request = try makeRequest(
                path: ["api", "session", question.sessionID, "question", question.id, "reject"],
                query: [],
                method: "POST",
                body: nil
            )
            try await transport.performExpectingEmptyResponse(request)
        }
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

    private func post<Body: Encodable, Response: Decodable>(
        _ path: [String],
        query: [URLQueryItem],
        body: Body,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        try await transport.post(path, query: query, body: body, timeout: timeout)
    }

    private func postWithoutBody<Response: Decodable>(
        _ path: [String],
        query: [URLQueryItem]
    ) async throws -> Response {
        try await transport.postWithoutBody(path, query: query)
    }

    private func postExpectingEmptyResponse<Body: Encodable>(
        _ path: [String],
        body: Body
    ) async throws {
        try await transport.postExpectingEmptyResponse(path, body: body)
    }

    func validateEmptyResponse(data: Data, response: URLResponse) throws {
        try transport.validateEmptyResponse(data: data, response: response)
    }

    private func instanceQuery(
        directory: String?,
        workspace: String? = nil
    ) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let directory, !directory.isEmpty {
            items.append(URLQueryItem(name: "directory", value: directory))
        }
        if let workspace, !workspace.isEmpty {
            items.append(URLQueryItem(name: "workspace", value: workspace))
        }
        return items
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
