import Foundation

struct OpenCodeTransport: OpenCodeHTTPTransport {
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
        request.setValue(
            OpenCodeServerAuthentication.basic(username: profile.username, password: password)
                .authorizationHeaderValue,
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request, delegate: redirectDelegate)
    }

    func boundedData(for request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request, delegate: redirectDelegate)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            throw OpenCodeResponseSizeLimitError()
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw OpenCodeResponseSizeLimitError() }
            data.append(byte)
        }
        return (data, response)
    }

    func events(
        path: [String],
        query: [URLQueryItem]
    ) -> AsyncThrowingStream<OpenCodeEvent, Error> {
        AsyncThrowingStream(
            bufferingPolicy: .bufferingNewest(OpenCodeEventStream.bufferLimit)
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
                    try OpenCodeEventStream.validateEventResponse(response)

                    var lineFramer = OpenCodeSSELineFramer()
                    var parser = OpenCodeSSEParser()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard let line = try lineFramer.ingest(byte: byte) else { continue }
                        if let data = try parser.ingest(line: line) {
                            guard
                                try OpenCodeEventStream.yieldEvent(
                                    decoder.decode(OpenCodeEvent.self, from: data),
                                    to: continuation
                                )
                            else { return }
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

}
