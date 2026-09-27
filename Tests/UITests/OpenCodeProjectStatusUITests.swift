import XCTest

final class OpenCodeProjectStatusUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testStatusSectionsAndMCPSwitching() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--project-status-fixture", "-byot.appearance", "light"]
        app.launch()
        let branch = app.descendants(matching: .any)["status-branch"]
        XCTAssertTrue(branch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(branch.label, "Branch feature/project-status, Default branch: main")
        let github = app.switches["mcp-github"]
        XCTAssertTrue(github.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(github.value as? String, "1")
        XCTAssertGreaterThanOrEqual(github.frame.height, 44 - 0.01)
        // Servers that need sign-in on the server's computer aren't switchable here.
        XCTAssertFalse(app.switches["mcp-linear"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["mcp-linear"].exists)
        attach("status-light")

        // Turning a server off shows progress, then the server's new status.
        github.switches.firstMatch.tap()
        let off = NSPredicate(format: "value == '0'")
        expectation(for: off, evaluatedWith: app.switches["mcp-github"])
        waitForExpectations(timeout: 5)

        // A connect that fails still reports the server's error.
        let postgres = app.switches["mcp-postgres"]
        postgres.switches.firstMatch.tap()
        XCTAssertTrue(app.switches["mcp-postgres"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["mcp-postgres"].value as? String, "0")

        let json = app.buttons["status-configuration-json"]
        for _ in 0..<6 where !json.isHittable { app.swipeUp() }
        XCTAssertTrue(json.isHittable, app.debugDescription)
        attach("status-light-lower")
        json.tap()
        let secret = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "fixture-secret"))
        XCTAssertTrue(app.buttons["status-configuration-copy"].waitForExistence(timeout: 5))
        XCTAssertEqual(secret.count, 0)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "githubcopilot")).firstMatch.exists)
        attach("status-configuration")
    }

    @MainActor func testDarkAppearanceAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--project-status-fixture", "-byot.appearance", "dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let branch = app.descendants(matching: .any)["status-branch"]
        XCTAssertTrue(branch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertLessThanOrEqual(branch.frame.maxX, app.frame.width)
        attach("status-dark-largest-text")
        app.swipeUp()
        let github = app.switches["mcp-github"]
        XCTAssertTrue(github.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThanOrEqual(github.frame.maxX, app.frame.width)
        attach("status-dark-largest-text-mcp")
    }

    @MainActor private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
