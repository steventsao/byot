import Foundation

/// A server file is a reference in a specific remote workspace, never a local iPhone URL.
struct OpenCodePromptFileReference: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    let serverID: UUID
    let projectID: String
    let directory: String
    let workspaceID: String?
    let path: String
    let selection: OpenCodeFileLineRange?

    init(id: UUID = UUID(), serverID: UUID, projectID: String, directory: String,
         workspaceID: String? = nil, path: String, selection: OpenCodeFileLineRange? = nil) {
        self.id = id
        self.serverID = serverID
        self.projectID = projectID
        self.directory = directory
        self.workspaceID = workspaceID
        self.path = path
        self.selection = selection
    }

    var filename: String { path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? path }
    var mimeType: String { "text/plain" }
    var displayName: String {
        guard let selection else { return path }
        return "\(path):\(selection.startLine)–\(selection.endLine)"
    }

    var absolutePath: String {
        if path.hasPrefix("/") || path.hasPrefix("\\\\") || path.range(of: "^[A-Za-z]:", options: .regularExpression) != nil {
            return path
        }
        return directory.replacingOccurrences(of: "[/\\\\]+$", with: "", options: .regularExpression) + "/" + path
    }

    var fileURL: String {
        // Match OpenCode's encodeFilePath; do not resolve remote paths on this device.
        var normalized = absolutePath.replacingOccurrences(of: "\\", with: "/")
        if normalized.range(of: "^[A-Za-z]:", options: .regularExpression) != nil { normalized = "/" + normalized }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        let encoded = normalized.components(separatedBy: "/").enumerated().map { index, segment in
            if index == 1, segment.range(of: "^[A-Za-z]:$", options: .regularExpression) != nil { return segment }
            return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
        }.joined(separator: "/")
        let query = selection.map { "?start=\($0.startLine)&end=\($0.endLine)" } ?? ""
        return "file://" + encoded + query
    }

    var v1URL: String { fileURL }
    var v2URI: String { fileURL }

    func matches(serverID: UUID, projectID: String, directory: String, workspaceID: String?) -> Bool {
        self.serverID == serverID && self.projectID == projectID && self.directory == directory
            && self.workspaceID == workspaceID
    }
}

struct OpenCodeFileLineRange: Equatable, Codable, Sendable {
    let startLine: Int
    let endLine: Int

    init?(startLine: Int, endLine: Int) {
        guard startLine >= 1, endLine >= startLine else { return nil }
        self.startLine = startLine
        self.endLine = endLine
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let start = try values.decode(Int.self, forKey: .startLine)
        let end = try values.decode(Int.self, forKey: .endLine)
        guard let valid = Self(startLine: start, endLine: end) else {
            throw DecodingError.dataCorruptedError(forKey: .endLine, in: values, debugDescription: "Invalid file line range")
        }
        self = valid
    }
}

extension OpenCodePromptFileReference {
    static func restored(from message: OpenCodeMessageEnvelope, serverID: UUID, projectID: String,
                         directory: String, workspaceID: String?) -> [Self] {
        message.parts.compactMap { part in
            guard part.type == "file", let value = part.url else { return nil }
            return restored(fromURI: value, serverID: serverID, projectID: projectID,
                            directory: directory, workspaceID: workspaceID)
        }
    }

    static func restored(fromURI value: String, serverID: UUID, projectID: String,
                         directory: String, workspaceID: String?) -> Self? {
        let scope = OpenCodeRemoteFileScope(serverID: serverID, serverName: "", projectID: projectID,
                                            directory: directory, workspaceID: workspaceID)
        guard let uri = URLComponents(string: value), uri.scheme?.lowercased() == "file" else { return nil }
        var path = uri.path
        if let host = uri.host, !host.isEmpty, host != "localhost" { path = "//" + host + path }
        if path.range(of: "^/[A-Za-z]:/", options: .regularExpression) != nil { path.removeFirst() }
        guard let relative = try? scope.relativePath(path) else { return nil }
        let startValue = uri.queryItems?.first { $0.name == "start" }?.value
        let endValue = uri.queryItems?.first { $0.name == "end" }?.value
        let selection: OpenCodeFileLineRange?
        if startValue != nil || endValue != nil {
            guard let start = startValue.flatMap(Int.init), let end = endValue.flatMap(Int.init),
                  let range = OpenCodeFileLineRange(startLine: start, endLine: end) else { return nil }
            selection = range
        } else { selection = nil }
        return scope.reference(path: relative, selection: selection)
    }
}
