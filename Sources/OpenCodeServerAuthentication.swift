import Foundation

/// Authentication for the OpenCode HTTP server itself.
///
/// OpenCode v1 and v2 both use HTTP Basic authentication here. Provider API
/// keys belong to OpenCode's model providers and are not server credentials.
struct OpenCodeServerAuthentication: Equatable, Sendable {
    private let username: String
    private let password: String

    static func basic(username: String, password: String) -> Self {
        Self(username: username, password: password)
    }

    var authorizationHeaderValue: String {
        let credentials = "\(username):\(password)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }
}
