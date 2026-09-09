import XCTest

final class OpenCodeSessionBrowserUITests: XCTestCase {
    @MainActor
    func testFlatListGroupingSortingServerSwitchAndDirectNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        XCTAssertTrue(app.buttons["Mac mini"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Windows"].exists)
        let active = app.buttons["session-active"]
        XCTAssertTrue(active.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Working"].exists)
        XCTAssertTrue(app.staticTexts["Provider rate limit"].exists)
        attach("sessions-recent")

        let search = app.searchFields.firstMatch
        let compose = app.buttons["New session"].firstMatch
        XCTAssertTrue(search.isHittable)
        XCTAssertTrue(compose.isHittable)
        if #available(iOS 26.0, *) {
            XCTAssertGreaterThan(search.frame.midY, app.frame.height * 0.75)
            XCTAssertEqual(search.frame.midY, compose.frame.midY, accuracy: 12)
        }
        search.tap()
        search.typeText("Review billing")
        XCTAssertTrue(app.buttons["session-retry"].waitForExistence(timeout: 5))
        XCTAssertFalse(active.exists)
        attach("sessions-bottom-search-filtered")
        app.buttons["Clear text"].tap()
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        if #available(iOS 26.0, *) {
            app.buttons["close"].tap()
        } else {
            app.buttons["Cancel"].tap()
        }
        XCTAssertTrue(compose.isHittable)

        app.buttons["Session list options"].tap()
        app.buttons["Session status"].tap()
        let retry = app.buttons["session-retry"]
        XCTAssertLessThan(retry.frame.minY, active.frame.minY)
        attach("sessions-by-status")

        app.buttons["Session list options"].tap()
        app.buttons["Group by project"].tap()
        XCTAssertTrue(app.staticTexts["1 retrying · 2 sessions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New session in byot"].exists)
        attach("sessions-grouped")

        app.terminate()
        app.launchArguments = ["--session-browser-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["New session in byot"].waitForExistence(timeout: 10))
        XCTAssertLessThan(app.buttons["session-retry"].frame.minY, app.buttons["session-active"].frame.minY)
        app.buttons["Windows"].tap()
        XCTAssertTrue(app.staticTexts["Windows build"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Fix checkout"].exists)
        app.buttons["session-active"].tap()
        XCTAssertTrue(app.textFields["Message"].waitForExistence(timeout: 10), app.debugDescription)
        attach("direct-session-navigation")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Windows"].waitForExistence(timeout: 5))
        app.buttons["New session in byot"].tap()
        XCTAssertTrue(app.textFields["Message"].waitForExistence(timeout: 10), app.debugDescription)
        attach("new-session-navigation")
    }

    @MainActor
    func testLargeTypeSearchAndServerBar() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["session-active"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Mac mini"].isHittable)
        attach("sessions-accessibility")
        let search = app.searchFields.firstMatch
        if !search.isHittable { app.swipeDown() }
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("nonexistent-long-search-string-without-results")
        XCTAssertTrue(app.staticTexts["No matching sessions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No matching sessions"].isHittable)
        attach("sessions-search-accessibility")
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
