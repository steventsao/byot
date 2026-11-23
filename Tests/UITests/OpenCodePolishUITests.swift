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

    /// Issue #115: a multiline draft must stay on screen once the keyboard closes.
    @MainActor
    func testMultilineDraftStaysOnScreenAfterKeyboardCloses() {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Draft session'")).firstMatch.tap()
        let field = app.descendants(matching: .any)["opencode-composer-message"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText(String(repeating: "A longer draft that wraps across several lines of the composer. ", count: 4))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let window = app.windows.firstMatch.frame
        screenshot(app, name: "multiline-draft-keyboard-closed")
        XCTAssertLessThanOrEqual(field.frame.maxY, window.maxY, "field \(field.frame), window \(window)")
        let send = app.buttons["opencode-composer-send"]
        XCTAssertTrue(send.exists)
        XCTAssertLessThanOrEqual(send.frame.maxY, window.maxY, "send \(send.frame), window \(window)")
        XCTAssertTrue(send.isHittable)
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
        let jump = app.buttons["jump-to-latest"]
        // A long transcript opens on its latest message.
        XCTAssertTrue(lastMessage.isHittable)
        XCTAssertFalse(jump.exists)
        let transcript = app.scrollViews.firstMatch
        transcript.swipeDown()
        transcript.swipeDown()
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

    /// A turn that fits on one screen stays under the header while it
    /// streams, with no slot left for a step that has nothing to show yet.
    @MainActor
    func testShortTranscriptStaysUnderHeaderWhileStreaming() {
        let app = launch(["--short-streaming", "-byot.appearance", "dark"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Short conversation'")).firstMatch.tap()
        let prompt = app.staticTexts["Clone the project into the dev folder"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10))
        let header = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Server UI tests")).firstMatch
        let reply = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Cloning the project.'")).firstMatch
        let transcript = app.scrollViews.containing(.staticText, identifier: "Clone the project into the dev folder").firstMatch

        // The fixture changes the reply every 300 ms for about six seconds.
        let firstReply = reply.label
        var tops: [CGFloat] = []
        for _ in 0..<6 {
            tops.append(prompt.frame.minY)
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTAssertNotEqual(reply.label, firstReply, "The reply should still be streaming while the prompt is sampled")
        XCTAssertLessThanOrEqual(tops.max()! - tops.min()!, 3, "The prompt moved while streaming: \(tops)")
        XCTAssertLessThan(tops[0] - header.frame.maxY, 40, "prompt \(prompt.frame), header \(header.frame)")

        // The fixture's second step has started but has nothing to show.
        let step = app.descendants(matching: .any).matching(identifier: "transcript-step-summary").firstMatch
        let activity = transcript.descendants(matching: .any).matching(NSPredicate(format: "label == 'Working'")).firstMatch
        XCTAssertLessThan(activity.frame.minY - step.frame.maxY, 40, "step \(step.frame), activity \(activity.frame)")
        // The running turn is timed from its prompt, and its work stays open.
        let timer = transcript.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Working for '")).firstMatch
        XCTAssertTrue(timer.exists)
        XCTAssertGreaterThan(timer.frame.minY, prompt.frame.maxY)
        XCTAssertFalse(app.buttons["transcript-turn-header"].exists)
        screenshot(app, name: "short-transcript-streaming")

        // There is nothing to scroll, with or without the keyboard.
        transcript.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(prompt.frame.minY, tops[0], accuracy: 3)
        app.descendants(matching: .any).matching(identifier: "opencode-composer-message").firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertLessThanOrEqual(prompt.frame.minY, tops[0] + 3, "The keyboard must not push the prompt down")
        screenshot(app, name: "short-transcript-keyboard")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(prompt.frame.minY, tops[0], accuracy: 3)
    }

    @MainActor
    func testStreamingFollowsLatestMessage() {
        let app = launch(["--streaming"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Long conversation'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Update 24.'")).firstMatch.waitForExistence(timeout: 10))
        // The fixture grows the last message twelve seconds after the stream opens.
        let updated = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Streaming update arrived.'")).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["jump-to-latest"].waitForExistence(timeout: 2), "The transcript should follow the reply")
        XCTAssertLessThanOrEqual(updated.frame.maxY, app.buttons["opencode-composer-send"].frame.minY,
                                 "The end of the reply should stay above the composer")
        screenshot(app, name: "streaming-follows-latest")
    }

    /// TestFlight feedback, 2026-11-22: "Should auto anchor to bottom until user
    /// starts scrolling back to history". A live turn adds tool rows and long
    /// paragraphs; the transcript keeps its latest line in view until the reader
    /// scrolls back, leaves them where they are while they read, and follows
    /// again once they return to the end.
    @MainActor
    func testLiveTurnFollowsUntilReaderScrollsBack() {
        let app = launch(["--live-turn"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Live turn'")).firstMatch.tap()
        let jump = app.buttons["jump-to-latest"]
        let composer = app.descendants(matching: .any).matching(identifier: "opencode-composer-message").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        func update(_ number: Int) -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Live update \(number).")).firstMatch
        }
        /// Waits for update `number`, then checks the newest update so far is in view above the composer.
        func assertFollowing(_ number: Int, _ message: String, line: UInt = #line) {
            XCTAssertTrue(update(number).waitForExistence(timeout: 25), "Live update \(number) never arrived", line: line)
            // Let a Jump to latest animation come to rest.
            Thread.sleep(forTimeInterval: 0.6)
            XCTAssertFalse(jump.exists, message, line: line)
            // One snapshot, so the newest update and every frame are read at the same moment.
            guard let screen = try? app.snapshot() else { return XCTFail("No accessibility snapshot", line: line) }
            func flattened(_ element: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
                [element] + element.children.flatMap(flattened)
            }
            let elements = flattened(screen)
            func updateNumber(_ element: XCUIElementSnapshot) -> Int {
                Int(element.label.dropFirst("Live update ".count).prefix { $0.isNumber }) ?? 0
            }
            guard let newest = elements.filter({ $0.elementType == .staticText && $0.label.hasPrefix("Live update ") })
                    .max(by: { updateNumber($0) < updateNumber($1) }),
                  let composerFrame = elements.first(where: { $0.identifier == "opencode-composer-message" })?.frame
            else { return XCTFail("\(message): no live update or composer on screen", line: line) }
            let latest = newest.frame
            // At least its first line shows above the composer. A paragraph that
            // grew a moment ago can still be a few points short of fully in view.
            XCTAssertLessThanOrEqual(latest.minY + 16, composerFrame.minY,
                                     "\(message): update \(updateNumber(newest)) \(latest) sits under the composer \(composerFrame)", line: line)
            XCTAssertGreaterThan(latest.maxY, screen.frame.midY / 2,
                                 "\(message): update \(updateNumber(newest)) \(latest) is off the top", line: line)
        }

        // Tool rows and long paragraphs keep arriving; the transcript keeps up.
        assertFollowing(9, "The transcript should follow the reply")
        assertFollowing(18, "The transcript should still follow after the tool rows and long paragraphs")
        screenshot(app, name: "live-turn-following")

        // Scrolling back stops following and holds the reader's place.
        let transcript = app.scrollViews.firstMatch
        transcript.swipeDown()
        transcript.swipeDown()
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        let reading = app.staticTexts.allElementsBoundByIndex.first {
            $0.label.hasPrefix("Earlier answer") && $0.isHittable
        }!
        let readingY = reading.frame.minY
        Thread.sleep(forTimeInterval: 2.5)
        XCTAssertTrue(jump.exists, "New output must not pull the reader back down")
        XCTAssertEqual(reading.frame.minY, readingY, accuracy: 3)
        screenshot(app, name: "live-turn-reading-history")

        // Jumping back resumes following for the rest of the turn.
        jump.tap()
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5))
        assertFollowing(40, "The transcript should follow again after Jump to latest")
        screenshot(app, name: "live-turn-following-again")

        // A swipe from the end stops inside this turn, which is taller than
        // several screens. The app comes to rest there while output arrives
        // below the screen, and scrolling back to the end follows again.
        let swipeStarted = Date()
        transcript.swipeDown()
        let swipeSeconds = Date().timeIntervalSince(swipeStarted)
        XCTAssertLessThan(swipeSeconds, 10, "The app never came to rest after the swipe (\(swipeSeconds) s)")
        XCTAssertTrue(jump.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        let queryStarted = Date()
        XCTAssertTrue(jump.isHittable)
        let querySeconds = Date().timeIntervalSince(queryStarted)
        XCTAssertLessThan(querySeconds, 5, "The app stayed busy while output arrived below the screen (\(querySeconds) s)")
        screenshot(app, name: "live-turn-inside-turn")
        for _ in 0..<4 where jump.exists { transcript.swipeUp() }
        XCTAssertTrue(jump.waitForNonExistence(timeout: 5), "Scrolling back to the end should follow again")
        assertFollowing(58, "The transcript should follow again after scrolling back to the end")
        assertFollowing(66, "The transcript should keep following to the end of the turn")
    }

    /// Comes to rest at a run of places in and above a running turn several
    /// screens tall. Stopping just above its end once held the main thread at
    /// 100% with "Jump to latest" on screen, and nothing else got through.
    @MainActor
    func testRestingInsideARunningTurnSettles() {
        let app = launch(["--live-turn"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Live turn'")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Live update 30."))
            .firstMatch.waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 0.6)
        let transcript = app.scrollViews.firstMatch
        for step in 0..<12 {
            // Each gesture returns once the app is idle, or after XCTest gives up at 60 s.
            let started = Date()
            switch step % 3 {
            case 0: transcript.swipeDown()
            case 1: transcript.swipeDown(velocity: .slow)
            default:
                let from = transcript.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 60 + 50 * Double(step % 4))))
            }
            let seconds = Date().timeIntervalSince(started)
            XCTAssertLessThan(seconds, 10, "The app never came to rest after scroll \(step) (\(seconds) s)")
            Thread.sleep(forTimeInterval: 0.4)
            // Back to the newest output, so the next stops land just above the end again.
            if step == 5 {
                app.buttons["jump-to-latest"].tap()
                Thread.sleep(forTimeInterval: 1)
            }
        }
        screenshot(app, name: "live-turn-resting")
    }

    @MainActor
    func testTranscriptPartsRenderAndOpenViewers() {
        let app = launch(["--transcript-parts"])
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Rich transcript'")).firstMatch.tap()
        let compaction = app.descendants(matching: .any)["transcript-compaction"]
        XCTAssertTrue(compaction.waitForExistence(timeout: 10))
        // The finished turn opens folded to its answer and the files it changed.
        let turn = app.buttons["transcript-turn-header"]
        XCTAssertTrue(turn.exists)
        XCTAssertEqual(turn.label, "Worked for 2s")
        XCTAssertTrue(app.descendants(matching: .any)["transcript-patch"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["transcript-retry"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["transcript-step-summary"].exists)
        screenshot(app, name: "transcript-parts-folded")
        turn.tap()
        XCTAssertTrue(app.descendants(matching: .any)["transcript-retry"].waitForExistence(timeout: 5))
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
        // Step footers sit with each finished turn's work.
        for turn in app.buttons.matching(identifier: "transcript-turn-header").allElementsBoundByIndex { turn.tap() }
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
