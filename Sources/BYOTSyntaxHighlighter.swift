import Foundation

/// Token classes the transcript, tool rows, and file reader color. The set is
/// deliberately coarse: operators and punctuation stay in the primary ink so
/// code reads calmly on a phone, and the palette only has to tune these.
enum BYOTSyntaxTokenKind: String, CaseIterable, Sendable {
    case keyword
    case type
    case function
    case string
    /// Numbers and language literals such as `true`, `nil`, and `None`.
    case constant
    case comment
    case attribute
    case preprocessor
    case property
    case tag
    case variable
    case inserted
    case deleted
    case hunk
    case heading
}

/// A colored run. `range` is a UTF-8 byte range into the tokenized text.
struct BYOTSyntaxToken: Equatable, Sendable {
    let kind: BYOTSyntaxTokenKind
    let range: Range<Int>
}

/// One run of a highlighted line; `kind == nil` is plain text.
struct BYOTSyntaxSegment: Equatable, Sendable {
    let text: String
    let kind: BYOTSyntaxTokenKind?
}

/// One source line. Lines never contain the `\n` separator, so joining every
/// line's text with `\n` reproduces the input exactly.
struct BYOTSyntaxLine: Equatable, Sendable {
    let segments: [BYOTSyntaxSegment]

    var text: String { segments.map(\.text).joined() }

    static func plain(_ text: String) -> BYOTSyntaxLine {
        BYOTSyntaxLine(segments: text.isEmpty ? [] : [BYOTSyntaxSegment(text: text, kind: nil)])
    }
}

/// A lightweight, dependency-free highlighter for the languages agents write
/// most. It scans UTF-8 bytes once, carries state across lines (block comments,
/// multi-line strings), and only ever breaks runs at ASCII delimiters, so the
/// output is lossless for any Unicode input. It is not a parser: the goal is
/// legible, stable color that stays fast on long files and mid-stream fences.
enum BYOTSyntaxHighlighter {
    /// Beyond this, text renders plain. Highlighting stays linear, but a very
    /// large attributed run costs more in layout than the color is worth.
    static let byteLimit = 256 * 1024

    static func tokens(in text: String, language: BYOTSyntaxLanguage) -> [BYOTSyntaxToken] {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty, bytes.count <= byteLimit else { return [] }
        var scanner = BYOTSyntaxScanner(bytes: bytes, grammar: language.grammar)
        return scanner.scan()
    }

    /// Splits `text` at `\n` (exactly like `components(separatedBy: "\n")`)
    /// and attaches the language's colors to each line.
    static func lines(_ text: String, language: BYOTSyntaxLanguage?) -> [BYOTSyntaxLine] {
        guard let language else { return plainLines(text) }
        let bytes = Array(text.utf8)
        guard bytes.count <= byteLimit else { return plainLines(text) }
        var scanner = BYOTSyntaxScanner(bytes: bytes, grammar: language.grammar)
        let tokens = scanner.scan()
        return segmentLines(bytes: bytes, tokens: tokens)
    }

    static func plainLines(_ text: String) -> [BYOTSyntaxLine] {
        text.components(separatedBy: "\n").map(BYOTSyntaxLine.plain)
    }

    private static func segmentLines(bytes: [UInt8], tokens: [BYOTSyntaxToken]) -> [BYOTSyntaxLine] {
        var lines: [BYOTSyntaxLine] = []
        var tokenIndex = 0
        var lineStart = 0

        func text(_ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
        }

        while true {
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }

            var segments: [BYOTSyntaxSegment] = []
            var cursor = lineStart
            while tokenIndex < tokens.count, tokens[tokenIndex].range.upperBound <= lineStart {
                tokenIndex += 1
            }
            var index = tokenIndex
            while index < tokens.count, tokens[index].range.lowerBound < lineEnd {
                let token = tokens[index]
                let start = max(token.range.lowerBound, lineStart)
                let end = min(token.range.upperBound, lineEnd)
                if start > cursor { segments.append(.init(text: text(cursor..<start), kind: nil)) }
                if end > start { segments.append(.init(text: text(start..<end), kind: token.kind)) }
                cursor = max(cursor, end)
                if token.range.upperBound > lineEnd { break }
                index += 1
            }
            tokenIndex = index
            if lineEnd > cursor { segments.append(.init(text: text(cursor..<lineEnd), kind: nil)) }
            lines.append(BYOTSyntaxLine(segments: segments))

            guard lineEnd < bytes.count else { break }
            lineStart = lineEnd + 1
        }
        return lines
    }
}

// MARK: - Scanner

private enum ASCII {
    static let tab: UInt8 = 0x09
    static let newline: UInt8 = 0x0A
    static let carriageReturn: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let bang: UInt8 = 0x21
    static let quote: UInt8 = 0x22
    static let hash: UInt8 = 0x23
    static let dollar: UInt8 = 0x24
    static let ampersand: UInt8 = 0x26
    static let apostrophe: UInt8 = 0x27
    static let openParen: UInt8 = 0x28
    static let closeParen: UInt8 = 0x29
    static let plus: UInt8 = 0x2B
    static let minus: UInt8 = 0x2D
    static let dot: UInt8 = 0x2E
    static let slash: UInt8 = 0x2F
    static let zero: UInt8 = 0x30
    static let nine: UInt8 = 0x39
    static let colon: UInt8 = 0x3A
    static let semicolon: UInt8 = 0x3B
    static let lessThan: UInt8 = 0x3C
    static let equals: UInt8 = 0x3D
    static let greaterThan: UInt8 = 0x3E
    static let question: UInt8 = 0x3F
    static let at: UInt8 = 0x40
    static let upperA: UInt8 = 0x41
    static let upperZ: UInt8 = 0x5A
    static let openBracket: UInt8 = 0x5B
    static let backslash: UInt8 = 0x5C
    static let closeBracket: UInt8 = 0x5D
    static let underscore: UInt8 = 0x5F
    static let backtick: UInt8 = 0x60
    static let lowerA: UInt8 = 0x61
    static let lowerE: UInt8 = 0x65
    static let lowerZ: UInt8 = 0x7A
    static let openBrace: UInt8 = 0x7B
    static let closeBrace: UInt8 = 0x7D
    static let tilde: UInt8 = 0x7E
}

struct BYOTSyntaxScanner {
    private let bytes: [UInt8]
    private let grammar: BYOTSyntaxGrammar
    private var tokens: [BYOTSyntaxToken] = []
    private var index = 0
    /// True until the first token on the current line, ignoring indentation
    /// (and YAML list markers). Drives line-start keys and C directives.
    private var atLineStart = true
    private var pendingDeclaration: BYOTSyntaxTokenKind?
    private var pendingIncludePath = false
    private var braceDepth = 0

    init(bytes: [UInt8], grammar: BYOTSyntaxGrammar) {
        self.bytes = bytes
        self.grammar = grammar
    }

    mutating func scan() -> [BYOTSyntaxToken] {
        switch grammar.mode {
        case .code: scanCode()
        case .markup: scanMarkup()
        case .diff: scanDiff()
        case .markdown: scanMarkdown()
        }
        return tokens
    }

    // MARK: Helpers

    private var count: Int { bytes.count }

    private func byte(_ offset: Int = 0) -> UInt8? {
        let position = index + offset
        return position < count ? bytes[position] : nil
    }

    private func matches(_ literal: [UInt8], at position: Int) -> Bool {
        guard !literal.isEmpty, position + literal.count <= count else { return false }
        for offset in 0..<literal.count where bytes[position + offset] != literal[offset] {
            return false
        }
        return true
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= ASCII.zero && byte <= ASCII.nine }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (byte >= ASCII.lowerA && byte <= ASCII.lowerZ) || (byte >= ASCII.upperA && byte <= ASCII.upperZ)
    }

    private func isIdentifierStart(_ byte: UInt8) -> Bool {
        Self.isLetter(byte) || byte == ASCII.underscore || byte >= 0x80
            || grammar.identifierStartExtras.contains(byte)
    }

    private func isIdentifierContinue(_ byte: UInt8) -> Bool {
        Self.isLetter(byte) || Self.isDigit(byte) || byte == ASCII.underscore || byte >= 0x80
            || grammar.identifierExtras.contains(byte)
    }

    private func previousIsIdentifier(_ position: Int) -> Bool {
        position > 0 && isIdentifierContinue(bytes[position - 1])
    }

    private mutating func emit(_ kind: BYOTSyntaxTokenKind, _ start: Int, _ end: Int) {
        guard end > start else { return }
        if let last = tokens.last, last.kind == kind, last.range.upperBound == start {
            tokens[tokens.count - 1] = BYOTSyntaxToken(kind: kind, range: last.range.lowerBound..<end)
        } else {
            tokens.append(BYOTSyntaxToken(kind: kind, range: start..<end))
        }
    }

    private func lineEnd(from position: Int) -> Int {
        var end = position
        while end < count, bytes[end] != ASCII.newline { end += 1 }
        return end
    }

    private func skippingInlineSpace(from position: Int) -> Int {
        var position = position
        while position < count, bytes[position] == ASCII.space || bytes[position] == ASCII.tab {
            position += 1
        }
        return position
    }

    // MARK: Code

    private mutating func scanCode() {
        while index < count {
            let current = bytes[index]

            if current == ASCII.newline {
                atLineStart = true
                pendingDeclaration = nil
                pendingIncludePath = false
                index += 1
                continue
            }
            if current == ASCII.space || current == ASCII.tab || current == ASCII.carriageReturn {
                index += 1
                continue
            }
            if grammar.keys == .lineStartColon, atLineStart, current == ASCII.minus,
               byte(1) == ASCII.space || byte(1) == ASCII.tab {
                // A YAML sequence item: its key still counts as the line's first token.
                index += 1
                continue
            }

            let wasAtLineStart = atLineStart
            atLineStart = false

            if scanComment() { continue }
            if pendingIncludePath, current == ASCII.lessThan, scanIncludePath() { continue }
            if grammar.keys == .lineStartEquals, wasAtLineStart, current == ASCII.openBracket {
                let end = lineEnd(from: index)
                var close = index
                while close < end, bytes[close] != ASCII.closeBracket { close += 1 }
                if close < end {
                    emit(.heading, index, close + 1)
                    index = close + 1
                    continue
                }
            }
            if scanString(atLineStart: wasAtLineStart) { continue }
            if scanSigil() { continue }
            if grammar.rustQuotes, current == ASCII.apostrophe, scanRustQuote() { continue }
            if Self.isDigit(current), !previousIsIdentifier(index) {
                scanNumber()
                continue
            }
            if isIdentifierStart(current) {
                scanIdentifier(atLineStart: wasAtLineStart)
                continue
            }

            if current == ASCII.openBrace { braceDepth += 1 }
            if current == ASCII.closeBrace { braceDepth = max(0, braceDepth - 1) }
            if current != ASCII.dot, current != ASCII.colon { pendingDeclaration = nil }
            index += 1
        }
    }

    private mutating func scanComment() -> Bool {
        for delimiter in grammar.blockComments where matches(delimiter.open, at: index) {
            let start = index
            var position = index + delimiter.open.count
            while position < count, !matches(delimiter.close, at: position) { position += 1 }
            index = min(count, position + delimiter.close.count)
            emit(.comment, start, index)
            return true
        }
        for marker in grammar.lineComments where matches(marker, at: index) {
            if grammar.hashCommentsNeedBoundary, marker == [ASCII.hash], index > 0,
               bytes[index - 1] != ASCII.space, bytes[index - 1] != ASCII.tab, bytes[index - 1] != ASCII.newline {
                continue
            }
            let start = index
            index = lineEnd(from: index)
            emit(.comment, start, index)
            return true
        }
        return false
    }

    private mutating func scanString(atLineStart: Bool) -> Bool {
        guard let delimiter = grammar.strings.first(where: { matches($0.open, at: index) }) else {
            return false
        }
        let start = index
        var position = index + delimiter.open.count
        while position < count {
            if delimiter.escapes, bytes[position] == ASCII.backslash {
                position += 2
                continue
            }
            if matches(delimiter.close, at: position) {
                position += delimiter.close.count
                break
            }
            if !delimiter.multiline, bytes[position] == ASCII.newline { break }
            position += 1
        }
        index = min(position, count)

        var kind = BYOTSyntaxTokenKind.string
        if isKey(endingAt: index, atLineStart: atLineStart) { kind = .property }
        emit(kind, start, index)
        pendingDeclaration = nil
        return true
    }

    private func isKey(endingAt end: Int, atLineStart: Bool) -> Bool {
        switch grammar.keys {
        case .none:
            return false
        case .jsonStrings:
            let next = skippingInlineSpace(from: end)
            return next < count && bytes[next] == ASCII.colon
        case .lineStartColon:
            guard atLineStart else { return false }
            let next = skippingInlineSpace(from: end)
            guard next < count, bytes[next] == ASCII.colon else { return false }
            let after = next + 1
            return after >= count || [ASCII.space, ASCII.tab, ASCII.newline, ASCII.carriageReturn].contains(bytes[after])
        case .lineStartEquals:
            guard atLineStart else { return false }
            let next = skippingInlineSpace(from: end)
            return next < count && (bytes[next] == ASCII.equals || bytes[next] == ASCII.colon)
        case .blockColon:
            guard braceDepth > 0 else { return false }
            let next = skippingInlineSpace(from: end)
            return next < count && bytes[next] == ASCII.colon
        }
    }

    private mutating func scanIncludePath() -> Bool {
        let end = lineEnd(from: index)
        var close = index + 1
        while close < end, bytes[close] != ASCII.greaterThan { close += 1 }
        guard close < end else { return false }
        emit(.string, index, close + 1)
        index = close + 1
        pendingIncludePath = false
        return true
    }

    private mutating func scanSigil() -> Bool {
        let current = bytes[index]
        guard let kind = grammar.sigils[current], !previousIsIdentifier(index) else { return false }
        guard let next = byte(1) else { return false }
        let start = index

        if current == ASCII.hash, grammar.bracketAttributes,
           next == ASCII.openBracket || (next == ASCII.bang && byte(2) == ASCII.openBracket) {
            let end = lineEnd(from: index)
            var close = index
            while close < end, bytes[close] != ASCII.closeBracket { close += 1 }
            index = min(close + 1, end)
            emit(kind, start, index)
            return true
        }

        if current == ASCII.dollar {
            if next == ASCII.openBrace || (next == ASCII.openParen && grammar.dollarParenVariables) {
                let closer = next == ASCII.openBrace ? ASCII.closeBrace : ASCII.closeParen
                let end = lineEnd(from: index)
                var close = index + 2
                while close < end, bytes[close] != closer { close += 1 }
                guard close < end else { return false }
                index = close + 1
                emit(kind, start, index)
                return true
            }
            if grammar.shellSpecialVariables,
               Self.isDigit(next) || [ASCII.at, ASCII.question, ASCII.hash, ASCII.dollar, ASCII.bang, 0x2A, ASCII.minus].contains(next) {
                index += 2
                emit(kind, start, index)
                return true
            }
        }

        // Ruby and Elixir symbols, but never a `::` scope separator.
        if current == ASCII.colon,
           next == ASCII.colon || (start > 0 && bytes[start - 1] == ASCII.colon) {
            return false
        }
        if current == ASCII.hash, kind == .constant {
            // CSS hex colors and ids: `#fff`, `#main`.
            var position = index + 1
            while position < count, isIdentifierContinue(bytes[position]) { position += 1 }
            guard position > index + 1 else { return false }
            index = position
            emit(kind, start, index)
            return true
        }

        guard isIdentifierStart(next) else { return false }
        var position = index + 1
        while position < count, isIdentifierContinue(bytes[position]) { position += 1 }
        index = position
        emit(kind, start, index)

        if kind == .preprocessor {
            let directive = String(decoding: bytes[(start + 1)..<index], as: UTF8.self)
            pendingIncludePath = directive == "include" || directive == "import"
        }
        return true
    }

    /// Rust uses `'` for both char literals and lifetimes (`'a`, `'static`).
    private mutating func scanRustQuote() -> Bool {
        let start = index
        let end = lineEnd(from: index)
        var position = index + 1
        if position < end, bytes[position] == ASCII.backslash { position += 2 } else {
            // Step over one (possibly multi-byte) character.
            position += 1
            while position < end, bytes[position] & 0xC0 == 0x80 { position += 1 }
        }
        if position < end, bytes[position] == ASCII.apostrophe {
            index = position + 1
            emit(.string, start, index)
            return true
        }
        if position <= end, let next = byte(1), isIdentifierStart(next) {
            var identifierEnd = index + 1
            while identifierEnd < count, isIdentifierContinue(bytes[identifierEnd]) { identifierEnd += 1 }
            index = identifierEnd
            emit(.attribute, start, index)
            return true
        }
        return false
    }

    private mutating func scanNumber() {
        let start = index
        index += 1
        while index < count {
            let current = bytes[index]
            if isIdentifierContinue(current) && current < 0x80 && !grammar.identifierExtras.contains(current) {
                let lowered = current | 0x20
                index += 1
                if lowered == ASCII.lowerE, let sign = byte(), sign == ASCII.plus || sign == ASCII.minus,
                   let digit = byte(1), Self.isDigit(digit), !isHexLiteral(start) {
                    index += 1
                }
                continue
            }
            if current == ASCII.dot, let next = byte(1), Self.isDigit(next) {
                index += 1
                continue
            }
            break
        }
        emit(.constant, start, index)
        pendingDeclaration = nil
    }

    private func isHexLiteral(_ start: Int) -> Bool {
        start + 1 < count && bytes[start] == ASCII.zero && (bytes[start + 1] | 0x20) == 0x78
    }

    private mutating func scanIdentifier(atLineStart: Bool) {
        let start = index
        index += 1
        while index < count, isIdentifierContinue(bytes[index]) { index += 1 }
        let word = String(decoding: bytes[start..<index], as: UTF8.self)
        let lookup = grammar.caseInsensitive ? word.lowercased() : word

        if isKey(endingAt: index, atLineStart: atLineStart) {
            emit(.property, start, index)
            pendingDeclaration = nil
            return
        }
        if grammar.keywords.contains(lookup) {
            emit(.keyword, start, index)
            if grammar.functionDeclarators.contains(lookup) {
                pendingDeclaration = .function
            } else if grammar.typeDeclarators.contains(lookup) {
                pendingDeclaration = .type
            } else {
                pendingDeclaration = nil
            }
            return
        }
        if let declaration = pendingDeclaration {
            emit(declaration, start, index)
            pendingDeclaration = nil
            return
        }
        if grammar.constants.contains(lookup) {
            emit(.constant, start, index)
            return
        }
        if grammar.types.contains(lookup) {
            emit(.type, start, index)
            return
        }
        if grammar.functions.contains(lookup) {
            emit(.function, start, index)
            return
        }
        if grammar.highlightsCalls, byte() == ASCII.openParen {
            emit(.function, start, index)
            return
        }
        if grammar.macroBang, byte() == ASCII.bang, byte(1) != ASCII.equals {
            // Rust macros: `println!`, `vec!`.
            index += 1
            emit(.function, start, index)
            return
        }
        if grammar.capitalizedTypes, let first = word.utf8.first, first >= ASCII.upperA, first <= ASCII.upperZ {
            if word.utf8.contains(where: { $0 >= ASCII.lowerA && $0 <= ASCII.lowerZ }) {
                emit(.type, start, index)
            } else if word.utf8.count > 1 {
                emit(.constant, start, index)
            }
        }
    }

    // MARK: Markup

    private mutating func scanMarkup() {
        let commentOpen = Array("<!--".utf8)
        let commentClose = Array("-->".utf8)
        let cdataOpen = Array("<![CDATA[".utf8)
        let cdataClose = Array("]]>".utf8)

        while index < count {
            let current = bytes[index]
            if matches(commentOpen, at: index) {
                scanUntil(commentClose, kind: .comment)
            } else if matches(cdataOpen, at: index) {
                scanUntil(cdataClose, kind: .string)
            } else if current == ASCII.lessThan, let next = byte(1), next == ASCII.bang || next == ASCII.question {
                scanUntil([ASCII.greaterThan], kind: .preprocessor)
            } else if current == ASCII.lessThan, let next = byte(1),
                      next == ASCII.slash || Self.isLetter(next) {
                scanTag()
            } else if current == ASCII.ampersand {
                let end = min(count, index + 12)
                var close = index + 1
                while close < end, bytes[close] != ASCII.semicolon, bytes[close] != ASCII.space { close += 1 }
                if close < end, bytes[close] == ASCII.semicolon, close > index + 1 {
                    emit(.constant, index, close + 1)
                    index = close + 1
                } else {
                    index += 1
                }
            } else {
                index += 1
            }
        }
    }

    private mutating func scanUntil(_ close: [UInt8], kind: BYOTSyntaxTokenKind) {
        let start = index
        var position = index + 1
        while position < count, !matches(close, at: position) { position += 1 }
        index = min(count, position + close.count)
        emit(kind, start, index)
    }

    private func isMarkupNameByte(_ byte: UInt8) -> Bool {
        Self.isLetter(byte) || Self.isDigit(byte) || byte >= 0x80
            || [ASCII.minus, ASCII.underscore, ASCII.colon, ASCII.dot, ASCII.at].contains(byte)
    }

    private mutating func scanTag() {
        index += 1
        if byte() == ASCII.slash { index += 1 }
        let nameStart = index
        while index < count, isMarkupNameByte(bytes[index]) { index += 1 }
        emit(.tag, nameStart, index)

        while index < count {
            let current = bytes[index]
            if current == ASCII.greaterThan {
                index += 1
                return
            }
            if current == ASCII.quote || current == ASCII.apostrophe {
                let start = index
                var position = index + 1
                while position < count, bytes[position] != current { position += 1 }
                index = min(count, position + 1)
                emit(.string, start, index)
                continue
            }
            if current == ASCII.lessThan { return }
            if isMarkupNameByte(current) || current == ASCII.colon {
                let start = index
                while index < count, isMarkupNameByte(bytes[index]) { index += 1 }
                emit(.property, start, index)
                continue
            }
            index += 1
        }
    }

    // MARK: Diff

    private mutating func scanDiff() {
        let headers = ["diff ", "index ", "*** ", "new file", "deleted file", "similarity", "rename "]
            .map { Array($0.utf8) }
        let oldFile = Array("--- ".utf8)
        let newFile = Array("+++ ".utf8)
        // `--- a` / `+++ b` is a file header only as a pair; alone it is a
        // removed `-- a` (a SQL or Lua comment) or an added `++ b`.
        var previousWasOldFile = false
        while index < count {
            let start = index
            let end = lineEnd(from: index)
            let kind: BYOTSyntaxTokenKind?
            let isOldFile = matches(oldFile, at: start) && matches(newFile, at: end + 1)
            let isNewFile = previousWasOldFile && matches(newFile, at: start)
            previousWasOldFile = isOldFile
            if isOldFile || isNewFile || headers.contains(where: { matches($0, at: start) }) {
                kind = .heading
            } else {
                switch bytes[start] {
                case ASCII.newline: kind = nil
                case 0x40 where byte(1) == 0x40: kind = .hunk
                case ASCII.plus: kind = .inserted
                case ASCII.minus: kind = .deleted
                case ASCII.backslash: kind = .comment
                default: kind = nil
                }
            }
            if let kind { emit(kind, start, end) }
            index = end + 1
        }
    }

    // MARK: Markdown

    private mutating func scanMarkdown() {
        var fence: UInt8?
        while index < count {
            let start = index
            let end = lineEnd(from: index)
            let content = skippingInlineSpace(from: start)

            let marker: UInt8? = content + 2 < end ? bytes[content] : nil
            if let marker, marker == ASCII.backtick || marker == ASCII.tilde,
               bytes[content + 1] == marker, bytes[content + 2] == marker {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                emit(.string, start, end)
            } else if fence != nil {
                emit(.string, start, end)
            } else if content < end, bytes[content] == ASCII.hash {
                var level = content
                while level < end, bytes[level] == ASCII.hash { level += 1 }
                if level - content <= 6, level == end || bytes[level] == ASCII.space {
                    emit(.heading, content, end)
                } else {
                    scanMarkdownInline(content, end)
                }
            } else if content < end, bytes[content] == ASCII.greaterThan {
                emit(.comment, content, end)
            } else {
                var body = content
                if content + 1 < end, [ASCII.minus, 0x2A, ASCII.plus].contains(bytes[content]),
                   bytes[content + 1] == ASCII.space {
                    emit(.keyword, content, content + 1)
                    body = content + 2
                } else {
                    var digits = content
                    while digits < end, Self.isDigit(bytes[digits]) { digits += 1 }
                    if digits > content, digits + 1 < end, bytes[digits] == ASCII.dot, bytes[digits + 1] == ASCII.space {
                        emit(.keyword, content, digits + 1)
                        body = digits + 2
                    }
                }
                scanMarkdownInline(body, end)
            }
            index = end + 1
        }
    }

    private mutating func scanMarkdownInline(_ start: Int, _ end: Int) {
        var position = start
        while position < end {
            if bytes[position] == ASCII.backtick {
                var close = position + 1
                while close < end, bytes[close] != ASCII.backtick { close += 1 }
                if close < end {
                    emit(.string, position, close + 1)
                    position = close + 1
                    continue
                }
            }
            if bytes[position] == ASCII.closeBracket, position + 1 < end, bytes[position + 1] == ASCII.openParen {
                var close = position + 2
                while close < end, bytes[close] != ASCII.closeParen { close += 1 }
                if close < end {
                    emit(.property, position + 2, close)
                    position = close + 1
                    continue
                }
            }
            position += 1
        }
    }
}
