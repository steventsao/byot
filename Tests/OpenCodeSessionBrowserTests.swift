import Foundation
import Testing
@testable import byot

@MainActor
struct OpenCodeSessionBrowserTests {
    @Test("Sessions remain available when status fails, without inventing idle")
    func statusFailurePreservesSessions() async {
        let service = BrowserService()
        await service.setStatusFailure(true)
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/one")])
        #expect(store.sessions.map(\.id) == ["/one"])
        #expect(store.statuses.isEmpty)
        #expect(store.groups[0].error?.contains("Status unavailable") == true)
    }

    @Test("A failed project does not hide sessions from other projects")
    func partialFailure() async {
        let service = BrowserService()
        await service.setFailedDirectory("/bad")
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/bad"), project("/good")])
        #expect(store.sessions.map(\.id) == ["/good"])
        #expect(store.groups.first { $0.id == "/bad" }?.error != nil)
        #expect(store.groups.first { $0.id == "/good" }?.error == nil)
        #expect(store.orderedGroups(by: .status).first?.id == "/bad")
    }

    @Test("Refreshing failure keeps loaded sessions but marks failed status unknown")
    func refreshFailureKeepsContent() async {
        let service = BrowserService()
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/one")])
        await service.setFailedDirectory("/one")
        await service.setStatusFailure(true)
        await store.load(projects: [project("/one")])
        #expect(store.sessions.count == 1)
        #expect(store.statuses.isEmpty)
        #expect(store.groups[0].error != nil)
    }

    @Test("Newer refresh wins over a slow previous request")
    func staleLoadCannotReplaceNewProjects() async throws {
        let service = BrowserService()
        let store = OpenCodeSessionBrowserStore(service: service)
        let old = Task { await store.load(projects: [project("/slow")]) }
        while await service.calls.isEmpty { await Task.yield() }
        await store.load(projects: [project("/new")])
        await old.value
        #expect(store.groups.map(\.id) == ["/new"])
        #expect(store.sessions.map(\.id) == ["/new"])
        #expect(!store.isLoading)
    }

    @Test("A fast project is published before the slow project completes")
    func progressiveLoading() async throws {
        let service = BrowserService()
        let store = OpenCodeSessionBrowserStore(service: service)
        let loading = Task { await store.load(projects: [project("/slow"), project("/fast")]) }
        for _ in 0..<100 where !store.sessions.contains(where: { $0.id == "/fast" }) {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(store.sessions.contains { $0.id == "/fast" })
        #expect(store.isLoading)
        await loading.value
        #expect(store.sessions.count == 2)
    }

    @Test("Configured-directory overlap does not request the same directory twice")
    func duplicateProjects() async {
        let service = BrowserService()
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/one"), project("/one")])
        #expect(store.groups.count == 1)
        #expect(store.sessions.count == 1)
        #expect(await service.calls == ["/one"])
    }

    @Test("Recency, status and title sorting are independent and deterministic")
    func sorting() {
        let a = session("a", title: "Zebra", updated: 30)
        let b = session("b", title: "Alpha", updated: 10)
        let c = session("c", title: "Beta", updated: 20)
        let statuses: [String: OpenCodeSessionStatus] = ["a": .idle, "b": .busy, "c": .retry(attempt: 1, message: "Rate limited", next: 0)]
        #expect(OpenCodeSessionSort.recent.ordered([b,c,a], statuses: statuses).map(\.id) == ["a","c","b"])
        #expect(OpenCodeSessionSort.status.ordered([a,b,c], statuses: statuses).map(\.id) == ["c","b","a"])
        #expect(OpenCodeSessionSort.name.ordered([c,b,a], statuses: statuses).map(\.id) == ["b","c","a"])
    }

    @Test("Child and archived sessions are excluded from the main browser")
    func excludesHiddenSessions() async {
        let service = BrowserService()
        await service.setExtraSessions([
            session("child", parent: "root"), session("archived", archived: 10), session("visible")
        ])
        let store = OpenCodeSessionBrowserStore(service: service)
        await store.load(projects: [project("/one")])
        #expect(Set(store.sessions.map(\.id)) == ["/one", "visible"])
    }

    private func project(_ directory: String) -> OpenCodeProject {
        OpenCodeProject(id: directory, worktree: directory, vcs: nil, name: nil,
                        time: OpenCodeProjectTime(created: 1, updated: 2), sandboxes: [])
    }
    private func session(_ id: String, title: String = "Session", updated: Double = 1, parent: String? = nil, archived: Double? = nil) -> OpenCodeSession {
        OpenCodeSession(id: id, slug: id, projectID: "/one", workspaceID: nil, directory: "/one", parentID: parent, summary: nil, title: title, agent: nil, version: "1.18.10", time: OpenCodeSessionTime(created: 1, updated: updated, compacting: nil, archived: archived))
    }
}

private actor BrowserService: OpenCodeSessionBrowsing {
    private(set) var calls: [String] = []
    private var failedDirectory: String?
    private var statusFailure = false
    private var extraSessions: [OpenCodeSession] = []
    func setFailedDirectory(_ value: String) { failedDirectory = value }
    func setStatusFailure(_ value: Bool) { statusFailure = value }
    func setExtraSessions(_ value: [OpenCodeSession]) { extraSessions = value }
    func listSessions(directory: String) async throws -> [OpenCodeSession] {
        calls.append(directory)
        if directory == "/slow" { try await Task.sleep(for: .milliseconds(350)) }
        if directory == failedDirectory { throw OpenCodeConnectionError.httpStatus(500, nil) }
        return [OpenCodeSession(id: directory, slug: directory, projectID: directory, workspaceID: nil, directory: directory, parentID: nil, summary: nil, title: directory, agent: nil, version: "1.18.10", time: OpenCodeSessionTime(created: 1, updated: 2, compacting: nil, archived: nil))] + extraSessions
    }
    func sessionStatuses(directory: String, workspace: String?) async throws -> [String: OpenCodeSessionStatus] {
        if statusFailure { throw OpenCodeConnectionError.httpStatus(503, nil) }
        return [:]
    }
}
