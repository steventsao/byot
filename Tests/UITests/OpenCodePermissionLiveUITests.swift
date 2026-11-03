import XCTest

/// Drives the unmodified App Store UI against real upstream permission requests.
/// Requests are created with the server API; no model or shell execution is required.
final class OpenCodePermissionLiveUITests: XCTestCase {
    @MainActor
    func testV2PermissionCardRejectOnceAndAlways() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BYOT_LIVE_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Requires isolated upstream acceptance servers")
        }
        let root = try XCTUnwrap(environment["BYOT_LIVE_ROOT"])
        continueAfterFailure = false
        let created = try await request("/api/session", body: [
            "title": "Permission approval check",
            "location": ["directory": root + "/v2/project"],
        ])
        let sessionID = try XCTUnwrap((created["data"] as? [String: Any])?["id"] as? String)
        let app = XCUIApplication()
        app.launch()
        connect(app, directory: root + "/v2/project")
        let session = app.buttons["session-" + sessionID]
        XCTAssertTrue(session.waitForExistence(timeout: 15), app.debugDescription)
        session.tap()
        XCTAssertTrue(app.textFields["Message"].waitForExistence(timeout: 10))

        let onceCommand = "printf BYOT_PERMISSION_ONCE"
        try await createPermission(sessionID, command: onceCommand, save: [onceCommand])
        assertCard(app, command: onceCommand)
        attach("permission-card-allow-once")
        app.buttons["Allow once"].tap()
        try await waitForNoPending(sessionID)
        XCTAssertTrue(app.staticTexts["Permission requested"].waitForNonExistence(timeout: 8))

        // Allow once must not create a reusable rule: the identical request asks again.
        try await createPermission(sessionID, command: onceCommand, save: [onceCommand])
        assertCard(app, command: onceCommand)
        attach("permission-card-reject")
        app.buttons["Reject"].tap()
        try await waitForNoPending(sessionID)
        XCTAssertTrue(app.staticTexts["Permission requested"].waitForNonExistence(timeout: 8))

        // Rejection is limited to that request, so a subsequent request still asks.
        try await createPermission(sessionID, command: onceCommand, save: [onceCommand])
        assertCard(app, command: onceCommand)
        app.buttons["Reject"].tap()
        try await waitForNoPending(sessionID)
        XCTAssertTrue(app.staticTexts["Permission requested"].waitForNonExistence(timeout: 8))

        let alwaysCommand = "printf BYOT_PERMISSION_ALWAYS"
        try await createPermission(sessionID, command: alwaysCommand, save: [alwaysCommand])
        assertCard(app, command: alwaysCommand)
        app.buttons["Always allow"].tap()
        let confirmation = app.buttons["Confirm always allow"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        attach("permission-always-confirmation")
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            // iOS 26 presents this as a popover; tapping outside cancels it.
            app.navigationBars.staticTexts["Permission approval check"].tap()
        }
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 5))
        let pendingAfterCancel = try await pending(sessionID)
        XCTAssertEqual(pendingAfterCancel.count, 1, "Cancel must preserve the pending request")
        app.buttons["Always allow"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap()
        try await waitForNoPending(sessionID)
        XCTAssertTrue(app.staticTexts["Permission requested"].waitForNonExistence(timeout: 8))

        let remembered = try await permission(sessionID, command: alwaysCommand, save: [alwaysCommand])
        XCTAssertEqual(remembered["effect"] as? String, "allow", "Always allow must save the rule on the real server")
        let pendingAfterRemembered = try await pending(sessionID)
        XCTAssertTrue(pendingAfterRemembered.isEmpty)
        attach("permission-always-remembered")

        // Requests without a reusable scope must not expose Always allow.
        let singleCommand = "printf BYOT_PERMISSION_NO_SAVED_SCOPE"
        try await createPermission(sessionID, command: singleCommand, save: [])
        XCTAssertTrue(app.staticTexts[singleCommand].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["This request can’t be remembered."].exists)
        XCTAssertFalse(app.buttons["Always allow"].exists)
        attach("permission-no-reusable-scope")
        app.buttons["Reject"].tap()
        try await waitForNoPending(sessionID)
    }

    @MainActor
    private func connect(_ app: XCUIApplication, directory: String) {
        addUIInterruptionMonitor(withDescription: "Password AutoFill") { interruption in
            guard interruption.buttons["Not Now"].exists else { return false }
            interruption.buttons["Not Now"].tap()
            return true
        }
        let add = app.buttons["Add server"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8) + "Permission check")
        let url = app.textFields["https://your-mac.example.ts.net"]
        url.tap(); url.typeText("https://127.0.0.1:4199")
        let password = app.secureTextFields["Server password"]
        password.tap(); password.typeText("byot-local-fixture-only")
        let path = app.textFields["/Users/me/project"]
        path.tap(); path.typeText(directory)
        app.buttons["Save"].tap()
        let notNow = app.buttons["Not Now"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        XCTAssertTrue(app.buttons["New session"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
    }

    @MainActor
    private func assertCard(_ app: XCUIApplication, command: String) {
        XCTAssertTrue(app.staticTexts["Permission requested"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["shell"].exists)
        XCTAssertTrue(app.staticTexts[command].firstMatch.exists)
        XCTAssertTrue(app.buttons["Reject"].isHittable)
        XCTAssertTrue(app.buttons["Allow once"].isHittable)
        XCTAssertTrue(app.buttons["Always allow"].isHittable)
    }

    @MainActor
    private func createPermission(_ sessionID: String, command: String, save: [String]) async throws {
        let response = try await permission(sessionID, command: command, save: save)
        XCTAssertEqual(response["effect"] as? String, "ask")
    }

    @MainActor
    private func permission(_ sessionID: String, command: String, save: [String]) async throws -> [String: Any] {
        let response = try await request("/api/session/\(sessionID)/permission", body: [
            "action": "shell", "resources": [command], "save": save,
            "metadata": ["description": "Harmless permission UI acceptance request"],
        ])
        return try XCTUnwrap(response["data"] as? [String: Any])
    }

    @MainActor
    private func pending(_ sessionID: String) async throws -> [[String: Any]] {
        let response = try await request("/api/session/\(sessionID)/permission")
        return try XCTUnwrap(response["data"] as? [[String: Any]])
    }

    @MainActor
    private func waitForNoPending(_ sessionID: String) async throws {
        for _ in 0..<40 {
            if try await pending(sessionID).isEmpty { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("The real OpenCode server still has a pending permission request")
    }

    @MainActor
    private func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://127.0.0.1:4199" + path)!)
        request.setValue("Basic " + Data("opencode:byot-local-fixture-only".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains((response as! HTTPURLResponse).statusCode), String(decoding: data, as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
