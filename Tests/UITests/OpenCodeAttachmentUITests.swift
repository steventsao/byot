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
        let choosePhoto = app.buttons["Choose Photo"]
        XCTAssertTrue(choosePhoto.waitForExistence(timeout: 5))
        choosePhoto.tap()

        let firstPhoto = app.collectionViews.cells.firstMatch
        XCTAssertTrue(firstPhoto.waitForExistence(timeout: 10))
        firstPhoto.tap()

        let add = app.buttons["Add"]
        if add.waitForExistence(timeout: 2) {
            add.tap()
        }

        let removeAttachment = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Remove Photo '")
        ).firstMatch
        XCTAssertTrue(removeAttachment.waitForExistence(timeout: 10))

        composer.tap()
        let screenshot = XCUIScreen.main.screenshot()
        let activity = XCTContext.runActivity(named: "Prompt with photo attachment") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "prompt-attachments"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        _ = activity

        if let output = ProcessInfo.processInfo.environment["BYOT_SCREENSHOT_OUTPUT"] {
            try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: output))
        }
    }
}
