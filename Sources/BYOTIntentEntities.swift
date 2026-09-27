import AppIntents
import Foundation

// Servers, projects and sessions as Siri and Shortcuts see them. Identifiers
// only hold what byot needs to find the item again; names are looked up.

struct OpenCodeServerEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OpenCode Server")
    static let defaultQuery = OpenCodeServerQuery()

    let id: UUID
    let name: String
    let host: String

    init(_ profile: OpenCodeServerProfile) {
        id = profile.id
        name = profile.name
        host = profile.normalizedURL?.host() ?? profile.baseURL
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(host)", image: .init(systemName: "server.rack"))
    }
}

struct OpenCodeServerQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [OpenCodeServerEntity] {
        let profiles = BYOTIntentService.live.profiles()
        return identifiers.compactMap { id in profiles.first { $0.id == id }.map(OpenCodeServerEntity.init) }
    }

    func entities(matching string: String) async throws -> [OpenCodeServerEntity] {
        try await suggestedEntities().filter {
            $0.name.localizedStandardContains(string) || $0.host.localizedStandardContains(string)
        }
    }

    func suggestedEntities() async throws -> [OpenCodeServerEntity] {
        BYOTIntentService.live.profiles().map(OpenCodeServerEntity.init)
    }

    /// The server byot last showed, so Siri only asks when you mean another.
    func defaultResult() async -> OpenCodeServerEntity? {
        (try? BYOTIntentService.live.profile(nil)).map(OpenCodeServerEntity.init)
    }
}

struct OpenCodeProjectEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OpenCode Project")
    static let defaultQuery = OpenCodeProjectQuery()

    let project: BYOTIntentProject
    var id: String { project.id }

    init(_ project: BYOTIntentProject) {
        self.project = project
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(project.name)", subtitle: "\(project.directory)",
                              image: .init(systemName: "folder"))
    }
}

struct OpenCodeProjectQuery: EntityStringQuery {
    /// Ask OpenCode lists the chosen server's projects.
    @IntentParameterDependency<AskOpenCodeIntent>(\.$server) var ask

    func entities(for identifiers: [String]) async throws -> [OpenCodeProjectEntity] {
        let known = await BYOTIntentEntityCache.projects
        return identifiers.compactMap { id in
            if let project = known[id] { return OpenCodeProjectEntity(project) }
            guard let (serverID, directory) = BYOTIntentProject.parse(id) else { return nil }
            return OpenCodeProjectEntity(BYOTIntentProject(serverID: serverID, directory: directory,
                                                           name: URL(fileURLWithPath: directory).lastPathComponent))
        }
    }

    func entities(matching string: String) async throws -> [OpenCodeProjectEntity] {
        try await suggestedEntities().filter {
            $0.project.name.localizedStandardContains(string) || $0.project.directory.localizedStandardContains(string)
        }
    }

    func suggestedEntities() async throws -> [OpenCodeProjectEntity] {
        let projects = try await BYOTIntentService.live.projects(serverID: ask?.server.id)
        await BYOTIntentEntityCache.remember(projects)
        return projects.map(OpenCodeProjectEntity.init)
    }
}

struct OpenCodeSessionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "OpenCode Session")
    static let defaultQuery = OpenCodeSessionQuery()

    let session: BYOTIntentSession
    var id: String { session.id }

    @Property(title: "Title") var title: String
    @Property(title: "Project") var project: String
    @Property(title: "Server") var server: String
    @Property(title: "Status") var status: String

    init(_ session: BYOTIntentSession) {
        self.session = session
        title = session.title
        project = session.projectName
        server = session.serverName
        status = session.state?.title ?? "Idle"
    }

    var displayRepresentation: DisplayRepresentation {
        let detail = [session.state?.title, session.projectName, session.serverName].compactMap { $0 }
        return DisplayRepresentation(title: "\(session.title)", subtitle: "\(detail.joined(separator: " · "))",
                                     image: .init(systemName: session.state?.symbol ?? "bubble.left.and.text.bubble.right"))
    }
}

struct OpenCodeSessionQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [OpenCodeSessionEntity] {
        let known = await BYOTIntentEntityCache.sessions
        let snapshot = BYOTWidgetSnapshotStore().load().sessions.map(BYOTIntentSession.init)
        var result: [OpenCodeSessionEntity] = []
        for id in identifiers {
            guard let link = URL(string: id).flatMap(BYOTWidgetLink.init(url:)) else { continue }
            if let session = known[id] ?? snapshot.first(where: { $0.id == id }) {
                result.append(OpenCodeSessionEntity(session))
            } else if let session = await BYOTIntentService.live.session(link) {
                result.append(OpenCodeSessionEntity(session))
            }
        }
        return result
    }

    func entities(matching string: String) async throws -> [OpenCodeSessionEntity] {
        try await suggestedEntities().filter {
            $0.session.title.localizedStandardContains(string)
                || $0.session.projectName.localizedStandardContains(string)
        }
    }

    func suggestedEntities() async throws -> [OpenCodeSessionEntity] {
        let sessions = try await BYOTIntentService.live.recentSessions()
        await BYOTIntentEntityCache.remember(sessions)
        return sessions.map(OpenCodeSessionEntity.init)
    }
}

/// Names seen during this launch, so resolving a chosen project or session
/// doesn't need another round trip to the server.
@MainActor
enum BYOTIntentEntityCache {
    private(set) static var projects: [String: BYOTIntentProject] = [:]
    private(set) static var sessions: [String: BYOTIntentSession] = [:]

    static func remember(_ projects: [BYOTIntentProject]) {
        for project in projects { self.projects[project.id] = project }
    }

    static func remember(_ sessions: [BYOTIntentSession]) {
        for session in sessions { self.sessions[session.id] = session }
    }
}
