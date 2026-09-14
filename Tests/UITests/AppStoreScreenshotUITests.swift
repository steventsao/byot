import XCTest

/// Captures the App Store and README screenshot set from the deterministic
/// `--app-store-screenshots` fixture. scripts/capture-app-store-screenshots.sh
/// runs it once per device size and exports the attachments.
final class AppStoreScreenshotUITests: XCTestCase {
    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        continueAfterFailure = false
        let app = XCUIApplication()

        launch(app, phase: "live")
        let session = app.buttons["session-ses_upload"]
        XCTAssertTrue(session.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Fix flaky checkout test"].waitForExistence(timeout: 10), app.debugDescription)
        capture("01-sessions")

        session.tap()
        XCTAssertTrue(app.buttons["opencode-composer-stop"].waitForExistence(timeout: 15), app.debugDescription)
        capture("02-live-turn")

        openSession(app, phase: "question")
        XCTAssertTrue(app.staticTexts["Which limiter should the upload route use?"].waitForExistence(timeout: 15), app.debugDescription)
        capture("03-answer-questions")

        openSession(app, phase: "permission")
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 15), app.debugDescription)
        capture("04-approve-permissions")

        openSession(app, phase: "done")
        XCTAssertTrue(app.buttons["opencode-composer-send"].waitForExistence(timeout: 15), app.debugDescription)
        capture("05-turn-complete")

        let changes = app.buttons["Changes"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: changes)
        waitForExpectations(timeout: 10)
        changes.tap()
        XCTAssertTrue(app.navigationBars["Session changes"].waitForExistence(timeout: 5), app.debugDescription)
        // Disclosure labels report as not hittable; expand bottom-up so one
        // expanded patch cannot displace the next row before it is tapped.
        for file in ["src/routes/upload.ts", "src/middleware/rateLimit.ts"] {
            let row = app.staticTexts[file]
            XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        capture("06-review-changes")
    }

    @MainActor
    private func launch(_ app: XCUIApplication, phase: String) {
        app.terminate()
        app.launchArguments = ["--app-store-screenshots", "-BYOTStorePhase", phase]
        app.launch()
    }

    @MainActor
    private func openSession(_ app: XCUIApplication, phase: String) {
        launch(app, phase: phase)
        let session = app.buttons["session-ses_upload"]
        XCTAssertTrue(session.waitForExistence(timeout: 15), app.debugDescription)
        session.tap()
    }

    @MainActor
    private func capture(_ name: String) {
        // Let scroll-to-bottom and sheet animations settle so every device
        // captures the same frame.
        Thread.sleep(forTimeInterval: 2)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
