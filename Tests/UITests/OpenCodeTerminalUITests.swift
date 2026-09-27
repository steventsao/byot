import XCTest

final class OpenCodeTerminalUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testKeysTabsScrollbackAndExit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--terminal-fixture", "-byot.appearance", "light"]
        app.launch()
        let first = app.buttons["terminal-tab-Terminal 1"]
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        let emulator = app.descendants(matching: .any)["terminal-emulator"]
        XCTAssertTrue(emulator.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForValue(of: emulator, containing: "terminal fixture"), String(describing: emulator.value))

        // Accessory keys reach the shell: the fixture echoes esc and tab in caret notation.
        let control = app.buttons["terminal-key-control"]
        control.tap()
        XCTAssertEqual(control.value as? String, "On")
        control.tap()
        XCTAssertEqual(control.value as? String, "Off")
        for key in ["escape", "tab", "control", "up"] {
            XCTAssertGreaterThanOrEqual(app.buttons["terminal-key-\(key)"].frame.height, 44 - 0.01, key)
        }
        app.buttons["terminal-key-escape"].tap()
        app.buttons["terminal-key-tab"].tap()
        attach("terminal-light")
        // Symbols sit past the arrows; the row scrolls to reach them.
        app.buttons["terminal-key-pipe"].tap()
        XCTAssertTrue(waitForValue(of: emulator, containing: "^[^I|"), String(describing: emulator.value))

        // A second tab has its own shell; returning keeps the first tab's scrollback.
        app.buttons["terminal-new"].tap()
        let second = app.buttons["terminal-tab-Terminal 2"]
        XCTAssertTrue(second.waitForExistence(timeout: 5))
        XCTAssertTrue(second.isSelected)
        XCTAssertTrue(waitForValue(of: emulator, containing: "terminal fixture"))
        XCTAssertFalse((emulator.value as? String ?? "").contains("^[^I|"))
        first.tap()
        XCTAssertTrue(waitForValue(of: emulator, containing: "^[^I|"), String(describing: emulator.value))

        // Typing on the software keyboard; `exit` ends the process and offers the next step.
        app.buttons["terminal-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Hide keyboard"].waitForExistence(timeout: 5))
        attach("terminal-keyboard")
        // The emulator is a UIKeyInput view, so type with the keyboard's own keys.
        let keyboard = app.keyboards.firstMatch
        keyboard.buttons["return"].tap()
        XCTAssertTrue(waitForValue(of: emulator, containing: "ran: ^[^I|"), String(describing: emulator.value))
        for letter in ["e", "x", "i", "t"] { keyboard.keys[letter].tap() }
        XCTAssertTrue(waitForValue(of: emulator, containing: "$ exit"), String(describing: emulator.value))
        keyboard.buttons["return"].tap()
        let exited = app.descendants(matching: .any)["terminal-exit-status"]
        XCTAssertTrue(exited.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(exited.label, "Process exited")
        attach("terminal-exited")
        app.buttons["Close tab"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 5))
        XCTAssertTrue(second.isSelected)
    }

    @MainActor func testDarkAppearanceAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--terminal-fixture", "-byot.appearance", "dark",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let tab = app.buttons["terminal-tab-Terminal 1"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
        let emulator = app.descendants(matching: .any)["terminal-emulator"]
        XCTAssertTrue(waitForValue(of: emulator, containing: "byot"))
        let escape = app.buttons["terminal-key-escape"]
        XCTAssertTrue(escape.isHittable)
        XCTAssertGreaterThanOrEqual(escape.frame.height, 44 - 0.01)
        XCTAssertLessThanOrEqual(tab.frame.maxX, app.frame.width)
        attach("terminal-dark-largest-text")
        app.buttons["terminal-actions"].tap()
        XCTAssertTrue(app.buttons["Larger text"].waitForExistence(timeout: 5))
        attach("terminal-actions-menu")
    }

    @MainActor private func waitForValue(of element: XCUIElement, containing text: String) -> Bool {
        let predicate = NSPredicate { object, _ in
            ((object as? XCUIElement)?.value as? String)?.contains(text) == true
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5) == .completed
    }

    @MainActor private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
