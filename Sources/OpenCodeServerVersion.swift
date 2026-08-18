import Foundation

struct OpenCodeServerVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    init?(parsing rawValue: String) {
        var text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }

        if let plus = text.firstIndex(of: "+") {
            let metadata = text[text.index(after: plus)...]
            guard Self.areValidIdentifiers(metadata) else { return nil }
            text = String(text[..<plus])
        }

        var prerelease: [String] = []
        if let hyphen = text.firstIndex(of: "-") {
            let identifiers = text[text.index(after: hyphen)...]
                .split(separator: ".", omittingEmptySubsequences: false)
            guard identifiers.allSatisfy({ Self.isValidPrereleaseIdentifier($0) }) else {
                return nil
            }
            prerelease = identifiers.map(String.init)
            text = String(text[..<hyphen])
        }

        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Self.parseCoreComponent(parts[0]),
              let minor = Self.parseCoreComponent(parts[1]),
              let patch = Self.parseCoreComponent(parts[2])
        else { return nil }
        self.init(major: major, minor: minor, patch: patch, prerelease: prerelease)
    }

    private static func parseCoreComponent(_ part: Substring) -> Int? {
        guard Self.isNumeric(part) else { return nil }
        if part.count > 1, part.first == "0" { return nil }
        return Int(part)
    }

    private static func areValidIdentifiers(_ dotSeparated: Substring) -> Bool {
        let identifiers = dotSeparated.split(separator: ".", omittingEmptySubsequences: false)
        return identifiers.allSatisfy { identifier in
            !identifier.isEmpty
                && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    private static func isValidPrereleaseIdentifier(_ identifier: Substring) -> Bool {
        guard areValidIdentifiers(identifier) else { return false }
        if isNumeric(identifier), identifier.count > 1, identifier.first == "0" {
            return false
        }
        return true
    }

    private static func isNumeric(_ text: Substring) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isNumeric(_ text: String) -> Bool {
        isNumeric(Substring(text))
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if (lhs.major, lhs.minor, lhs.patch) != (rhs.major, rhs.minor, rhs.patch) {
            return (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
        }
        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, true):
            return false
        case (false, true):
            return true
        case (true, false):
            return false
        case (false, false):
            for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
                if left == right { continue }
                switch (isNumeric(left), isNumeric(right)) {
                case (true, true):
                    if left.count != right.count { return left.count < right.count }
                    return left < right
                case (true, false):
                    return true
                case (false, true):
                    return false
                case (false, false):
                    return left < right
                }
            }
            return lhs.prerelease.count < rhs.prerelease.count
        }
    }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease.joined(separator: "."))"
    }
}
