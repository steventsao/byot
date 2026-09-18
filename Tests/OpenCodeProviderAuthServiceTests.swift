import Foundation
import Testing

@testable import byot

@Suite("Provider authentication contracts")
struct OpenCodeProviderAuthServiceTests {
  @Test("V1 retains advertised method indices and recommends device login")
  func catalog() async throws {
    let transport = ProviderAuthTransport(replies: [
      (
        200,
        #"{"all":[{"id":"openai","name":"OpenAI"},{"id":"custom","name":"Custom"}],"connected":[]}"#
      ),
      (
        200,
        #"{"openai":[{"type":"oauth","label":"ChatGPT Pro/Plus (browser)"},{"type":"unknown","label":"Future"},{"type":"oauth","label":"ChatGPT Pro/Plus (headless)"},{"type":"api","label":"Manually enter API Key"}]}"#
      ),
    ])
    let providers = try await service(transport).providerConnections(
      directory: "/repo", workspace: "wrk")
    let openai = try #require(providers.first { $0.id == "openai" })
    #expect(openai.methods.map(\.id) == ["0", "2", "3"])
    #expect(openai.orderedMethods.first?.id == "2")
    #expect(openai.methods.first?.unavailableReason != nil)
    #expect(providers.first { $0.id == "custom" }?.methods.first?.kind == .key)
  }

  @Test("V1 key and OAuth use scoped bodies and invalidate the provider catalog")
  func v1Requests() async throws {
    let transport = ProviderAuthTransport(replies: [
      (200, "true"), (200, "true"),
      (
        200,
        #"{"url":"https://auth.example.test/device","method":"auto","instructions":"Enter fixture code"}"#
      ),
      (200, "true"), (200, "true"),
    ])
    let api = service(transport)
    try await api.connectProviderKey(
      providerID: "openai", key: "fixture-key", directory: "/repo", workspace: "wrk")
    let auth = try await api.startProviderOAuth(
      providerID: "openai", methodID: "2", inputs: ["account": "personal"], directory: "/repo",
      workspace: "wrk")
    #expect(auth.mode == .automatic)
    #expect(
      try await api.providerOAuthStatus(
        providerID: "openai", attemptID: auth.attemptID, directory: "/repo", workspace: "wrk")
        == .complete)
    let requests = await transport.requests
    #expect(
      requests.map { $0.url!.path } == [
        "/auth/openai", "/instance/dispose", "/provider/openai/oauth/authorize",
        "/provider/openai/oauth/callback", "/instance/dispose",
      ])
    #expect(requests[0].httpMethod == "PUT")
    #expect(try body(requests[0]) == ["type": .string("api"), "key": .string("fixture-key")])
    #expect(
      try body(requests[2]) == [
        "method": .number(2), "inputs": .object(["account": .string("personal")]),
      ])
    #expect(try body(requests[3]) == ["method": .number(2)])
    #expect(requests[3].timeoutInterval == 900)
    #expect(
      requests.allSatisfy {
        URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems == [
          .init(name: "directory", value: "/repo"), .init(name: "workspace", value: "wrk"),
        ]
      })
    await #expect(throws: OpenCodeProviderUnsupportedError.self) {
      try await api.cancelProviderOAuth(
        providerID: "openai", attemptID: auth.attemptID, directory: "/repo", workspace: nil)
    }
    #expect(await transport.requests.count == 5)
  }

  @Test("Current v2 uses form answers and provider-scoped attempt routes")
  func v2Requests() async throws {
    let transport = ProviderAuthTransport(replies: [
      (204, ""),
      (
        200,
        #"{"data":{"attemptID":"attempt_one","url":"https://auth.example.test/device","instructions":"Fixture code","mode":"auto","time":{"created":1,"expires":9999999999999}}}"#
      ),
      (200, #"{"data":{"status":"pending"}}"#), (204, ""), (204, ""),
    ])
    let api = try v2Service(transport)
    try await api.connectProviderKey(
      providerID: "openai", key: "fixture-key", inputs: ["account": "enterprise"],
      directory: "/repo", workspace: "wrk")
    let auth = try await api.startProviderOAuth(
      providerID: "openai", methodID: "device-login", inputs: ["account": "enterprise"],
      directory: "/repo", workspace: "wrk")
    #expect(
      try await api.providerOAuthStatus(
        providerID: "openai", attemptID: auth.attemptID, directory: "/repo", workspace: "wrk")
        == .pending)
    try await api.completeProviderOAuth(
      providerID: "openai", attemptID: auth.attemptID, code: "fixture-code", directory: "/repo",
      workspace: "wrk")
    try await api.cancelProviderOAuth(
      providerID: "openai", attemptID: auth.attemptID, directory: "/repo", workspace: "wrk")
    let requests = await transport.requests
    #expect(
      requests.map { $0.url!.path } == [
        "/api/integration/openai/connect/key", "/api/integration/openai/connect/oauth",
        "/api/integration/openai/connect/oauth/attempt_one",
        "/api/integration/openai/connect/oauth/attempt_one/complete",
        "/api/integration/openai/connect/oauth/attempt_one",
      ])
    #expect(requests.last?.httpMethod == "DELETE")
    #expect(
      try body(requests[0]) == [
        "key": .string("fixture-key"), "answer": .object(["account": .string("enterprise")]),
      ])
    #expect(
      try body(requests[1]) == [
        "methodID": .string("device-login"), "answer": .object(["account": .string("enterprise")]),
      ])
    #expect(try body(requests[3]) == ["code": .string("fixture-code")])
    #expect(
      requests.allSatisfy {
        URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems == [
          .init(name: "location[directory]", value: "/repo"),
          .init(name: "location[workspace]", value: "wrk"),
        ]
      })
  }

  @Test("V2 string/select form fields retain conditional requirements and defaults")
  func v2Forms() async throws {
    let transport = ProviderAuthTransport(replies: [
      (
        200,
        #"{"data":[{"id":"copilot","name":"Copilot","connections":[],"methods":[{"id":"login","type":"oauth","label":"Sign in","form":[{"key":"account","type":"string","required":true,"default":"personal","options":[{"value":"personal","label":"Personal"},{"value":"enterprise","label":"Enterprise"}]},{"key":"host","type":"string","required":true,"when":[{"key":"account","op":"eq","value":"enterprise"}]}]}]}]}"#
      )
    ])
    let method = try #require(
      try await v2Service(transport).providerConnections(directory: "/repo", workspace: nil).first?
        .methods.first)
    #expect(method.prompts.first?.defaultValue == "personal")
    #expect(method.prompts.first?.kind == .select)
    #expect(method.visiblePrompts(inputs: ["account": "personal"]).map(\.key) == ["account"])
    #expect(method.missingRequiredInput(inputs: ["account": "enterprise"]) == "host")
  }

  @Test("Missing v2 routes cause no requests")
  func unsupported() async throws {
    let transport = ProviderAuthTransport(replies: [])
    let api = service(transport, schema: .object(["paths": .object([:])]))
    await #expect(throws: OpenCodeProviderUnsupportedError.self) {
      _ = try await api.providerConnections(directory: "/repo", workspace: nil)
    }
    #expect(await transport.requests.isEmpty)
  }

  @Test("Invalid authorization destinations cancel the v2 attempt")
  func unsafeURL() async throws {
    let transport = ProviderAuthTransport(replies: [
      (
        200,
        #"{"data":{"attemptID":"bad","url":"http://localhost:1455","instructions":"","mode":"auto","time":{"created":1,"expires":2}}}"#
      ), (204, ""),
    ])
    await #expect(throws: OpenCodeProviderConnectionError.self) {
      _ = try await v2Service(transport).startProviderOAuth(
        providerID: "openai", methodID: "browser", inputs: [:], directory: "/repo", workspace: nil)
    }
    #expect(await transport.requests.last?.httpMethod == "DELETE")
  }

  @Test("False success and server error bodies cannot mark credentials connected or expose them")
  func rejectedCredentials() async throws {
    for reply in [
      (200, "false"), (400, #"{"message":"fixture-secret-key"}"#), (404, "{}"),
      (200, "<html>fallback</html>"),
    ] {
      let transport = ProviderAuthTransport(replies: [reply])
      do {
        try await service(transport).connectProviderKey(
          providerID: "openai", key: "fixture-secret-key", directory: "/repo", workspace: nil)
        Issue.record("Must reject unsuccessful auth")
      } catch { #expect(!error.localizedDescription.contains("fixture-secret-key")) }
      #expect(await transport.requests.count == 1)
    }
  }

  private func service(_ transport: ProviderAuthTransport, schema: OpenCodeJSONValue? = nil)
    -> OpenCodeProviderAuthService
  {
    .init(
      context: .init(
        serverProtocol: schema == nil ? .v1 : .v2, schema: schema, transport: transport,
        profile: .init(name: "Fixture", baseURL: "https://fixture.example.test")))
  }
  private func v2Service(_ transport: ProviderAuthTransport) throws -> OpenCodeProviderAuthService {
    let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
      "Fixtures/opencode2-beta-19242-openapi.json")
    return service(
      transport,
      schema: try JSONDecoder().decode(OpenCodeJSONValue.self, from: Data(contentsOf: path)))
  }
  private func body(_ request: URLRequest) throws -> [String: OpenCodeJSONValue] {
    try JSONDecoder().decode([String: OpenCodeJSONValue].self, from: request.httpBody!)
  }
}

private actor ProviderAuthTransport: OpenCodeHTTPTransport {
  private(set) var requests: [URLRequest] = []
  private var replies: [(Int, String)]
  init(replies: [(Int, String)]) { self.replies = replies }
  nonisolated func makeRequest(path: [String], query: [URLQueryItem], method: String, body: Data?)
    throws -> URLRequest
  {
    try OpenCodeTransport(
      profile: .init(name: "Fixture", baseURL: "https://fixture.example.test"),
      password: "fixture-server-password", session: .shared
    ).makeRequest(path: path, query: query, method: method, body: body)
  }
  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    guard !replies.isEmpty else { throw OpenCodeConnectionError.invalidResponse }
    let (status, body) = replies.removeFirst()
    return (
      Data(body.utf8),
      HTTPURLResponse(
        url: request.url!, statusCode: status, httpVersion: nil,
        headerFields: ["Content-Type": "application/json"])!
    )
  }
  nonisolated func events(path: [String], query: [URLQueryItem]) -> AsyncThrowingStream<
    OpenCodeEvent, Error
  > { AsyncThrowingStream { $0.finish() } }
}
