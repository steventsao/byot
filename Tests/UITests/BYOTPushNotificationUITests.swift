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
        XCTAssertTrue(app.staticTexts["Server Windows, project C:/work/byot"].exists, app.debugDescription)
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
        XCTAssertTrue(app.staticTexts["Server Windows, project C:/work/byot"].waitForExistence(timeout: 10), app.debugDescription)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "notification-session-route"; shot.lifetime = .keepAlways; add(shot)
    }
}
