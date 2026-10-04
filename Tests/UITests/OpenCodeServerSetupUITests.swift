import XCTest

/// Server setup shortcuts on a fresh install: scanning a pairing code, finding
/// nearby servers, and opening a `byot://pair` link (#93, #10).
final class OpenCodeServerSetupUITests: XCTestCase {
    @MainActor
    func testSetupShortcutsOpenScannerAndNearbyPages() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments.append("--telemetry-disabled")  // No usage-data question over the real root view.
        app.launch()

        let scan = app.buttons["scan-pairing-code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["find-nearby-servers"].exists)
        XCTAssertTrue(app.buttons["Add server"].exists)
        attach(app, "empty-state")

        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan pairing code"].waitForExistence(timeout: 5))
        // The simulator has no camera, so the page offers the other ways in.
        XCTAssertTrue(app.staticTexts["No camera available"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose from Photos"].exists)
        attach(app, "scanner")

        app.navigationBars["Scan pairing code"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["OpenCode server"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["editor-find-nearby"].exists)
        attach(app, "form")

        app.buttons["editor-find-nearby"].tap()
        XCTAssertTrue(app.navigationBars["Find nearby"].waitForExistence(timeout: 5))
        let settled = NSPredicate { _, _ in
            app.staticTexts["No servers found yet"].exists || app.buttons["nearby-server"].exists
        }
        expectation(for: settled, evaluatedWith: app)
        waitForExpectations(timeout: 10)
        attach(app, "nearby")
    }

    @MainActor
    func testPairingLinkFillsTheForm() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments.append("--telemetry-disabled")  // No usage-data question over the real root view.
        app.launch()
        XCTAssertTrue(app.buttons["scan-pairing-code"].waitForExistence(timeout: 10))

        app.open(URL(string: "byot://pair?v=1&url=http%3A%2F%2F192.168.1.8%3A4096&name=Studio")!)
        XCTAssertTrue(app.navigationBars["OpenCode server"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Name"].value as? String, "Studio")
        XCTAssertEqual(app.textFields["https://your-mac.example.ts.net"].value as? String, "http://192.168.1.8:4096")
        XCTAssertTrue(app.otherElements["local-http-notice"].exists || app.staticTexts["Local network, not encrypted"].exists)
        attach(app, "paired-form")
    }

    @MainActor
    func testSetupAtLargestAccessibilityTextSize() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchArguments.append("--telemetry-disabled")  // No usage-data question over the real root view.
        app.launch()
        let scan = app.buttons["scan-pairing-code"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        attach(app, "empty-state-axxxl")
        scan.tap()
        XCTAssertTrue(app.navigationBars["Scan pairing code"].waitForExistence(timeout: 5))
        attach(app, "scanner-axxxl")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
