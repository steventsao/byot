import Foundation

struct BYOTPushClient: Sendable {
    static let baseURL = URL(string: "https://byot-push.steventsao.workers.dev")!
    // Requests use only a BYOT subscription credential, never an OpenCode password.
    func request(_ method: String, credential: BYOTPushCredential, action: String? = nil,
                 body: Data? = nil) async throws -> Data {
        var url = Self.baseURL.appending(path: "v1/subscriptions/\(credential.subscriptionID.uuidString.lowercased())")
        if let action { url.append(path: action) }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(credential.ownerKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let session = URLSession(configuration: .ephemeral, delegate: BYOTPushRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            guard data.count < 65_536 else { throw BYOTPushError.unavailable("The notification service returned an invalid response.") }
            data.append(byte)
        }
        // A lost DELETE response must remain recoverable on retry.
        if method == "DELETE", (response as? HTTPURLResponse)?.statusCode == 404 { return Data() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw BYOTPushError.unavailable("Couldn’t update notifications. Check your connection and try again.")
        }
        return data
    }
}
private final class BYOTPushRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
