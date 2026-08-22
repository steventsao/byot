import Foundation

struct OpenCodeFileEntry: Codable, Identifiable, Equatable, Sendable {
    let name: String
    let path: String
    let absolute: String?
    let type: String
    let ignored: Bool

    init(
        name: String,
        path: String,
        absolute: String? = nil,
        type: String,
        ignored: Bool = false
    ) {
        self.name = name
        self.path = path
        self.absolute = absolute
        self.type = type
        self.ignored = ignored
    }

    var id: String { "\(type):\(path)" }
    var isDirectory: Bool { type == "directory" }
}

struct OpenCodeFileContent: Codable, Equatable, Sendable {
    let type: String
    let content: String
    let diff: String?
    let encoding: String?
    let mimeType: String?
}

struct OpenCodeFileStatus: Codable, Identifiable, Equatable, Sendable {
    let path: String
    let added: Int
    let removed: Int
    let status: String

    var id: String { path }
    var additions: Int { added }
    var deletions: Int { removed }
}

struct OpenCodeFileLine: Identifiable, Equatable, Sendable {
    let number: Int
    let text: String

    var id: Int { number }
}

struct OpenCodeFileBrowserPolicy: Equatable, Sendable {
    let canBrowseTree: Bool
    let canReadFiles: Bool
    let canListChanges: Bool
    let canSearch: Bool
    let treeUnavailableReason: String?
    let readUnavailableReason: String?

    init(capabilities: OpenCodeProtocolCapabilities) {
        canBrowseTree = capabilities.fileTree.isSupported
        canReadFiles = capabilities.fileRead.isSupported
        canListChanges = capabilities.fileStatus.isSupported
        canSearch = capabilities.fileSearch.isSupported
        treeUnavailableReason = capabilities.fileTree.unavailableReason
        readUnavailableReason = capabilities.fileRead.unavailableReason
    }
}

enum OpenCodeFileBrowserPath {
    static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/")
    }

    static func join(_ parent: String, _ child: String) -> String {
        normalize([parent, child].filter { !$0.isEmpty }.joined(separator: "/"))
    }

    static func parent(of path: String) -> String {
        normalize(path).split(separator: "/", omittingEmptySubsequences: true)
            .dropLast()
            .joined(separator: "/")
    }

    static func title(for path: String) -> String {
        let path = normalize(path)
        guard !path.isEmpty else { return "Project files" }
        return path.split(separator: "/").last.map(String.init) ?? "Project files"
    }
}

struct OpenCodeFileContentPresentation: Equatable, Sendable {
    let path: String
    let content: OpenCodeFileContent?
    private let support: OpenCodeFeatureSupport?

    init(
        path: String,
        content: OpenCodeFileContent?,
        support: OpenCodeFeatureSupport?
    ) {
        self.path = path
        self.content = content
        self.support = support
    }

    var lines: [OpenCodeFileLine] {
        guard canDisplayText, let content else { return [] }
        return content.content.components(separatedBy: "\n").enumerated().map {
            OpenCodeFileLine(number: $0.offset + 1, text: $0.element)
        }
    }

    var canDisplayText: Bool {
        content?.type == "text"
    }

    var unavailableReason: String? {
        guard content == nil else { return nil }
        return support?.unavailableReason
    }

    var binaryDescription: String? {
        guard let content, content.type == "binary" else { return nil }
        return "Binary file · \(content.mimeType ?? "unknown type")"
    }

    var accessibilitySummary: String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if canDisplayText {
            return "\(name), \(lines.count) line\(lines.count == 1 ? "" : "s")"
        }
        return binaryDescription ?? unavailableReason ?? name
    }
}

struct OpenCodeFileBrowserRequestVersion: Equatable, Sendable {
    private(set) var value = 0

    mutating func begin() -> Int {
        value &+= 1
        return value
    }

    func accepts(_ request: Int) -> Bool {
        request == value
    }
}
