import XCTest

final class BYOTPushNotificationUITests: XCTestCase {
    @MainActor
    func testNotificationSettingsAreAvailableForTheSelectedServer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        XCTAssertTrue(app.buttons["session-active"].waitForExistence(timeout: 10))
        app.buttons["OpenCode servers"].tap()
        app.buttons["Notifications"].tap()
        XCTAssertTrue(app.buttons["push-setup"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Mac mini"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "notifications-setup"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testColdNotificationOpensItsSessionOnTheCorrectServer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser", "--push-route-fixture", "--push-cold-launch"]
        app.launch()
        XCTAssertTrue(app.textFields["opencode-composer-message"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(windowsHeader(in: app).waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testWarmNotificationSwitchesFromAnOpenSessionToItsSavedServer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser", "--push-route-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["session-active"].waitForExistence(timeout: 10))
        app.buttons["session-active"].tap()
        XCTAssertTrue(app.textFields["opencode-composer-message"].waitForExistence(timeout: 10))
        app.buttons["Simulate notification"].tap()
        XCTAssertTrue(windowsHeader(in: app).waitForExistence(timeout: 10), app.debugDescription)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "notification-session-route"; shot.lifetime = .keepAlways; add(shot)
    }

    /// The session header names the server and project. Where the server has
    /// a status screen it is a button, and it may also name the branch.
    @MainActor
    private func windowsHeader(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Server Windows, project C:/work/byot")).firstMatch
    }
}
