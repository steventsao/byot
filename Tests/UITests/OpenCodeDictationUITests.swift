import XCTest

final class OpenCodeDictationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testMicrophonePromptWaitsForTapAndExplainsItsUse() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        app.launchArguments = ["--attachment-screenshot", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let composer = app.textFields["opencode-composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Fix the failing test")
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(system.alerts.firstMatch.exists, "Typing does not request microphone access")

        app.buttons["opencode-dictation-toggle"].tap()
        let alert = system.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(
            format: "label CONTAINS %@", "records your voice to draft a message to your OpenCode agent"
        )).firstMatch.exists)
        screenshot(system, name: "microphone-permission-description")
        let deny = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "don")).firstMatch
        XCTAssertTrue(deny.exists)
        deny.tap()
        let notNow = app.buttons["Not Now"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 5))
        notNow.tap()
        XCTAssertEqual(composer.value as? String, "Fix the failing test")
        composer.tap()
        composer.typeText(" without voice")
        XCTAssertEqual(composer.value as? String, "Fix the failing test without voice")
    }

    @MainActor
    func testDictationStreamsIntoTheDraftAndDoneKeepsTheFinalWording() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--attachment-screenshot", "--dictation-fixture", "-byot.appearance", appearance]
            app.launch()
            let composer = app.textFields["opencode-composer-message"]
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            composer.tap()
            composer.typeText("Please")

            let microphone = app.buttons["opencode-dictation-toggle"]
            XCTAssertTrue(microphone.waitForExistence(timeout: 5))
            XCTAssertEqual(microphone.label, "Dictate")
            microphone.tap()

            // Live words follow what was typed, and the header says where audio goes.
            XCTAssertTrue(app.descendants(matching: .any)["opencode-dictation-status"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Stays on this device"].exists)
            XCTAssertEqual(microphone.label, "Stop dictation")
            let streamed = NSPredicate(format: "value == %@", "Please summarize the failing tests")
            expectation(for: streamed, evaluatedWith: composer)
            waitForExpectations(timeout: 10)
            screenshot(app, name: "dictation-listening-\(appearance)")

            // Done ends listening and still takes the recognizer's final punctuation.
            app.buttons["opencode-dictation-done"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["opencode-dictation-status"].waitForNonExistence(timeout: 5))
            XCTAssertEqual(composer.value as? String, "Please summarize the failing tests.")
            XCTAssertEqual(microphone.label, "Dictate")
            screenshot(app, name: "dictation-finished-\(appearance)")
            app.terminate()
        }
    }

    @MainActor
    func testTypingDuringDictationStopsItAndKeepsTheEdit() {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "--dictation-fixture",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let composer = app.textFields["opencode-composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        let microphone = app.buttons["opencode-dictation-toggle"]
        XCTAssertTrue(microphone.waitForExistence(timeout: 5))
        microphone.tap()
        let status = app.descendants(matching: .any)["opencode-dictation-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let firstWord = NSPredicate(format: "value BEGINSWITH %@", "Summarize")
        expectation(for: firstWord, evaluatedWith: composer)
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.buttons["opencode-dictation-done"].isHittable, "Done stays reachable at accessibility sizes")
        screenshot(app, name: "dictation-listening-axxxl")

        composer.typeText("!")
        XCTAssertTrue(status.waitForNonExistence(timeout: 5), "An edit ends dictation")
        let edited = composer.value as? String
        XCTAssertEqual(edited?.last, "!")
        sleep(1)
        XCTAssertEqual(composer.value as? String, edited, "Late words never overwrite the edit")
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
