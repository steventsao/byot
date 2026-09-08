import Foundation
import Testing

@testable import byot

@Suite("OpenCode service composition", .timeLimit(.minutes(1)))
struct OpenCodeConnectionLayerTests {
    @Test("Concurrent client copies share discovery and schema acquisition")
    func sharesAcquisition() async throws {
        let transport = LayerTestTransport()
        let client = OpenCodeClient(profile: testProfile, transport: transport)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                let copy = client
                group.addTask {
                    let statuses = try await copy.sessionStatuses(directory: "/repo")
                    #expect(statuses.isEmpty)
                }
            }
            try await group.waitForAll()
        }
        #expect(await transport.count("/global/health") == 1)
        #expect(await transport.count("/api/health") == 1)
        #expect(await transport.count("/openapi.json") == 1)
        #expect(await transport.count("/api/session/active") == 20)
    }

    @Test("A stale schema finishing after refresh cannot replace the new adapter")
    func refreshDuringAcquisition() async throws {
        let gate = LayerTestGate()
        let source = ControlledConnectionSource(firstBuildGate: gate)
        let connection = OpenCodeConnection(source: source, serverProtocol: .v2)
        let stale = Task { try await connection.adapter() }
        await source.buildStarted.wait()
        _ = try await connection.probe()
        let refreshed = try await connection.adapter()
        #expect(refreshed.usesForms)
        // Deliberately let the old source ignore cancellation and finish late.
        await gate.open()
        let originalCaller = try await stale.value
        #expect(originalCaller.usesForms)
        #expect(try await connection.adapter().usesForms)
        #expect(await source.buildCount == 2)
    }

    @Test("Cancelling one waiter preserves shared acquisition for other consumers")
    func cancellationIsLocalToWaiter() async throws {
        let gate = LayerTestGate()
        let source = ControlledConnectionSource(firstBuildGate: gate)
        let connection = OpenCodeConnection(source: source, serverProtocol: .v2)
        let cancelled = Task { try await connection.adapter() }
        await source.buildStarted.wait()
        cancelled.cancel()
        let survivor = Task { try await connection.adapter() }
        await gate.open()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await survivor.value.serverProtocol == .v2)
        #expect(await source.buildCount == 1)
        #expect(await source.wasBuildCancelled == false)
    }

    @Test("Cancelled health waiters do not poison discovery for the next consumer")
    func cancellationDuringProbe() async throws {
        let gate = LayerTestGate()
        let source = ControlledConnectionSource(probeGate: gate)
        let connection = OpenCodeConnection(source: source)
        let cancelled = Task { try await connection.adapter() }
        await source.probeStarted.wait()
        cancelled.cancel()
        await gate.open()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await connection.adapter().serverProtocol == .v2)
        #expect(await source.probeCount == 1)
        #expect(await source.buildCount == 1)
    }

    @Test("Failed schema acquisition is retryable")
    func failedAcquisitionRetries() async throws {
        let source = ControlledConnectionSource(failFirstBuild: true)
        let connection = OpenCodeConnection(source: source, serverProtocol: .v2)
        await #expect(throws: LayerTestFailure.self) { try await connection.adapter() }
        #expect(try await connection.adapter().serverProtocol == .v2)
        #expect(await source.buildCount == 2)
    }

    @Test("A failed refresh discards the old protocol and can be retried")
    func failedRefreshRetries() async throws {
        let source = ControlledConnectionSource(failFirstProbe: true)
        let connection = OpenCodeConnection(source: source, serverProtocol: .v1)
        #expect(try await connection.adapter().serverProtocol == .v1)
        await #expect(throws: LayerTestFailure.self) { try await connection.probe() }
        #expect(try await connection.adapter().serverProtocol == .v2)
        #expect(await source.probeCount == 2)
        #expect(await source.buildCount == 2)
    }

    @Test("Separate connection scopes never reuse another server's adapter")
    func independentScopes() async throws {
        let source = ControlledConnectionSource()
        let first = OpenCodeConnection(source: source, serverProtocol: .v1)
        let second = OpenCodeConnection(source: source, serverProtocol: .v2)
        #expect(try await first.adapter().serverProtocol == .v1)
        #expect(try await second.adapter().serverProtocol == .v2)
        #expect(try await first.adapter().serverProtocol == .v1)
        #expect(await source.buildCount == 2)
    }
}

private let testProfile = OpenCodeServerProfile(name: "Layer test", baseURL: "https://layers.test")
private enum LayerTestFailure: Error { case unavailable }

// Async signals make the overlap deterministic without sleep-based assertions.
private actor LayerTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor ControlledConnectionSource: OpenCodeConnectionSource {
    let buildStarted = LayerTestGate()
    let probeStarted = LayerTestGate()
    private let firstBuildGate: LayerTestGate?
    private let probeGate: LayerTestGate?
    private let failFirstBuild: Bool
    private let failFirstProbe: Bool
    private(set) var buildCount = 0
    private(set) var probeCount = 0
    private(set) var wasBuildCancelled = false

    init(
        firstBuildGate: LayerTestGate? = nil, probeGate: LayerTestGate? = nil, failFirstBuild: Bool = false,
        failFirstProbe: Bool = false
    ) {
        self.firstBuildGate = firstBuildGate
        self.probeGate = probeGate
        self.failFirstBuild = failFirstBuild
        self.failFirstProbe = failFirstProbe
    }

    func probe() async throws -> OpenCodeServerProbe {
        probeCount += 1
        await probeStarted.open()
        if let probeGate { await probeGate.wait() }
        if failFirstProbe, probeCount == 1 { throw LayerTestFailure.unavailable }
        return OpenCodeServerProbe(
            protocol: .v2, health: OpenCodeHealth(healthy: true, version: "0.0.0-beta-19271"))
    }

    func makeAdapter(for serverProtocol: OpenCodeServerProtocol) async throws -> any OpenCodeProtocolAdapting
    {
        buildCount += 1
        let build = buildCount
        await buildStarted.open()
        if build == 1, let firstBuildGate { await firstBuildGate.wait() }
        wasBuildCancelled = Task.isCancelled
        if failFirstBuild, build == 1 { throw LayerTestFailure.unavailable }
        if serverProtocol == .v1 {
            return OpenCodeV1Adapter(transport: LayerTestTransport(), profile: testProfile)
        }
        return OpenCodeV2Adapter(
            contract: try OpenCodeV2Contract(
                schema: JSONDecoder().decode(OpenCodeJSONValue.self, from: layerSchema(forms: build > 1))),
            transport: LayerTestTransport(),
            profile: testProfile
        )
    }
}

private actor LayerTestTransport: OpenCodeHTTPTransport {
    private var paths: [String: Int] = [:]

    func count(_ path: String) -> Int { paths[path, default: 0] }

    nonisolated func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws
        -> URLRequest
    {
        let url = try #require(URL(string: "https://layers.test/" + path.joined(separator: "/")))
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        return request
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        paths[url.path, default: 0] += 1
        let body: Data
        let contentType: String
        switch url.path {
        case "/global/health":
            body = Data("<html></html>".utf8)
            contentType = "text/html"
        case "/api/health":
            body = Data(#"{"healthy":true,"pid":1}"#.utf8)
            contentType = "application/json"
        case "/openapi.json":
            body = layerSchema(forms: true)
            contentType = "application/json"
        case "/api/session/active":
            body = Data(#"{"data":{}}"#.utf8)
            contentType = "application/json"
        default:
            Issue.record("Unexpected request: \(url.path)")
            throw LayerTestFailure.unavailable
        }
        return (
            body,
            try #require(
                HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": contentType]))
        )
    }

    nonisolated func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<
        OpenCodeEvent, Error
    > {
        AsyncThrowingStream { $0.finish(throwing: LayerTestFailure.unavailable) }
    }
}

private func layerSchema(forms: Bool) -> Data {
    let form = forms ? #", "/api/session/{sessionID}/form": {}"# : ""
    return Data(
        """
        {"paths":{"/api/session/{sessionID}/prompt":{"post":{"requestBody":{"content":{"application/json":{"schema":{"properties":{"text":{}}}}}}}}\(form)}}
        """.utf8)
}
