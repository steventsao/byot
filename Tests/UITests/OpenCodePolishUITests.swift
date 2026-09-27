import XCTest

final class OpenCodePolishUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testNewSessionOpensComposerWithKeyboard() {
        let app = launch()
        app.buttons["New session"].tap()
        XCTAssertTrue(app.navigationBars["New session"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["opencode-composer-message"].exists)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        screenshot(app, name: "new-session-composer")
    }

    @MainActor
    func testCreationFailureStaysOnListAndAllowsRetry() {
        let app = launch(["--creation-error"])
        app.buttons["New session"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '503'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.navigationBars["Polish project"].exists)
        XCTAssertTrue(app.buttons["New session"].isEnabled)
    }

    @MainActor
    func testJumpToLatest() {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Long conversation'")).firstMatch.tap()
        let lastMessage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Update 24.'")).firstMatch
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 10))
        let transcript = app.scrollViews.firstMatch
        transcript.swipeDown()
        transcript.swipeDown()
        let jump = app.buttons["jump-to-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        XCTAssertEqual(jump.label, "Jump to latest")
        screenshot(app, name: "jump-to-latest")
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
        XCTAssertTrue(lastMessage.isHittable)
    }

    @MainActor
    func testJumpToPendingResponse() {
        let app = launch(["--pending-action"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Long conversation'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 10))
        app.scrollViews.firstMatch.swipeDown()
        app.scrollViews.firstMatch.swipeDown()
        let jump = app.buttons["jump-to-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        XCTAssertEqual(jump.label, "Response needed")
        screenshot(app, name: "response-needed")
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Allow once"].isHittable)
    }

    @MainActor
    func testStreamingPreservesReadingPosition() {
        let app = launch(["--streaming"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Long conversation'")).firstMatch.tap()
        let lastMessage = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Update 24.'")).firstMatch
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 10))
        app.scrollViews.firstMatch.swipeDown()
        app.scrollViews.firstMatch.swipeDown()
        let jump = app.buttons["jump-to-latest"]
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        let olderMessage = app.staticTexts.allElementsBoundByIndex.first {
            $0.label.hasPrefix("Update ") && $0.isHittable
        }!
        let originalY = olderMessage.frame.minY
        // The fixture emits one update twelve seconds after the stream opens.
        let settled = expectation(description: "Streaming update delivered")
        DispatchQueue.main.asyncAfter(deadline: .now() + 13) { settled.fulfill() }
        wait(for: [settled], timeout: 15)
        XCTAssertTrue(jump.exists)
        XCTAssertEqual(olderMessage.frame.minY, originalY, accuracy: 3)
        jump.tap()
        let updated = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Streaming update arrived.'")).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 5))
        XCTAssertTrue(updated.isHittable)
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--polish-ui-tests"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["New session"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS 'Draft session'")).firstMatch.waitForExistence(timeout: 10))
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
