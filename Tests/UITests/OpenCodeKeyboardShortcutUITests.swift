import XCTest

/// Hardware keyboard shortcuts and the regular-width split view, driven
/// through the session browser fixture. ⌘↩ isn't covered: the shared
/// simulator's input method takes Return before the app sees it.
final class OpenCodeKeyboardShortcutUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testSplitViewKeepsSessionsBesideTheConversation() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(regularWidth: true)
        let placeholder = app.staticTexts["No session selected"]
        XCTAssertTrue(placeholder.waitForExistence(timeout: 10), app.debugDescription)
        let retry = app.buttons["session-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["split-new-session"].exists, app.debugDescription)
        attach("split-empty-detail")

        retry.tap()
        XCTAssertTrue(app.navigationBars["Review billing"].waitForExistence(timeout: 10), app.debugDescription)
        // The list stays beside the conversation and marks the open session.
        XCTAssertTrue(retry.isHittable)
        XCTAssertTrue(retry.isSelected, retry.debugDescription)
        XCTAssertFalse(placeholder.exists)
        attach("split-session-selected")

        // ⌘] moves down the list and wraps to the top; ⌘[ wraps back. The
        // last row sits below the fold on an iPhone in landscape.
        let active = app.buttons["session-active"]
        XCTAssertTrue(press("]", in: app, until: app.navigationBars["Update documentation"]), app.debugDescription)
        XCTAssertTrue(app.staticTexts["This model is no longer available."].waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertFalse(retry.isSelected)
        XCTAssertTrue(press("]", in: app, until: app.navigationBars["Fix checkout"]), app.debugDescription)
        XCTAssertTrue(active.isSelected, active.debugDescription)
        XCTAssertTrue(press("[", in: app, until: app.navigationBars["Update documentation"]), app.debugDescription)
        XCTAssertFalse(active.isSelected)

        // ⌘N opens the new-session form in the detail column, beside the list.
        XCTAssertTrue(press("n", in: app, until: app.buttons["new-session-server"]), app.debugDescription)
        XCTAssertTrue(retry.isHittable)
        XCTAssertFalse(app.navigationBars["Update documentation"].exists)
        attach("split-new-session")

        // ⌘K puts the cursor in the session search.
        XCTAssertTrue(press("k", in: app, until: focusedField("session-search", in: app)), app.debugDescription)
    }

    @MainActor
    func testStopShortcutEndsARunningTurn() throws {
        let app = launch(regularWidth: false)
        let active = app.buttons["session-active"]
        XCTAssertTrue(active.waitForExistence(timeout: 10), app.debugDescription)
        active.tap()
        let stop = app.buttons["opencode-composer-stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), app.debugDescription)
        // The shortcut buttons stay out of VoiceOver's way.
        XCTAssertFalse(app.buttons["Stop Turn"].exists, app.debugDescription)
        // Nothing has keyboard focus: the root holds the shortcut.
        XCTAssertTrue(press(".", in: app, until: app.buttons["opencode-composer-send"]), app.debugDescription)
        XCTAssertFalse(stop.exists)
    }

    @MainActor
    func testNewSessionAndSearchShortcutsOnIPhone() throws {
        let app = launch(regularWidth: false)
        let idle = app.buttons["session-idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 10), app.debugDescription)

        XCTAssertTrue(press("n", in: app, until: app.buttons["new-session-server"]), app.debugDescription)

        // ⌘K from anywhere returns to the list with the cursor in search.
        let search = focusedField("session-search", in: app)
        XCTAssertTrue(press("k", in: app, until: search), app.debugDescription)
        XCTAssertFalse(app.buttons["new-session-server"].exists)
        search.typeText("docu")
        XCTAssertTrue(idle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["session-active"].exists)
        // Switching needs the sidebar, so it does nothing on iPhone.
        app.typeKey("]", modifierFlags: .command)
        XCTAssertTrue(search.exists)
        XCTAssertFalse(app.navigationBars["Update documentation"].exists)
    }

    /// A key pressed while the simulator is still moving keyboard focus, right
    /// after launch or a navigation, can be dropped; press again until the
    /// shortcut lands.
    @MainActor
    private func press(_ key: String, in app: XCUIApplication, until element: XCUIElement) -> Bool {
        for _ in 0..<3 {
            app.typeKey(key, modifierFlags: .command)
            if element.waitForExistence(timeout: 2) { return true }
        }
        return false
    }

    @MainActor
    private func focusedField(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.textFields
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .matching(identifier: identifier)
            .firstMatch
    }

    @MainActor
    private func launch(regularWidth: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        if regularWidth { app.launchArguments.append("--regular-width") }
        app.launch()
        return app
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
