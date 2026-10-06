import XCTest
import UIKit

final class OpenCodeAttachmentUITests: XCTestCase {
    @MainActor
    func testDraftSurvivesAppTermination() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "--persist-composer-draft"]
        app.launch()
        let composer = app.textFields["opencode-composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        if let value = composer.value as? String, value != "Message", !value.isEmpty {
            composer.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        let remove = app.buttons["Remove review-notes.txt"]
        if remove.exists { remove.tap() }
        composer.tap()
        composer.typeText("Draft survives relaunch")
        app.buttons["Add attachment"].tap()
        app.buttons["Add Text Fixture"].tap()
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Draft survives relaunch")
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        attach("restored-composer-draft")
        app.buttons["opencode-composer-send"].tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "Message")
        XCTAssertFalse(remove.exists)
    }

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
        // Accessibility converts screen coordinates through floating-point transforms.
        // A 44 pt control can be reported as 43.99999999999994 pt.
        XCTAssertGreaterThanOrEqual(remove.frame.width, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(remove.frame.height, 44 - 0.01)
        XCTAssertTrue(remove.isHittable)
        remove.tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testEmptyModelPickerDoesNotOverlapAutomaticAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let composer = app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        // The model control lives in the composer's knob row, which appears once
        // the composer is in use.
        composer.tap()
        XCTAssertTrue(app.buttons["Choose model"].waitForExistence(timeout: 10))
        app.buttons["Choose model"].tap()
        let automatic = app.buttons["automatic-model-option"]
        let empty = app.staticTexts["No models"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        attach("empty-model-picker-largest-text")
        XCTAssertGreaterThanOrEqual(empty.frame.minY, automatic.frame.maxY)
        XCTAssertTrue(automatic.isHittable)
    }

    @MainActor
    func testComposerCollapsesToOneRowAndKeepsFilesInTheAddMenu() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot"]
        app.launch()
        let composer = app.textFields["opencode-composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        let model = app.buttons["Choose model"]
        let add = app.buttons["Add attachment"]
        let send = app.buttons["opencode-composer-send"]
        XCTAssertTrue(add.exists)
        XCTAssertTrue(send.exists)
        XCTAssertFalse(model.exists, "An untouched composer shows one row")
        XCTAssertFalse(app.buttons["remote-file-picker"].exists, "Files moved into the add menu")
        let collapsed = composer.frame.height
        attach("composer-collapsed")

        add.tap()
        let serverFiles = app.buttons["Server Files"]
        XCTAssertTrue(serverFiles.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose Photo"].exists)
        XCTAssertTrue(app.buttons["Choose File"].exists)
        attach("composer-add-menu")
        serverFiles.tap()
        let browser = app.navigationBars["Server files"]
        XCTAssertTrue(browser.waitForExistence(timeout: 10), app.debugDescription)
        browser.buttons["Done"].tap()
        XCTAssertTrue(browser.waitForNonExistence(timeout: 10))

        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5), "Focus reveals the knob row")
        composer.typeText("Minimize the composer after sending")
        XCTAssertGreaterThan(model.frame.minY, composer.frame.maxY,
                             "The knobs sit under the message, in one row")
        attach("composer-expanded")

        XCTAssertTrue(app.buttons["opencode-composer-send"].isHittable)
        app.buttons["opencode-composer-send"].tap()
        XCTAssertTrue(model.waitForNonExistence(timeout: 5),
                      "Sending folds the composer back to one row")
        XCTAssertEqual(composer.value as? String, "Message")
        XCTAssertEqual(composer.frame.height, collapsed, accuracy: 1)
        attach("composer-collapsed-after-send")
    }

    // One row under the message holds every knob, in view: none scrolled away,
    // clipped or under the microphone and send (TestFlight
    // AIAoHtnG8Ldw4SfpRhItoTo asked for the one row, AL92ozHEMfBSiCvNBmFR3KQ
    // for knobs that fit it).
    @MainActor
    func testEveryComposerKnobSharesTheRowWithSend() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "--composer-catalog"]
        app.launch()
        let composer = app.textFields["opencode-composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        let add = app.buttons["Add attachment"]
        let model = app.buttons["Choose model"]
        let agent = app.buttons["opencode-agent-picker"]
        let variant = app.buttons["opencode-variant-picker"]
        let microphone = app.buttons["opencode-dictation-toggle"]
        let send = app.buttons["opencode-composer-send"]
        for control in [add, model, agent, variant, send] {
            XCTAssertTrue(control.waitForExistence(timeout: 5), control.debugDescription)
        }
        attach("composer-one-control-row")
        assertOneRow([add, model, agent, variant] + (microphone.exists ? [microphone] : []) + [send],
                     under: composer, in: app)
    }

    // The row at its fullest: a long model name with the shell toggle and the
    // microphone present, at the width of the phone the report came from and of
    // the narrowest current one (TestFlight AL92ozHEMfBSiCvNBmFR3KQ).
    @MainActor
    func testComposerKnobsFitWithLongModelNameShellAndDictation() throws {
        let xxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"]
        let accessibility = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        let chinese = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        let layouts: [(name: String, width: String, arguments: [String])] = [
            ("regular-english", "393", []), ("regular-chinese", "393", chinese),
            ("xxxl-english", "393", xxxl), ("xxxl-chinese", "393", xxxl + chinese),
            ("accessibility-english", "393", accessibility),
            ("accessibility-chinese", "393", accessibility + chinese),
            ("regular-narrow", "375", [])
        ]
        for layout in layouts {
            let app = launchCrowdedComposer(["-BYOTScreenWidth", layout.width] + layout.arguments)
            let composer = app.textFields["opencode-composer-message"]
            let controls = crowdedControls(in: app)
            attach("composer-crowded-row-\(layout.name)")
            if layout.name.hasPrefix("accessibility") {
                // These sizes stack the knobs on their own lines instead.
                for control in controls {
                    XCTAssertTrue(control.exists, "\(layout.name): \(control)")
                    XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX, "\(layout.name): \(control)")
                    XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX, "\(layout.name): \(control)")
                }
                XCTAssertTrue(controls[controls.count - 1].isHittable, layout.name)
            } else {
                assertOneRow(controls, under: composer, in: app, "\(layout.name):")
                let agent = app.buttons["opencode-agent-picker"]
                XCTAssertEqual(agent.value as? String, "Build")
                agent.tap()
                XCTAssertEqual(agent.value as? String, "Plan", "The toggle still cycles without its name")
                assertOneRow(controls, under: composer, in: app, "\(layout.name) after switching agent:")
            }
            app.terminate()
        }
    }

    // Icons are for a row short of room. A wide one, here an iPhone on its
    // side, spells every knob out as before.
    @MainActor
    func testComposerKnobsKeepTheirNamesWhereTheyFit() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchCrowdedComposer([])
        attach("composer-crowded-row-landscape")
        assertOneRow(crowdedControls(in: app), under: app.textFields["opencode-composer-message"], in: app)
        for knob in ["opencode-model-picker", "opencode-agent-picker", "opencode-variant-picker"] {
            XCTAssertGreaterThan(app.buttons[knob].frame.width, 60, "\(knob) shows its name")
        }
    }

    // A column too narrow for the icons alone (an iPad slide-over, a zoomed
    // display) scrolls the knobs; the microphone and send stay where they are.
    @MainActor
    func testComposerKnobsScrollWhenEvenIconsCannotFit() throws {
        let app = launchCrowdedComposer(["-BYOTScreenWidth", "320"])
        let composer = app.textFields["opencode-composer-message"]
        let controls = crowdedControls(in: app)
        let variant = app.buttons["opencode-variant-picker"]
        attach("composer-knobs-scroll-narrow")
        assertOneRow(Array(controls[..<3]), under: composer, in: app)
        XCTAssertFalse(variant.isHittable, "The last knob starts out of view at this width")
        app.buttons["opencode-agent-picker"].swipeLeft()
        attach("composer-knobs-scrolled-narrow")
        assertOneRow(Array(controls[3...]), under: composer, in: app, "scrolled:")
    }

    /// Opens the composer with a long model name, the shell toggle, both
    /// agents, an effort and the microphone, and waits for its knobs.
    @MainActor
    private func launchCrowdedComposer(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "--composer-catalog", "--composer-crowded",
                               "--dictation-fixture"] + arguments
        app.launch()
        let composer = app.textFields["opencode-composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        XCTAssertTrue(app.buttons["opencode-variant-picker"].waitForExistence(timeout: 5))
        return app
    }

    /// Every control of the crowded row, leading to trailing.
    @MainActor
    private func crowdedControls(in app: XCUIApplication) -> [XCUIElement] {
        ["opencode-composer-add", "opencode-shell-toggle", "opencode-model-picker", "opencode-agent-picker",
         "opencode-variant-picker", "opencode-dictation-toggle", "opencode-composer-send"].map { app.buttons[$0] }
    }

    /// The controls run left to right in one row under the message, each in
    /// view at full size, none reaching under the next.
    @MainActor
    private func assertOneRow(_ controls: [XCUIElement], under composer: XCUIElement, in app: XCUIApplication,
                              _ context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        var previous: XCUIElement?
        for control in controls {
            XCTAssertTrue(control.exists, "\(context) \(control)", file: file, line: line)
            let name = "\(context) \(control.identifier.isEmpty ? control.label : control.identifier) \(control.frame)"
            XCTAssertTrue(control.isHittable, "In view: \(name)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.width, 44 - 0.01, "At full size: \(name)", file: file, line: line)
            XCTAssertLessThan(abs(control.frame.midY - controls[controls.count - 1].frame.midY), 12,
                              "Shares the row: \(name)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.midY, composer.frame.maxY,
                                        "Sits under the message: \(name)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(control.frame.minX, (previous?.frame.maxX ?? app.frame.minX) - 0.5,
                                        "Starts after the control before it: \(name)", file: file, line: line)
            previous = control
        }
        XCTAssertLessThanOrEqual(previous?.frame.maxX ?? 0, app.frame.maxX, context, file: file, line: line)
    }

    @MainActor
    func testAgentToggleCyclesPrimaryAgentsInOneTap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "--composer-catalog"]
        app.launch()
        let composer = app.textFields["opencode-composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        let agent = app.buttons["opencode-agent-picker"]
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        XCTAssertEqual(agent.value as? String, "Build", "The toggle names the session's agent")
        XCTAssertGreaterThanOrEqual(agent.frame.height, 44)
        agent.tap()
        XCTAssertEqual(agent.value as? String, "Plan")
        attach("composer-agent-toggle-plan")
        agent.tap()
        XCTAssertEqual(agent.value as? String, "Build", "Cycling wraps back to the first agent")

        // Touch and hold lists every agent and opens the full picker.
        agent.press(forDuration: 1)
        let allAgents = app.buttons["All Agents…"]
        XCTAssertTrue(allAgents.waitForExistence(timeout: 5))
        attach("composer-agent-menu")
        allAgents.tap()
        let plan = app.buttons["opencode-agent-plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        plan.tap()
        XCTAssertTrue(plan.waitForNonExistence(timeout: 5))
        // The sheet took focus, so the composer folded; refocus to see the knobs.
        composer.tap()
        XCTAssertTrue(agent.waitForExistence(timeout: 5))
        XCTAssertEqual(agent.value as? String, "Plan")
    }

    @MainActor
    func testComposerKnobsStayReachableAtLargestTextSize() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--attachment-screenshot", "--composer-catalog",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let composer = app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.tap()
        let send = app.buttons["opencode-composer-send"]
        for control in [app.buttons["Add attachment"], app.buttons["Choose model"],
                        app.buttons["opencode-agent-picker"], app.buttons["opencode-variant-picker"], send] {
            XCTAssertTrue(control.waitForExistence(timeout: 5), control.debugDescription)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
        }
        attach("composer-controls-largest-text")
        XCTAssertTrue(send.isHittable)
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

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
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

        let opener = app.buttons["Add attachment"]
        let openerReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: opener)
        XCTAssertEqual(XCTWaiter.wait(for: [openerReady], timeout: 5), .completed,
                       "The attachment menu must be available before opening it")
        opener.tap()
        let addFixture = app.buttons["Add Screenshot Fixture"]
        // Retry one missed opening tap only while the fixture is still absent;
        // leave an already-open menu untouched.
        if !addFixture.waitForExistence(timeout: 3), opener.exists, opener.isHittable, !addFixture.exists {
            opener.tap()
        }
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
