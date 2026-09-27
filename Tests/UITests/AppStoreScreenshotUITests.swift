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
        XCTAssertTrue(changes.waitForExistence(timeout: 10), app.debugDescription)
        changes.tap()
        XCTAssertTrue(app.navigationBars["Changes"].waitForExistence(timeout: 5), app.debugDescription)
        let route = app.buttons["diff-file-src/routes/upload.ts"]
        XCTAssertTrue(route.waitForExistence(timeout: 5), app.debugDescription)
        route.tap()
        XCTAssertTrue(app.navigationBars["upload.ts"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.scrollViews["diff-lines"].waitForExistence(timeout: 5), app.debugDescription)
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
