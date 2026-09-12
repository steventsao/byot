import XCTest

/// Uses the production app, HTTPS transport, server editor, and Keychain.
/// scripts/test-opencode-upstream.sh supplies real, pinned upstream servers.
final class OpenCodeUpstreamLiveUITests: XCTestCase {
    @MainActor
    func testComposerSlashAgentAndVariantControlsOnRealServers() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BYOT_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Run scripts/test-opencode-upstream.sh") }
        let root = try XCTUnwrap(environment["BYOT_LIVE_ROOT"])
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        for (major, port) in [("v1", 4195), ("v2", 4199)] {
            connect(app, name: "Composer \(major)", port: port, directory: root + "/\(major)/project")
            let newSession = app.buttons["New session"].firstMatch
            XCTAssertTrue(newSession.waitForExistence(timeout: 10))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: newSession)
            waitForExpectations(timeout: 20)
            newSession.tap()
            startConfiguredSession(app)
            let composer = app.textFields["opencode-composer-message"]
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            app.buttons["Choose model"].tap()
            let model = app.buttons["Local acceptance fixture, BYOT Fixture"]
            XCTAssertTrue(model.waitForExistence(timeout: 10))
            model.tap()
            let agentPicker = app.buttons["opencode-agent-picker"]
            XCTAssertTrue(agentPicker.waitForExistence(timeout: 10))
            agentPicker.tap()
            let plan = app.buttons["opencode-agent-plan"]
            XCTAssertTrue(plan.waitForExistence(timeout: 10))
            plan.tap()
            let variants = app.buttons["opencode-variant-picker"]
            XCTAssertTrue(variants.waitForExistence(timeout: 10))
            variants.tap()
            app.buttons["byot-careful"].tap()
            XCTAssertEqual(variants.value as? String, "byot-careful")
            composer.tap()
            composer.typeText("/byot")
            let custom = app.buttons["opencode-command-command:byot-acceptance"]
            XCTAssertTrue(custom.waitForExistence(timeout: 10))
            XCTAssertTrue(custom.isHittable)
            attach("\(major)-slash-command-catalog")
            custom.tap()
            composer.typeText("UI argument \(major)")
            XCTAssertTrue(app.staticTexts["opencode-command-arguments"].exists)
            attach("\(major)-agent-variant-command-ready")
            let send = app.buttons["opencode-composer-send"]
            XCTAssertTrue(send.isHittable)
            send.tap()
            XCTAssertTrue(app.staticTexts["BYOT upstream compatibility verified."].firstMatch.waitForExistence(timeout: 30))
            app.buttons["session-actions"].tap()
            app.buttons["Session details"].tap()
            XCTAssertTrue(app.navigationBars["Session details"].waitForExistence(timeout: 10))
            let rename = app.buttons["session-rename"]
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: rename)
            waitForExpectations(timeout: 10)
            rename.tap()
            let alert = app.alerts["Rename conversation"]
            XCTAssertTrue(alert.waitForExistence(timeout: 5))
            let title = alert.textFields.firstMatch
            let renamed = "Composer verified \(major)"
            title.tap()
            title.press(forDuration: 1.1)
            let selectAll = app.menuItems["Select All"].firstMatch
            XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
            selectAll.tap()
            title.typeText(renamed)
            XCTAssertEqual(title.value as? String, renamed, "Replace the entire old title before saving")
            alert.buttons["Save"].tap()
            XCTAssertTrue(app.staticTexts[renamed].waitForExistence(timeout: 10))
            attach("\(major)-session-details-renamed")
            app.buttons["Done"].tap()
            XCTAssertTrue(app.navigationBars[renamed].waitForExistence(timeout: 5))
            app.buttons["session-actions"].tap()
            app.buttons["Tasks"].tap()
            XCTAssertTrue(app.navigationBars["Tasks"].waitForExistence(timeout: 5))
            attach("\(major)-session-tasks")
            app.buttons["Done"].tap()
            app.buttons["session-actions"].tap()
            let undo = app.buttons["session-menu-undo"]
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            XCTAssertTrue(undo.isEnabled)
            undo.tap()
            expectation(for: NSPredicate(format: "value CONTAINS %@", "UI argument \(major)"), evaluatedWith: composer)
            waitForExpectations(timeout: 10)
            attach("\(major)-undo-restored-command-prompt")
            app.buttons["session-actions"].tap()
            let redo = app.buttons["session-menu-redo"]
            XCTAssertTrue(redo.waitForExistence(timeout: 5))
            XCTAssertTrue(redo.isEnabled)
            redo.tap()
            XCTAssertTrue(app.staticTexts["BYOT upstream compatibility verified."].firstMatch.waitForExistence(timeout: 10))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    @MainActor
    func testRetiredAutomaticModelRecoversOnV1AndV2() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BYOT_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Run scripts/test-opencode-upstream.sh") }
        let root = try XCTUnwrap(environment["BYOT_LIVE_ROOT"])
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        for (major, port) in [("v1", 4195), ("v2", 4199)] {
            connect(app, name: "Recovery \(major)", port: port, directory: root + "/\(major)/retired")
            let newSession = app.buttons["New session"].firstMatch
            XCTAssertTrue(newSession.waitForExistence(timeout: 10))
            expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: newSession)
            waitForExpectations(timeout: 20)
            newSession.tap()
            startConfiguredSession(app)
            // SwiftUI removes the placeholder from the accessibility identifier
            // after typing. The chat has one text field, which remains stable.
            let composer = app.textFields.firstMatch
            XCTAssertTrue(composer.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["Choose model"].exists)
            let prompt = "Recover this prompt on \(major)."
            composer.tap()
            composer.typeText(prompt)
            let send = app.buttons["Send message"]
            expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: send)
            waitForExpectations(timeout: 10)
            XCTAssertEqual(composer.value as? String, prompt)
            attach("\(major)-retired-prompt-ready")
            send.tap()
            expectation(for: NSPredicate(format: "value != %@", prompt), evaluatedWith: composer)
            waitForExpectations(timeout: 5)
            let choose = app.buttons["Choose another model"]
            XCTAssertTrue(choose.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10), "Model recovery must be visible above the composer")
            app.swipeUp()
            attach("\(major)-retired-model-recovery")
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "no longer available")).firstMatch.exists)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "about:blank")).firstMatch.exists)
            choose.tap()
            let active = app.buttons["Local acceptance fixture, BYOT Fixture"]
            XCTAssertTrue(active.waitForExistence(timeout: 10))
            active.tap()
            let retry = app.buttons["retry-model-failure"]
            XCTAssertTrue(retry.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(retry.isHittable, "The composer must not cover model recovery")
            retry.tap()
            let reply = app.staticTexts["BYOT upstream compatibility verified."].firstMatch
            XCTAssertTrue(reply.waitForExistence(timeout: 30), app.debugDescription)
            app.swipeUp()
            attach("\(major)-recovered-with-active-model")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    @MainActor
    func testV1AndV2ConnectSendReloadAndSwitchServers() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BYOT_LIVE_ACCEPTANCE"] == "1" else { throw XCTSkip("Run scripts/test-opencode-upstream.sh") }
        let root = try XCTUnwrap(environment["BYOT_LIVE_ROOT"])
        let v1 = try XCTUnwrap(environment["BYOT_LIVE_V1_VERSION"])
        let v2 = try XCTUnwrap(environment["BYOT_LIVE_V2_VERSION"])
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "Password AutoFill") { interruption in
            guard interruption.buttons["Not Now"].exists else { return false }
            interruption.buttons["Not Now"].tap()
            return true
        }
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        let v1Name = "OpenCode " + v1
        let v2Name = "V2 " + v2.replacingOccurrences(of: "opencode2 v", with: "").replacingOccurrences(of: "0.0.0-", with: "")

        connect(app, name: v1Name, port: 4195, directory: root + "/v1/project")
        exerciseSession(app, major: "v1")
        XCTAssertEqual(app.buttons[v1Name].value as? String, "Selected server")

        connect(app, name: v2Name, port: 4199, directory: root + "/v2/project")
        exerciseSession(app, major: "v2")
        XCTAssertEqual(app.buttons[v2Name].value as? String, "Selected server")
        attach("upstream-v2-session-browser")

        app.buttons["Session list options"].tap()
        app.buttons["Group by project"].tap()
        XCTAssertTrue(app.buttons["New session in project"].waitForExistence(timeout: 5))
        attach("upstream-v2-grouped-sessions")

        app.buttons[v1Name].tap()
        XCTAssertEqual(app.buttons[v1Name].value as? String, "Selected server")
        XCTAssertTrue(app.staticTexts["BYOT v1 acceptance"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts.matching(identifier: "BYOT v1 acceptance").count, 1, "Global and configured v1 projects must not duplicate a session")
        XCTAssertFalse(app.staticTexts["BYOT attachment acceptance"].exists)
        attach("upstream-v1-grouped-sessions")

        // Relaunch exercises persisted server selection, grouping, and password retrieval.
        app.terminate()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["New session in project"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons[v1Name].value as? String, "Selected server")
        XCTAssertTrue(app.staticTexts["BYOT v1 acceptance"].waitForExistence(timeout: 10))
        app.buttons[v2Name].tap()
        XCTAssertTrue(app.staticTexts["BYOT attachment acceptance"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["BYOT v1 acceptance"].exists)
        attach("upstream-v2-restored-server-switch")
    }

    @MainActor
    private func startConfiguredSession(_ app: XCUIApplication) {
        let start = app.buttons["start-session"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        expectation(for: NSPredicate(format: "enabled == true AND hittable == true"), evaluatedWith: start)
        waitForExpectations(timeout: 20)
        start.tap()
    }

    @MainActor
    private func connect(_ app: XCUIApplication, name serverName: String, port: Int, directory workingDirectory: String) {
        let add = app.buttons["Add server"].firstMatch
        guard waitUntilHittable(add, timeout: 10) else { XCTFail(app.debugDescription); return }
        add.tap()
        let name = app.textFields["Name"]
        // Wait through sheet presentation; retry only a missed reversible opening tap.
        if !name.waitForExistence(timeout: 3), add.exists, add.isHittable { add.tap() }
        guard waitUntilHittable(name, timeout: 7), focus(name, in: app) else {
            XCTFail("The server Name field must have keyboard focus before typing. " + app.debugDescription)
            return
        }
        let initialName = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: initialName.count) + serverName)
        let url = app.textFields["https://your-mac.example.ts.net"]
        guard focus(url, in: app) else { XCTFail("Server URL did not receive keyboard focus"); return }
        url.typeText("https://127.0.0.1:\(port)")
        let password = app.secureTextFields["Server password"]
        guard focus(password, in: app) else { XCTFail("Server password did not receive keyboard focus"); return }
        password.typeText("byot-local-fixture-only")
        let directory = app.textFields["/Users/me/project"]
        guard focus(directory, in: app) else { XCTFail("Project directory did not receive keyboard focus"); return }
        directory.typeText(workingDirectory)
        app.buttons["Save"].tap()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        XCTAssertTrue(app.buttons[serverName].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func focus(_ field: XCUIElement, in app: XCUIApplication) -> Bool {
        guard waitUntilHittable(field, timeout: 5) else { return false }
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

    @MainActor
    private func exerciseSession(_ app: XCUIApplication, major: String) {
        let newSession = app.buttons["New session"].firstMatch
        XCTAssertTrue(newSession.waitForExistence(timeout: 10))
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: newSession)
        waitForExpectations(timeout: 20)
        newSession.tap()
        startConfiguredSession(app)
        let composer = app.textFields["Message"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Creating a session must open its chat immediately")
        XCTAssertFalse(app.buttons["Navigation"].exists)
        composer.tap(); composer.typeText("Verify OpenCode \(major) compatibility.")
        app.buttons["Send message"].tap()
        let reply = app.staticTexts["BYOT upstream compatibility verified."].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30), app.debugDescription)
        app.swipeDown()
        attach("upstream-\(major)-live-transcript")
        app.buttons["Choose model"].tap()
        XCTAssertTrue(app.navigationBars["Choose model"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Local acceptance fixture, BYOT Fixture"].waitForExistence(timeout: 5))
        attach("upstream-\(major)-model-picker")
        app.buttons["Done"].tap()
        if major == "v2" {
            app.buttons["Changes"].tap()
            XCTAssertTrue(app.navigationBars["Session changes"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Session changes unavailable"].waitForExistence(timeout: 5))
            attach("upstream-v2-changes-availability")
            app.buttons["Done"].tap()
        } else {
            XCTAssertFalse(app.buttons["Changes"].isEnabled, "A v1 session without file changes has no diff to present")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.textFields["session-search"].waitForExistence(timeout: 5))
        let latestSession = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "session-")).firstMatch
        XCTAssertTrue(latestSession.waitForExistence(timeout: 10), app.debugDescription)
        attach("upstream-\(major)-session-browser")
        latestSession.tap()
        XCTAssertTrue(app.textFields["Message"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Verify OpenCode \(major) compatibility."].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "Transcript must reload from the upstream server")
        attach("upstream-\(major)-reloaded-transcript")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["New session"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
