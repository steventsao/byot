import Foundation

final class OpenCodeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHost: String?
    private let allowedPort: Int
    private let allowedScheme: String?

    init(baseURL: URL?) {
        allowedHost = baseURL?.host?.lowercased()
        allowedPort = Self.effectivePort(for: baseURL)
        allowedScheme = baseURL?.scheme?.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(
            redirectedRequest(request, originalRequest: task.originalRequest)
        )
    }

    func allowsRedirect(to url: URL?) -> Bool {
        // Credentials follow a redirect only to the exact original origin, so
        // an HTTPS server can never downgrade to HTTP and a local HTTP server
        // can never hand the password to another host or port.
        guard let url, allowedScheme == "https" || allowedScheme == "http" else { return false }
        return url.scheme?.lowercased() == allowedScheme
            && url.host?.lowercased() == allowedHost
            && Self.effectivePort(for: url) == allowedPort
    }

    func redirectedRequest(
        _ request: URLRequest,
        originalRequest: URLRequest?
    ) -> URLRequest? {
        guard allowsRedirect(to: request.url) else { return nil }
        var redirected = request
        if let authorization = originalRequest?.value(forHTTPHeaderField: "Authorization") {
            redirected.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        return redirected
    }

    private static func effectivePort(for url: URL?) -> Int {
        if let port = url?.port { return port }
        return url?.scheme?.lowercased() == "https" ? 443 : 80
    }
}
