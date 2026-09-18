#if DEBUG
  import SwiftUI

  /// Deterministic protocol-level fixture; no real credentials or account login.
  struct OpenCodeProviderAuthHarness: View {
    @StateObject private var store: OpenCodeSessionStore
    init() {
      let profile = OpenCodeServerProfile(
        name: "Auth fixture server", baseURL: "https://auth-fixture.example.test")
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [OpenCodeProviderAuthFixtureProtocol.self]
      let client = OpenCodeClient(
        profile: profile, password: "fixture-server-only",
        session: URLSession(configuration: configuration), serverProtocol: .v1)
      let session = OpenCodeSession(
        id: "ses_auth", slug: "auth", projectID: "project", workspaceID: nil,
        directory: "/fixture", parentID: nil, summary: nil, title: "Provider login", agent: nil,
        version: "1", time: .init(created: 1, updated: 1, compacting: nil, archived: nil))
      _store = StateObject(
        wrappedValue: OpenCodeSessionStore(
          client: client, session: session, directory: "/fixture",
          defaults: UserDefaults(suiteName: "byot.auth-fixture")!))
    }
    var body: some View {
      OpenCodeModelPickerView(store: store).task { await store.reloadModels() }
    }
  }

  private final class OpenCodeProviderAuthFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var connected = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
      Self.lock.lock()
      defer { Self.lock.unlock() }
      var requestData = request.httpBody
      if requestData == nil, let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
          let count = stream.read(&buffer, maxLength: buffer.count)
          if count <= 0 { break }
          data.append(contentsOf: buffer.prefix(count))
        }
        requestData = data
      }
      var status = 200
      let body: String
      switch request.url!.path {
      case "/provider":
        let connected = Self.connected ? #"["openai"]"# : "[]"
        body =
          #"{"all":[{"id":"openai","name":"OpenAI","models":{"fixture-model":{"id":"fixture-model","name":"Fixture model","status":"active","limit":{"context":128000,"output":4096}}}}],"connected":\#(connected),"default":{}}"#
      case "/provider/auth":
        body =
          #"{"openai":[{"type":"oauth","label":"ChatGPT Pro/Plus (browser)"},{"type":"oauth","label":"ChatGPT Pro/Plus (headless)"},{"type":"api","label":"Manually enter API Key"},{"type":"oauth","label":"Code sign-in","prompts":[{"type":"select","key":"account","message":"Account type","options":[{"label":"Personal","value":"personal"},{"label":"Enterprise","value":"enterprise"}]},{"type":"text","key":"host","message":"Enterprise host","when":{"key":"account","op":"eq","value":"enterprise"}}]}]}"#
      case "/auth/openai":
        if requestData.flatMap({ String(data: $0, encoding: .utf8) })?.contains("invalid")
          == true
        {
          status = 400
          body = #"{"message":"invalid-fixture-key-must-not-appear"}"#
        } else {
          Self.connected = true
          body = "true"
        }
      case "/instance/dispose": body = "true"
      case "/provider/openai/oauth/authorize":
        let isCode =
          requestData.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
          }?["method"] as? Int == 3
        body =
          #"{"url":"https://auth.example.test/device","method":"\#(isCode ? "code" : "auto")","instructions":"Enter code: FIXTURE-ONLY"}"#
      case "/provider/openai/oauth/callback":
        Thread.sleep(forTimeInterval: 3)
        Self.connected = true
        body = "true"
      case "/agent", "/command": body = "[]"
      case "/config": body = "{}"
      default:
        status = 404
        body = "{}"
      }
      client?.urlProtocol(
        self,
        didReceive: HTTPURLResponse(
          url: request.url!, statusCode: status, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: Data(body.utf8))
      client?.urlProtocolDidFinishLoading(self)
    }
  }
#endif
