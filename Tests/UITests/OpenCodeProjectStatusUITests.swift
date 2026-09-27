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

    @MainActor func testServerSettingsEditing() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--project-status-fixture", "-byot.appearance", "light"]
        app.launch()
        let edit = app.buttons["status-edit-settings"]
        XCTAssertTrue(app.descendants(matching: .any)["status-branch"].waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<8 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.isHittable, app.debugDescription)
        XCTAssertGreaterThanOrEqual(edit.frame.height, 44 - 0.01)
        edit.tap()

        let model = app.buttons["settings-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(model.value as? String, "Claude Sonnet 4.5")
        let save = app.buttons["settings-save"]
        XCTAssertFalse(save.isEnabled, "Nothing to save before an edit")
        attach("settings-light")

        // Pick another model from the connected providers.
        model.tap()
        let gpt = app.buttons["GPT-5, OpenAI"]
        XCTAssertTrue(gpt.waitForExistence(timeout: 5), app.debugDescription)
        attach("settings-model-picker")
        gpt.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, "GPT-5")

        let sharing = app.buttons["settings-sharing"]
        sharing.tap()
        let off = app.buttons["Off"]
        XCTAssertTrue(off.waitForExistence(timeout: 5), app.debugDescription)
        off.tap()
        XCTAssertTrue(save.isEnabled)

        // Saving asks first, since the server reloads its projects.
        save.tap()
        let confirm = app.buttons["settings-save-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["settings-save"].exists)

        // Reopening reads back what the server stored.
        edit.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, "GPT-5")
        XCTAssertEqual(app.buttons["settings-sharing"].value as? String, "Off")
    }

    @MainActor func testServerSettingsDarkAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--project-status-fixture", "-byot.appearance", "dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["status-branch"].waitForExistence(timeout: 10), app.debugDescription)
        let edit = app.buttons["status-edit-settings"]
        for _ in 0..<16 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.isHittable, app.debugDescription)
        edit.tap()
        let model = app.buttons["settings-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThanOrEqual(model.frame.maxX, app.frame.width)
        attach("settings-dark-largest-text")
        let shell = app.textFields["settings-shell"]
        for _ in 0..<8 where !shell.isHittable { app.swipeUp() }
        XCTAssertTrue(shell.isHittable, app.debugDescription)
        XCTAssertLessThanOrEqual(shell.frame.maxX, app.frame.width)
        attach("settings-dark-largest-text-lower")
    }

    @MainActor private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
