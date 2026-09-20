import XCTest
final class BYOTDurableQueueUITests: XCTestCase {
    @MainActor func testUnsentQueueSurvivesAppTerminationAndShowsDeliveryState() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--durable-queue-fixture", "--reset-queue-fixture"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.navigationBars["Message queue"].waitForExistence(timeout: 10))
        for _ in 0..<3 { if app.staticTexts["Implement the account settings screen"].exists { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Implement the account settings screen"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.otherElements["queue-state-local"].firstMatch.exists || app.staticTexts["Saved on this iPhone"].firstMatch.exists, app.debugDescription)
        app.terminate()
        app.launchArguments = ["--durable-queue-fixture"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        for _ in 0..<3 { if app.staticTexts["Implement the account settings screen"].exists { break }; app.swipeUp() }
        XCTAssertTrue(app.staticTexts["Implement the account settings screen"].waitForExistence(timeout: 10))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Then run the tests and fix any failures"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "durable-queue-restored"; shot.lifetime = .keepAlways; add(shot)
    }
    @MainActor func testQueueEntryIsAvailableFromSessionActions() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        XCTAssertTrue(app.buttons["session-active"].waitForExistence(timeout: 10))
        app.buttons["session-active"].tap()
        XCTAssertTrue(app.buttons["session-actions"].waitForExistence(timeout: 10))
        app.buttons["session-actions"].tap()
        app.buttons["session-queue"].tap()
        XCTAssertTrue(app.buttons["queue-enable"].waitForExistence(timeout: 5), app.debugDescription)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "durable-queue-setup"; shot.lifetime = .keepAlways; add(shot)
    }
}
