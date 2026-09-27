import XCTest

final class OpenCodeSubagentUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testTaskCardOpensSubagentAndStepsBetweenSiblings() {
        let app = launchTeam()
        let scan = app.buttons["subagent-task-task_scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        XCTAssertTrue(scan.label.contains("Explore subagent, Scan for crashes, Done"))
        let running = app.buttons["subagent-task-task_tests"]
        XCTAssertTrue(running.label.contains("Running"))
        XCTAssertTrue(app.descendants(matching: .any)["subagent-task-result-task_scan"].exists)
        screenshot(app, name: "subagent-task-cards")

        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan for crashes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["subagent-bar"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["opencode-composer-message"].exists)
        let parent = app.buttons["subagent-parent"]
        XCTAssertTrue(parent.waitForExistence(timeout: 5))
        XCTAssertEqual(parent.value as? String, "Subagent review")
        XCTAssertTrue(app.staticTexts["1 of 2"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["subagent-previous"].isEnabled)
        screenshot(app, name: "subagent-session")

        app.buttons["subagent-next"].tap()
        XCTAssertTrue(app.navigationBars["Write regression tests"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 of 2"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["subagent-stop"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["subagent-next"].isEnabled)

        // The parent sits beneath on the stack, so the breadcrumb pops to it.
        app.buttons["subagent-parent"].tap()
        XCTAssertTrue(app.navigationBars["Subagent review"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["subagent-task-task_scan"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["opencode-composer-message"].exists)
    }

    @MainActor
    func testSessionDetailsListSubagents() {
        let app = launchTeam()
        XCTAssertTrue(app.buttons["subagent-task-task_scan"].waitForExistence(timeout: 10))
        app.buttons["session-actions"].tap()
        app.buttons["Session details"].tap()
        XCTAssertTrue(app.navigationBars["Session details"].waitForExistence(timeout: 5))
        let child = app.buttons["session-child-ses_sub_tests"]
        XCTAssertTrue(child.waitForExistence(timeout: 10))
        XCTAssertTrue(child.label.contains("Write regression tests"))
        XCTAssertTrue(child.label.contains("Running"))
        screenshot(app, name: "subagent-details")
        child.tap()
        XCTAssertTrue(app.navigationBars["Write regression tests"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["subagent-parent"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSubagentsInDarkAppearance() {
        let app = launchTeam(["-byot.appearance", "dark"])
        let scan = app.buttons["subagent-task-task_scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        screenshot(app, name: "subagent-task-cards-dark")
        scan.tap()
        XCTAssertTrue(app.descendants(matching: .any)["subagent-bar"].waitForExistence(timeout: 10))
        screenshot(app, name: "subagent-session-dark")
    }

    @MainActor
    func testSubagentsAtLargestTextSize() {
        let app = launchTeam(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        let scan = app.buttons["subagent-task-task_scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(scan.frame.maxX, app.windows.firstMatch.frame.maxX)
        screenshot(app, name: "subagent-task-cards-xxxl")
        scan.tap()
        let next = app.buttons["subagent-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(next.isHittable)
        XCTAssertGreaterThanOrEqual(next.frame.width, 44)
        screenshot(app, name: "subagent-session-xxxl")
    }

    @MainActor
    private func launchTeam(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--polish-ui-tests", "--subagents"] + arguments
        app.launch()
        let team = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Subagent review'")).firstMatch
        XCTAssertTrue(team.waitForExistence(timeout: 10))
        team.tap()
        return app
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
