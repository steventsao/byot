import Foundation
import SwiftUI
import Testing
import UIKit
@testable import byot

@Suite("Syntax highlighting")
struct BYOTSyntaxHighlighterTests {
    // MARK: Language detection

    @Test(
        "Fence labels resolve common spellings",
        arguments: [
            ("swift", BYOTSyntaxLanguage.swift),
            ("TypeScript", .typescript),
            ("tsx", .typescript),
            ("language-py", .python),
            ("js title=\"server.js\"", .javascript),
            ("swift:Sources/App.swift", .swift),
            ("{.python}", .python),
            ("Sources/App.swift", .swift),
            ("c++", .cpp),
            ("objective-c", .objectiveC),
            ("console", .shell),
            ("yml", .yaml),
            ("jsonc", .json),
            ("patch", .diff),
            ("plist", .xml),
        ]
    )
    func fenceLabels(label: String, expected: BYOTSyntaxLanguage) {
        #expect(BYOTSyntaxLanguage(fenceLabel: label) == expected)
    }

    @Test("Unknown or empty fence labels stay plain")
    func unknownFenceLabels() {
        #expect(BYOTSyntaxLanguage(fenceLabel: nil) == nil)
        #expect(BYOTSyntaxLanguage(fenceLabel: "  ") == nil)
        #expect(BYOTSyntaxLanguage(fenceLabel: "text") == nil)
        #expect(BYOTSyntaxLanguage(fenceLabel: "output") == nil)
    }

    @Test(
        "Paths resolve by extension and well-known names",
        arguments: [
            ("/repo/Sources/App.swift", BYOTSyntaxLanguage.swift),
            ("web/src/index.test.tsx", .typescript),
            ("Dockerfile", .dockerfile),
            ("deploy/Dockerfile.prod", .dockerfile),
            ("Makefile", .makefile),
            ("~/.zshrc", .shell),
            (".env.local", .ini),
            ("Cargo.lock", .toml),
            ("Podfile", .ruby),
            ("Info.plist", .xml),
            ("config/app.YAML", .yaml),
            ("lib/main.rs", .rust),
        ]
    )
    func paths(path: String, expected: BYOTSyntaxLanguage) {
        #expect(BYOTSyntaxLanguage(path: path) == expected)
    }

    @Test("Paths without a known language stay plain")
    func unknownPaths() {
        #expect(BYOTSyntaxLanguage(path: "README") == nil)
        #expect(BYOTSyntaxLanguage(path: "notes.") == nil)
        #expect(BYOTSyntaxLanguage(path: "image.png") == nil)
        #expect(BYOTSyntaxLanguage(mimeType: "application/json; charset=utf-8") == .json)
        #expect(BYOTSyntaxLanguage(mimeType: "text/plain") == nil)
    }

    // MARK: Tokens

    @Test("Swift declarations, attributes, literals, and comments")
    func swiftTokens() {
        let runs = colored("""
        @MainActor final class Greeter: View {
            #if DEBUG
            func greet(name: String) -> Int { print("hi"); return 0x1F } // done
        }
        """, .swift)

        #expect(runs.contains(.init("@MainActor", .attribute)))
        #expect(runs.contains(.init("final", .keyword)))
        #expect(runs.contains(.init("Greeter", .type)))
        #expect(runs.contains(.init("View", .type)))
        #expect(runs.contains(.init("#if", .preprocessor)))
        #expect(runs.contains(.init("greet", .function)))
        #expect(runs.contains(.init("String", .type)))
        #expect(runs.contains(.init("print", .function)))
        #expect(runs.contains(.init("\"hi\"", .string)))
        #expect(runs.contains(.init("0x1F", .constant)))
        #expect(runs.contains(.init("// done", .comment)))
        #expect(!runs.contains { $0.text == "name" })
    }

    @Test("Escaped quotes stay inside the string")
    func escapedQuotes() {
        let runs = colored(#"let s = "a\"b" + x"#, .swift)

        #expect(runs.contains(.init(#""a\"b""#, .string)))
        #expect(!runs.contains { $0.text == "x" })
    }

    @Test("Block comments and triple-quoted strings carry across lines")
    func multilineState() {
        let lines = BYOTSyntaxHighlighter.lines("x = 1 /* open\nstill */ y\n\"\"\"\nbody\n\"\"\" z", language: .swift)

        #expect(lines.count == 5)
        #expect(lines[1].segments.first == BYOTSyntaxSegment(text: "still */", kind: .comment))
        #expect(lines[3].segments == [BYOTSyntaxSegment(text: "body", kind: .string)])
        #expect(lines[4].segments.first == BYOTSyntaxSegment(text: "\"\"\"", kind: .string))
    }

    @Test("An unterminated single-line string stops at the line end")
    func unterminatedString() {
        let lines = BYOTSyntaxHighlighter.lines("let s = \"open\nlet t = 1", language: .swift)

        #expect(lines[1].segments.first == BYOTSyntaxSegment(text: "let", kind: .keyword))
    }

    @Test("Python keywords, decorators, and triple quotes")
    func pythonTokens() {
        let runs = colored("@cache\ndef load(path: str) -> None:\n    '''Docs'''\n    return True  # ok", .python)

        #expect(runs.contains(.init("@cache", .attribute)))
        #expect(runs.contains(.init("def", .keyword)))
        #expect(runs.contains(.init("load", .function)))
        #expect(runs.contains(.init("str", .type)))
        #expect(runs.contains(.init("None", .constant)))
        #expect(runs.contains(.init("'''Docs'''", .string)))
        #expect(runs.contains(.init("True", .constant)))
        #expect(runs.contains(.init("# ok", .comment)))
    }

    @Test("TypeScript types and template literals")
    func typescriptTokens() {
        let runs = colored("interface Props { id: number }\nconst url = `/api/${id}`\nexport function run(): void {}", .typescript)

        #expect(runs.contains(.init("interface", .keyword)))
        #expect(runs.contains(.init("Props", .type)))
        #expect(runs.contains(.init("number", .type)))
        #expect(runs.contains(.init("`/api/${id}`", .string)))
        #expect(runs.contains(.init("run", .function)))
    }

    @Test("Rust separates lifetimes, chars, macros, and attributes")
    func rustTokens() {
        let runs = colored("#[derive(Debug)]\nfn first<'a>(s: &'a str) -> char { println!(\"{}\", s); 'x' }", .rust)

        #expect(runs.contains(.init("#[derive(Debug)]", .attribute)))
        #expect(runs.contains(.init("first", .function)))
        #expect(runs.contains(.init("'a", .attribute)))
        #expect(runs.contains(.init("str", .type)))
        #expect(runs.contains(.init("println!", .function)))
        #expect(runs.contains(.init("'x'", .string)))
    }

    @Test("C preprocessor directives color their include path")
    func cInclude() {
        let runs = colored("#include <stdio.h>\nint main(void) { return NULL; }", .c)

        #expect(runs.contains(.init("#include", .preprocessor)))
        #expect(runs.contains(.init("<stdio.h>", .string)))
        #expect(runs.contains(.init("int", .keyword)))
        #expect(runs.contains(.init("NULL", .constant)))
    }

    @Test("Shell comments need a word boundary and variables are colored")
    func shellTokens() {
        let runs = colored("export NAME=\"$HOME/${DIR}\" # set\necho a#b $1 '$literal'", .shell)

        #expect(runs.contains(.init("export", .keyword)))
        #expect(runs.contains(.init("\"$HOME/${DIR}\"", .string)))
        #expect(runs.contains(.init("# set", .comment)))
        #expect(runs.contains(.init("echo", .function)))
        #expect(!runs.contains { $0.kind == .comment && $0.text.contains("b") })
        #expect(runs.contains(.init("$1", .variable)))
        #expect(runs.contains(.init("'$literal'", .string)))
    }

    @Test("JSON separates keys from string values")
    func jsonTokens() {
        let runs = colored("{\n  \"name\" : \"byot\",\n  \"count\": 2,\n  \"ok\": true\n}", .json)

        #expect(runs.contains(.init("\"name\"", .property)))
        #expect(runs.contains(.init("\"byot\"", .string)))
        #expect(runs.contains(.init("2", .constant)))
        #expect(runs.contains(.init("true", .constant)))
    }

    @Test("YAML keys, list items, anchors, and comments")
    func yamlTokens() {
        let runs = colored("jobs:\n  - run-tests: yes # on push\n    url: http://x.y/#frag\n    base: &base 1", .yaml)

        #expect(runs.contains(.init("jobs", .property)))
        #expect(runs.contains(.init("run-tests", .property)))
        #expect(runs.contains(.init("yes", .constant)))
        #expect(runs.contains(.init("# on push", .comment)))
        #expect(!runs.contains { $0.kind == .comment && $0.text.contains("frag") })
        #expect(runs.contains(.init("&base", .variable)))
    }

    @Test("TOML sections and keys")
    func tomlTokens() {
        let runs = colored("[package]\nname = \"byot\"\nedition = 2021", .toml)

        #expect(runs.contains(.init("[package]", .heading)))
        #expect(runs.contains(.init("name", .property)))
        #expect(runs.contains(.init("\"byot\"", .string)))
        #expect(runs.contains(.init("2021", .constant)))
    }

    @Test("CSS properties only inside blocks")
    func cssTokens() {
        let runs = colored("a:hover { color: #fff; margin-top: 4px !important; }\n@media print {}", .css)

        #expect(!runs.contains { $0.text == "hover" })
        #expect(runs.contains(.init("color", .property)))
        #expect(runs.contains(.init("#fff", .constant)))
        #expect(runs.contains(.init("margin-top", .property)))
        #expect(runs.contains(.init("4px", .constant)))
        #expect(runs.contains(.init("!important", .keyword)))
        #expect(runs.contains(.init("@media", .keyword)))
    }

    @Test("SQL keywords ignore case")
    func sqlTokens() {
        let runs = colored("SELECT id FROM users WHERE name = 'o''k' -- note", .sql)

        #expect(runs.contains(.init("SELECT", .keyword)))
        #expect(runs.contains(.init("FROM", .keyword)))
        #expect(runs.contains(.init("-- note", .comment)))
        #expect(runs.contains(.init("'o''k'", .string)))
    }

    @Test("Ruby symbols never swallow a scope separator")
    func rubySymbols() {
        let runs = colored("Foo::Bar.call(:name, @ivar)", .ruby)

        #expect(runs.contains(.init(":name", .constant)))
        #expect(runs.contains(.init("@ivar", .variable)))
        #expect(!runs.contains { $0.text.hasPrefix(":Bar") || $0.text == ":" })
    }

    @Test("Markup tags, attributes, values, comments, and entities")
    func markupTokens() {
        let runs = colored("<!-- note -->\n<a href=\"/x\" data-id='1'>Tom &amp; Jerry</a>", .html)

        #expect(runs.contains(.init("<!-- note -->", .comment)))
        #expect(runs.contains(.init("a", .tag)))
        #expect(runs.contains(.init("href", .property)))
        #expect(runs.contains(.init("\"/x\"", .string)))
        #expect(runs.contains(.init("data-id", .property)))
        #expect(runs.contains(.init("&amp;", .constant)))
        #expect(!runs.contains { $0.text.contains("Tom") })
    }

    @Test("Diffs color headers, hunks, additions, and deletions by line")
    func diffTokens() {
        let lines = BYOTSyntaxHighlighter.lines("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same", language: .diff)

        #expect(lines.map { $0.segments.first?.kind } == [.heading, .heading, .hunk, .deleted, .inserted, nil])
    }

    @Test("Markdown headings, list markers, inline code, and fences")
    func markdownTokens() {
        let lines = BYOTSyntaxHighlighter.lines("# Title\n- use `swift`\n```\n# not heading\n```", language: .markdown)

        #expect(lines[0].segments == [BYOTSyntaxSegment(text: "# Title", kind: .heading)])
        #expect(lines[1].segments.contains(BYOTSyntaxSegment(text: "-", kind: .keyword)))
        #expect(lines[1].segments.contains(BYOTSyntaxSegment(text: "`swift`", kind: .string)))
        #expect(lines[3].segments == [BYOTSyntaxSegment(text: "# not heading", kind: .string)])
    }

    // MARK: Robustness

    @Test("Highlighting is lossless for every language and awkward input")
    func lossless() {
        let samples = [
            "",
            "\n\n",
            "let 名字 = \"你好\" // café 👩🏽‍💻\n\tprint(名字)\n",
            "windows\r\nline\r\n",
            "\"unterminated\n'also\n`tick\n/* never closed",
            "#[\n$\n${\n@\n<\n<!--\n&\n#",
            "e\u{301}\"\u{301}x\"é 1e+ 0x 1.2.3 ..< 'a",
        ]
        for language in BYOTSyntaxLanguage.allCases {
            for sample in samples {
                let lines = BYOTSyntaxHighlighter.lines(sample, language: language)
                #expect(lines.map(\.text).joined(separator: "\n") == sample, "\(language) \(sample.debugDescription)")
                #expect(lines.count == sample.components(separatedBy: "\n").count)
                #expect(lines.allSatisfy { $0.segments.allSatisfy { !$0.text.isEmpty } })
            }
        }
    }

    @Test("Tokens are ordered and never overlap")
    func tokensAreOrdered() {
        let source = (0..<40).map { "func f\($0)(x: Int) -> String { \"v\" } // \($0)" }.joined(separator: "\n")
        let tokens = BYOTSyntaxHighlighter.tokens(in: source, language: .swift)

        #expect(!tokens.isEmpty)
        for (previous, next) in zip(tokens, tokens.dropFirst()) {
            #expect(previous.range.upperBound <= next.range.lowerBound)
        }
    }

    @Test("Text past the size limit renders plain")
    func byteLimit() {
        let line = "let value = \"text\"\n"
        let source = String(repeating: line, count: BYOTSyntaxHighlighter.byteLimit / line.utf8.count + 1)
        let lines = BYOTSyntaxHighlighter.lines(source, language: .swift)

        #expect(lines.allSatisfy { $0.segments.allSatisfy { $0.kind == nil } })
        #expect(lines.map(\.text).joined(separator: "\n") == source)
    }

    @Test("A long file highlights quickly")
    func longFilePerformance() {
        let source = (0..<1_500).map { index in
            """
            /// Documentation for the type.
            struct Item\(index): Codable, Sendable {
                let id: String = "item"
                func total(values: [Double]) -> Double { values.reduce(0, +) * 1.5 }
            }

            """
        }.joined()
        #expect(source.utf8.count < BYOTSyntaxHighlighter.byteLimit)

        let start = Date()
        let lines = BYOTSyntaxHighlighter.lines(source, language: .swift)
        let elapsed = Date().timeIntervalSince(start)

        #expect(lines.count == 7_501)
        // Generous for unoptimized test builds; release builds are far faster.
        #expect(elapsed < 3)
    }

    // MARK: Rendering

    @Test("Rendered text keeps the source and colors tokens")
    func rendering() {
        let code = "let x = 1\nprint(x)"
        let attributed = BYOTSyntaxRenderer.attributedString(code: code, language: .swift)

        #expect(String(attributed.characters) == code)
        let keyword = attributed.runs.first { String(attributed[$0.range].characters) == "let" }
        #expect(keyword?.foregroundColor == BYOTSyntaxPalette.color(for: .keyword))

        let plain = BYOTSyntaxRenderer.attributedString(code: code, language: nil)
        #expect(plain.runs.allSatisfy { $0.foregroundColor == nil })
    }

    @Test("Selectable code keeps base attributes and exact text")
    @MainActor
    func selectableCode() {
        let code = "\tlet 名字 = \"你好\"\r\n    print(名字)\n"
        let document = AgentSelectionDocument.render(code, isCode: true, language: .swift)

        #expect(document.string == code)
        let keyword = (document.string as NSString).range(of: "let")
        let color = document.attribute(.foregroundColor, at: keyword.location, effectiveRange: nil) as? UIColor
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let expected = BYOTSyntaxPalette.uiColor(for: .keyword).resolvedColor(with: traits)
        #expect(color?.resolvedColor(with: traits) == expected)
        #expect(document.attribute(.backgroundColor, at: keyword.location, effectiveRange: nil) != nil)
    }

    @Test("Every color keeps 4.5:1 contrast on code surfaces in both appearances")
    func paletteContrast() {
        let lightSurfaces: [UInt32] = [0xFFFFFF, 0xF2F2F7]
        let darkSurfaces: [UInt32] = [0x000000, 0x1C1C1E, 0x2C2C2E]
        for kind in BYOTSyntaxTokenKind.allCases {
            for increased in [false, true] {
                let light = BYOTSyntaxPalette.components(for: kind, dark: false, increasedContrast: increased)
                let dark = BYOTSyntaxPalette.components(for: kind, dark: true, increasedContrast: increased)
                for surface in lightSurfaces {
                    #expect(contrast(light, surface) >= 4.5, "\(kind) light on \(String(surface, radix: 16))")
                }
                for surface in darkSurfaces {
                    #expect(contrast(dark, surface) >= 4.5, "\(kind) dark on \(String(surface, radix: 16))")
                }
            }
            let normal = contrast(BYOTSyntaxPalette.components(for: kind, dark: false), 0xFFFFFF)
            let increased = contrast(BYOTSyntaxPalette.components(for: kind, dark: false, increasedContrast: true), 0xFFFFFF)
            #expect(increased > normal)
        }
    }

    // MARK: Helpers

    struct Run: Equatable {
        let text: String
        let kind: BYOTSyntaxTokenKind

        init(_ text: String, _ kind: BYOTSyntaxTokenKind) {
            self.text = text
            self.kind = kind
        }
    }

    private func colored(_ source: String, _ language: BYOTSyntaxLanguage) -> [Run] {
        let bytes = Array(source.utf8)
        return BYOTSyntaxHighlighter.tokens(in: source, language: language).map {
            Run(String(decoding: bytes[$0.range], as: UTF8.self), $0.kind)
        }
    }

    private func contrast(_ color: (red: Double, green: Double, blue: Double), _ surface: UInt32) -> Double {
        func linear(_ value: Double) -> Double {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminance(_ red: Double, _ green: Double, _ blue: Double) -> Double {
            0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        let foreground = luminance(color.red, color.green, color.blue)
        let background = luminance(
            Double((surface >> 16) & 0xFF) / 255,
            Double((surface >> 8) & 0xFF) / 255,
            Double(surface & 0xFF) / 255
        )
        return (max(foreground, background) + 0.05) / (min(foreground, background) + 0.05)
    }
}
