import Foundation
import XCTest
@testable import byot

final class OpenCodeRemoteFileLiveTests: XCTestCase {
    func testLiveV1SelectedProjectBrowseSearchReadAndChanges() async throws { try await verifyFiles(major: "v1", port: 4195) }
    func testLiveV2SelectedProjectBrowseSearchReadAndChanges() async throws { try await verifyFiles(major: "v2", port: 4199) }

    private func verifyFiles(major: String, port: Int) async throws {
        guard ProcessInfo.processInfo.environment["BYOT_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Requires isolated upstream HTTPS fixture") }
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["BYOT_LIVE_ROOT"])
        let directory = root + "/" + major + "/project"
        let profile = OpenCodeServerProfile(name: "Remote file live \(major)", baseURL: "https://127.0.0.1:\(port)", directory: directory)
        let client = OpenCodeClient(profile: profile, password: "byot-local-fixture-only")
        let session = try await client.createSession(directory: directory, title: "Server file acceptance")
        let service = OpenCodeRemoteFileService(client: client, session: session, directory: directory)
        let capabilities = try await service.capabilities()
        XCTAssertEqual(capabilities, .init(search: true, browse: true, read: true, changes: major == "v2", context: true, lineSelection: major == "v2"))
        let entries = try await service.list(path: "")
        XCTAssertTrue(entries.contains { $0.path == "src" && $0.isDirectory })
        let nested = try await service.list(path: "src")
        let path = "src/acceptance #%.txt"
        XCTAssertTrue(nested.contains { $0.path == path })
        let results = try await service.search(query: "acceptance")
        XCTAssertTrue(results.contains { $0.path == path })
        let read = try await service.read(path: path)
        let expected = "BYOT remote file fixture\nSelected second line\nThird line" + (major == "v2" ? "\n" : "")
        XCTAssertEqual(read.text, expected)
        if major == "v2" {
            let changed = try await service.changes()
            XCTAssertTrue(changed.contains { $0.file == path && $0.status == "modified" })
        } else {
            do { _ = try await service.changes(); XCTFail("v1 status is a server stub, not a clean working copy") }
            catch { XCTAssertEqual(error as? OpenCodeRemoteFileError, .unsupported("changed files")) }
        }
        let reference = service.scope.reference(path: path, selection: try XCTUnwrap(.init(startLine: 2, endLine: 3)))
        XCTAssertTrue(reference.fileURL.hasSuffix("/src/acceptance%20%23%25.txt?start=2&end=3"))
        XCTAssertTrue(reference.matches(serverID: profile.id, projectID: session.projectID, directory: directory, workspaceID: session.workspaceID))
    }
}
