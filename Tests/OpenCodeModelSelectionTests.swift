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

    @Test(
        "Picking a model saves it as the server default for new sessions",
        .bug(id: "ASC-AABmkFjmRxi7p9YEo0hLHxA")
    )
    @MainActor
    func serverDefaultModelPersistsAcrossSessions() async throws {
        let suiteName = "opencode-model-default-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = makeModelStubClient()

        let first = OpenCodeSessionStore(
            client: client,
            session: makeModelTestSession(id: "ses-first"),
            directory: "/repo",
            defaults: defaults
        )
        await first.reloadModels()
        let longContext = try #require(
            first.providerModels.flatMap(\.models)
                .first { $0.qualifiedID == "kimi-for-coding/k3-256k" }
        )
        first.selectModel(longContext)

        let second = OpenCodeSessionStore(
            client: client,
            session: makeModelTestSession(id: "ses-second"),
            directory: "/repo",
            defaults: defaults
        )
        await second.reloadModels()
        #expect(second.selectedModel?.qualifiedID == "kimi-for-coding/k3-256k")

        // A session's own saved choice still beats the server default.
        let base = try #require(
            second.providerModels.flatMap(\.models)
                .first { $0.qualifiedID == "kimi-for-coding/k3" }
        )
        second.selectModel(base)
        let firstAgain = OpenCodeSessionStore(
            client: client,
            session: makeModelTestSession(id: "ses-first"),
            directory: "/repo",
            defaults: defaults
        )
        await firstAgain.reloadModels()
        #expect(firstAgain.selectedModel?.qualifiedID == "kimi-for-coding/k3-256k")

        // Choosing Automatic clears the server default for new sessions.
        second.selectModel(nil)
        let third = OpenCodeSessionStore(
            client: client,
            session: makeModelTestSession(id: "ses-third"),
            directory: "/repo",
            defaults: defaults
        )
        await third.reloadModels()
        #expect(third.selectedModel == nil)
    }

    private func makeModelStubClient() -> OpenCodeClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenCodeModelCatalogStub.self]
        let profile = OpenCodeServerProfile(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A11D")!,
            name: "Model stub",
            baseURL: "https://models.example.test",
            username: "opencode"
        )
        return OpenCodeClient(
            profile: profile,
            password: "probe-secret",
            session: URLSession(configuration: configuration)
        )
    }

    private func makeModelTestSession(id: String) -> OpenCodeSession {
        OpenCodeSession(
            id: id,
            slug: id,
            projectID: "project",
            workspaceID: nil,
            directory: "/repo",
            parentID: nil,
            summary: nil,
            title: id,
            agent: nil,
            version: "1.18.10",
            time: OpenCodeSessionTime(
                created: 0,
                updated: 1,
                compacting: nil,
                archived: nil
            )
        )
    }
}

// Stateless stub for the provider catalog route so these tests stay isolated
// from suites that mutate OpenCodeProtocolStub's shared responses.
final class OpenCodeModelCatalogStub: URLProtocol, @unchecked Sendable {
    private static let catalogBody = Data(
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
            }
          ],
          "connected": ["kimi-for-coding"],
          "default": {}
        }
        """#.utf8
    )

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "models.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let isCatalog = url.path == "/provider"
        let response = HTTPURLResponse(
            url: url,
            statusCode: isCatalog ? 200 : 404,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: isCatalog ? Self.catalogBody : Data(#"{"message":"not found"}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
