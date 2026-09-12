import Foundation

/// HTTP boundary shared by both protocol adapters. JSON codecs and response
/// validation live here; URLSession, authentication and redirects live below it.
protocol OpenCodeHTTPTransport: Sendable {
    func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func boundedData(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse)
    func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error>
}

struct OpenCodeResponseSizeLimitError: Error {}

extension OpenCodeHTTPTransport {
    /// Test/custom transports retain a bounded fallback; the production transport stops the download.
    func boundedData(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let result = try await data(for: request)
        guard result.0.count <= maximumBytes else { throw OpenCodeResponseSizeLimitError() }
        return result
    }

    func probeJSON(_ path: [String]) async throws -> OpenCodeProbeOutcome {
        let request = try makeRequest(path: path, query: [], method: "GET", body: nil)
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return .undecodable(path: request.url?.path ?? "", contentType: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            return .httpError(status: http.statusCode)
        }
        if let mimeType = declaredNonJSONMIME(http) {
            return .nonJSON(path: request.url?.path ?? "", contentType: mimeType)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .undecodable(path: request.url?.path ?? "", contentType: http.mimeType)
        }
        return .object(object)
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
        let (data, response) = try await data(for: request)
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
        if http.statusCode != 204, let mime = declaredNonJSONMIME(http) {
            throw OpenCodeConnectionError.unexpectedContentType(path: http.url?.path ?? "", contentType: mime)
        }
    }

    func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await data(for: request)
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
        let mime =
            raw.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !mime.isEmpty, !(mime == "application/json" || mime.hasSuffix("+json")) else { return nil }
        return mime
    }

    private static func looksLikeHTML(_ data: Data) -> Bool {
        var index = data.startIndex
        while index < data.endIndex,
            data[index] == 0x20 || data[index] == 0x09
                || data[index] == 0x0A || data[index] == 0x0D
        {
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
                let message = nested["message"]?.stringValue
            {
                return message
            }
            return nil
        default:
            return nil
        }
    }
}
