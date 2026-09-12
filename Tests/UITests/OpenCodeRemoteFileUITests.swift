import XCTest

final class OpenCodeRemoteFileUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testBrowseReadSelectLinesRemoveAndSendContext() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--remote-files-fixture"]
        app.launch()
        let open = app.buttons["remote-file-picker"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(app.staticTexts["/repo/byot"].waitForExistence(timeout: 5))
        app.buttons["Sources"].tap()
        let file = app.buttons["remote-file-open-Sources/App.swift"]
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        let line2 = app.buttons["remote-file-line-2"]
        XCTAssertTrue(line2.waitForExistence(timeout: 5))
        line2.tap()
        app.buttons["remote-file-line-3"].tap()
        XCTAssertTrue(app.staticTexts["Lines 2–3"].exists)
        attach("server-file-line-range")
        app.buttons["remote-file-add-lines"].tap()
        let selected = app.buttons["Preview server file Sources/App.swift:2–3"]
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        app.buttons["Remove server file Sources/App.swift:2–3"].tap()
        XCTAssertTrue(selected.waitForNonExistence(timeout: 5))
        open.tap()
        app.buttons["Changed"].tap()
        XCTAssertTrue(app.staticTexts["Deleted · −4"].waitForExistence(timeout: 5))
        app.buttons["Add Sources/App.swift as context"].tap()
        XCTAssertTrue(app.buttons["Preview server file Sources/App.swift"].waitForExistence(timeout: 5))
        attach("server-file-context-composer")
        app.buttons["remote-file-send"].tap()
        XCTAssertTrue(app.staticTexts["file:///repo/byot/Sources/App.swift"].waitForExistence(timeout: 5))
    }

    @MainActor func testExplicitAtMentionSearchAddsStructuredContextAndKeepsProse() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--remote-files-fixture"]
        app.launch()
        let draft = app.textFields["remote-file-draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertTrue(focus(draft, in: app), "The draft must have keyboard focus before typing")
        draft.typeText("Explain @App")
        let suggestion = app.buttons["remote-file-suggestion-Sources/App.swift"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        suggestion.tap()
        XCTAssertEqual(draft.value as? String, "Explain ")
        XCTAssertTrue(app.buttons["Preview server file Sources/App.swift"].exists)
        attach("at-mention-context")
    }

    @MainActor private func focus(_ field: XCUIElement, in app: XCUIApplication) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: field)
        guard XCTWaiter.wait(for: [hittable], timeout: 5) == .completed else { return false }
        for _ in 0..<2 {
            field.tap()
            let focused = app.descendants(matching: field.elementType)
                .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.keyboards.firstMatch.exists && focused.allElementsBoundByIndex.contains { $0.frame == field.frame }
            }, object: nil)
            if XCTWaiter.wait(for: [ready], timeout: 3) == .completed { return true }
        }
        return false
    }

    @MainActor private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
