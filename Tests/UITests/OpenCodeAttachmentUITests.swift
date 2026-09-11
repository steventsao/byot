import XCTest
import UIKit

final class OpenCodeAttachmentUITests: XCTestCase {
    @MainActor
    func testImageAndDocumentPreviewsKeepTheDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot"]
        app.launch()
        let composer = app.textFields["opencode-composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Keep this draft while previewing")
        for (fixture, filename) in [("Add Screenshot Fixture", "byot-design.png"),
                                    ("Add Text Fixture", "review-notes.txt")] {
            app.buttons["Add attachment"].tap()
            app.buttons[fixture].tap()
            let preview = app.buttons["Preview \(filename)"]
            XCTAssertTrue(preview.waitForExistence(timeout: 5))
            XCTAssertTrue(preview.isHittable)
            preview.tap()
            XCTAssertTrue(app.navigationBars[filename].waitForExistence(timeout: 5))
            XCTAssertTrue(app.otherElements["attachment-preview-content"].waitForExistence(timeout: 10))
            if filename.hasSuffix("png") {
                expectation(for: NSPredicate { _, _ in
                    (try? self.previewGreenCoverage(app)) ?? 0 > 0.04
                }, evaluatedWith: app)
                waitForExpectations(timeout: 15)
            } else {
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(
                    format: "label CONTAINS %@ OR value CONTAINS %@",
                    "Review the attachment preview", "Review the attachment preview"
                )).firstMatch.waitForExistence(timeout: 10))
            }
            attach("preview-\(filename)")
            app.buttons["Done"].tap()
            XCTAssertTrue(composer.waitForExistence(timeout: 5))
            XCTAssertEqual(composer.value as? String, "Keep this draft while previewing")
            let remove = app.buttons["Remove \(filename)"]
            XCTAssertTrue(remove.isHittable)
            remove.tap()
            XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        }
        attach("composer-after-previews")
    }

    @MainActor
    private func previewGreenCoverage(_ app: XCUIApplication) throws -> Double {
        let image = try XCTUnwrap(app.screenshot().image.cgImage)
        var pixels = [UInt8](repeating: 0, count: 40 * 80 * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 40, height: 80,
            bitsPerComponent: 8, bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 80))
        var count = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[i])
            let green = Double(pixels[i + 1])
            let blue = Double(pixels[i + 2])
            if green > red * 1.4 && green > blue * 1.2 && green > 40 { count += 1 }
        }
        return Double(count) / 3_200
    }

    @MainActor
    func testAttachmentRemovalAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["Add attachment"].waitForExistence(timeout: 10))
        let composer = app.textFields["Message"]
        composer.tap()
        composer.typeText("Review this design")
        app.buttons["Add attachment"].tap()
        app.buttons["Add Screenshot Fixture"].tap()
        let remove = app.buttons["Remove byot-design.png"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        attach("attachment-largest-text")
        XCTAssertLessThanOrEqual(remove.frame.maxX, app.frame.maxX - 10)
        XCTAssertGreaterThanOrEqual(remove.frame.width, 44)
        XCTAssertGreaterThanOrEqual(remove.frame.height, 44)
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testEmptyModelPickerDoesNotOverlapAutomaticAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["Choose model"].waitForExistence(timeout: 10))
        app.buttons["Choose model"].tap()
        let automatic = app.buttons["automatic-model-option"]
        let empty = app.staticTexts["No models"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        attach("empty-model-picker-largest-text")
        XCTAssertGreaterThanOrEqual(empty.frame.minY, automatic.frame.maxY)
        XCTAssertTrue(automatic.isHittable)
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAttachmentPickerScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot"]
        app.launch()

        let composer = app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        composer.typeText("Review this design and suggest the next implementation step")

        app.buttons["Add attachment"].tap()
        let addFixture = app.buttons["Add Screenshot Fixture"]
        XCTAssertTrue(addFixture.waitForExistence(timeout: 5))
        addFixture.tap()
        XCTAssertTrue(addFixture.waitForNonExistence(timeout: 5))

        let removeAttachment = app.buttons.matching(
            NSPredicate(format: "label == 'Remove byot-design.png'")
        ).firstMatch
        XCTAssertTrue(removeAttachment.waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        Thread.sleep(forTimeInterval: 1)

        let screenshot = XCUIScreen.main.screenshot()
        XCTContext.runActivity(named: "Prompt with photo attachment") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = "prompt-attachments"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

    }
}
