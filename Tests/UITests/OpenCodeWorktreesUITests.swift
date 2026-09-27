import XCTest

final class OpenCodeWorktreesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testCreateDeleteAndStartSession() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--worktrees-fixture", "-byot.appearance", "light"]
        app.launch()
        let login = app.descendants(matching: .any)["worktree-login-flow"]
        XCTAssertTrue(login.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForLabel(of: login, containing: "3 uncommitted changes · 2 sessions"), login.label)
        XCTAssertTrue(login.label.contains("branch opencode/login-flow"), login.label)
        let actions = app.buttons["worktree-actions-login-flow"]
        XCTAssertGreaterThanOrEqual(actions.frame.height, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(actions.frame.width, 44 - 0.01)
        attach("worktrees-light")

        // A named worktree shows its progress until the server reports it checked out.
        app.buttons["worktree-new"].tap()
        let alert = app.alerts["New worktree"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), app.debugDescription)
        alert.textFields.firstMatch.typeText("Fix Crash")
        alert.buttons["Create"].tap()
        let created = app.descendants(matching: .any)["worktree-fix-crash"]
        XCTAssertTrue(created.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(waitForLabel(of: created, containing: "Preparing"), created.label)
        attach("worktrees-preparing")
        XCTAssertTrue(waitForLabel(of: created, containing: "No uncommitted changes · No sessions"), created.label)
        XCTAssertFalse(created.label.contains("Preparing"), created.label)

        // Deleting says what will be lost first.
        actions.tap()
        app.buttons["Delete Worktree…"].tap()
        let warning = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "3 uncommitted changes will be lost"))
        XCTAssertTrue(warning.firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        attach("worktrees-delete-confirmation")
        app.buttons["Delete Worktree"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: login)
        waitForExpectations(timeout: 5)

        // A session can start in any worktree.
        app.buttons["worktree-actions-misty-island"].tap()
        app.buttons["New Session"].tap()
        let session = app.staticTexts["worktree-fixture-session"]
        XCTAssertTrue(session.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(session.label, "Session in misty-island")
    }

    @MainActor func testDarkAppearanceAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--worktrees-fixture", "-byot.appearance", "dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let login = app.descendants(matching: .any)["worktree-login-flow"]
        XCTAssertTrue(login.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(waitForLabel(of: login, containing: "2 sessions"), login.label)
        XCTAssertLessThanOrEqual(login.frame.maxX, app.frame.width)
        let actions = app.buttons["worktree-actions-login-flow"]
        XCTAssertTrue(actions.exists)
        XCTAssertLessThanOrEqual(actions.frame.maxX, app.frame.width)
        attach("worktrees-dark-largest-text")
    }

    /// The new-session page over the session-browser fixture, which serves v1 worktree
    /// routes: a session already in a worktree is labelled, and a new one starts in a new worktree.
    @MainActor func testNewSessionStartsInANewWorktree() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        let existing = app.buttons["session-worktree"]
        XCTAssertTrue(existing.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(existing.label.contains("login-flow"), existing.label)

        app.buttons["New session"].firstMatch.tap()
        let workspace = app.buttons["new-session-workspace"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["new-session-manage-worktrees"].exists)
        XCTAssertTrue(selectMenuItem(app.buttons["New worktree"], opening: workspace), app.debugDescription)
        let name = app.textFields["new-session-worktree-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), app.debugDescription)
        name.tap()
        name.typeText("Fix Crash")
        let hint = app.staticTexts["Creates the branch opencode/fix-crash in a new folder on the server."]
        XCTAssertTrue(hint.waitForExistence(timeout: 5), app.debugDescription)
        attach("new-session-new-worktree")

        app.buttons["start-session"].tap()
        let composer = app.textFields["opencode-composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 15), app.debugDescription)
        let context = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Server Mac mini, project /repo/worktrees/fix-crash"))
            .firstMatch
        XCTAssertTrue(context.exists, app.debugDescription)
    }

    @MainActor private func selectMenuItem(_ item: XCUIElement, opening menu: XCUIElement) -> Bool {
        for _ in 0..<3 {
            menu.tap()
            if item.waitForExistence(timeout: 2) {
                item.tap()
                return true
            }
        }
        return false
    }

    @MainActor private func waitForLabel(of element: XCUIElement, containing text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                                timeout: timeout) == .completed
    }

    @MainActor private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
