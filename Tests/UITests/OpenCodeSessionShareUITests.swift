import XCTest

final class OpenCodeSessionShareUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testPublishShowsServerLinkAndUnpublishReturnsToPrivate() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--polish-ui-tests", "--share", "-byot.appearance", appearance]
            app.launch()
            openConversation(app)

            // Publishing is an explicit step from the session menu.
            app.buttons["session-actions"].tap()
            let menuItem = app.buttons["session-menu-share"]
            XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
            XCTAssertEqual(menuItem.label, "Publish on web")
            menuItem.tap()
            let publish = app.buttons["session-share-publish"]
            XCTAssertTrue(publish.waitForExistence(timeout: 5))
            XCTAssertFalse(app.descendants(matching: .any)["session-share-link"].exists)
            screenshot(app, name: "share-private-\(appearance)")

            publish.tap()
            let link = app.descendants(matching: .any)["session-share-link"].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 10))
            XCTAssertEqual(link.value as? String, "https://opncd.ai/share/fixture-history")
            XCTAssertTrue(app.buttons["session-share-copy"].exists)
            XCTAssertTrue(app.buttons["session-share-open"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["session-share-sheet"].firstMatch.exists)
            screenshot(app, name: "share-published-\(appearance)")

            // The session header keeps showing that the conversation is public.
            app.buttons["Done"].tap()
            let indicator = app.buttons["session-shared-indicator"]
            XCTAssertTrue(indicator.waitForExistence(timeout: 5))
            screenshot(app, name: "share-indicator-\(appearance)")

            indicator.tap()
            let unpublish = app.buttons["session-share-unpublish"]
            XCTAssertTrue(unpublish.waitForExistence(timeout: 5))
            unpublish.tap()
            let confirm = app.buttons["session-share-confirm-unpublish"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            confirm.tap()
            XCTAssertTrue(app.buttons["session-share-publish"].waitForExistence(timeout: 10))
            app.buttons["Done"].tap()
            XCTAssertTrue(indicator.waitForNonExistence(timeout: 5))
            app.terminate()
        }
    }

    @MainActor
    func testPublishedSheetFitsAccessibilityText() {
        let app = XCUIApplication()
        app.launchArguments = ["--polish-ui-tests", "--share", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        openConversation(app)
        app.buttons["session-actions"].tap()
        let menuItem = app.buttons["session-menu-share"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5))
        menuItem.tap()
        let publish = app.buttons["session-share-publish"]
        XCTAssertTrue(publish.waitForExistence(timeout: 5))
        publish.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session-share-link"].firstMatch.waitForExistence(timeout: 10))
        screenshot(app, name: "share-published-ax5")
        let unpublish = app.buttons["session-share-unpublish"]
        for _ in 0..<4 where !unpublish.isHittable { app.swipeUp() }
        XCTAssertTrue(unpublish.isHittable, "Every action stays reachable at the largest text size")
        screenshot(app, name: "share-published-ax5-scrolled")
        app.terminate()
    }

    @MainActor
    private func openConversation(_ app: XCUIApplication) {
        let conversation = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Long conversation'")).firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        XCTAssertTrue(app.buttons["session-actions"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
