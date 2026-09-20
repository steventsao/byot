import XCTest
@testable import byot

@MainActor
final class BYOTPushNotificationTests: XCTestCase {
    private let key = Data(repeating: 9, count: 32).base64EncodedString()
    private let serverID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private func credential() -> BYOTPushCredential {
        BYOTPushCredential(subscriptionID: UUID(), serverID: serverID, fingerprint: "fixture", ownerKey: "fixture", routeKey: key)
    }
    private func envelope(_ route: BYOTPushRoute, credential: BYOTPushCredential, kind: String = "permission", version: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["byot": ["version": version, "subscriptionID": credential.subscriptionID.uuidString,
            "kind": kind, "route": try route.encrypted(key: credential.routeKey)]])
    }
    func testNodeEncryptedRouteDecodesInCryptoKit() throws {
        let sealed = "AQEBAQEBAQEBAQEBwlLyAGGRrQJYCn33x76xIo309fvU7Uzx3YIkpR3waf8CSTdnC+ncsVcJYNWai75UpxUEHM7sJk6F+o2ANnN8/qoL8eH9Y8mYSX31L5Z6yF2IZC+RYzW3Kd/AXoABx6QoBWmCMdDVEqfZFx6rPytB94zL5gzJwCSjs3+o2U2tn8Qsp8Gl7jGl6jlhZgbo4W+4tbyCadI="
        let route = try BYOTPushRoute.decrypt(sealed, key: key)
        XCTAssertEqual(route.serverID, serverID)
        XCTAssertEqual(route.sessionID, "ses_node")
        XCTAssertEqual(route.directory, "/private/測試 project")
        XCTAssertEqual(route.workspace, "work_1")
    }
    func testTamperedCiphertextAndWrongKeysAreRejected() throws {
        let route = BYOTPushRoute(serverID: serverID, sessionID: "ses_1", directory: "/private/project", workspace: nil)
        let sealed = try route.encrypted(key: key)
        var data = Data(base64Encoded: sealed)!
        data[data.count - 1] ^= 1
        XCTAssertThrowsError(try BYOTPushRoute.decrypt(data.base64EncodedString(), key: key))
        XCTAssertThrowsError(try BYOTPushRoute.decrypt(sealed, key: Data(repeating: 8, count: 32).base64EncodedString()))
    }
    func testOnlyPairedServerAndKnownSubscriptionCanRoute() throws {
        let credential = credential(), manager = BYOTPushNotifications(credentials: [])
        let route = BYOTPushRoute(serverID: serverID, sessionID: "ses_1", directory: "/project", workspace: nil)
        let data = try envelope(route, credential: credential)
        XCTAssertThrowsError(try manager.decode(data))
        let paired = BYOTPushNotifications(credentials: [credential])
        XCTAssertEqual(try paired.decode(data), route)
        let wrong = BYOTPushRoute(serverID: UUID(), sessionID: "ses_1", directory: "/project", workspace: nil)
        XCTAssertThrowsError(try paired.decode(envelope(wrong, credential: credential)))
        XCTAssertThrowsError(try paired.decode(envelope(route, credential: credential, version: 2)))
    }
    func testForegroundSuppressionOnlyForTheViewedSession() throws {
        let credential = credential(), manager = BYOTPushNotifications(credentials: [credential])
        let route = BYOTPushRoute(serverID: serverID, sessionID: "ses_1", directory: "/project", workspace: nil)
        let data = try envelope(route, credential: credential)
        XCTAssertTrue(manager.shouldPresent(data))
        manager.activeRoute = route
        XCTAssertFalse(manager.shouldPresent(data))
        manager.activeRoute = BYOTPushRoute(serverID: serverID, sessionID: "ses_2", directory: "/project", workspace: nil)
        XCTAssertTrue(manager.shouldPresent(data))
        manager.receive(data)
        XCTAssertEqual(manager.pendingDestination?.route, route)
    }
    func testTestNotificationOpensSettingsAndCannotMasqueradeAsAnApproval() throws {
        let credential = credential(), manager = BYOTPushNotifications(credentials: [credential])
        let route = BYOTPushRoute(serverID: serverID, sessionID: "", directory: "", workspace: nil)
        XCTAssertEqual(try manager.decode(envelope(route, credential: credential, kind: "test")), route)
        XCTAssertThrowsError(try manager.decode(envelope(route, credential: credential)))
    }
    func testRouteValidationRejectsTraversalAndUnboundedMetadata() {
        XCTAssertFalse(BYOTPushRoute(serverID: serverID, sessionID: "../other", directory: "/project", workspace: nil).isValid)
        XCTAssertFalse(BYOTPushRoute(serverID: serverID, sessionID: "ses_1", directory: String(repeating: "a", count: 1025), workspace: nil).isValid)
        XCTAssertFalse(BYOTPushRoute(serverID: serverID, sessionID: "ses_1", directory: "a\0b", workspace: nil).isValid)
    }
}
