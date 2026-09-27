import XCTest

/// A size change carries the open conversation between the iPhone stack and
/// the split view. Kept apart from the keyboard tests: after these rotations
/// the simulator can drop the next test's synthesized key presses.
final class OpenCodeSplitViewResizeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testResizingKeepsTheOpenConversation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser", "--regular-width-when-wide"]
        app.launch()
        let active = app.buttons["session-active"]
        XCTAssertTrue(active.waitForExistence(timeout: 10), app.debugDescription)
        active.tap()
        let title = app.navigationBars["Fix checkout"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), app.debugDescription)

        // Widening opens the conversation beside the list.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(active.wait(for: \.isSelected, toEqual: true, timeout: 10), app.debugDescription)
        XCTAssertTrue(title.exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["No session selected"].exists)
        attach("resize-to-split")

        // Narrowing pushes it back over the list.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.navigationBars["Fix checkout"].buttons["BackButton"].waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertFalse(active.isHittable)
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
