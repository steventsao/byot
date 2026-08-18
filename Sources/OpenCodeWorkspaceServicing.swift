import Foundation

protocol OpenCodeWorkspaceServicing: Sendable {
    func probeCompatibility() async throws -> OpenCodeCompatibilitySummary
    func listProjects() async throws -> [OpenCodeProject]
}

extension OpenCodeClient: OpenCodeWorkspaceServicing { }
