import XCTest

/// Captures the App Store and README screenshot set from the deterministic
/// `--app-store-screenshots` fixture. scripts/capture-app-store-screenshots.sh
/// runs it once per device size and exports the attachments; each attachment
/// name is the file name, so the numbers set the store order.
final class AppStoreScreenshotUITests: XCTestCase {
    @MainActor
    func testCaptureAppStoreScreenshots() throws {
        continueAfterFailure = false
        let app = XCUIApplication()

        // A streaming turn: tool activity, highlighted code, the context meter.
        openSession(app, phase: "live")
        XCTAssertTrue(app.buttons["opencode-composer-stop"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["session-context-meter"].waitForExistence(timeout: 10), app.debugDescription)
        capture("01-live-turn")

        // Diff review of the finished turn.
        openSession(app, phase: "done")
        XCTAssertTrue(app.buttons["opencode-composer-send"].waitForExistence(timeout: 15), app.debugDescription)
        let changes = app.buttons["Changes"]
        XCTAssertTrue(changes.waitForExistence(timeout: 10), app.debugDescription)
        changes.tap()
        XCTAssertTrue(app.navigationBars["Changes"].waitForExistence(timeout: 5), app.debugDescription)
        let route = app.buttons["diff-file-src/routes/upload.ts"]
        XCTAssertTrue(route.waitForExistence(timeout: 5), app.debugDescription)
        route.tap()
        XCTAssertTrue(app.navigationBars["upload.ts"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.scrollViews["diff-lines"].waitForExistence(timeout: 5), app.debugDescription)
        capture("03-review-changes")

        openSession(app, phase: "permission")
        XCTAssertTrue(app.buttons["Allow once"].waitForExistence(timeout: 15), app.debugDescription)
        capture("04-approve-permissions")

        // The terminal, over the in-memory PTY fixture.
        app.terminate()
        app.launchArguments = ["--terminal-fixture", "--app-store-screenshots"]
        app.launch()
        XCTAssertTrue(app.buttons["terminal-tab-Terminal 1"].waitForExistence(timeout: 15), app.debugDescription)
        let emulator = app.descendants(matching: .any)["terminal-emulator"]
        XCTAssertTrue(emulator.waitForExistence(timeout: 5), app.debugDescription)
        let passed = NSPredicate { _, _ in (emulator.value as? String)?.contains("4 passed") == true }
        expectation(for: passed, evaluatedWith: emulator)
        waitForExpectations(timeout: 10)
        capture("05-terminal")

        // Context and spend for the finished session.
        openSession(app, phase: "done")
        let meter = app.buttons["session-context-meter"]
        XCTAssertTrue(meter.waitForExistence(timeout: 15), app.debugDescription)
        meter.tap()
        XCTAssertTrue(app.descendants(matching: .any)["usage-context-summary"].waitForExistence(timeout: 5), app.debugDescription)
        if isPad {
            // The iPad's half-height sheet cuts off the session totals; open it fully.
            let bar = app.navigationBars["Context and usage"]
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)))
        }
        capture("06-context-usage")

        // On iPad every frame already shows the session list beside the
        // conversation, and the list alone leaves the detail column empty.
        if !isPad {
            launch(app, phase: "live")
            XCTAssertTrue(app.buttons["session-ses_upload"].waitForExistence(timeout: 15), app.debugDescription)
            XCTAssertTrue(app.staticTexts["Fix flaky checkout test"].waitForExistence(timeout: 10), app.debugDescription)
            capture("07-sessions")
        }

        // Shell mode: a `!` command in the composer, an earlier run in the
        // transcript. Last, because the unsent draft outlives relaunches.
        openSession(app, phase: "shell")
        XCTAssertTrue(app.descendants(matching: .any)["opencode-shell-run"].waitForExistence(timeout: 15), app.debugDescription)
        let field = app.descendants(matching: .any)["opencode-composer-message"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText("!")
        XCTAssertTrue(app.descendants(matching: .any)["opencode-shell-header"].waitForExistence(timeout: 5), app.debugDescription)
        let shellField = app.descendants(matching: .any)["opencode-composer-message"].firstMatch
        shellField.tap()
        shellField.typeText("npm run lint")
        dismissKeyboard(app)
        let jump = app.buttons["jump-to-latest"]
        if jump.waitForExistence(timeout: 2) { jump.tap() }
        XCTAssertTrue(app.buttons["jump-to-latest"].waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["opencode-shell-header"].exists, app.debugDescription)
        capture("02-shell-mode")

        // A fresh install: pair by code, find a nearby server, or add one by
        // hand. Phone only; on the iPad canvas it is mostly empty space.
        if !isPad {
            app.terminate()
            app.launchArguments = []
            app.launch()
            XCTAssertTrue(app.buttons["scan-pairing-code"].waitForExistence(timeout: 15), app.debugDescription)
            capture("08-server-setup")
        }
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

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

    /// Drags the transcript down so the keyboard slides away and the draft stays.
    @MainActor
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: end)
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
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
