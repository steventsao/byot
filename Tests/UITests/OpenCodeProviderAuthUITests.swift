import XCTest

final class OpenCodeProviderAuthUITests: XCTestCase {
  @MainActor
  func testEmptyPickerConnectsAPIKeyAndRefreshesModels() {
    let app = launch()
    XCTAssertTrue(app.staticTexts["No models"].waitForExistence(timeout: 10))
    app.buttons["connect-provider"].tap()
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "OpenAI")).firstMatch
        .waitForExistence(timeout: 10))
    attach("provider-catalog")
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "OpenAI")).firstMatch.tap()
    XCTAssertTrue(app.staticTexts["Recommended for this phone"].exists)
    attach("provider-methods")
    app.buttons["Manually enter API Key"].tap()
    app.secureTextFields["API key"].tap()
    app.secureTextFields["API key"].typeText("invalid")
    app.buttons["Connect"].tap()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "400")).firstMatch
        .waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["invalid-fixture-key-must-not-appear"].exists)
    app.secureTextFields["API key"].tap()
    app.secureTextFields["API key"].typeText(
      String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7) + "fixture-key")
    app.buttons["Connect"].tap()
    XCTAssertTrue(app.staticTexts["Provider connected"].waitForExistence(timeout: 10))
    attach("provider-connected")
    app.buttons["Done"].firstMatch.tap()
    XCTAssertTrue(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture model")).firstMatch
        .waitForExistence(timeout: 10), app.debugDescription)
    attach("provider-models-refreshed")
  }

  @MainActor
  func testDeviceSignInAndReturnFromBackground() {
    let app = launch()
    app.buttons["connect-provider"].tap()
    let provider = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "OpenAI"))
      .firstMatch
    XCTAssertTrue(provider.waitForExistence(timeout: 10))
    provider.tap()
    app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ChatGPT Pro/Plus (headless)"))
      .firstMatch.tap()
    app.buttons["Start sign-in"].tap()
    XCTAssertTrue(app.staticTexts["Enter code: FIXTURE-ONLY"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      app.links["Open auth.example.test"].exists || app.buttons["Open auth.example.test"].exists)
    attach("provider-device-code")
    XCUIDevice.shared.press(.home)
    app.activate()
    XCTAssertTrue(
      app.staticTexts["Provider connected"].waitForExistence(timeout: 20), app.debugDescription)
  }

  @MainActor
  private func launch() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--provider-auth-fixture"]
    XCUIDevice.shared.orientation = .portrait
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.buttons["connect-provider"].waitForExistence(timeout: 10))
    return app
  }
  @MainActor private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIApplication().screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
