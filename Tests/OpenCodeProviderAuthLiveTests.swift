import Foundation
import XCTest

@testable import byot

final class OpenCodeProviderAuthLiveTests: XCTestCase {
  func testProviderDiscoveryAndKeyRefreshOnRealServers() async throws {
    guard ProcessInfo.processInfo.environment["BYOT_LIVE_ACCEPTANCE"] == "1",
      let root = ProcessInfo.processInfo.environment["BYOT_LIVE_ROOT"]
    else {
      throw XCTSkip("Requires isolated upstream servers")
    }
    for (version, port) in [("v1", 4195), ("v2", 4199)] {
      let directory = root + "/" + version + "/project"
      let client = OpenCodeClient(
        profile: .init(name: "Isolated \(version)", baseURL: "https://127.0.0.1:\(port)"),
        password: "byot-local-fixture-only")
      let providers = try await client.providerConnections(directory: directory, workspace: nil)
      let openai = try XCTUnwrap(providers.first { $0.id == "openai" })
      XCTAssertNotNil(openai.recommendedMethod)
      XCTAssertNotNil(openai.methods.first { $0.label.contains("browser") }?.unavailableReason)
      // Synthetic credentials go only to the disposable server, never a real provider API.
      try await client.connectProviderKey(
        providerID: "openai", key: "byot-isolated-fixture-not-a-real-key", directory: directory,
        workspace: nil)
      let refreshed = try await client.providerConnections(directory: directory, workspace: nil)
      XCTAssertEqual(refreshed.first { $0.id == "openai" }?.isConnected, true)
      let models = try await client.connectedProviderModels(directory: directory, workspace: nil)
      XCTAssertTrue(models.contains { $0.providerID == "openai" && !$0.models.isEmpty })
    }
  }
  func testCodeOAuthAgainstIsolatedPlugin() async throws {
    guard ProcessInfo.processInfo.environment["BYOT_LIVE_ACCEPTANCE"] == "1",
      let root = ProcessInfo.processInfo.environment["BYOT_LIVE_ROOT"]
    else {
      throw XCTSkip("Requires isolated upstream servers")
    }
    let directory = root + "/v1/project"
    let client = OpenCodeClient(
      profile: .init(name: "Isolated OAuth", baseURL: "https://127.0.0.1:4195"),
      password: "byot-local-fixture-only")
    let catalog = try await client.providerConnections(directory: directory, workspace: nil)
    // The opt-in plugin is installed by the provider-auth acceptance runner.
    guard let provider = catalog.first(where: { $0.id == "byot-auth-fixture" }),
      let method = provider.methods.first
    else {
      throw XCTSkip("Requires the synthetic provider-auth plugin")
    }
    let auth = try await client.startProviderOAuth(
      providerID: provider.id, methodID: method.id, inputs: ["account": "personal"],
      directory: directory, workspace: nil)
    XCTAssertEqual(auth.mode, .code)
    do {
      try await client.completeProviderOAuth(
        providerID: provider.id, attemptID: auth.attemptID, code: "wrong-fixture-code",
        directory: directory, workspace: nil)
      XCTFail("Incorrect authorization code must fail")
    } catch { XCTAssertFalse(error.localizedDescription.contains("wrong-fixture-code")) }
    try await client.completeProviderOAuth(
      providerID: provider.id, attemptID: auth.attemptID, code: "fixture-code",
      directory: directory, workspace: nil)
    let refreshed = try await client.providerConnections(directory: directory, workspace: nil)
    XCTAssertEqual(refreshed.first { $0.id == provider.id }?.isConnected, true)
  }

}
