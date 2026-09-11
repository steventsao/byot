import XCTest

final class OpenCodeSessionBrowserUITests: XCTestCase {
    @MainActor
    func testFinalProviderFailureReturnsToTheSessionList() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        let idle = app.buttons["session-idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 10))
        idle.tap()
        let failure = app.staticTexts["This model is no longer available."]
        XCTAssertTrue(failure.waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Needs attention"].waitForExistence(timeout: 10))
        XCTAssertTrue(failure.exists)
        app.buttons["Session list options"].tap()
        app.buttons["Session status"].tap()
        XCTAssertLessThan(idle.frame.minY, app.buttons["session-active"].frame.minY)
        attach("session-list-final-model-failure")
        app.terminate()
        app.launchArguments = ["--session-browser-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Needs attention"].waitForExistence(timeout: 10))
        XCTAssertTrue(failure.exists)
    }

    @MainActor
    func testNewSessionUsesInlineServerAndProjectSelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        let compose = app.buttons["New session"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        compose.tap()
        let server = app.buttons["new-session-server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5), app.debugDescription)
        server.tap()
        app.buttons["Windows"].firstMatch.tap()
        let project = app.buttons["new-session-project"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        project.tap()
        app.buttons["docs"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["C:/work/docs"].waitForExistence(timeout: 5))
        attach("new-session-inline-context")
        project.tap()
        app.buttons["Other directory…"].tap()
        let directory = app.textFields["new-session-directory"]
        XCTAssertTrue(directory.waitForExistence(timeout: 5))
        directory.tap()
        directory.typeText("C:/work/new-project")
        app.swipeUp()
        app.buttons["start-session"].tap()
        XCTAssertTrue(app.textFields["opencode-composer-message"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Windows · new-project"].exists, app.debugDescription)
        attach("new-session-custom-directory")
    }

    @MainActor
    func testBottomSearchAndServerMenuPreserveEditedProfile() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        let search = app.textFields["session-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let compose = app.buttons.matching(identifier: "New session").firstMatch
        XCTAssertTrue(compose.isHittable)
        XCTAssertGreaterThan(search.frame.minY, app.frame.height * 0.7)
        XCTAssertLessThan(abs(search.frame.midY - compose.frame.midY), 24)
        app.buttons["OpenCode servers"].tap()
        attach("server-picker-alignment")
        try XCTUnwrap(app.buttons.matching(identifier: "Windows").allElementsBoundByIndex
            .first(where: { $0.isHittable })).tap()
        XCTAssertTrue(app.staticTexts["Windows build"].waitForExistence(timeout: 10))
        app.buttons["OpenCode servers"].tap()
        app.buttons["Edit server"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Windows")
        XCTAssertEqual(app.textFields["https://your-mac.example.ts.net"].value as? String,
                       "https://windows.example.test")
        attach("edit-selected-server")
        app.buttons["Cancel"].tap()
    }

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
        let search = app.textFields["session-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("FUZZ-SEARCH-" + String(repeating: "A", count: 128))
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
