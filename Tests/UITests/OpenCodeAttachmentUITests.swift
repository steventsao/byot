import XCTest

final class OpenCodeAttachmentUITests: XCTestCase {
    @MainActor
    func testAttachmentRemovalAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["Add attachment"].waitForExistence(timeout: 10))
        app.buttons["Add attachment"].tap()
        app.buttons["Add Screenshot Fixture"].tap()
        let remove = app.buttons["Remove byot-design.png"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        attach("attachment-largest-text")
        XCTAssertLessThanOrEqual(remove.frame.maxX, app.frame.maxX - 10)
        XCTAssertGreaterThanOrEqual(remove.frame.width, 44)
        XCTAssertGreaterThanOrEqual(remove.frame.height, 44)
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testEmptyModelPickerDoesNotOverlapAutomaticAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["Choose model"].waitForExistence(timeout: 10))
        app.buttons["Choose model"].tap()
        let automatic = app.buttons["automatic-model-option"]
        let empty = app.staticTexts["No models"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        attach("empty-model-picker-largest-text")
        XCTAssertGreaterThanOrEqual(empty.frame.minY, automatic.frame.maxY)
        XCTAssertTrue(automatic.isHittable)
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAttachmentPickerScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot"]
        app.launch()

        let composer = app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Review this design and suggest the next implementation step")

        app.buttons["Add attachment"].tap()
        let addFixture = app.buttons["Add Screenshot Fixture"]
        XCTAssertTrue(addFixture.waitForExistence(timeout: 5))
        addFixture.tap()
        XCTAssertTrue(addFixture.waitForNonExistence(timeout: 5))

        let removeAttachment = app.buttons.matching(
            NSPredicate(format: "label == 'Remove byot-design.png'")
        ).firstMatch
        XCTAssertTrue(removeAttachment.waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        Thread.sleep(forTimeInterval: 1)

        let screenshot = XCUIScreen.main.screenshot()
        XCTContext.runActivity(named: "Prompt with photo attachment") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "prompt-attachments"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

    }
}
