import Foundation

enum OpenCodeV2Surface: String, CaseIterable, Hashable, Sendable {
    case pty
    case skill
    case integration
    case shell
    case worktree
    case webSearch
    case oneShotGenerate
}

enum OpenCodeV2EndpointAvailability: Equatable, Sendable {
    case present(path: String)
    case absentFromPinnedSchema
}

enum OpenCodeV2MobileDisposition: Equatable, Sendable {
    case adopted(explanation: String)
    case ownedByIssue(Int)
    case deferred(reason: String)
    case unavailable(reason: String)

    var isAdopted: Bool {
        switch self {
        case .adopted, .ownedByIssue:
            true
        case .deferred, .unavailable:
            false
        }
    }

    var explanation: String? {
        switch self {
        case .adopted(let explanation), .deferred(let explanation), .unavailable(let explanation):
            explanation
        case .ownedByIssue(let number):
            "Tracked by issue #\(number)."
        }
    }
}

struct OpenCodeV2MobileSurfaceDecision: Equatable, Sendable {
    let surface: OpenCodeV2Surface
    let endpoint: OpenCodeV2EndpointAvailability
    let disposition: OpenCodeV2MobileDisposition
}

struct OpenCodeV2MobileSurfaceCatalog: Equatable, Sendable {
    static let pinnedOpenCodeCommit = "3a31c4ea801915c0b050df4b3842997ea62b6e93"

    let decisions: [OpenCodeV2MobileSurfaceDecision]

    subscript(surface: OpenCodeV2Surface) -> OpenCodeV2MobileSurfaceDecision {
        guard let decision = decisions.first(where: { $0.surface == surface }) else {
            preconditionFailure("Missing OpenCode v2 mobile decision for \(surface.rawValue)")
        }
        return decision
    }

    static let current = Self(decisions: [
        .init(
            surface: .pty,
            endpoint: .present(path: "/api/pty"),
            disposition: .deferred(
                reason: "A useful PTY requires the single-use WebSocket ticket flow and terminal emulation; a REST-only process list would imply terminal support that the app does not provide."
            )
        ),
        .init(
            surface: .skill,
            endpoint: .present(path: "/api/skill"),
            disposition: .adopted(
                explanation: "The server discovers and executes skills; no separate mobile management screen is required."
            )
        ),
        .init(
            surface: .integration,
            endpoint: .present(path: "/api/integration"),
            disposition: .ownedByIssue(7)
        ),
        .init(
            surface: .shell,
            endpoint: .absentFromPinnedSchema,
            disposition: .unavailable(
                reason: "The pinned current v2 schema exposes no shell route."
            )
        ),
        .init(
            surface: .worktree,
            endpoint: .absentFromPinnedSchema,
            disposition: .unavailable(
                reason: "The pinned current v2 schema exposes no worktree route."
            )
        ),
        .init(
            surface: .webSearch,
            endpoint: .absentFromPinnedSchema,
            disposition: .unavailable(
                reason: "The pinned current v2 schema exposes no web-search route."
            )
        ),
        .init(
            surface: .oneShotGenerate,
            endpoint: .absentFromPinnedSchema,
            disposition: .unavailable(
                reason: "The pinned current v2 schema exposes no one-shot generation route."
            )
        ),
    ])
}
