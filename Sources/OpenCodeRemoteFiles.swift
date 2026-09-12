import Foundation

struct OpenCodeRemoteFileScope: Equatable, Sendable {
    let serverID: UUID
    let serverName: String
    let projectID: String
    let directory: String
    let workspaceID: String?

    func reference(path: String, selection: OpenCodeFileLineRange? = nil) -> OpenCodePromptFileReference {
        .init(serverID: serverID, projectID: projectID, directory: directory,
              workspaceID: workspaceID, path: path, selection: selection)
    }

    func relativePath(_ path: String, allowRoot: Bool = false) throws -> String {
        let windows = directory.range(of: "^[A-Za-z]:", options: .regularExpression) != nil || directory.hasPrefix("\\\\")
        let root = (windows ? directory.replacingOccurrences(of: "\\", with: "/") : directory)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        var value = windows ? path.replacingOccurrences(of: "\\", with: "/") : path
        if value == root { value = "" }
        else if value.hasPrefix(root + "/") { value = String(value.dropFirst(root.count + 1)) }
        if value.hasPrefix("./") { value = String(value.dropFirst(2)) }
        guard !value.hasPrefix("/"), !value.contains("\0"),
              value.range(of: "^[A-Za-z]:", options: .regularExpression) == nil,
              !value.components(separatedBy: "/").contains(".."),
              allowRoot || !value.isEmpty else { throw OpenCodeRemoteFileError.outsideProject }
        return value
    }
}

struct OpenCodeRemoteFileEntry: Identifiable, Equatable, Decodable, Sendable {
    let path: String
    let type: String
    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var isDirectory: Bool { type == "directory" }
}

struct OpenCodeRemoteFileChange: Identifiable, Equatable, Decodable, Sendable {
    let file: String
    let additions: Int
    let deletions: Int
    let status: String
    var id: String { file }
}

struct OpenCodeRemoteFileContent: Equatable, Sendable {
    let path: String
    let text: String?
    let mimeType: String
    let byteCount: Int
    var lines: [String] { text?.components(separatedBy: .newlines) ?? [] }
}

struct OpenCodeRemoteFileCapabilities: Equatable, Sendable {
    let search: Bool
    let browse: Bool
    let read: Bool
    let changes: Bool
    let context: Bool
}

enum OpenCodeRemoteFileError: LocalizedError, Equatable {
    case unsupported(String)
    case outsideProject
    case wrongLocation
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unsupported(let operation): "This server does not provide \(operation)."
        case .outsideProject: "Choose a file inside this session’s project."
        case .wrongLocation: "The server returned files from a different project or workspace. Refresh the session before choosing context."
        case .tooLarge: "This file is too large to preview on your phone. You can still add the file as context."
        }
    }
}

protocol OpenCodeRemoteFileServicing: Sendable {
    var scope: OpenCodeRemoteFileScope { get }
    func capabilities() async throws -> OpenCodeRemoteFileCapabilities
    func search(query: String) async throws -> [OpenCodeRemoteFileEntry]
    func list(path: String) async throws -> [OpenCodeRemoteFileEntry]
    func read(path: String) async throws -> OpenCodeRemoteFileContent
    func changes() async throws -> [OpenCodeRemoteFileChange]
}

struct OpenCodeRemoteFileService: OpenCodeRemoteFileServicing {
    static let maximumPreviewBytes = 2 * 1_024 * 1_024
    let scope: OpenCodeRemoteFileScope
    let context: @Sendable () async throws -> OpenCodeFeatureContext

    init(client: OpenCodeClient, session: OpenCodeSession, directory: String) {
        scope = .init(serverID: client.profile.id, serverName: client.profile.name,
                      projectID: session.projectID, directory: directory, workspaceID: session.workspaceID)
        context = { try await client.featureContext() }
    }

    init(scope: OpenCodeRemoteFileScope,
         context: @escaping @Sendable () async throws -> OpenCodeFeatureContext) {
        self.scope = scope
        self.context = context
    }

    func capabilities() async throws -> OpenCodeRemoteFileCapabilities {
        let connection = try await context()
        guard connection.profile.id == scope.serverID else { throw OpenCodeRemoteFileError.wrongLocation }
        if connection.serverProtocol == .v1 {
            return .init(search: true, browse: true, read: true, changes: true, context: true)
        }
        return .init(search: connection.supports("/api/fs/find"), browse: connection.supports("/api/fs/list"),
                     read: connection.supports("/api/fs/read/*"), changes: connection.supports("/api/vcs/status"),
                     context: Self.supportsFileContext(connection.schema))
    }

    func search(query: String) async throws -> [OpenCodeRemoteFileEntry] {
        let connection = try await checkedContext(v2Path: "/api/fs/find", operation: "file search")
        let queryItems = locationQuery(connection) + [URLQueryItem(name: "query", value: query),
                                                      URLQueryItem(name: "type", value: "file"),
                                                      URLQueryItem(name: "limit", value: "50")]
        let entries: [OpenCodeRemoteFileEntry]
        if connection.serverProtocol == .v1 {
            let paths: [String] = try await connection.transport.get(["find", "file"], query: queryItems)
            entries = paths.map { .init(path: $0, type: "file") }
        } else {
            let response: FileLocationResponse<[OpenCodeRemoteFileEntry]> = try await connection.transport.get(
                ["api", "fs", "find"], query: queryItems)
            try response.validate(scope)
            entries = response.data
        }
        return try normalize(entries)
    }

    func list(path: String) async throws -> [OpenCodeRemoteFileEntry] {
        let relative = try scope.relativePath(path, allowRoot: true)
        let connection = try await checkedContext(v2Path: "/api/fs/list", operation: "file browsing")
        let query = locationQuery(connection) + [URLQueryItem(name: "path", value: relative)]
        let entries: [OpenCodeRemoteFileEntry]
        if connection.serverProtocol == .v1 {
            entries = try await connection.transport.get(["file"], query: query)
        } else {
            let response: FileLocationResponse<[OpenCodeRemoteFileEntry]> = try await connection.transport.get(
                ["api", "fs", "list"], query: query)
            try response.validate(scope)
            entries = response.data
        }
        return try normalize(entries).sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    func changes() async throws -> [OpenCodeRemoteFileChange] {
        let connection = try await checkedContext(v2Path: "/api/vcs/status", operation: "changed files")
        let values: [OpenCodeRemoteFileChange]
        if connection.serverProtocol == .v1 {
            values = try await connection.transport.get(["file", "status"], query: locationQuery(connection))
        } else {
            let response: FileLocationResponse<[OpenCodeRemoteFileChange]> = try await connection.transport.get(
                ["api", "vcs", "status"], query: locationQuery(connection))
            try response.validate(scope)
            values = response.data
        }
        return try values.map { .init(file: try scope.relativePath($0.file), additions: $0.additions,
                                       deletions: $0.deletions, status: $0.status) }
    }

    func read(path: String) async throws -> OpenCodeRemoteFileContent {
        let relative = try scope.relativePath(path)
        let connection = try await checkedContext(v2Path: "/api/fs/read/*", operation: "file previews")
        if connection.serverProtocol == .v1 {
            struct Content: Decodable { let type: String; let content: String; let encoding: String?; let mimeType: String? }
            let value: Content = try await connection.transport.get(["file", "content"],
                query: locationQuery(connection) + [URLQueryItem(name: "path", value: relative)])
            let data = value.encoding == "base64" ? Data(base64Encoded: value.content) ?? Data() : Data(value.content.utf8)
            guard data.count <= Self.maximumPreviewBytes else { throw OpenCodeRemoteFileError.tooLarge }
            return .init(path: relative, text: value.type == "text" ? String(data: data, encoding: .utf8) : nil,
                         mimeType: value.mimeType ?? (value.type == "text" ? "text/plain" : "application/octet-stream"),
                         byteCount: data.count)
        }
        var request = try connection.transport.makeRequest(path: ["api", "fs", "read"],
            query: locationQuery(connection), method: "GET", body: nil)
        guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { throw OpenCodeConnectionError.invalidResponse }
        // The wildcard is one encoded remote relative path, preserving literal %, # and ? in names.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "%?#"))
        guard let encoded = relative.addingPercentEncoding(withAllowedCharacters: allowed)
        else { throw OpenCodeRemoteFileError.outsideProject }
        components.percentEncodedPath += "/" + encoded
        request.url = components.url
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await connection.transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenCodeConnectionError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw OpenCodeConnectionError.httpStatus(http.statusCode, nil) }
        guard data.count <= Self.maximumPreviewBytes else { throw OpenCodeRemoteFileError.tooLarge }
        let mime = http.mimeType ?? "application/octet-stream"
        let text = data.contains(0) ? nil : String(data: data, encoding: .utf8)
        return .init(path: relative, text: text, mimeType: mime, byteCount: data.count)
    }

    private func checkedContext(v2Path: String, operation: String) async throws -> OpenCodeFeatureContext {
        let connection = try await context()
        guard connection.profile.id == scope.serverID else { throw OpenCodeRemoteFileError.wrongLocation }
        guard connection.supports(v2Path) else { throw OpenCodeRemoteFileError.unsupported(operation) }
        return connection
    }

    private func normalize(_ entries: [OpenCodeRemoteFileEntry]) throws -> [OpenCodeRemoteFileEntry] {
        var seen = Set<String>()
        return try entries.compactMap { entry in
            let path = try scope.relativePath(entry.path)
            guard entry.type == "file" || entry.type == "directory", seen.insert(path).inserted else { return nil }
            return .init(path: path, type: entry.type)
        }
    }

    private func locationQuery(_ connection: OpenCodeFeatureContext) -> [URLQueryItem] {
        let prefix = connection.serverProtocol == .v2
        var query = [URLQueryItem(name: prefix ? "location[directory]" : "directory", value: scope.directory)]
        if let workspace = scope.workspaceID {
            query.append(URLQueryItem(name: prefix ? "location[workspace]" : "workspace", value: workspace))
        }
        return query
    }

    static func supportsFileContext(_ schema: OpenCodeJSONValue?) -> Bool {
        guard let root = schema?.objectValue else { return false }
        func resolve(_ value: OpenCodeJSONValue?) -> OpenCodeJSONValue? {
            guard let name = value?.objectValue?["$ref"]?.stringValue?.split(separator: "/").last else { return value }
            return root["components"]?.objectValue?["schemas"]?.objectValue?[String(name)]
        }
        let request = root["paths"]?.objectValue?["/api/session/{sessionID}/prompt"]?.objectValue?["post"]?
            .objectValue?["requestBody"]?.objectValue?["content"]?.objectValue?["application/json"]?.objectValue?["schema"]
        let properties = resolve(request)?.objectValue?["properties"]?.objectValue
        let prompt = resolve(properties?["prompt"])?.objectValue?["properties"]?.objectValue ?? properties
        let file = resolve(prompt?["files"]?.objectValue?["items"])
        return file?.objectValue?["properties"]?.objectValue?["uri"] != nil
    }
}

private struct FileLocationResponse<Value: Decodable>: Decodable {
    struct Location: Decodable {
        struct Project: Decodable { let id: String }
        let directory: String
        let workspaceID: String?
        let project: Project
    }
    let location: Location
    let data: Value
    func validate(_ scope: OpenCodeRemoteFileScope) throws {
        guard location.directory == scope.directory, location.project.id == scope.projectID,
              location.workspaceID == scope.workspaceID else { throw OpenCodeRemoteFileError.wrongLocation }
    }
}
