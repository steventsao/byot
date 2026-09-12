import XCTest

final class AgentTextSelectionUITests: XCTestCase {
    @MainActor
    func testNativeCodeSelectionCopiesSubstring() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--text-selection-fixture"]
        app.launch()
        let select = app.buttons["Select code"]
        XCTAssertTrue(select.waitForExistence(timeout: 10))
        select.tap()
        let text = app.textViews["response-selection-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5), app.debugDescription)
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.03)).press(forDuration: 1.2)
        let copy = app.menuItems["Copy"].firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.tap()
        app.buttons["Done"].tap()
        app.buttons["Read clipboard"].tap()
        let clipboard = app.staticTexts["selection-clipboard"]
        XCTAssertTrue(clipboard.waitForExistence(timeout: 5))
        XCTAssertFalse(clipboard.label.isEmpty)
        XCTAssertTrue("let greeting = \"Hello, 世界\"\n    print(greeting)".contains(clipboard.label))
        XCTAssertLessThan(clipboard.label.count, 40)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "native-code-substring-copied"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testResponseSelectionAtLargestTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--text-selection-fixture", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let prose = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "precise selection")).firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 10))
        prose.press(forDuration: 1.2)
        app.buttons["Select text"].tap()
        let text = app.textViews["response-selection-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.swipeUp()
        XCTAssertTrue(app.buttons["Done"].isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "native-response-selection-accessibility"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
