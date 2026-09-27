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
    func testTranscriptPartsRenderAndOpenViewers() {
        let app = launch(["--transcript-parts"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Rich transcript'")).firstMatch.tap()
        let compaction = app.descendants(matching: .any)["transcript-compaction"]
        XCTAssertTrue(compaction.waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["transcript-retry"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["transcript-step-summary"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["transcript-patch"].exists)
        XCTAssertTrue(app.staticTexts["Checkpoint · 9c1e2d4"].exists || app.otherElements["Workspace checkpoint 9c1e2d4"].exists)
        screenshot(app, name: "transcript-parts-bottom")
        app.scrollViews.firstMatch.swipeDown()
        let image = app.buttons.matching(identifier: "transcript-image").firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "transcript-image").count, 2)
        screenshot(app, name: "transcript-parts-top")

        image.tap()
        let done = app.buttons["image-viewer-done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["1 of 2"].exists)
        screenshot(app, name: "image-viewer")
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 5))

        app.scrollViews.firstMatch.swipeUp()
        let file = app.buttons["Sources/App.swift"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        // The reviewer opens pinned to the step's turn, straight into the tapped file.
        XCTAssertTrue(app.navigationBars["App.swift"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Guard the empty state'")).firstMatch.waitForExistence(timeout: 5))
        screenshot(app, name: "patch-opens-diff")
    }

    @MainActor
    func testTranscriptPartsInDarkAppearance() {
        let app = launch(["--transcript-parts", "-byot.appearance", "dark"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Rich transcript'")).firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["transcript-compaction"].waitForExistence(timeout: 10))
        screenshot(app, name: "transcript-parts-dark-bottom")
        app.scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(app.buttons.matching(identifier: "transcript-image").firstMatch.waitForExistence(timeout: 5))
        screenshot(app, name: "transcript-parts-dark-top")
    }

    @MainActor
    func testContextMeterOpensUsageDetails() {
        let app = launch(["--usage"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Token budget'")).firstMatch.tap()
        let meter = app.buttons["session-context-meter"]
        XCTAssertTrue(meter.waitForExistence(timeout: 10))
        XCTAssertEqual(meter.value as? String, "72 percent used, 144,000 of 200,000 tokens")
        XCTAssertTrue(meter.isHittable)
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(identifier: "transcript-step-summary").count, 2)
        screenshot(app, name: "context-meter")

        meter.tap()
        XCTAssertTrue(app.navigationBars["Context and usage"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "72% of context used").exists)
        XCTAssertTrue(element(app, containing: "Claude Sonnet 4.5").exists)
        XCTAssertTrue(element(app, containing: "$1.24").exists)
        // The sheet opens at half height; the token totals sit below the fold.
        app.collectionViews.firstMatch.swipeUp()
        XCTAssertTrue(element(app, containing: "242,400").waitForExistence(timeout: 5))
        screenshot(app, name: "context-usage-sheet")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Context and usage"].waitForNonExistence(timeout: 5))

        app.buttons["session-actions"].tap()
        app.buttons["Session details"].tap()
        XCTAssertTrue(app.navigationBars["Session details"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "$1.24").waitForExistence(timeout: 5))
    }

    @MainActor
    func testContextMeterAtLargestTextSize() {
        let app = launch(["--usage", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Token budget'")).firstMatch.tap()
        let meter = app.buttons["session-context-meter"]
        XCTAssertTrue(meter.waitForExistence(timeout: 10))
        XCTAssertTrue(meter.isHittable)
        XCTAssertLessThanOrEqual(meter.frame.maxX, app.windows.firstMatch.frame.maxX)
        screenshot(app, name: "context-meter-xxxl")
        meter.tap()
        XCTAssertTrue(app.navigationBars["Context and usage"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "72% of context used").exists)
        screenshot(app, name: "context-usage-sheet-xxxl")
    }

    @MainActor
    func testContextUsageInDarkAppearance() {
        let app = launch(["--usage", "-byot.appearance", "dark"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Token budget'")).firstMatch.tap()
        let meter = app.buttons["session-context-meter"]
        XCTAssertTrue(meter.waitForExistence(timeout: 10))
        screenshot(app, name: "context-meter-dark")
        meter.tap()
        XCTAssertTrue(app.navigationBars["Context and usage"].waitForExistence(timeout: 5))
        screenshot(app, name: "context-usage-sheet-dark")
    }

    @MainActor
    func testTranscriptExportCopyAndAgentsSetup() {
        // Export choices persist; start every run from the defaults.
        let app = launch(["--usage", "-byot.transcriptExport.assistantMetadata", "YES",
                          "-byot.transcriptExport.thinking", "NO", "-byot.transcriptExport.toolDetails", "NO"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Token budget'")).firstMatch.tap()
        // The meter reads the model catalog, which also names the model in the export.
        let meter = app.buttons["session-context-meter"]
        XCTAssertTrue(meter.waitForExistence(timeout: 10))
        let catalogLoaded = NSPredicate(format: "value CONTAINS '200,000'")
        wait(for: [XCTNSPredicateExpectation(predicate: catalogLoaded, object: meter)], timeout: 10)

        app.buttons["session-actions"].tap()
        app.buttons["Export transcript…"].tap()
        XCTAssertTrue(app.navigationBars["Export transcript"].waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "token-budget.md").exists)
        XCTAssertTrue(element(app, containing: "## Assistant (Build · Claude Sonnet 4.5 · 0.5s)").waitForExistence(timeout: 5))
        let share = app.buttons["transcript-export-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isEnabled && share.isHittable)
        screenshot(app, name: "transcript-export")

        let metadata = app.switches["transcript-export-assistant-metadata"]
        XCTAssertTrue(metadata.exists)
        metadata.switches.firstMatch.tap()
        XCTAssertTrue(element(app, containing: "## Assistant\n").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, containing: "(Build ·").exists)
        app.buttons["transcript-export-copy"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 2))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Export transcript"].waitForNonExistence(timeout: 5))

        app.buttons["session-actions"].tap()
        app.buttons["Copy transcript"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["transcript-copied"].waitForExistence(timeout: 3))

        app.buttons["session-actions"].tap()
        app.buttons["Set up AGENTS.md…"].tap()
        let alert = app.alerts["Set up AGENTS.md"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.textFields["Focus (optional)"].exists)
        screenshot(app, name: "agents-setup")
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 5))

        let composer = app.textViews["opencode-composer-message"].exists
            ? app.textViews["opencode-composer-message"] : app.textFields["opencode-composer-message"]
        composer.tap()
        composer.typeText("/")
        XCTAssertTrue(app.buttons["opencode-command-app-export"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["opencode-command-app-copy"].exists)
        XCTAssertTrue(app.buttons["opencode-command-command:init"].exists)
        screenshot(app, name: "slash-transcript-actions")
    }

    @MainActor
    func testTranscriptExportAtLargestTextSizeInDarkAppearance() {
        let app = launch(["--usage", "-byot.appearance", "dark",
                          "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Token budget'")).firstMatch.tap()
        XCTAssertTrue(app.buttons["session-context-meter"].waitForExistence(timeout: 10))
        app.buttons["session-actions"].tap()
        // At this size the actions menu scrolls; export sits below the fold.
        let export = app.buttons["Export transcript…"]
        for _ in 0..<4 where !export.isHittable { app.collectionViews.firstMatch.swipeUp() }
        export.tap()
        XCTAssertTrue(app.navigationBars["Export transcript"].waitForExistence(timeout: 5))
        let share = app.buttons["transcript-export-share"]
        let copy = app.buttons["transcript-export-copy"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isHittable && copy.isHittable)
        XCTAssertLessThanOrEqual(share.frame.maxX, app.windows.firstMatch.frame.maxX)
        screenshot(app, name: "transcript-export-xxxl-dark")
    }

    @MainActor
    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
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
