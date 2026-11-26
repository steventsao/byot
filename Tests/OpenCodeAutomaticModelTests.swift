import Foundation
import Testing
@testable import byot

@Suite("Automatic names the model the server will run", .bug(id: "ASC-AAYJ3gkOlrnf_zpEvM9ChNE"))
struct OpenCodeAutomaticModelTests {
    private static func model(_ provider: String, _ id: String, _ name: String) -> OpenCodeModelOption {
        OpenCodeModelOption(providerID: provider, providerName: provider.capitalized, modelID: id, modelName: name, status: nil)
    }

    /// OpenCode Go with Big Pickle as the server's fallback, plus a second provider.
    private static let providers = [
        OpenCodeProviderModels(providerID: "opencode", providerName: "OpenCode",
                               models: [model("opencode", "big-pickle", "Big Pickle"), model("opencode", "glm", "GLM")],
                               fallbackRank: 0, fallbackModelID: "big-pickle"),
        OpenCodeProviderModels(providerID: "anthropic", providerName: "Anthropic",
                               models: [model("anthropic", "sonnet", "Sonnet")]),
    ]

    private func resolve(_ serverProtocol: OpenCodeServerProtocol, session: String? = nil, agent: String? = nil,
                         config: String? = nil, providers: [OpenCodeProviderModels] = providers) -> String? {
        OpenCodeAutomaticModel.resolve(serverProtocol: serverProtocol, sessionModelID: session, agentModelID: agent,
                                       configuredModelID: config, providers: providers)?.qualifiedID
    }

    @Test("With nothing configured, the server's first available model is named")
    func fallback() {
        #expect(resolve(.v2) == "opencode/big-pickle")
        #expect(resolve(.v1) == "opencode/big-pickle")
    }

    @Test("v2 order: session model, then agent model, then config model")
    func v2Order() {
        #expect(resolve(.v2, session: "opencode/glm", agent: "anthropic/sonnet", config: "anthropic/sonnet") == "opencode/glm")
        #expect(resolve(.v2, agent: "anthropic/sonnet", config: "opencode/glm") == "anthropic/sonnet")
        #expect(resolve(.v2, config: "opencode/glm") == "opencode/glm")
    }

    @Test("v1 order: agent model, then the session's last model, then config model")
    func v1Order() {
        #expect(resolve(.v1, session: "opencode/glm", agent: "anthropic/sonnet") == "anthropic/sonnet")
        #expect(resolve(.v1, session: "opencode/glm", config: "anthropic/sonnet") == "opencode/glm")
        #expect(resolve(.v1, config: "anthropic/sonnet") == "anthropic/sonnet")
    }

    @Test("A model the server does not list falls through to the next step")
    func unavailableFallsThrough() {
        #expect(resolve(.v2, session: "gone/x", agent: "gone/y", config: "anthropic/sonnet") == "anthropic/sonnet")
        #expect(resolve(.v2, config: "gone/z") == "opencode/big-pickle")
    }

    @Test("No answer from the server keeps the plain Server default")
    func noAnswer() {
        let unranked = [OpenCodeProviderModels(providerID: "anthropic", providerName: "Anthropic",
                                               models: [Self.model("anthropic", "sonnet", "Sonnet")])]
        #expect(resolve(.v2, providers: unranked) == nil)
        #expect(resolve(.v1, config: "gone/z", providers: []) == nil)
    }

    @Test("The lowest-ranked provider's fallback wins")
    func lowestRank() {
        let providers = [
            OpenCodeProviderModels(providerID: "a", providerName: "A", models: [Self.model("a", "one", "One")],
                                   fallbackRank: 3, fallbackModelID: "one"),
            OpenCodeProviderModels(providerID: "b", providerName: "B", models: [Self.model("b", "two", "Two")],
                                   fallbackRank: 1, fallbackModelID: "two"),
        ]
        #expect(resolve(.v1, providers: providers) == "b/two")
    }

    @Test("v1 provider catalog ranks each connected provider's default in server order")
    func v1CatalogDefaults() throws {
        let data = Data(#"""
        {
          "all": [
            {"id": "anthropic", "name": "Anthropic", "models": {"sonnet": {"id": "sonnet", "name": "Sonnet"}}},
            {"id": "opencode", "name": "OpenCode", "models": {"big-pickle": {"id": "big-pickle", "name": "Big Pickle"}}}
          ],
          "connected": ["opencode", "anthropic"],
          "default": {"opencode": "big-pickle", "anthropic": "sonnet"}
        }
        """#.utf8)
        let catalog = try JSONDecoder().decode(OpenCodeProviderCatalog.self, from: data)
        #expect(OpenCodeAutomaticModel.fallback(catalog.connectedProviders)?.qualifiedID == "opencode/big-pickle")
    }

    @Test("v1 provider catalog without defaults has no fallback")
    func v1CatalogWithoutDefaults() throws {
        let data = Data(#"{"all":[{"id":"x","name":"X","models":{"m":{"name":"M"}}}],"connected":["x"]}"#.utf8)
        let catalog = try JSONDecoder().decode(OpenCodeProviderCatalog.self, from: data)
        #expect(OpenCodeAutomaticModel.fallback(catalog.connectedProviders) == nil)
    }

    @Test("Config model reads v1 strings and v2 objects; the last v2 document wins")
    func configuredModel() {
        #expect(OpenCodeAutomaticModel.configuredModelID(.string("openrouter/anthropic/claude")) == "openrouter/anthropic/claude")
        #expect(OpenCodeAutomaticModel.configuredModelID(.object([
            "providerID": .string("opencode"), "model": .string("big-pickle"), "variant": .string("high"),
        ])) == "opencode/big-pickle")
        let entries: [OpenCodeJSONValue] = [
            .object(["type": .string("document"), "info": .object(["model": .string("anthropic/sonnet")])]),
            .object(["type": .string("document"), "info": .object(["model": .string("opencode/glm")])]),
            .object(["type": .string("document"), "info": .object(["share": .string("manual")])]),
            .object(["type": .string("directory"), "path": .string("/x")]),
        ]
        #expect(OpenCodeAutomaticModel.configuredModelID(v2Entries: entries) == "opencode/glm")
        #expect(OpenCodeAutomaticModel.configuredModelID(v2Entries: []) == nil)
    }

    @Test("Agent models parse from v1 and v2 agent shapes")
    func agentModel() {
        let v1 = OpenCodeAgentOption.parse(.object([
            "name": .string("build"), "mode": .string("primary"),
            "model": .object(["providerID": .string("anthropic"), "modelID": .string("sonnet")]),
        ]))
        let v2 = OpenCodeAgentOption.parse(.object([
            "id": .string("plan"), "mode": .string("primary"),
            "model": .object(["providerID": .string("opencode"), "id": .string("glm")]),
        ]))
        let none = OpenCodeAgentOption.parse(.object(["name": .string("build"), "mode": .string("primary")]))
        #expect(v1?.modelID == "anthropic/sonnet")
        #expect(v2?.modelID == "opencode/glm")
        #expect(none?.modelID == nil)
    }
}
