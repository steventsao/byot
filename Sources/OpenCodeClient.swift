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

private struct OpenCodePromptTextPart: Encodable {
    let type = "text"
    let text: String
}

private struct OpenCodePromptModel: Encodable {
    let providerID: String
    let modelID: String
}

private struct OpenCodePromptBody: Encodable {
    let model: OpenCodePromptModel?
    let parts: [OpenCodePromptTextPart]
}

struct OpenCodeClient: Sendable {
    static let eventBufferLimit = 16

    let profile: OpenCodeServerProfile
    private let password: String
    private let session: URLSession
    private let redirectDelegate: OpenCodeRedirectDelegate

    init(
        profile: OpenCodeServerProfile,
        password: String,
        session: URLSession = .shared
    ) {
        self.profile = profile
        self.password = password
        self.session = session
        redirectDelegate = OpenCodeRedirectDelegate(baseURL: profile.normalizedURL)
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
        let capabilityProbe = try await experimentalCapabilities()
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
        let request = try makeRequest(path: path, query: [], method: "GET", body: nil)
        let (data, response) = try await session.data(
            for: request,
            delegate: redirectDelegate
        )
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        if declaredNonJSONMIME(http) != nil {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func isJSONMIME(_ mimeType: String) -> Bool {
        mimeType == "application/json" || mimeType.hasSuffix("+json")
    }

    // Returns the response's MIME type only when the server actually declared
    // a non-JSON one. HTTPURLResponse.mimeType falls back to an inferred
    // "text/plain" when no Content-Type header is present, so that value is
    // treated as "undeclared" rather than as a real type.
    private func declaredNonJSONMIME(_ http: HTTPURLResponse) -> String? {
        guard let raw = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        else { return nil }
        let mime = raw.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !mime.isEmpty, !Self.isJSONMIME(mime) else { return nil }
        return mime
    }

    func listProjects() async throws -> [OpenCodeProject] {
        try await get(
            ["project"],
            query: instanceQuery(directory: profile.normalizedDirectory)
        )
    }

    func listSessions(directory: String) async throws -> [OpenCodeSession] {
        try await get(
            ["session"],
            query: instanceQuery(directory: directory) + [
                URLQueryItem(name: "scope", value: "project"),
                URLQueryItem(name: "roots", value: "true"),
                URLQueryItem(name: "limit", value: "100"),
            ]
        )
    }

    func createSession(directory: String, title: String?) async throws -> OpenCodeSession {
        struct Body: Encodable { let title: String? }
        return try await post(
            ["session"],
            query: instanceQuery(directory: directory),
            body: Body(title: title)
        )
    }

    func connectedProviderModels(
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeProviderModels] {
        let catalog: OpenCodeProviderCatalog = try await get(
            ["provider"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
        return catalog.connectedProviders
    }

    func messages(
        sessionID: String,
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeMessageEnvelope] {
        try await get(
            ["session", sessionID, "message"],
            query: instanceQuery(directory: directory, workspace: workspace)
                + [URLQueryItem(name: "limit", value: "200")]
        )
    }

    func sendMessage(
        sessionID: String,
        directory: String,
        workspace: String? = nil,
        model: OpenCodeModelOption? = nil,
        text: String
    ) async throws {
        let request = try makeSendMessageRequest(
            sessionID: sessionID,
            directory: directory,
            workspace: workspace,
            model: model,
            text: text
        )
        try await performExpectingEmptyResponse(request)
    }

    func makeSendMessageRequest(
        sessionID: String,
        directory: String,
        workspace: String? = nil,
        model: OpenCodeModelOption? = nil,
        text: String
    ) throws -> URLRequest {
        let data = try JSONEncoder().encode(
            OpenCodePromptBody(
                model: model.map {
                    OpenCodePromptModel(
                        providerID: $0.providerID,
                        modelID: $0.modelID
                    )
                },
                parts: [OpenCodePromptTextPart(text: text)]
            )
        )
        return try makeRequest(
            path: ["session", sessionID, "prompt_async"],
            query: instanceQuery(directory: directory, workspace: workspace),
            method: "POST",
            body: data
        )
    }

    func diffs(
        sessionID: String,
        directory: String,
        workspace: String? = nil
    ) async throws -> [OpenCodeDiff] {
        try await get(
            ["session", sessionID, "diff"],
            query: instanceQuery(directory: directory, workspace: workspace)
        )
    }

    func sessionStatuses(
        directory: String,
        workspace: String? = nil
    ) async throws -> [String: OpenCodeSessionStatus] {
        try await get(
            ["session", "status"],
            query: instanceQuery(directory: directory, workspace: workspace)
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
            try await performExpectingEmptyResponse(request)
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
                    let decoder = JSONDecoder()
                    var request = try makeRequest(
                        path: ["event"],
                        query: instanceQuery(directory: directory, workspace: workspace),
                        method: "GET",
                        body: nil
                    )
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 86_400
                    let (bytes, response) = try await session.bytes(
                        for: request,
                        delegate: redirectDelegate
                    )
                    try Self.validateEventResponse(response)

                    var lineFramer = OpenCodeSSELineFramer()
                    var parser = OpenCodeSSEParser()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let line = try lineFramer.ingest(byte: byte) else { continue }
                        if let data = try parser.ingest(line: line) {
                            guard try Self.yieldEvent(
                                decoder.decode(OpenCodeEvent.self, from: data),
                                to: continuation
                            ) else { return }
                        }
                    }
                    lineFramer.discardIncompleteLine()
                    parser.discard()
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
        var url = try profile.validatedBaseURL()
        for component in path {
            url.append(path: component)
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OpenCodeConnectionError.invalidProfile("The OpenCode server URL could not be built.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let requestURL = components.url else {
            throw OpenCodeConnectionError.invalidProfile("The OpenCode server URL could not be built.")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let credentials = "\(profile.username):\(password)"
        request.setValue(
            "Basic \(Data(credentials.utf8).base64EncodedString())",
            forHTTPHeaderField: "Authorization"
        )
        return request
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
        let request = try makeRequest(path: path, query: query, method: "GET", body: nil)
        return try await perform(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: [String],
        query: [URLQueryItem],
        body: Body,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let data = try JSONEncoder().encode(body)
        var request = try makeRequest(path: path, query: query, method: "POST", body: data)
        if let timeout { request.timeoutInterval = timeout }
        return try await perform(request)
    }

    private func postWithoutBody<Response: Decodable>(
        _ path: [String],
        query: [URLQueryItem]
    ) async throws -> Response {
        let request = try makeRequest(path: path, query: query, method: "POST", body: nil)
        return try await perform(request)
    }

    private func postExpectingEmptyResponse<Body: Encodable>(
        _ path: [String],
        body: Body
    ) async throws {
        let data = try JSONEncoder().encode(body)
        let request = try makeRequest(path: path, query: [], method: "POST", body: data)
        try await performExpectingEmptyResponse(request)
    }

    private func performExpectingEmptyResponse(_ request: URLRequest) async throws {
        let (responseData, response) = try await session.data(
            for: request,
            delegate: redirectDelegate
        )
        try validateEmptyResponse(data: responseData, response: response)
    }

    func validateEmptyResponse(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeConnectionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenCodeConnectionError.httpStatus(
                http.statusCode,
                serverMessage(from: data)
            )
        }
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(
            for: request,
            delegate: redirectDelegate
        )
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeConnectionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenCodeConnectionError.httpStatus(http.statusCode, serverMessage(from: data))
        }
        // #19: OpenCode 2 answers legacy v1 routes with a 200 text/html web-app
        // fallback, so a successful status code proves nothing about the body.
        // Note: Foundation reports an inferred "text/plain" when the response
        // has no Content-Type header at all, so only a *declared* non-JSON
        // type short-circuits here.
        if let mimeType = declaredNonJSONMIME(http) {
            throw OpenCodeConnectionError.unexpectedContentType(
                path: request.url?.path ?? "",
                contentType: mimeType
            )
        }
        guard !data.isEmpty else { throw OpenCodeConnectionError.emptyResponse }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            if Self.looksLikeHTML(data) {
                throw OpenCodeConnectionError.unexpectedContentType(
                    path: request.url?.path ?? "",
                    contentType: http.mimeType
                )
            }
            throw OpenCodeConnectionError.server("OpenCode returned data this app could not read: \(error.localizedDescription)")
        }
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        var index = data.startIndex
        while index < data.endIndex,
              data[index] == 0x20 || data[index] == 0x09 || data[index] == 0x0A || data[index] == 0x0D {
            index += 1
        }
        return index < data.endIndex && data[index] == 0x3C // "<"
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

    private func serverMessage(from data: Data) -> String? {
        guard let value = try? JSONDecoder().decode(OpenCodeJSONValue.self, from: data) else { return nil }
        switch value {
        case .object(let object):
            if let direct = object["message"]?.stringValue { return direct }
            if case .object(let nested) = object["data"],
               let message = nested["message"]?.stringValue {
                return message
            }
            return nil
        default:
            return nil
        }
    }
}
