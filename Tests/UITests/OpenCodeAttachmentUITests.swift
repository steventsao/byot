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

        // PhotosPicker is hosted in a remote view. Element queries do not
        // expose its grid on current iOS simulators, so drive only that
        // system-owned surface by stable normalized positions: first grid
        // item, then the top-right Add button.
        sleep(2)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.17, dy: 0.63)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.91, dy: 0.17)).tap()

        let removeAttachment = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Remove Photo '")
        ).firstMatch
        XCTAssertTrue(removeAttachment.waitForExistence(timeout: 10))

        composer.tap()
        let screenshot = XCUIScreen.main.screenshot()
        XCTContext.runActivity(named: "Prompt with photo attachment") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "prompt-attachments"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        if let output = ProcessInfo.processInfo.environment["BYOT_SCREENSHOT_OUTPUT"] {
            try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: output))
        }
    }
}
