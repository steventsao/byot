import XCTest
import UIKit

final class BYOTAppearanceUITests: XCTestCase {
    @MainActor
    func testAppearanceChangesImmediatelyAndPersists() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["About BYOT"].waitForExistence(timeout: 10))
        let systemIsDark = try backgroundIsDark(app)
        app.buttons["About BYOT"].tap()
        let picker = app.buttons["appearance-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.label.contains("System"), picker.debugDescription)

        for (name, isDark) in [("Dark", true), ("Light", false)] {
            picker.tap()
            app.buttons[name].tap()
            XCTAssertTrue(picker.label.contains(name), picker.debugDescription)
            try assertAppearance(app, dark: isDark, name: "settings-\(name)")
            app.buttons["Done"].tap()
            try assertAppearance(app, dark: isDark, name: "home-\(name)")

            // A separate system form must inherit the app's chosen appearance.
            app.buttons["Add server"].tap()
            XCTAssertTrue(app.navigationBars["OpenCode server"].waitForExistence(timeout: 5))
            try assertAppearance(app, dark: isDark, name: "server-\(name)")
            app.buttons["Cancel"].tap()

            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons["About BYOT"].waitForExistence(timeout: 5))
            try assertAppearance(app, dark: isDark, name: "relaunch-\(name)")
            app.buttons["About BYOT"].tap()
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(picker.label.contains(name), picker.debugDescription)
        }

        picker.tap()
        app.buttons["System"].tap()
        try assertAppearance(app, dark: systemIsDark, name: "settings-System")
        app.buttons["Done"].tap()
        try assertAppearance(app, dark: systemIsDark, name: "home-System")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["About BYOT"].waitForExistence(timeout: 5))
        try assertAppearance(app, dark: systemIsDark, name: "relaunch-System")
    }

    @MainActor
    private func assertAppearance(_ app: XCUIApplication, dark: Bool, name: String) throws {
        // Check the rendered background rather than a debug-only theme label.
        let matches = NSPredicate { _, _ in
            (try? self.backgroundIsDark(app)) == dark
        }
        expectation(for: matches, evaluatedWith: app)
        waitForExpectations(timeout: 5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func backgroundIsDark(_ app: XCUIApplication) throws -> Bool {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        // This blank area is below the controls on the home, About, and server screens.
        let sample = try XCTUnwrap(image.cropping(to: CGRect(
            x: Double(image.width) * 0.5,
            y: Double(image.height) * 0.86,
            width: 8,
            height: 8
        )))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) < 384
    }
}
