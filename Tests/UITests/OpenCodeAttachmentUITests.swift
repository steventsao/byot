import XCTest

final class OpenCodeAttachmentUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAttachmentPickerScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot"]
        app.launch()

        let composer = app.textFields["Message OpenCode"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Review this design and suggest the next implementation step")

        app.buttons["Add attachment"].tap()
        let addFixture = app.buttons["Add Screenshot Fixture"]
        XCTAssertTrue(addFixture.waitForExistence(timeout: 5))
        addFixture.tap()

        let removeAttachment = app.buttons.matching(
            NSPredicate(format: "label == 'Remove byot-design.png'")
        ).firstMatch
        XCTAssertTrue(removeAttachment.waitForExistence(timeout: 10))

        let screenshot = XCUIScreen.main.screenshot()
        XCTContext.runActivity(named: "Prompt with photo attachment") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "prompt-attachments"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

    }
}
