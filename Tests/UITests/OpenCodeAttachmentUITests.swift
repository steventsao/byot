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
