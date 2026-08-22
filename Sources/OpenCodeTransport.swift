import Foundation

struct OpenCodeTransport: Sendable {
    let profile: OpenCodeServerProfile
    private let password: String
    private let session: URLSession
    private let redirectDelegate: OpenCodeRedirectDelegate

    init(
        profile: OpenCodeServerProfile,
        password: String,
        session: URLSession
    ) {
        self.profile = profile
        self.password = password
        self.session = session
        redirectDelegate = OpenCodeRedirectDelegate(baseURL: profile.normalizedURL)
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
            throw OpenCodeConnectionError.invalidProfile(
                "The OpenCode server URL could not be built."
            )
        }
        if !query.isEmpty { components.queryItems = query }
        guard let requestURL = components.url else {
            throw OpenCodeConnectionError.invalidProfile(
                "The OpenCode server URL could not be built."
            )
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

    func probeJSON(_ path: [String]) async throws -> [String: Any]? {
        let request = try makeRequest(path: path, query: [], method: "GET", body: nil)
        let (data, response) = try await session.data(
            for: request,
            delegate: redirectDelegate
        )
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        if declaredNonJSONMIME(http) != nil { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func get<Response: Decodable>(
        _ path: [String],
        query: [URLQueryItem]
    ) async throws -> Response {
        let request = try makeRequest(path: path, query: query, method: "GET", body: nil)
        return try await perform(request)
    }

    func post<Body: Encodable, Response: Decodable>(
        _ path: [String],
        query: [URLQueryItem] = [],
        body: Body,
        timeout: TimeInterval? = nil
    ) async throws -> Response {
        let data = try JSONEncoder().encode(body)
        var request = try makeRequest(path: path, query: query, method: "POST", body: data)
        if let timeout { request.timeoutInterval = timeout }
        return try await perform(request)
    }

    func patch<Body: Encodable, Response: Decodable>(
        _ path: [String],
        query: [URLQueryItem] = [],
        body: Body
    ) async throws -> Response {
        let data = try JSONEncoder().encode(body)
        let request = try makeRequest(path: path, query: query, method: "PATCH", body: data)
        return try await perform(request)
    }

    func delete<Response: Decodable>(
        _ path: [String],
        query: [URLQueryItem] = []
    ) async throws -> Response {
        let request = try makeRequest(path: path, query: query, method: "DELETE", body: nil)
        return try await perform(request)
    }

    func postWithoutBody<Response: Decodable>(
        _ path: [String],
        query: [URLQueryItem]
    ) async throws -> Response {
        let request = try makeRequest(path: path, query: query, method: "POST", body: nil)
        return try await perform(request)
    }

    func postExpectingEmptyResponse<Body: Encodable>(
        _ path: [String],
        query: [URLQueryItem] = [],
        body: Body
    ) async throws {
        let data = try JSONEncoder().encode(body)
        let request = try makeRequest(path: path, query: query, method: "POST", body: data)
        try await performExpectingEmptyResponse(request)
    }

    func postWithoutBodyExpectingEmptyResponse(
        _ path: [String],
        query: [URLQueryItem] = []
    ) async throws {
        let request = try makeRequest(path: path, query: query, method: "POST", body: nil)
        try await performExpectingEmptyResponse(request)
    }

    func performExpectingEmptyResponse(_ request: URLRequest) async throws {
        let (data, response) = try await session.data(
            for: request,
            delegate: redirectDelegate
        )
        try validateEmptyResponse(data: data, response: response)
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

    func events(
        path: [String],
        query: [URLQueryItem]
    ) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream(
            bufferingPolicy: .bufferingNewest(OpenCodeClient.eventBufferLimit)
        ) { continuation in
            let task = Task {
                do {
                    let decoder = JSONDecoder()
                    var request = try makeRequest(
                        path: path,
                        query: query,
                        method: "GET",
                        body: nil
                    )
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.timeoutInterval = 86_400
                    let (bytes, response) = try await session.bytes(
                        for: request,
                        delegate: redirectDelegate
                    )
                    try OpenCodeClient.validateEventResponse(response)

                    var lineFramer = OpenCodeSSELineFramer()
                    var parser = OpenCodeSSEParser()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let line = try lineFramer.ingest(byte: byte) else { continue }
                        if let data = try parser.ingest(line: line) {
                            guard try OpenCodeClient.yieldEvent(
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

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(
            for: request,
            delegate: redirectDelegate
        )
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeConnectionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenCodeConnectionError.httpStatus(
                http.statusCode,
                serverMessage(from: data)
            )
        }
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
            throw OpenCodeConnectionError.server(
                "OpenCode returned data this app could not read: \(error.localizedDescription)"
            )
        }
    }

    private func declaredNonJSONMIME(_ http: HTTPURLResponse) -> String? {
        guard let raw = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        else { return nil }
        let mime = raw.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !mime.isEmpty, !OpenCodeClient.isJSONMIME(mime) else { return nil }
        return mime
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        var index = data.startIndex
        while index < data.endIndex,
              data[index] == 0x20 || data[index] == 0x09
                || data[index] == 0x0A || data[index] == 0x0D {
            index += 1
        }
        return index < data.endIndex && data[index] == 0x3C
    }

    private func serverMessage(from data: Data) -> String? {
        guard let value = try? JSONDecoder().decode(OpenCodeJSONValue.self, from: data)
        else { return nil }
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
