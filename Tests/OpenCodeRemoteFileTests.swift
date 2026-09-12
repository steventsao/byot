import Foundation
import XCTest
@testable import byot

final class OpenCodeRemoteFileTests: XCTestCase {
    private let profile = OpenCodeServerProfile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, name: "Files", baseURL: "https://files.example.test/opencode")
    private var scope: OpenCodeRemoteFileScope { .init(serverID: profile.id, serverName: profile.name, projectID: "pro_test", directory: "/repo/My Project", workspaceID: "wrk_test") }

    func testRemoteURLsPreserveReservedCharactersAndLinesWithoutUsingDeviceFilesystem() throws {
        let reference = scope.reference(path: "src/a #?%你好.swift", selection: try XCTUnwrap(.init(startLine: 2, endLine: 4)))
        XCTAssertEqual(reference.v1URL, "file:///repo/My%20Project/src/a%20%23%3F%25%E4%BD%A0%E5%A5%BD.swift?start=2&end=4")
        XCTAssertEqual(reference.v2URI, reference.v1URL)
        XCTAssertEqual(try JSONDecoder().decode(OpenCodePromptFileReference.self, from: JSONEncoder().encode(reference)), reference)
        XCTAssertTrue(reference.matches(serverID: profile.id, projectID: "pro_test", directory: scope.directory, workspaceID: "wrk_test"))
        XCTAssertFalse(reference.matches(serverID: UUID(), projectID: "pro_test", directory: scope.directory, workspaceID: "wrk_test"))
        XCTAssertFalse(reference.matches(serverID: profile.id, projectID: "pro_test", directory: scope.directory, workspaceID: nil))
        XCTAssertFalse(reference.matches(serverID: profile.id, projectID: "other", directory: scope.directory, workspaceID: "wrk_test"))
    }

    func testNormalizedServerFileSourceRestoresReferenceAndLineSelection() throws {
        let reference = scope.reference(path: "src/a #%.swift", selection: try XCTUnwrap(.init(startLine: 2, endLine: 4)))
        let source: OpenCodeJSONValue = .object(["id": .string("msg_file"), "type": .string("user"), "text": .string("Inspect this"),
            "time": .object(["created": .number(1)]),
            "files": .array([.object(["name": .string(reference.filename), "mime": .string("text/plain"),
                "data": .string("Ym9keQ=="), "source": .object(["type": .string("uri"), "uri": .string(reference.fileURL)])])])])
        let message = try XCTUnwrap(OpenCodeV2Normalization.message(try XCTUnwrap(source.objectValue), sessionID: "ses_file"))
        XCTAssertEqual(message.parts.last?.url, reference.fileURL)
        let restored = OpenCodePromptFileReference.restored(from: message, serverID: profile.id,
            projectID: scope.projectID, directory: scope.directory, workspaceID: scope.workspaceID)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.path, reference.path)
        XCTAssertEqual(restored.first?.selection, reference.selection)
        XCTAssertEqual(restored.first?.workspaceID, "wrk_test")
    }

    func testWindowsNewlinesPreserveServerLineNumbers() {
        let content = OpenCodeRemoteFileContent(path: "file.txt", text: "one\r\ntwo\r\nthree", mimeType: "text/plain", byteCount: 15)
        XCTAssertEqual(content.lines, ["one", "two", "three"])
    }

    func testWindowsContextUsesRemoteDriveAndEscapesURI() {
        let reference = OpenCodePromptFileReference(serverID: profile.id, projectID: "p", directory: "C:\\work\\my app", path: "src\\a#b.swift")
        XCTAssertEqual(reference.fileURL, "file:///C:/work/my%20app/src/a%23b.swift")
    }

    func testInvalidLinesAndPathsCannotBecomeContextOrReadAnotherProject() throws {
        XCTAssertNil(OpenCodeFileLineRange(startLine: 0, endLine: 5))
        XCTAssertNil(OpenCodeFileLineRange(startLine: 5, endLine: 4))
        XCTAssertThrowsError(try JSONDecoder().decode(OpenCodeFileLineRange.self, from: Data(#"{"startLine":9,"endLine":1}"#.utf8)))
        XCTAssertThrowsError(try scope.relativePath("../private.txt"))
        XCTAssertThrowsError(try scope.relativePath("/repo/My Project-Other/private.txt"))
        XCTAssertThrowsError(try scope.relativePath("src/../private.txt"))
        XCTAssertEqual(try scope.relativePath("/repo/My Project/src/a.swift"), "src/a.swift")
    }

    func testV1RoutesUseSelectedDirectoryAndWorkspace() async throws {
        let transport = FileTestTransport(profile: profile) { request in
            switch request.url!.path {
            case "/opencode/find/file": return .json(["src/a.swift"])
            case "/opencode/file": return .json([["path": "src", "type": "directory", "name": "src", "absolute": "/repo/My Project/src", "ignored": false]])
            case "/opencode/file/status": return .json([["file": "src/a.swift", "additions": 3, "deletions": 1, "status": "modified"]])
            default: return .json(["type": "text", "content": "one\ntwo", "mimeType": "text/plain"])
            }
        }
        let service = makeService(transport: transport, protocol: .v1)
        let found = try await service.search(query: "a#%?")
        XCTAssertEqual(found.first?.path, "src/a.swift")
        let listed = try await service.list(path: "")
        XCTAssertEqual(listed.first?.type, "directory")
        let changes = try await service.changes()
        XCTAssertEqual(changes.first?.additions, 3)
        let read = try await service.read(path: "src/a.swift")
        XCTAssertEqual(read.text, "one\ntwo")
        for request in transport.requests {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "directory" }?.value, scope.directory)
            XCTAssertEqual(query.first { $0.name == "workspace" }?.value, "wrk_test")
        }
        XCTAssertEqual(URLComponents(url: transport.requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "query" }?.value, "a#%?")
    }

    func testPinnedV2SchemaAndExactFileContracts() async throws {
        let transport = FileTestTransport(profile: profile) { request in
            if request.url!.path.contains("/read/") { return .init(data: Data("let value = 42\n".utf8), mime: "application/octet-stream") }
            if request.url!.path.hasSuffix("/status") { return self.envelope([["file": "src/a.swift", "additions": 2, "deletions": 0, "status": "added"]]) }
            return self.envelope([["path": "src/a #?%.swift", "type": "file"]])
        }
        let service = makeService(transport: transport, protocol: .v2, schema: try schema())
        let caps = try await service.capabilities()
        XCTAssertEqual(caps, .init(search: true, browse: true, read: true, changes: true, context: true))
        _ = try await service.search(query: "a")
        _ = try await service.list(path: "src")
        _ = try await service.changes()
        let content = try await service.read(path: "src/a #?%.swift")
        XCTAssertEqual(content.text, "let value = 42\n")
        XCTAssertEqual(transport.requests.map { $0.url!.path }, ["/opencode/api/fs/find", "/opencode/api/fs/list", "/opencode/api/vcs/status", "/opencode/api/fs/read/src/a #?%.swift"])
        let readURL = transport.requests.last!.url!
        XCTAssertTrue(readURL.absoluteString.contains("a%20%23%3F%25.swift"))
        XCTAssertEqual(URLComponents(url: readURL, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "location[directory]", value: scope.directory), URLQueryItem(name: "location[workspace]", value: "wrk_test")])
    }

    func testMissingV2RoutesDoNotIssueGuessedRequests() async throws {
        let transport = FileTestTransport(profile: profile) { _ in .json([]) }
        let service = makeService(transport: transport, protocol: .v2, schema: .object(["paths": .object([:])]))
        let caps = try await service.capabilities()
        XCTAssertEqual(caps, .init(search: false, browse: false, read: false, changes: false, context: false))
        do { _ = try await service.read(path: "a.swift"); XCTFail("Read must be unavailable") } catch { XCTAssertEqual(error as? OpenCodeRemoteFileError, .unsupported("file previews")) }
        do { _ = try await service.search(query: "a"); XCTFail("Search must be unavailable") } catch {}
        do { _ = try await service.changes(); XCTFail("Changes must be unavailable") } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testWrongLocationResponseIsRejected() async throws {
        let transport = FileTestTransport(profile: profile) { _ in
            .json(["location": ["directory": "/wrong", "project": ["id": "pro_test"]], "data": [["path": "private.txt", "type": "file"]]])
        }
        let service = makeService(transport: transport, protocol: .v2, schema: try schema())
        do { _ = try await service.search(query: "private"); XCTFail("Wrong project must be rejected") }
        catch { XCTAssertEqual(error as? OpenCodeRemoteFileError, .wrongLocation) }
    }

    func testProductionTransportBoundsDeclaredAndStreamingResponses() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FileLimitProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let transport = OpenCodeTransport(profile: profile, password: "test", session: session)
        for kind in ["declared-large", "streaming-large"] {
            let request = try transport.makeRequest(path: [kind], query: [], method: "GET", body: nil)
            do {
                _ = try await transport.boundedData(for: request, maximumBytes: 4)
                XCTFail("Oversize response should stop")
            } catch { XCTAssertTrue(error is OpenCodeResponseSizeLimitError) }
        }
        let request = try transport.makeRequest(path: ["within-limit"], query: [], method: "GET", body: nil)
        let response = try await transport.boundedData(for: request, maximumBytes: 4)
        XCTAssertEqual(response.0, Data("ABCD".utf8))
    }

    func testBinaryAndTooLargeFilesAreNotRenderedAsCode() async throws {
        let binary = FileTestTransport(profile: profile) { _ in .init(data: Data([0, 255, 4]), mime: "image/png") }
        let service = makeService(transport: binary, protocol: .v2, schema: try schema())
        let content = try await service.read(path: "logo.png")
        XCTAssertNil(content.text)
        let huge = FileTestTransport(profile: profile) { _ in .init(data: Data(repeating: 65, count: OpenCodeRemoteFileService.maximumPreviewBytes + 1), mime: "text/plain") }
        do { _ = try await makeService(transport: huge, protocol: .v2, schema: schema()).read(path: "large.txt"); XCTFail("Preview must be bounded") }
        catch { XCTAssertEqual(error as? OpenCodeRemoteFileError, .tooLarge) }
    }

    func testOnlyExplicitMentionSearchIsRemovedOnContextSelection() {
        XCTAssertNil(OpenCodeFileMention.query(in: "mail me@example.com"))
        XCTAssertNil(OpenCodeFileMention.query(in: "@file is mentioned"))
        XCTAssertEqual(OpenCodeFileMention.query(in: "Explain @src/a"), "src/a")
        XCTAssertEqual(OpenCodeFileMention.removingQuery(from: "Explain @src/a"), "Explain ")
    }

    @MainActor func testStaleFilePreviewCannotReplaceNewerSelection() async throws {
        let store = OpenCodeRemoteFileStore(service: DelayedFileService(scope: scope))
        let first = Task { await store.read(path: "slow.swift") }
        try await Task.sleep(for: .milliseconds(10))
        await store.read(path: "new.swift")
        await first.value
        XCTAssertEqual(store.content?.path, "new.swift")
        XCTAssertFalse(store.isReading)
    }

    private func schema() throws -> OpenCodeJSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/opencode2-beta-19242-openapi.json")
        return try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(contentsOf: url))
    }
    private func makeService(transport: FileTestTransport, protocol value: OpenCodeServerProtocol, schema: OpenCodeJSONValue? = nil) -> OpenCodeRemoteFileService {
        let context = OpenCodeFeatureContext(serverProtocol: value, schema: schema, transport: transport, profile: profile)
        return .init(scope: scope) { context }
    }
    private func envelope(_ data: Any) -> FileTestTransport.Response {
        .json(["location": ["directory": scope.directory, "workspaceID": "wrk_test", "project": ["id": "pro_test"]], "data": data])
    }
}

private final class FileTestTransport: OpenCodeHTTPTransport, @unchecked Sendable {
    struct Response {
        let data: Data
        let mime: String
        static func json(_ value: Any) -> Self { .init(data: try! JSONSerialization.data(withJSONObject: value), mime: "application/json") }
    }
    let base: OpenCodeTransport
    let respond: (URLRequest) -> Response
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    init(profile: OpenCodeServerProfile, respond: @escaping (URLRequest) -> Response) {
        base = .init(profile: profile, password: "test", session: .shared); self.respond = respond
    }
    func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?) throws -> URLRequest {
        try base.makeRequest(path: path, query: query, method: method, body: body)
    }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(request) }
        let response = respond(request)
        return (response.data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": response.mime])!)
    }
    func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<OpenCodeEvent, Error> { .init { $0.finish() } }
}

private struct DelayedFileService: OpenCodeRemoteFileServicing {
    let scope: OpenCodeRemoteFileScope
    func capabilities() async throws -> OpenCodeRemoteFileCapabilities { .init(search: true, browse: true, read: true, changes: true, context: true) }
    func search(query: String) async throws -> [OpenCodeRemoteFileEntry] { [] }
    func list(path: String) async throws -> [OpenCodeRemoteFileEntry] { [] }
    func changes() async throws -> [OpenCodeRemoteFileChange] { [] }
    func read(path: String) async throws -> OpenCodeRemoteFileContent {
        if path == "slow.swift" { try await Task.sleep(for: .milliseconds(150)) }
        return .init(path: path, text: path, mimeType: "text/plain", byteCount: path.utf8.count)
    }
}

private final class FileLimitProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url else { return }
        let kind = url.lastPathComponent
        let header = kind == "declared-large" ? ["Content-Length": "1000000000"] : [:]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: header)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((kind == "within-limit" ? "ABCD" : "ABCDEFGH").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
