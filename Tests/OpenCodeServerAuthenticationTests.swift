import Foundation
import Testing
@testable import byot

struct OpenCodeServerAuthenticationTests {
    @Test("OpenCode server auth uses an exact UTF-8 Basic credential pair")
    func basicCredentialEncoding() {
        let authentication = OpenCodeServerAuthentication.basic(
            username: "opencode-✓",
            password: "pair:pässword"
        )
        let expected = Data("opencode-✓:pair:pässword".utf8).base64EncodedString()

        #expect(authentication.authorizationHeaderValue == "Basic \(expected)")
    }

    @Test("Provider API keys are not a server authentication scheme")
    func providerAPIKeyIsNotServerAuth() {
        let authentication = OpenCodeServerAuthentication.basic(
            username: "opencode",
            password: "server-secret"
        )

        #expect(authentication.authorizationHeaderValue.hasPrefix("Basic "))
        #expect(!authentication.authorizationHeaderValue.hasPrefix("Bearer "))
    }
}
