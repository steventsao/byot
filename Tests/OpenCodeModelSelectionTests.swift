import Foundation
import Testing
@testable import byot

struct OpenCodeModelSelectionTests {
    @Test("Only connected provider models appear in the picker")
    func connectedProviderCatalog() throws {
        let data = Data(
            #"""
            {
              "all": [
                {
                  "id": "kimi-for-coding",
                  "name": "Kimi For Coding",
                  "models": {
                    "k3": { "id": "k3", "name": "Kimi K3", "status": "active" },
                    "k3-256k": { "id": "k3-256k", "name": "Kimi K3-256K", "status": "active" }
                  }
                },
                {
                  "id": "not-connected",
                  "name": "Not Connected",
                  "models": {
                    "hidden": { "id": "hidden", "name": "Hidden" }
                  }
                }
              ],
              "connected": ["kimi-for-coding"],
              "default": {}
            }
            """#.utf8
        )

        let catalog = try JSONDecoder().decode(OpenCodeProviderCatalog.self, from: data)
        let provider = try #require(catalog.connectedProviders.first)

        #expect(catalog.connectedProviders.count == 1)
        #expect(provider.providerID == "kimi-for-coding")
        #expect(provider.connectionState == .confirmed)
        #expect(provider.models.map(\.qualifiedID) == [
            "kimi-for-coding/k3",
            "kimi-for-coding/k3-256k",
        ])
    }

    @Test("Model search matches provider, display name, and model ID")
    func modelSearch() throws {
        let provider = OpenCodeProviderModels(
            providerID: "kimi-for-coding",
            providerName: "Kimi For Coding",
            models: [
                OpenCodeModelOption(
                    providerID: "kimi-for-coding",
                    providerName: "Kimi For Coding",
                    modelID: "k3",
                    modelName: "Kimi K3",
                    status: "active"
                ),
                OpenCodeModelOption(
                    providerID: "kimi-for-coding",
                    providerName: "Kimi For Coding",
                    modelID: "kimi-for-coding-highspeed",
                    modelName: "Kimi For Coding HighSpeed",
                    status: "active"
                ),
            ]
        )

        #expect(provider.matching("K3")?.models.map(\.modelID) == ["k3"])
        #expect(provider.matching("highspeed")?.models.map(\.modelID) == ["kimi-for-coding-highspeed"])
        #expect(provider.matching("kimi-for-coding")?.models.count == 2)
        #expect(provider.matching("claude") == nil)
    }

    @Test("Selected provider and model are included in prompt requests")
    func selectedModelPromptRequest() throws {
        let client = OpenCodeClient(
            profile: OpenCodeServerProfile(
                name: "Mac",
                baseURL: "https://mac.example.test",
                username: "opencode"
            ),
            password: "secret"
        )
        let model = OpenCodeModelOption(
            providerID: "kimi-for-coding",
            providerName: "Kimi For Coding",
            modelID: "k3",
            modelName: "Kimi K3",
            status: "active"
        )

        let request = try client.makeSendMessageRequest(
            sessionID: "ses_123",
            directory: "/project",
            model: model,
            text: "Build it"
        )
        let bodyData = try #require(request.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        let requestModel = try #require(body["model"] as? [String: String])

        #expect(requestModel["providerID"] == "kimi-for-coding")
        #expect(requestModel["modelID"] == "k3")
    }

    @Test("Automatic model leaves the prompt model unspecified")
    func automaticModelPromptRequest() throws {
        let client = OpenCodeClient(
            profile: OpenCodeServerProfile(
                name: "Mac",
                baseURL: "https://mac.example.test",
                username: "opencode"
            ),
            password: "secret"
        )

        let request = try client.makeSendMessageRequest(
            sessionID: "ses_123",
            directory: "/project",
            text: "Use the default"
        )
        let bodyData = try #require(request.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )

        #expect(body["model"] == nil)
    }
}
