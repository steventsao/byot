import Foundation
import Testing
@testable import byot

/// The released OpenCode 2 line, pinned from the published
/// https://opencode.ai/openapi.json on 2026-11-02, when upstream's current 2.x
/// release was v2.2.5. The pre-GA beta contract this client was first built
/// against stays alongside it as a regression fixture: both must negotiate.
@Suite("OpenCode 2 GA contract")
struct OpenCodeV2GAContractTests {
    @Test("The released 2.x schema negotiates flat prompts, forms and project discovery")
    func releasedSchemaNegotiates() throws {
        let contract = try OpenCodeV2Contract(schema: try gaSchema())

        #expect(contract.flatPrompts)
        #expect(contract.forms)
        #expect(contract.projectList)
        #expect(contract.sessionTitle)
    }

    // GA keeps /api/permission/request but drops /api/question/request, so the
    // per-location lists must degrade to the per-session ones instead of 404ing.
    @Test("GA drops /api/question/request, so pending requests fall back to per-session lists")
    func releasedSchemaHasNoQuestionRequestList() throws {
        let contract = try OpenCodeV2Contract(schema: try gaSchema())

        #expect(contract.pendingRequestLists == false)
    }

    // Protocol detection turns on exactly this: GA serves no /api/health at all.
    @Test("GA retired /api/health and serves /api/info instead")
    func releasedSchemaRetiredHealthRoute() throws {
        let paths = try #require(try gaSchema().objectValue?["paths"]?.objectValue)

        #expect(paths["/api/health"] == nil)
        #expect(paths["/api/info"] != nil)
    }

    @Test("Every route the v2 adapter drives still exists on the released line")
    func releasedSchemaKeepsAdapterRoutes() throws {
        let paths = try #require(try gaSchema().objectValue?["paths"]?.objectValue)

        for route in [
            "/api/project",
            "/api/location",
            "/api/session",
            "/api/session/{sessionID}",
            "/api/provider",
            "/api/model",
            "/api/session/{sessionID}/message",
            "/api/session/{sessionID}/model",
            "/api/session/{sessionID}/prompt",
            "/api/session/active",
            "/api/session/{sessionID}/interrupt",
            "/api/event",
        ] {
            #expect(paths[route] != nil, "\(route) is missing from the released schema")
        }
    }

    // The released line replies to a permission with `decision`; the betas
    // used `reply`. Both negotiations are driven off the schema, so pin both.
    @Test("GA negotiates the decision permission field and DELETE form cancellation")
    func releasedSchemaNegotiatesFormAndPermissionShapes() throws {
        let schema = try gaSchema()

        #expect(OpenCodeV2Contract.permissionReplyField(schema) == "decision")
        #expect(OpenCodeV2Contract.cancelsFormsWithDelete(schema))
    }

    private func gaSchema() throws -> OpenCodeJSONValue {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/opencode2-ga-20261102-openapi.json")
        return try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(contentsOf: url))
    }
}
