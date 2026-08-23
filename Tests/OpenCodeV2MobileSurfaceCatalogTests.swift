import Testing
@testable import byot

struct OpenCodeV2MobileSurfaceCatalogTests {
    private let catalog = OpenCodeV2MobileSurfaceCatalog.current

    @Test("Every issue 17 surface has one explicit mobile decision")
    func completeCatalog() {
        #expect(catalog.decisions.count == OpenCodeV2Surface.allCases.count)
        #expect(Set(catalog.decisions.map(\.surface)) == Set(OpenCodeV2Surface.allCases))
    }

    @Test("Only routes in the pinned v2 schema are advertised as present")
    func pinnedRoutePresence() {
        #expect(catalog[.pty].endpoint == .present(path: "/api/pty"))
        #expect(catalog[.skill].endpoint == .present(path: "/api/skill"))
        #expect(catalog[.integration].endpoint == .present(path: "/api/integration"))

        #expect(catalog[.shell].endpoint == .absentFromPinnedSchema)
        #expect(catalog[.worktree].endpoint == .absentFromPinnedSchema)
        #expect(catalog[.webSearch].endpoint == .absentFromPinnedSchema)
        #expect(catalog[.oneShotGenerate].endpoint == .absentFromPinnedSchema)
    }

    @Test("Absent routes can never be selected for mobile adoption")
    func noSpeculativeAdoption() {
        let absent = catalog.decisions.filter { $0.endpoint == .absentFromPinnedSchema }

        #expect(absent.allSatisfy { !$0.disposition.isAdopted })
        #expect(absent.allSatisfy { $0.disposition.explanation != nil })
    }

    @Test("PTY requires a complete terminal experience before adoption")
    func ptyDecision() {
        let disposition = catalog[.pty].disposition

        #expect(!disposition.isAdopted)
        #expect(disposition.explanation?.contains("single-use WebSocket ticket") == true)
        #expect(disposition.explanation?.contains("terminal emulation") == true)
    }

    @Test("Integration work is routed to its existing issue")
    func integrationDecision() {
        #expect(catalog[.integration].disposition == .ownedByIssue(7))
    }

    @Test("Skills need no separate mobile management screen")
    func skillDecision() {
        #expect(catalog[.skill].disposition.isAdopted)
        #expect(catalog[.skill].disposition.explanation?.contains("server") == true)
    }
}
