import XCTest

final class OpenCodeV2LiveUITests: XCTestCase {
    @MainActor
    func testConnectCreateSendAndViewBetaChanges() throws {
        guard ProcessInfo.processInfo.environment["BYOT_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Requires isolated beta fixture") }
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Password AutoFill") { interruption in
            let notNow = interruption.buttons["Not Now"]
            guard notNow.exists else { return false }
            notNow.tap()
            return true
        }
        let app = XCUIApplication()
        app.launch()
        if app.buttons["OpenCode servers"].waitForExistence(timeout: 3) { app.buttons["OpenCode servers"].tap() }
        let add = app.buttons["Add server"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "BYOT Beta Acceptance")
        let url = app.textFields["https://your-mac.example.ts.net"]
        url.tap(); url.typeText("https://127.0.0.1:4199")
        let password = app.secureTextFields["Server password"]
        password.tap(); password.typeText("byot-local-fixture-only")
        let directory = app.textFields["/Users/me/project"]
        directory.tap(); directory.typeText("/tmp/byot-v2-runtime-19242/project")
        app.buttons["Save"].tap()
        let project = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "/tmp/byot-v2-runtime-19242/project")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15), app.debugDescription); project.tap()
        let newSession = app.buttons["New session"].firstMatch
        XCTAssertTrue(newSession.waitForExistence(timeout: 10)); newSession.tap()
        let title = app.textFields["Optional title"]
        XCTAssertTrue(title.waitForExistence(timeout: 3)); title.typeText("Beta UI acceptance")
        app.buttons["Create"].tap()
        let composer = app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Creating a session must open its chat immediately")
        XCTAssertFalse(app.buttons["Navigation"].exists, "A second menu must not crowd the native back button")
        composer.tap(); composer.typeText("Say BYOT live beta verified.")
        app.buttons["Send message"].tap()
        let reply = app.staticTexts["BYOT live beta verified."].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        app.swipeDown()
        attach("beta-live-transcript")
        app.buttons["Choose model"].tap()
        XCTAssertTrue(app.navigationBars["Choose model"].waitForExistence(timeout: 5))
        attach("model-picker-appearance")
        app.buttons["Done"].tap()
        app.buttons["Changes"].tap()
        XCTAssertTrue(app.staticTexts["Session changes unavailable"].waitForExistence(timeout: 5))
        attach("beta-changes-availability")
        app.buttons["Done"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["New session"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Navigation"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["BYOT"].waitForExistence(timeout: 5))
        attach("byot-project-navigation")
        app.buttons["About BYOT"].tap()
        XCTAssertTrue(app.staticTexts["Version"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["OpenCode servers"].exists)
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
