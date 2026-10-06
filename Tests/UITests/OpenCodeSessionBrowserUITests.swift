import XCTest
import UIKit

final class OpenCodeSessionBrowserUITests: XCTestCase {
    @MainActor
    func testSlowTranscriptHasOneCenteredLoadingState() throws {
        try checkSlowTranscript(largeText: false)
    }

    @MainActor
    func testSlowTranscriptAtLargestTextSize() throws {
        try checkSlowTranscript(largeText: true)
    }

    @MainActor
    private func checkSlowTranscript(largeText: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser", "--slow-transcript"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        defer { app.terminate() }
        let session = app.buttons["session-idle"]
        XCTAssertTrue(session.waitForExistence(timeout: 10))
        session.tap()
        let loading = app.descendants(matching: .any)["session-transcript-loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["session-task-progress"].exists,
                       "Tasks must not float above an unloaded transcript")
        XCTAssertFalse(app.activityIndicators.firstMatch.exists,
                       "Do not show a second spinner in the composer")
        let send = app.buttons["opencode-composer-send"]
        XCTAssertFalse(send.isEnabled)
        XCTAssertEqual(loading.frame.midX, app.frame.midX, accuracy: 2)
        XCTAssertGreaterThan(loading.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        XCTAssertLessThan(loading.frame.maxY, send.frame.minY)
        XCTAssertLessThanOrEqual(loading.frame.maxX, app.frame.maxX)
        // The send button sits low in the taller largest-text composer, so only
        // the regular size measures the vertical middle against it.
        let header = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Server Mac mini")).firstMatch
        if !largeText {
            XCTAssertEqual(loading.frame.midY, (header.frame.maxY + send.frame.minY) / 2, accuracy: 32,
                           "loader \(loading.frame), header \(header.frame), send \(send.frame)")
        }
        attach(largeText ? "slow-transcript-largest-text" : "slow-transcript")
        XCTAssertTrue(loading.waitForNonExistence(timeout: 25), app.debugDescription)
        XCTAssertTrue(app.buttons["session-task-progress"].waitForExistence(timeout: 5))
        if !largeText {
            let message = app.staticTexts["Review this project"]
            XCTAssertLessThan(message.frame.minY - header.frame.maxY, 40,
                              "message \(message.frame), header \(header.frame)")
        }
        attach(largeText ? "loaded-transcript-largest-text" : "loaded-transcript")
    }

    // TestFlight AEk0EYWkKW0QGxg8A34z3r0 and AJvs6pGkEt5k3xS1gTpvmDI: a session
    // whose status hasn't arrived says so in the header, not with a spinner
    // beside the send button.
    @MainActor
    func testUnknownStatusShowsNoComposerSpinner() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser", "--slow-status", "--dictation-fixture"]
        app.launch()
        defer { app.terminate() }
        let session = app.buttons["session-idle"]
        XCTAssertTrue(session.waitForExistence(timeout: 40))
        session.tap()
        XCTAssertTrue(app.staticTexts["Review this project"].waitForExistence(timeout: 10), app.debugDescription)
        let connecting = app.staticTexts["Connecting"]
        let send = app.buttons["opencode-composer-send"]
        let microphone = app.buttons["opencode-dictation-toggle"]
        attach("unknown-status")
        XCTAssertFalse(app.activityIndicators.firstMatch.exists, "The composer must not show a spinner")
        XCTAssertEqual(send.frame.minX - microphone.frame.maxX, 4, accuracy: 0.5,
                       "Nothing sits between the microphone and send")
        XCTAssertTrue(connecting.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(send.isEnabled)

        // The row with the model and agent knobs, as it is while typing.
        app.textFields["opencode-composer-message"].tap()
        XCTAssertTrue(app.buttons["Choose model"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.activityIndicators.firstMatch.exists, "The composer must not show a spinner")
        let sendFrame = send.frame
        let microphoneFrame = microphone.frame
        XCTAssertEqual(sendFrame.minX - microphoneFrame.maxX, 4, accuracy: 0.5,
                       "Nothing sits between the microphone and send")
        attach("unknown-status-focused")
        XCTAssertTrue(connecting.exists, "The status arrived before the composer was measured")

        // Neither control moves when the status arrives.
        XCTAssertTrue(app.staticTexts["Idle"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertEqual(send.frame.minX, sendFrame.minX, accuracy: 0.5)
        XCTAssertEqual(microphone.frame.minX, microphoneFrame.minX, accuracy: 0.5)
        attach("known-status-focused")
    }

    @MainActor
    func testEmptySessionActionStaysReadableAndOpensComposer() throws {
        try checkEmptySessionAction(largeText: false)
    }

    @MainActor
    func testEmptySessionActionAtLargestTextSize() throws {
        try checkEmptySessionAction(largeText: true)
    }

    @MainActor
    private func checkEmptySessionAction(largeText: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser", "--empty-session-browser"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.staticTexts["No sessions"].waitForExistence(timeout: 10), app.debugDescription)
        // The empty-state action is above the separate bottom compose button.
        let action = try XCTUnwrap(app.buttons.matching(identifier: "New session").allElementsBoundByIndex
            .filter { $0.isHittable }.min { $0.frame.minY < $1.frame.minY })
        attach(largeText ? "empty-sessions-largest-text" : "empty-sessions")
        XCTAssertGreaterThan(action.frame.width, action.frame.height,
                             "The action must read horizontally, not wrap one character per line")
        XCTAssertGreaterThanOrEqual(action.frame.height, 44 - 0.01)
        XCTAssertGreaterThanOrEqual(action.frame.minX, 0)
        XCTAssertLessThanOrEqual(action.frame.maxX, app.frame.width)
        XCTAssertLessThan(action.frame.maxY, app.textFields["session-search"].frame.minY)
        action.tap()
        XCTAssertTrue(app.buttons["new-session-server"].waitForExistence(timeout: 5), app.debugDescription)
        app.terminate()
    }

    @MainActor
    func testFinalProviderFailureReturnsToTheSessionList() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        let idle = app.buttons["session-idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 10))
        idle.tap()
        let failure = app.staticTexts["This model is no longer available."]
        XCTAssertTrue(failure.waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Needs attention"].waitForExistence(timeout: 10))
        XCTAssertTrue(failure.exists)
        app.buttons["root-menu"].tap()
        app.buttons["Session status"].tap()
        XCTAssertLessThan(idle.frame.minY, app.buttons["session-active"].frame.minY)
        attach("session-list-final-model-failure")
        app.terminate()
        app.launchArguments = ["--session-browser-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Needs attention"].waitForExistence(timeout: 10))
        XCTAssertTrue(failure.exists)
    }

    @MainActor
    func testOfflineLaunchShowsSavedSessionsAndTranscript() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser", "--offline-cache-fixture"]
        app.launch()
        let idle = app.buttons["session-idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 10))
        idle.tap()
        let prompt = app.staticTexts["Review this project"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(idle.waitForExistence(timeout: 5))
        // Leaving the conversation saves it; give the write a moment to land.
        Thread.sleep(forTimeInterval: 1)
        app.terminate()

        app.launchArguments = ["--session-browser-fixture", "--offline-cache-fixture", "--server-offline"]
        app.launch()
        XCTAssertTrue(idle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["session-active"].exists)
        let notice = app.staticTexts["offline-notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["offline-retry"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(app.buttons["offline-retry"].frame.height, 44 - 0.01)
        attach("offline-session-list")
        idle.tap()
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
        attach("offline-transcript")
        app.terminate()

        // The notice wraps rather than truncates at the largest text size.
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(notice.waitForExistence(timeout: 10), app.debugDescription)
        let retry = app.buttons["offline-retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(retry.frame.height, 44 - 0.01)
        XCTAssertLessThanOrEqual(notice.frame.maxX, app.frame.width)
        attach("offline-session-list-largest-text")
        app.terminate()
    }

    @MainActor
    func testLiveEventsUpdateTheSessionList() throws {
        try checkLiveSessionList(largeText: false)
    }

    @MainActor
    func testLiveEventsAtLargestTextSize() throws {
        try checkLiveSessionList(largeText: true)
    }

    @MainActor
    private func checkLiveSessionList(largeText: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser", "--live-session-list"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        // Neither appears in the first snapshot; both arrive over the server-wide stream.
        let live = app.buttons["session-live"]
        XCTAssertTrue(live.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Started from the terminal"].exists)
        let active = app.buttons["session-active"]
        XCTAssertTrue(app.staticTexts["Needs input"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(active.label.contains("Needs input"), active.label)
        XCTAssertGreaterThanOrEqual(active.frame.height, 44 - 0.01)
        attach(largeText ? "session-list-live-largest-text" : "session-list-live")
        app.terminate()
    }

    @MainActor
    func testSwipeLeftArchivesASession() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        let idle = app.buttons["session-idle"]
        XCTAssertTrue(idle.waitForExistence(timeout: 10), app.debugDescription)
        idle.swipeLeft()
        let archive = app.buttons["Archive"]
        XCTAssertTrue(archive.waitForExistence(timeout: 5), app.debugDescription)
        // A horizontal pill with the icon beside the title, not the round system action.
        XCTAssertGreaterThan(archive.frame.width, archive.frame.height * 1.5, archive.debugDescription)
        attach("session-swipe-archive")
        archive.tap()
        XCTAssertTrue(idle.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["session-active"].exists)
        // The fixture still lists the session with time.archived, as OpenCode 1.18 does.
        app.collectionViews.firstMatch.swipeDown()
        XCTAssertTrue(app.buttons["session-active"].waitForExistence(timeout: 5))
        XCTAssertFalse(idle.waitForExistence(timeout: 3), app.debugDescription)
        attach("session-archived")
    }

    @MainActor
    func testNewSessionUsesInlineServerAndProjectSelection() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        let compose = app.buttons["New session"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 10))
        compose.tap()
        let server = app.buttons["new-session-server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5), app.debugDescription)
        let windows = app.buttons["Windows"].firstMatch
        guard selectMenuItem(windows, opening: server) else {
            XCTFail("The server menu did not present", file: #filePath, line: #line)
            return
        }
        let project = app.buttons["new-session-project"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        let docs = app.buttons["docs"].firstMatch
        guard selectMenuItem(docs, opening: project) else {
            XCTFail("The project menu did not present", file: #filePath, line: #line)
            return
        }
        XCTAssertTrue(app.staticTexts["C:/work/docs"].waitForExistence(timeout: 5))
        attach("new-session-inline-context")
        guard selectMenuItem(app.buttons["Other directory…"], opening: project) else {
            XCTFail("The custom-directory menu item did not present", file: #filePath, line: #line)
            return
        }
        let directory = app.textFields["new-session-directory"]
        XCTAssertTrue(directory.waitForExistence(timeout: 5))
        directory.tap()
        directory.typeText("C:/work/new-project")
        app.swipeUp()
        app.buttons["start-session"].tap()
        let composer = app.textFields["opencode-composer-message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "A newly created session should activate its composer keyboard")
        let focusedComposer = app.textFields
            .matching(NSPredicate(format: "hasKeyboardFocus == true"))
            .matching(identifier: "opencode-composer-message")
            .firstMatch
        XCTAssertTrue(focusedComposer.waitForExistence(timeout: 5),
                      "The new session composer should receive keyboard focus")
        // The header opens the project's status where the server has one, and adds the branch it reports.
        let context = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Server Windows, project C:/work/new-project")).firstMatch
        XCTAssertTrue(context.exists, app.debugDescription)
        attach("new-session-custom-directory")
    }

    @MainActor
    private func selectMenuItem(_ item: XCUIElement, opening menu: XCUIElement) -> Bool {
        for _ in 0..<3 {
            menu.tap()
            if item.waitForExistence(timeout: 2) {
                item.tap()
                return true
            }
        }
        return false
    }

    @MainActor
    func testBottomSearchAndServerMenuPreserveEditedProfile() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        let search = app.textFields["session-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        let compose = app.buttons.matching(identifier: "New session").firstMatch
        XCTAssertTrue(compose.isHittable)
        XCTAssertGreaterThan(search.frame.minY, app.frame.height * 0.7)
        XCTAssertLessThan(abs(search.frame.midY - compose.frame.midY), 24)
        // The chips switch servers; the server's own actions are under Settings.
        app.buttons["Windows"].tap()
        XCTAssertTrue(app.staticTexts["Windows build"].waitForExistence(timeout: 10))
        XCTAssertTrue(selectMenuItem(app.buttons["Settings"], opening: app.buttons["root-menu"]), app.debugDescription)
        XCTAssertTrue(app.buttons["Edit server"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Edit server"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Windows")
        XCTAssertEqual(app.textFields["https://your-mac.example.ts.net"].value as? String,
                       "https://windows.example.test")
        attach("edit-selected-server")
        app.buttons["Cancel"].tap()
    }

    // ASC-AHwZujtTEgWM5VoXJrN0T-I
    @MainActor
    func testRootHasOneTopRightMenu() throws {
        try checkOneTopRightMenu(regularWidth: false)
    }

    @MainActor
    func testSidebarHasOneTopRightMenuAtRegularWidth() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        try checkOneTopRightMenu(regularWidth: true)
    }

    /// The server menu, the list options, Terminal and Status were separate
    /// controls in the top right. One menu there now holds all of them.
    @MainActor
    private func checkOneTopRightMenu(regularWidth: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        if regularWidth { app.launchArguments.append("--regular-width") }
        app.launch()
        XCTAssertTrue(app.buttons["session-active"].waitForExistence(timeout: 10), app.debugDescription)
        for retired in ["OpenCode servers", "Session list options", "open-terminal", "open-status"] {
            XCTAssertFalse(app.buttons[retired].exists, retired)
        }
        let bar = app.navigationBars["byot"]
        let trailing = bar.buttons.allElementsBoundByIndex.filter { $0.frame.midX > bar.frame.midX }
        // Beside a conversation, the system adds its own sidebar toggle after the menu.
        XCTAssertEqual(trailing.map(\.label), regularWidth ? ["Menu", "Hide Sidebar"] : ["Menu"], bar.debugDescription)
        XCTAssertEqual(trailing.first?.identifier, "root-menu")
        let name = regularWidth ? "root-menu-regular-width" : "root-menu"
        attach(name + "-closed")

        app.buttons["root-menu"].tap()
        let menu = app.collectionViews.containing(.button, identifier: "Settings").firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        for item in ["Group by project", "Session status", "Terminal", "Status"] {
            XCTAssertTrue(menu.buttons[item].exists, item + "\n" + app.debugDescription)
        }
        attach(name)
        // The bar's own Add server button is outside the menu, so look inside it.
        menu.buttons["Settings"].tap()
        let settings = app.collectionViews.containing(.button, identifier: "Notifications").firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        for item in ["Edit server", "Remove server", "Add server", "Scan pairing code"] {
            XCTAssertTrue(settings.buttons[item].exists, item + "\n" + app.debugDescription)
        }
        attach(name + "-settings")
    }

    // ASC-AFYHRmAVeK5fOtdHnURLf6Q
    @MainActor
    func testSelectedServerChipIsNeutralInLightAndDark() throws {
        continueAfterFailure = false
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--session-browser-fixture", "--reset-browser", "-byot.appearance", appearance]
            app.launch()
            XCTAssertTrue(app.buttons["session-active"].waitForExistence(timeout: 10), app.debugDescription)
            let chip = app.buttons["Mac mini"]
            XCTAssertEqual(chip.value as? String, "Selected server")
            attach("server-chips-" + appearance)
            // The mint chip's name and fill were green; a neutral chip is all grays.
            XCTAssertLessThan(try channelSpread(of: chip), 0.05, appearance)
            app.terminate()
        }
    }

    /// The widest gap between the red, green and blue of any pixel of
    /// `element`: 0 when every pixel is a gray, up to 1.
    @MainActor
    private func channelSpread(of element: XCUIElement) throws -> Double {
        let image = try XCTUnwrap(element.screenshot().image.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var spread = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let channels = pixels[i..<i + 3].map(Int.init)
            spread = max(spread, (channels.max() ?? 0) - (channels.min() ?? 0))
        }
        return Double(spread) / 255
    }

    @MainActor
    func testFlatListGroupingSortingServerSwitchAndDirectNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser"]
        app.launch()
        XCTAssertTrue(app.buttons["Mac mini"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Windows"].exists)
        let active = app.buttons["session-active"]
        XCTAssertTrue(active.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Working"].exists)
        XCTAssertTrue(app.staticTexts["Provider rate limit"].exists)
        attach("sessions-recent")

        app.buttons["root-menu"].tap()
        app.buttons["Session status"].tap()
        let retry = app.buttons["session-retry"]
        XCTAssertLessThan(retry.frame.minY, active.frame.minY)
        attach("sessions-by-status")

        app.buttons["root-menu"].tap()
        app.buttons["Group by project"].tap()
        // byot's count includes the session in its login-flow worktree.
        XCTAssertTrue(app.staticTexts["1 retrying · 3 sessions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["New session in byot"].exists)
        attach("sessions-grouped")

        app.terminate()
        app.launchArguments = ["--session-browser-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["New session in byot"].waitForExistence(timeout: 10))
        XCTAssertLessThan(app.buttons["session-retry"].frame.minY, app.buttons["session-active"].frame.minY)
        app.buttons["Windows"].tap()
        expectation(for: NSPredicate(format: "value == %@", "Selected server"), evaluatedWith: app.buttons["Windows"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["Windows build"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["Fix checkout"].exists)
        app.buttons["session-active"].tap()
        XCTAssertTrue(app.textFields["Message"].waitForExistence(timeout: 10), app.debugDescription)
        attach("direct-session-navigation")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Windows"].waitForExistence(timeout: 5))
        app.buttons["New session in byot"].tap()
        XCTAssertTrue(app.textFields["Message"].waitForExistence(timeout: 10), app.debugDescription)
        attach("new-session-navigation")
    }

    @MainActor
    func testLargeTypeSearchAndServerBar() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--session-browser-fixture", "--reset-browser", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["session-active"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Mac mini"].isHittable)
        attach("sessions-accessibility")
        let search = app.textFields["session-search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("FUZZ-SEARCH-" + String(repeating: "A", count: 128))
        XCTAssertTrue(app.staticTexts["No matching sessions"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No matching sessions"].isHittable)
        attach("sessions-search-accessibility")
    }

    @MainActor private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
