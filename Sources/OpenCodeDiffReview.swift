import Foundation

/// What the reviewer compares. OpenCode's own clients offer the same choices:
/// the TUI diff viewer's git/branch/last-turn modes and the web app's review tab.
enum OpenCodeDiffSource: String, CaseIterable, Identifiable, Sendable {
    /// Files changed by one prompt and its replies (v1 message summaries).
    case turn
    /// The older whole-session snapshot some v1 servers and reverts still publish.
    case session
    /// Working copy against HEAD.
    case uncommitted
    /// Working copy against the merge base with the repository's default branch.
    case branch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .turn: "Turn"
        case .session: "Session"
        case .uncommitted: "Uncommitted"
        case .branch: "Branch"
        }
    }

    var emptyTitle: String {
        switch self {
        case .turn: "No changes in this turn"
        case .session: "No session changes"
        case .uncommitted: "Working tree is clean"
        case .branch: "No branch changes"
        }
    }
}

struct OpenCodeVcsBranch: Equatable, Sendable {
    let current: String?
    let defaultBranch: String?

    /// OpenCode reports neither name outside a git repository. A detached HEAD
    /// still resolves the default branch, so its working copy stays reviewable.
    var isRepository: Bool { current != nil || defaultBranch != nil }

    /// OpenCode returns an empty branch diff while checked out on the default branch.
    var comparesWithDefault: Bool {
        guard let current, let defaultBranch else { return false }
        return current != defaultBranch
    }
}

/// Negotiated per connection: never guessed from the protocol major alone.
struct OpenCodeDiffAvailability: Equatable, Sendable {
    var turn = false
    var uncommitted = false
    var branch: OpenCodeVcsBranch?
    var unavailableReason: String?

    static let none = Self(unavailableReason: "This server does not provide file changes for review.")
}

enum OpenCodeDiffFileStatus: String, Equatable, Sendable {
    case added, deleted, modified

    var title: String {
        switch self {
        case .added: "Added"
        case .deleted: "Deleted"
        case .modified: "Modified"
        }
    }

    var symbol: String {
        switch self {
        case .added: "plus.square.fill"
        case .deleted: "minus.square.fill"
        case .modified: "square.split.diagonal.fill"
        }
    }
}

/// One reviewable file, normalized from v1 snapshot/VCS diffs and v2 FileDiff.Info.
struct OpenCodeDiffFile: Identifiable, Equatable, Sendable {
    let path: String
    let status: OpenCodeDiffFileStatus
    let additions: Int
    let deletions: Int
    let patch: String?

    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
    var folder: String? {
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let value = String(path[..<slash])
        return value.isEmpty ? nil : value
    }

    var accessibilitySummary: String {
        var parts = [name, status.title]
        if let folder { parts.append("in \(folder)") }
        parts.append("\(additions) \(additions == 1 ? "addition" : "additions")")
        parts.append("\(deletions) \(deletions == 1 ? "deletion" : "deletions")")
        return parts.joined(separator: ", ")
    }

    static func normalized(_ diffs: [OpenCodeDiff], directory: String) -> [OpenCodeDiffFile] {
        let root = directory.replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        var seen = Set<String>()
        return diffs.enumerated().compactMap { index, diff in
            // Parsing a whole patch is only needed when the server omitted a field it describes.
            let needsPatch = diff.file?.trimmedNonEmpty == nil || diff.status == nil
                || (diff.additions == 0 && diff.deletions == 0)
            let parsed = needsPatch ? diff.patch.map(OpenCodeUnifiedDiff.parse) : nil
            guard var path = diff.file?.trimmedNonEmpty ?? parsed?.path else {
                // A path-less entry cannot be matched or navigated; keep it reviewable.
                return OpenCodeDiffFile(path: "Changed file \(index + 1)", status: .modified,
                                        additions: diff.additions, deletions: diff.deletions, patch: diff.patch)
            }
            if !root.isEmpty, path.hasPrefix(root + "/") { path = String(path.dropFirst(root.count + 1)) }
            guard seen.insert(path).inserted else { return nil }
            let status = diff.status.flatMap(OpenCodeDiffFileStatus.init(rawValue:)) ?? parsed?.status ?? .modified
            // Some snapshot diffs report zero counts beside a real patch.
            let counted = diff.additions == 0 && diff.deletions == 0 && parsed.map { $0.additions + $0.deletions > 0 } == true
            return OpenCodeDiffFile(path: path, status: status,
                                    additions: counted ? parsed?.additions ?? 0 : diff.additions,
                                    deletions: counted ? parsed?.deletions ?? 0 : diff.deletions,
                                    patch: diff.patch)
        }
    }
}

// MARK: - Unified diff

/// Parses one file's unified diff from `git diff` or jsdiff's `formatPatch`
/// (OpenCode's snapshot diffs), tolerating both header styles.
struct OpenCodeUnifiedDiff: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case context, addition, deletion }
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
        let text: String
        var missingNewline = false
    }

    struct Hunk: Identifiable, Equatable, Sendable {
        let id: Int
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let section: String?
        var lines: [Line]

        var header: String {
            "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
        }

        var title: String { section.map { "\(header) \($0)" } ?? header }
    }

    var hunks: [Hunk] = []
    var path: String?
    var status: OpenCodeDiffFileStatus?
    var isBinary = false

    var additions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    var deletions: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }
    var maximumLineNumber: Int {
        hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 0
    }

    static func parse(_ patch: String) -> OpenCodeUnifiedDiff {
        var result = OpenCodeUnifiedDiff()
        var oldPath: String?
        var newPath: String?
        var sawDevNullOld = false
        var sawDevNullNew = false
        var current: Hunk?
        var oldLine = 0
        var newLine = 0
        var oldRemaining = 0
        var newRemaining = 0

        func finishHunk() {
            if let hunk = current { result.hunks.append(hunk) }
            current = nil
        }

        // "\r\n" is one Character in Swift, so split on both line endings explicitly.
        for raw in patch.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = String(raw)
            if current != nil, oldRemaining > 0 || newRemaining > 0 {
                let marker = line.first
                let text = line.isEmpty ? "" : String(line.dropFirst())
                switch marker {
                case "+":
                    current?.lines.append(Line(kind: .addition, oldNumber: nil, newNumber: newLine, text: text))
                    newLine += 1; newRemaining -= 1
                    continue
                case "-":
                    current?.lines.append(Line(kind: .deletion, oldNumber: oldLine, newNumber: nil, text: text))
                    oldLine += 1; oldRemaining -= 1
                    continue
                case " ", nil:
                    // Some tools strip the space from blank context lines.
                    current?.lines.append(Line(kind: .context, oldNumber: oldLine, newNumber: newLine, text: text))
                    oldLine += 1; newLine += 1; oldRemaining -= 1; newRemaining -= 1
                    continue
                case "\\":
                    markMissingNewline(&current)
                    continue
                default:
                    break // A malformed count: fall through and treat this as a header.
                }
            }
            if line.hasPrefix("\\"), current != nil {
                markMissingNewline(&current)
                continue
            }
            if let header = HunkHeader(line) {
                finishHunk()
                current = Hunk(id: result.hunks.count, oldStart: header.oldStart, oldCount: header.oldCount,
                               newStart: header.newStart, newCount: header.newCount, section: header.section, lines: [])
                oldLine = header.oldStart
                newLine = header.newStart
                oldRemaining = header.oldCount
                newRemaining = header.newCount
                continue
            }
            finishHunk()
            if line.hasPrefix("--- ") {
                oldPath = headerPath(line.dropFirst(4), prefix: "a/")
                sawDevNullOld = oldPath == nil
            } else if line.hasPrefix("+++ ") {
                newPath = headerPath(line.dropFirst(4), prefix: "b/")
                sawDevNullNew = newPath == nil
            }
            else if line.hasPrefix("new file mode") { result.status = .added }
            else if line.hasPrefix("deleted file mode") { result.status = .deleted }
            else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { result.isBinary = true }
            else if line.hasPrefix("Index: "), newPath == nil { newPath = String(line.dropFirst(7)).trimmedNonEmpty }
        }
        finishHunk()

        if result.status == nil, sawDevNullOld, newPath != nil { result.status = .added }
        if result.status == nil, sawDevNullNew, oldPath != nil { result.status = .deleted }
        result.path = newPath ?? oldPath
        return result
    }

    private static func markMissingNewline(_ hunk: inout Hunk?) {
        guard var value = hunk, !value.lines.isEmpty else { return }
        value.lines[value.lines.count - 1].missingNewline = true
        hunk = value
    }

    /// `a/src/x.swift`, `b/src/x.swift`, `src/x.swift\t(date)` or `/dev/null`.
    private static func headerPath(_ value: Substring, prefix: String) -> String? {
        var path = String(value.split(separator: "\t", maxSplits: 1).first ?? value)
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 { path = String(path.dropFirst().dropLast()) }
        guard path != "/dev/null", !path.isEmpty else { return nil }
        if path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
        return path.trimmedNonEmpty
    }

    private struct HunkHeader {
        let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
        let section: String?

        init?(_ line: String) {
            guard line.hasPrefix("@@ -") else { return nil }
            let body = line.dropFirst(4)
            guard let close = body.range(of: " @@") else { return nil }
            let ranges = body[..<close.lowerBound].split(separator: " ")
            guard ranges.count == 2, ranges[1].hasPrefix("+"),
                  let old = Self.range(ranges[0]), let new = Self.range(ranges[1].dropFirst()) else { return nil }
            (oldStart, oldCount) = old
            (newStart, newCount) = new
            section = String(body[close.upperBound...]).trimmingCharacters(in: .whitespaces).trimmedNonEmpty
        }

        private static func range(_ value: Substring) -> (Int, Int)? {
            let parts = value.split(separator: ",", maxSplits: 1)
            guard let start = parts.first.flatMap({ Int($0) }) else { return nil }
            guard parts.count == 2 else { return (start, 1) }
            guard let count = Int(parts[1]) else { return nil }
            return (start, count)
        }
    }
}

// MARK: - Presentation rows

/// Rows the file reviewer renders. Long unchanged runs collapse to a gap the
/// reviewer can expand, so full-file snapshot patches stay readable on a phone.
enum OpenCodeDiffRow: Identifiable, Equatable, Sendable {
    case hunk(id: String, title: String)
    case line(id: String, OpenCodeUnifiedDiff.Line)
    case gap(id: String, hiddenLines: Int)

    var id: String {
        switch self {
        case .hunk(let id, _), .line(let id, _), .gap(let id, _): id
        }
    }

    static let visibleContext = 3
    /// Keeps a single-line gap from costing more than the line it hides.
    static let minimumCollapsedLines = 4
    /// Keeps pathological single-line files from blowing up text layout.
    static let maximumDisplayedCharacters = 2_000

    static func rows(for diff: OpenCodeUnifiedDiff, expandedGaps: Set<String>) -> [OpenCodeDiffRow] {
        var rows: [OpenCodeDiffRow] = []
        for hunk in diff.hunks {
            rows.append(.hunk(id: "h\(hunk.id)", title: hunk.title))
            var index = 0
            while index < hunk.lines.count {
                guard hunk.lines[index].kind == .context else {
                    rows.append(.line(id: "h\(hunk.id)-\(index)", hunk.lines[index]))
                    index += 1
                    continue
                }
                var end = index
                while end < hunk.lines.count, hunk.lines[end].kind == .context { end += 1 }
                let leading = index == 0 ? 0 : visibleContext
                let trailing = end == hunk.lines.count ? 0 : visibleContext
                let hidden = (end - index) - leading - trailing
                let gapID = "h\(hunk.id)-gap\(index)"
                if hidden >= minimumCollapsedLines, !expandedGaps.contains(gapID) {
                    for offset in index..<(index + leading) { rows.append(.line(id: "h\(hunk.id)-\(offset)", hunk.lines[offset])) }
                    rows.append(.gap(id: gapID, hiddenLines: hidden))
                    for offset in (end - trailing)..<end { rows.append(.line(id: "h\(hunk.id)-\(offset)", hunk.lines[offset])) }
                } else {
                    for offset in index..<end { rows.append(.line(id: "h\(hunk.id)-\(offset)", hunk.lines[offset])) }
                }
                index = end
            }
        }
        return rows
    }

    static func displayText(_ text: String) -> String {
        let expanded = text.replacingOccurrences(of: "\t", with: "    ")
        guard expanded.count > maximumDisplayedCharacters else { return expanded }
        return String(expanded.prefix(maximumDisplayedCharacters)) + "…"
    }

    /// East Asian wide characters and emoji take two monospaced columns.
    static func displayColumns(_ text: String) -> Int {
        text.reduce(0) { count, character in
            count + (character.unicodeScalars.contains { $0.value >= 0x1100 } ? 2 : 1)
        }
    }

    /// Longest line in the whole patch, hidden context included, in monospaced columns.
    static func columns(in diff: OpenCodeUnifiedDiff) -> Int {
        diff.hunks.reduce(0) { longest, hunk in
            hunk.lines.reduce(max(longest, displayColumns(hunk.title))) { max($0, displayColumns(displayText($1.text))) }
        }
    }
}

// MARK: - Service

protocol OpenCodeDiffReviewServicing: Sendable {
    /// Throws only when the server can't be reached; missing routes resolve to hidden sources.
    func availability() async throws -> OpenCodeDiffAvailability
    func diffs(_ source: OpenCodeDiffSource, messageID: String?) async throws -> [OpenCodeDiff]
}

enum OpenCodeDiffReviewError: LocalizedError, Equatable {
    case unsupported(OpenCodeDiffSource)
    case missingTurn
    case wrongLocation

    var errorDescription: String? {
        switch self {
        case .unsupported(let source): "This server does not provide \(source.title.lowercased()) changes."
        case .missingTurn: "Send a prompt first. Changes appear here after OpenCode edits files."
        case .wrongLocation: "The server returned changes for a different project. Refresh the session and try again."
        }
    }
}

/// Contract: OpenCode v1 1.18.29 (`/session/{id}/diff?messageID`, `/vcs`, `/vcs/diff?mode=git|branch`)
/// and the v2 beta schema (`/api/vcs`, `/api/vcs/diff?mode=working|branch`). v2 has no
/// per-session or per-turn diff route, so v2 review is working-copy based.
struct OpenCodeDiffReviewService: OpenCodeDiffReviewServicing {
    let sessionID: String
    let directory: String
    let workspace: String?
    let context: @Sendable () async throws -> OpenCodeFeatureContext

    init(client: OpenCodeClient, session: OpenCodeSession, directory: String) {
        sessionID = session.id
        self.directory = directory
        workspace = session.workspaceID
        context = { try await client.featureContext() }
    }

    init(sessionID: String, directory: String, workspace: String?,
         context: @escaping @Sendable () async throws -> OpenCodeFeatureContext) {
        self.sessionID = sessionID
        self.directory = directory
        self.workspace = workspace
        self.context = context
    }

    func availability() async throws -> OpenCodeDiffAvailability {
        // A connection failure is retryable, not a missing feature.
        let connection = try await context()
        if connection.serverProtocol == .v1 {
            // Servers that predate /vcs answer 404 or the web app's HTML; both mean no VCS review.
            let branch = try? await vcsBranch(connection)
            return .init(turn: true, uncommitted: branch?.isRepository == true, branch: branch)
        }
        guard connection.supports("/api/vcs/diff") else {
            return .init(unavailableReason: "This OpenCode 2 server does not provide file changes yet.")
        }
        let branch = connection.supports("/api/vcs") ? try? await vcsBranch(connection) : nil
        return .init(turn: false, uncommitted: branch?.isRepository ?? true, branch: branch)
    }

    func diffs(_ source: OpenCodeDiffSource, messageID: String?) async throws -> [OpenCodeDiff] {
        let connection = try await context()
        let v2 = connection.serverProtocol == .v2
        switch source {
        case .turn, .session:
            guard !v2 else { throw OpenCodeDiffReviewError.unsupported(source) }
            var query = locationQuery(v2: false)
            if source == .turn {
                guard let messageID else { throw OpenCodeDiffReviewError.missingTurn }
                query.append(URLQueryItem(name: "messageID", value: messageID))
            }
            return try await connection.transport.get(["session", sessionID, "diff"], query: query)
        case .uncommitted, .branch:
            if !v2 {
                let mode = source == .uncommitted ? "git" : "branch"
                return try await connection.transport.get(
                    ["vcs", "diff"], query: locationQuery(v2: false) + [URLQueryItem(name: "mode", value: mode)])
            }
            guard connection.supports("/api/vcs/diff") else { throw OpenCodeDiffReviewError.unsupported(source) }
            let mode = source == .uncommitted ? "working" : "branch"
            let response: LocatedResponse<[OpenCodeDiff]> = try await connection.transport.get(
                ["api", "vcs", "diff"], query: locationQuery(v2: true) + [URLQueryItem(name: "mode", value: mode)])
            try response.validate(directory: directory, workspace: workspace)
            return response.data
        }
    }

    private func vcsBranch(_ connection: OpenCodeFeatureContext) async throws -> OpenCodeVcsBranch {
        if connection.serverProtocol == .v1 {
            struct Info: Decodable { let branch: String?; let default_branch: String? }
            let info: Info = try await connection.transport.get(["vcs"], query: locationQuery(v2: false))
            return .init(current: info.branch?.trimmedNonEmpty, defaultBranch: info.default_branch?.trimmedNonEmpty)
        }
        struct Info: Decodable {
            struct Branch: Decodable { let current: String?; let `default`: String? }
            let branch: Branch?
        }
        let response: LocatedResponse<Info> = try await connection.transport.get(["api", "vcs"], query: locationQuery(v2: true))
        try response.validate(directory: directory, workspace: workspace)
        return .init(current: response.data.branch?.current?.trimmedNonEmpty,
                     defaultBranch: response.data.branch?.default?.trimmedNonEmpty)
    }

    private func locationQuery(v2: Bool) -> [URLQueryItem] {
        var query = [URLQueryItem(name: v2 ? "location[directory]" : "directory", value: directory)]
        if let workspace { query.append(URLQueryItem(name: v2 ? "location[workspace]" : "workspace", value: workspace)) }
        return query
    }
}

private struct LocatedResponse<Value: Decodable>: Decodable {
    struct Location: Decodable {
        let directory: String
        let workspaceID: String?
    }
    let location: Location
    let data: Value

    func validate(directory: String, workspace: String?) throws {
        guard location.directory == directory, location.workspaceID == workspace else {
            throw OpenCodeDiffReviewError.wrongLocation
        }
    }
}
