import XCTest

final class OpenCodeShellModeUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testShellRunsRenderAndRefusedCommandReturnsToComposer() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--polish-ui-tests", "--shell", "-byot.appearance", appearance]
            app.launch()
            let conversation = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Long conversation'")).firstMatch
            XCTAssertTrue(conversation.waitForExistence(timeout: 10))
            conversation.tap()

            // A recorded v1 run is one card, never the server's bookkeeping text.
            let run = app.descendants(matching: .any)["opencode-shell-run"].firstMatch
            XCTAssertTrue(run.waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["The following tool was executed by the user"].exists)
            XCTAssertTrue(app.staticTexts["Done"].exists)
            XCTAssertTrue(app.buttons["Show all 17 lines"].exists)
            screenshot(app, name: "shell-run-\(appearance)")

            // Typing ! enters shell mode and names where the command will run.
            let field = app.descendants(matching: .any)["opencode-composer-message"].firstMatch
            field.tap()
            field.typeText("!")
            XCTAssertTrue(app.descendants(matching: .any)["opencode-shell-header"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Runs in fixture on UI tests"].exists)
            let shellField = app.descendants(matching: .any)["opencode-composer-message"].firstMatch
            XCTAssertTrue(shellField.waitForExistence(timeout: 5))
            shellField.tap()
            shellField.typeText("git status")
            XCTAssertEqual(app.buttons["opencode-shell-toggle"].value as? String, "On")
            screenshot(app, name: "shell-mode-\(appearance)")

            // The fixture server is busy: the command comes back, and the refusal stays visible.
            app.buttons["opencode-composer-send"].tap()
            let refused = app.staticTexts["Didn’t run"]
            XCTAssertTrue(refused.waitForExistence(timeout: 10))
            let visible = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: refused)
            XCTWaiter().wait(for: [visible], timeout: 5)
            screenshot(app, name: "shell-refused-\(appearance)")
            XCTAssertTrue(refused.isHittable, "The refusal scrolls into view")
            XCTAssertTrue(app.descendants(matching: .any)["opencode-shell-header"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.descendants(matching: .any)["opencode-composer-message"].firstMatch.value as? String, "git status")

            app.buttons["opencode-shell-exit"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["opencode-shell-header"].waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
