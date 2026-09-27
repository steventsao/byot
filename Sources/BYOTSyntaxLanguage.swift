import Foundation

/// Languages the highlighter understands, detected from a fence label
/// (```` ```ts ````) or a file path (`Sources/App.swift`). Unknown labels and
/// extensions return `nil` and render plain, never as a guess.
enum BYOTSyntaxLanguage: String, CaseIterable, Sendable {
    case c, cpp, csharp, css, dart, diff, dockerfile, elixir, go, html, ini, java, javascript, json,
         kotlin, lua, makefile, markdown, objectiveC, php, python, ruby, rust, scala, shell, sql,
         swift, toml, typescript, xml, yaml, zig

    /// Resolves a Markdown fence info string such as `swift`, `TypeScript`,
    /// `language-py`, `js title="x"`, or `Sources/App.swift`.
    init?(fenceLabel: String?) {
        guard var label = fenceLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !label.isEmpty else { return nil }
        if let end = label.firstIndex(where: { $0 == " " || $0 == "{" || $0 == "," || $0 == ":" }) {
            let rest = label[end...].drop(while: { $0 == ":" || $0 == " " })
            // `swift:Sources/App.swift` and `{.python}` style labels.
            label = end == label.startIndex ? String(rest) : String(label[..<end])
        }
        label = label.trimmingCharacters(in: CharacterSet(charactersIn: "{}."))
        if label.hasPrefix("language-") { label.removeFirst("language-".count) }
        if let language = Self.aliases[label] {
            self = language
        } else if label.contains("/") || label.contains("."), let language = BYOTSyntaxLanguage(path: label) {
            self = language
        } else {
            return nil
        }
    }

    /// Resolves a file path by extension or by well-known file name.
    init?(path: String?) {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        if let language = Self.fileNames[name] {
            self = language
            return
        }
        if name.hasPrefix("dockerfile") || name.hasSuffix(".dockerfile") || name.hasPrefix("containerfile") {
            self = .dockerfile
            return
        }
        if name == ".env" || name.hasPrefix(".env.") {
            self = .ini
            return
        }
        guard let dot = name.lastIndex(of: "."), dot != name.index(before: name.endIndex) else { return nil }
        let fileExtension = String(name[name.index(after: dot)...])
        guard let language = Self.extensions[fileExtension] ?? Self.aliases[fileExtension] else { return nil }
        self = language
    }

    /// A best effort for server previews that only carry a MIME type.
    init?(mimeType: String?) {
        guard let mimeType = mimeType?.lowercased() else { return nil }
        let subtype = mimeType.split(separator: "/").last.map(String.init) ?? mimeType
        let bare = subtype.split(separator: ";").first.map(String.init) ?? subtype
        switch bare {
        case "json", "ld+json", "geo+json": self = .json
        case "xml", "xhtml+xml", "svg+xml", "plist": self = .xml
        case "html": self = .html
        case "css": self = .css
        case "javascript", "x-javascript", "ecmascript": self = .javascript
        case "typescript", "x-typescript": self = .typescript
        case "yaml", "x-yaml": self = .yaml
        case "markdown", "x-markdown": self = .markdown
        case "x-sh", "x-shellscript": self = .shell
        case "x-python", "x-python-script": self = .python
        case "x-swift": self = .swift
        case "x-diff", "x-patch": self = .diff
        default: return nil
        }
    }

    var displayName: String {
        switch self {
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .css: "CSS"
        case .dart: "Dart"
        case .diff: "Diff"
        case .dockerfile: "Dockerfile"
        case .elixir: "Elixir"
        case .go: "Go"
        case .html: "HTML"
        case .ini: "INI"
        case .java: "Java"
        case .javascript: "JavaScript"
        case .json: "JSON"
        case .kotlin: "Kotlin"
        case .lua: "Lua"
        case .makefile: "Makefile"
        case .markdown: "Markdown"
        case .objectiveC: "Objective-C"
        case .php: "PHP"
        case .python: "Python"
        case .ruby: "Ruby"
        case .rust: "Rust"
        case .scala: "Scala"
        case .shell: "Shell"
        case .sql: "SQL"
        case .swift: "Swift"
        case .toml: "TOML"
        case .typescript: "TypeScript"
        case .xml: "XML"
        case .yaml: "YAML"
        case .zig: "Zig"
        }
    }

    private static let aliases: [String: BYOTSyntaxLanguage] = [
        "c": .c, "h": .c,
        "cpp": .cpp, "c++": .cpp, "cc": .cpp, "cxx": .cpp, "hpp": .cpp, "hh": .cpp, "hxx": .cpp, "ino": .cpp,
        "cs": .csharp, "csharp": .csharp, "c#": .csharp,
        "css": .css, "scss": .css, "sass": .css, "less": .css, "postcss": .css,
        "dart": .dart,
        "diff": .diff, "patch": .diff, "udiff": .diff,
        "dockerfile": .dockerfile, "docker": .dockerfile, "containerfile": .dockerfile,
        "elixir": .elixir, "ex": .elixir, "exs": .elixir, "heex": .elixir,
        "go": .go, "golang": .go,
        "html": .html, "htm": .html, "xhtml": .html, "vue": .html, "svelte": .html, "astro": .html,
        "ini": .ini, "cfg": .ini, "conf": .ini, "properties": .ini, "editorconfig": .ini, "env": .ini,
        "dotenv": .ini, "gitconfig": .ini,
        "java": .java,
        "js": .javascript, "javascript": .javascript, "jsx": .javascript, "mjs": .javascript,
        "cjs": .javascript, "node": .javascript,
        "json": .json, "jsonc": .json, "json5": .json, "jsonl": .json, "ndjson": .json, "geojson": .json,
        "kt": .kotlin, "kts": .kotlin, "kotlin": .kotlin, "gradle": .kotlin,
        "lua": .lua,
        "make": .makefile, "makefile": .makefile, "mk": .makefile,
        "md": .markdown, "markdown": .markdown, "mdx": .markdown,
        "objc": .objectiveC, "objective-c": .objectiveC, "objectivec": .objectiveC, "m": .objectiveC,
        "mm": .objectiveC, "objcpp": .objectiveC,
        "php": .php,
        "py": .python, "python": .python, "python3": .python, "py3": .python, "pyi": .python,
        "rb": .ruby, "ruby": .ruby, "rake": .ruby, "gemspec": .ruby, "podspec": .ruby,
        "rs": .rust, "rust": .rust,
        "scala": .scala, "sc": .scala, "sbt": .scala,
        "sh": .shell, "shell": .shell, "bash": .shell, "zsh": .shell, "ksh": .shell, "fish": .shell,
        "console": .shell, "shellsession": .shell, "terminal": .shell, "shell-session": .shell,
        "sql": .sql, "psql": .sql, "mysql": .sql, "sqlite": .sql, "pgsql": .sql, "postgres": .sql,
        "postgresql": .sql, "plsql": .sql,
        "swift": .swift,
        "toml": .toml,
        "ts": .typescript, "typescript": .typescript, "tsx": .typescript, "mts": .typescript,
        "cts": .typescript,
        "xml": .xml, "plist": .xml, "svg": .xml, "xsd": .xml, "xsl": .xml, "xslt": .xml,
        "storyboard": .xml, "xib": .xml, "csproj": .xml, "entitlements": .xml, "xcprivacy": .xml,
        "rss": .xml, "atom": .xml,
        "yaml": .yaml, "yml": .yaml,
        "zig": .zig, "zon": .zig,
    ]

    private static let extensions: [String: BYOTSyntaxLanguage] = [
        "command": .shell, "bats": .shell,
    ]

    private static let fileNames: [String: BYOTSyntaxLanguage] = [
        "makefile": .makefile, "gnumakefile": .makefile,
        "gemfile": .ruby, "rakefile": .ruby, "podfile": .ruby, "fastfile": .ruby, "appfile": .ruby,
        "brewfile": .ruby, "dangerfile": .ruby, "guardfile": .ruby,
        ".bashrc": .shell, ".zshrc": .shell, ".profile": .shell, ".bash_profile": .shell,
        ".zprofile": .shell, ".zshenv": .shell,
        ".editorconfig": .ini, ".gitconfig": .ini, ".npmrc": .ini,
        "cargo.lock": .toml, "package.resolved": .json, "pipfile": .toml,
    ]
}

// MARK: - Grammars

struct BYOTSyntaxDelimiter: Sendable {
    let open: [UInt8]
    let close: [UInt8]
    var escapes = true
    var multiline = false

    init(_ open: String, _ close: String? = nil, escapes: Bool = true, multiline: Bool = false) {
        self.open = Array(open.utf8)
        self.close = Array((close ?? open).utf8)
        self.escapes = escapes
        self.multiline = multiline
    }
}

/// Declarative description of a language for `BYOTSyntaxScanner`.
struct BYOTSyntaxGrammar: Sendable {
    enum Mode: Sendable { case code, markup, diff, markdown }

    /// How configuration-style keys are recognized and colored as properties.
    enum KeyStyle: Sendable {
        case none
        /// JSON: a string followed by `:`.
        case jsonStrings
        /// YAML and Makefile: the first word on a line followed by `: ` or `:⏎`.
        case lineStartColon
        /// TOML and INI: the first word on a line followed by `=` (and `[sections]`).
        case lineStartEquals
        /// CSS: a word inside a `{}` block followed by `:`.
        case blockColon
    }

    var mode: Mode = .code
    var keywords: Set<String> = []
    var types: Set<String> = []
    var constants: Set<String> = []
    var functions: Set<String> = []
    var functionDeclarators: Set<String> = []
    var typeDeclarators: Set<String> = []
    var lineComments: [[UInt8]] = []
    var blockComments: [BYOTSyntaxDelimiter] = []
    /// Ordered longest first so `"""` wins over `"`.
    var strings: [BYOTSyntaxDelimiter] = []
    var identifierStartExtras: Set<UInt8> = []
    var identifierExtras: Set<UInt8> = []
    /// A prefix byte that colors the word it starts: `@attribute`, `$variable`, `#directive`.
    var sigils: [UInt8: BYOTSyntaxTokenKind] = [:]
    var keys: KeyStyle = .none
    var capitalizedTypes = false
    var highlightsCalls = true
    var caseInsensitive = false
    var hashCommentsNeedBoundary = false
    var bracketAttributes = false
    var rustQuotes = false
    var macroBang = false
    var dollarParenVariables = false
    var shellSpecialVariables = false

    static func words(_ list: String) -> Set<String> {
        Set(list.split(whereSeparator: \.isWhitespace).map(String.init))
    }

    static func bytes(_ characters: String) -> Set<UInt8> { Set(characters.utf8) }
}

private extension BYOTSyntaxGrammar {
    static let slashComments: [[UInt8]] = [Array("//".utf8)]
    static let cBlockComment = [BYOTSyntaxDelimiter("/*", "*/")]
    static let hashComment: [[UInt8]] = [Array("#".utf8)]
    static let cStrings = [BYOTSyntaxDelimiter("\""), BYOTSyntaxDelimiter("'")]

    static let cKeywords = """
    auto break case char const continue default do double else enum extern float for goto if inline int long
    register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while
    _Bool _Atomic _Noreturn
    """
    static let cTypes = """
    bool size_t ssize_t ptrdiff_t intptr_t uintptr_t int8_t int16_t int32_t int64_t uint8_t uint16_t uint32_t
    uint64_t FILE wchar_t
    """
    static let cppKeywords = cKeywords + """
     alignas alignof and asm bitand bitor catch class compl concept consteval constexpr constinit const_cast
     co_await co_return co_yield decltype delete dynamic_cast explicit export friend mutable namespace new
     noexcept not operator or override final private protected public reinterpret_cast requires static_assert
     static_cast template this thread_local throw try typeid typename using virtual xor
    """
}

extension BYOTSyntaxLanguage {
    var grammar: BYOTSyntaxGrammar {
        switch self {
        case .swift: BYOTSyntaxGrammar.swift
        case .javascript: BYOTSyntaxGrammar.javascript
        case .typescript: BYOTSyntaxGrammar.typescript
        case .python: BYOTSyntaxGrammar.python
        case .go: BYOTSyntaxGrammar.go
        case .rust: BYOTSyntaxGrammar.rust
        case .c: BYOTSyntaxGrammar.c
        case .cpp: BYOTSyntaxGrammar.cpp
        case .objectiveC: BYOTSyntaxGrammar.objectiveC
        case .java: BYOTSyntaxGrammar.java
        case .kotlin: BYOTSyntaxGrammar.kotlin
        case .csharp: BYOTSyntaxGrammar.csharp
        case .scala: BYOTSyntaxGrammar.scala
        case .dart: BYOTSyntaxGrammar.dart
        case .ruby: BYOTSyntaxGrammar.ruby
        case .php: BYOTSyntaxGrammar.php
        case .elixir: BYOTSyntaxGrammar.elixir
        case .lua: BYOTSyntaxGrammar.lua
        case .zig: BYOTSyntaxGrammar.zig
        case .shell: BYOTSyntaxGrammar.shell
        case .dockerfile: BYOTSyntaxGrammar.dockerfile
        case .makefile: BYOTSyntaxGrammar.makefile
        case .sql: BYOTSyntaxGrammar.sql
        case .json: BYOTSyntaxGrammar.json
        case .yaml: BYOTSyntaxGrammar.yaml
        case .toml: BYOTSyntaxGrammar.toml
        case .ini: BYOTSyntaxGrammar.ini
        case .css: BYOTSyntaxGrammar.css
        case .html, .xml: BYOTSyntaxGrammar(mode: .markup)
        case .diff: BYOTSyntaxGrammar(mode: .diff)
        case .markdown: BYOTSyntaxGrammar(mode: .markdown)
        }
    }
}

extension BYOTSyntaxGrammar {
    static let swift = BYOTSyntaxGrammar(
        keywords: words("""
        actor any as associatedtype async await borrowing break case catch class consume consuming continue
        convenience default defer deinit didSet do dynamic else enum extension fallthrough fileprivate final for
        func get guard if import in indirect init inout internal is isolated lazy let macro mutating nonisolated
        nonmutating open operator optional override package precedencegroup private protocol public repeat
        required rethrows return self Self set some static struct subscript super switch throw throws try
        typealias unowned var weak where while willSet
        """),
        constants: words("true false nil"),
        functionDeclarators: words("func"),
        typeDeclarators: words("class struct enum protocol extension actor typealias associatedtype"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("\"\"\"", multiline: true), BYOTSyntaxDelimiter("\"")],
        sigils: [0x40: .attribute, 0x23: .preprocessor],
        capitalizedTypes: true
    )

    static let javascript = BYOTSyntaxGrammar(
        keywords: words("""
        as async await break case catch class const continue debugger default delete do else export extends
        finally for from function get if import in instanceof let new of return set static super switch this
        throw try typeof var void while with yield
        """),
        constants: words("true false null undefined NaN Infinity"),
        functionDeclarators: words("function"),
        typeDeclarators: words("class extends"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("\""), BYOTSyntaxDelimiter("'"), BYOTSyntaxDelimiter("`", multiline: true)],
        identifierStartExtras: bytes("$"),
        identifierExtras: bytes("$"),
        sigils: [0x40: .attribute],
        capitalizedTypes: true
    )

    static let typescript: BYOTSyntaxGrammar = {
        var grammar = javascript
        grammar.keywords.formUnion(words("""
        abstract accessor declare enum implements infer interface is keyof module namespace override private
        protected public readonly satisfies type unique
        """))
        grammar.types = words("any bigint boolean never number object string symbol unknown void")
        grammar.typeDeclarators.formUnion(words("interface type enum namespace implements"))
        return grammar
    }()

    static let python = BYOTSyntaxGrammar(
        keywords: words("""
        and as assert async await break case class continue def del elif else except finally for from global if
        import in is lambda match nonlocal not or pass raise return try while with yield
        """),
        types: words("bool bytes dict float frozenset int list object set str tuple type"),
        constants: words("True False None Ellipsis NotImplemented"),
        functionDeclarators: words("def"),
        typeDeclarators: words("class"),
        lineComments: hashComment,
        strings: [
            BYOTSyntaxDelimiter("\"\"\"", multiline: true), BYOTSyntaxDelimiter("'''", multiline: true),
            BYOTSyntaxDelimiter("\""), BYOTSyntaxDelimiter("'"),
        ],
        sigils: [0x40: .attribute],
        capitalizedTypes: true
    )

    static let go = BYOTSyntaxGrammar(
        keywords: words("""
        break case chan const continue default defer else fallthrough for func go goto if import interface map
        package range return select struct switch type var
        """),
        types: words("""
        any bool byte comparable complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune
        string uint uint8 uint16 uint32 uint64 uintptr
        """),
        constants: words("true false nil iota"),
        functionDeclarators: words("func"),
        typeDeclarators: words("type"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("\""), BYOTSyntaxDelimiter("'"), BYOTSyntaxDelimiter("`", escapes: false, multiline: true)]
    )

    static let rust = BYOTSyntaxGrammar(
        keywords: words("""
        as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move
        mut pub ref return self Self static struct super trait type union unsafe use where while macro_rules
        """),
        types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str"),
        constants: words("true false"),
        functionDeclarators: words("fn"),
        typeDeclarators: words("struct enum trait type union"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("\"", multiline: true)],
        sigils: [0x23: .attribute],
        capitalizedTypes: true,
        bracketAttributes: true,
        rustQuotes: true,
        macroBang: true
    )

    static let c = BYOTSyntaxGrammar(
        keywords: words(cKeywords),
        types: words(cTypes),
        constants: words("NULL true false"),
        typeDeclarators: words("struct enum union"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: cStrings,
        sigils: [0x23: .preprocessor]
    )

    static let cpp: BYOTSyntaxGrammar = {
        var grammar = c
        grammar.keywords = words(cppKeywords)
        grammar.constants = words("nullptr NULL true false")
        grammar.types.formUnion(words("std string vector map unordered_map set shared_ptr unique_ptr optional"))
        grammar.typeDeclarators = words("class struct enum union namespace")
        grammar.capitalizedTypes = true
        return grammar
    }()

    static let objectiveC: BYOTSyntaxGrammar = {
        var grammar = c
        grammar.keywords.formUnion(words("self super id instancetype nonatomic atomic strong weak copy assign readonly readwrite nullable nonnull"))
        grammar.constants = words("nil Nil NULL YES NO true false")
        grammar.types.formUnion(words("BOOL SEL IMP Class NSInteger NSUInteger CGFloat"))
        grammar.sigils[0x40] = .keyword
        grammar.capitalizedTypes = true
        return grammar
    }()

    static let java = BYOTSyntaxGrammar(
        keywords: words("""
        abstract assert boolean break byte case catch char class const continue default do double else enum
        extends final finally float for goto if implements import instanceof int interface long native new
        non-sealed package permits private protected public record return sealed short static strictfp super
        switch synchronized this throw throws transient try var void volatile while yield
        """),
        constants: words("true false null"),
        typeDeclarators: words("class interface enum record extends implements"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("\"\"\"", multiline: true)] + cStrings,
        sigils: [0x40: .attribute],
        capitalizedTypes: true
    )

    static let kotlin = BYOTSyntaxGrammar(
        keywords: words("""
        abstract actual annotation as break by catch class companion const constructor continue crossinline data
        do else enum expect external final finally for fun get if import in infix init inline inner interface
        internal is lateinit noinline object open operator out override package private protected public reified
        return sealed set super suspend tailrec this throw try typealias val value var vararg when where while
        """),
        constants: words("true false null"),
        functionDeclarators: words("fun"),
        typeDeclarators: words("class interface object typealias"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("\"\"\"", multiline: true)] + cStrings,
        sigils: [0x40: .attribute],
        capitalizedTypes: true
    )

    static let csharp = BYOTSyntaxGrammar(
        keywords: words("""
        abstract as async await base bool break byte case catch char checked class const continue decimal default
        delegate do double dynamic else enum event explicit extern finally fixed float for foreach get goto if
        implicit in init int interface internal is lock long namespace nameof new object operator out override
        params private protected public readonly record ref return sbyte sealed set short sizeof stackalloc static
        string struct switch this throw try typeof uint ulong unchecked unsafe ushort using value var virtual void
        volatile when where while yield
        """),
        constants: words("true false null"),
        typeDeclarators: words("class struct interface enum record namespace"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("\"\"\"", multiline: true)] + cStrings,
        sigils: [0x23: .preprocessor],
        capitalizedTypes: true
    )

    static let scala = BYOTSyntaxGrammar(
        keywords: words("""
        abstract case catch class def do else enum export extends extension final finally for given if implicit
        import lazy match new object override package private protected return sealed super then this throw trait
        try type using val var while with yield
        """),
        constants: words("true false null"),
        functionDeclarators: words("def"),
        typeDeclarators: words("class trait object enum type"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("\"\"\"", multiline: true)] + cStrings,
        sigils: [0x40: .attribute],
        capitalizedTypes: true
    )

    static let dart = BYOTSyntaxGrammar(
        keywords: words("""
        abstract as assert async await base break case catch class const continue covariant default deferred do
        dynamic else enum export extends extension external factory final finally for get hide if implements
        import in interface is late library mixin new on operator part required rethrow return sealed set show
        static super switch sync this throw try typedef var void when while with yield
        """),
        constants: words("true false null"),
        typeDeclarators: words("class mixin enum extension typedef"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("'''", multiline: true), BYOTSyntaxDelimiter("\"\"\"", multiline: true)] + cStrings,
        sigils: [0x40: .attribute],
        capitalizedTypes: true
    )

    static let ruby = BYOTSyntaxGrammar(
        keywords: words("""
        alias and begin break case class def defined? do else elsif end ensure extend for if in include module
        next not or private protected public raise redo require require_relative rescue retry return self super
        then undef unless until when while yield attr_accessor attr_reader attr_writer
        """),
        constants: words("true false nil"),
        functions: words("puts print p lambda proc"),
        functionDeclarators: words("def"),
        typeDeclarators: words("class module"),
        lineComments: hashComment,
        strings: cStrings + [BYOTSyntaxDelimiter("`")],
        identifierExtras: bytes("?!"),
        sigils: [0x40: .variable, 0x24: .variable, 0x3A: .constant],
        capitalizedTypes: true
    )

    static let php = BYOTSyntaxGrammar(
        keywords: words("""
        abstract and array as break callable case catch class clone const continue declare default do echo else
        elseif empty enum extends final finally fn for foreach function global goto if implements include
        include_once instanceof insteadof interface isset list match namespace new or print private protected
        public readonly require require_once return static switch throw trait try unset use var while xor yield
        """),
        constants: words("true false null TRUE FALSE NULL"),
        functionDeclarators: words("function fn"),
        typeDeclarators: words("class interface trait enum extends implements"),
        lineComments: slashComments + hashComment,
        blockComments: cBlockComment,
        strings: cStrings,
        sigils: [0x24: .variable],
        capitalizedTypes: true
    )

    static let elixir = BYOTSyntaxGrammar(
        keywords: words("""
        after alias and case catch cond def defdelegate defexception defguard defimpl defmacro defmacrop
        defmodule defp defprotocol defstruct do else end fn for if import in not or quote raise receive require
        rescue try unless unquote use when with
        """),
        constants: words("true false nil"),
        functionDeclarators: words("def defp defmacro defmacrop defguard"),
        typeDeclarators: words("defmodule defprotocol defimpl"),
        lineComments: hashComment,
        strings: [BYOTSyntaxDelimiter("\"\"\"", multiline: true), BYOTSyntaxDelimiter("\""), BYOTSyntaxDelimiter("'")],
        identifierExtras: bytes("?!"),
        sigils: [0x40: .attribute, 0x3A: .constant],
        capitalizedTypes: true
    )

    static let lua = BYOTSyntaxGrammar(
        keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
        constants: words("true false nil"),
        functionDeclarators: words("function"),
        lineComments: [Array("--".utf8)],
        blockComments: [BYOTSyntaxDelimiter("--[[", "]]")],
        strings: cStrings + [BYOTSyntaxDelimiter("[[", "]]", escapes: false, multiline: true)]
    )

    static let zig = BYOTSyntaxGrammar(
        keywords: words("""
        addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const
        continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline
        nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union
        unreachable usingnamespace var volatile while
        """),
        types: words("""
        i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f16 f32 f64 f128 bool void anyerror anyopaque type
        comptime_int comptime_float noreturn
        """),
        constants: words("true false null undefined"),
        functionDeclarators: words("fn"),
        lineComments: slashComments,
        strings: cStrings,
        sigils: [0x40: .function],
        capitalizedTypes: true
    )

    static let shell = BYOTSyntaxGrammar(
        keywords: words("""
        if then else elif fi case esac for select while until do done in function time coproc return exit break
        continue local export readonly declare typeset unset source alias set shift trap eval exec
        """),
        constants: words("true false"),
        functions: words("echo printf cd pwd read test sudo"),
        functionDeclarators: words("function"),
        lineComments: hashComment,
        strings: [
            BYOTSyntaxDelimiter("\"", multiline: true),
            BYOTSyntaxDelimiter("'", escapes: false, multiline: true),
            BYOTSyntaxDelimiter("`", multiline: true),
        ],
        sigils: [0x24: .variable],
        highlightsCalls: false,
        hashCommentsNeedBoundary: true,
        shellSpecialVariables: true
    )

    static let dockerfile: BYOTSyntaxGrammar = {
        var grammar = shell
        grammar.keywords.formUnion(words("""
        FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK
        SHELL AS MAINTAINER
        """))
        return grammar
    }()

    static let makefile = BYOTSyntaxGrammar(
        keywords: words("ifeq ifneq ifdef ifndef else endif include define endef export override unexport vpath"),
        lineComments: hashComment,
        strings: cStrings,
        identifierStartExtras: bytes("."),
        identifierExtras: bytes("-./"),
        sigils: [0x24: .variable],
        keys: .lineStartColon,
        highlightsCalls: false,
        dollarParenVariables: true,
        shellSpecialVariables: true
    )

    static let sql = BYOTSyntaxGrammar(
        keywords: words("""
        add all alter and as asc begin between by cascade case check column commit constraint create cross
        database default delete desc distinct drop else end except exists explain foreign from full grant group
        having if in index inner insert intersect into is join key left like limit not null offset on or order
        outer over partition primary references replace returning revoke right rollback select set table then
        to transaction trigger truncate union unique update using values view when where window with recursive
        """),
        types: words("""
        bigint blob boolean bool char date datetime decimal double float int integer interval json jsonb numeric
        real serial smallint text time timestamp timestamptz uuid varchar
        """),
        constants: words("true false null"),
        lineComments: [Array("--".utf8)],
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("'", escapes: false), BYOTSyntaxDelimiter("\"", escapes: false)],
        caseInsensitive: true
    )

    static let json = BYOTSyntaxGrammar(
        constants: words("true false null"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: [BYOTSyntaxDelimiter("\"")],
        keys: .jsonStrings,
        highlightsCalls: false
    )

    static let yaml = BYOTSyntaxGrammar(
        constants: words("true false null yes no on off True False Null Yes No TRUE FALSE NULL"),
        lineComments: hashComment,
        strings: [BYOTSyntaxDelimiter("\""), BYOTSyntaxDelimiter("'", escapes: false)],
        identifierExtras: bytes("-./"),
        sigils: [0x26: .variable, 0x2A: .variable, 0x21: .type],
        keys: .lineStartColon,
        highlightsCalls: false,
        hashCommentsNeedBoundary: true
    )

    static let toml = BYOTSyntaxGrammar(
        constants: words("true false inf nan"),
        lineComments: hashComment,
        strings: [
            BYOTSyntaxDelimiter("\"\"\"", multiline: true), BYOTSyntaxDelimiter("'''", escapes: false, multiline: true),
            BYOTSyntaxDelimiter("\""), BYOTSyntaxDelimiter("'", escapes: false),
        ],
        identifierExtras: bytes("-."),
        keys: .lineStartEquals,
        highlightsCalls: false
    )

    static let ini = BYOTSyntaxGrammar(
        constants: words("true false yes no on off"),
        lineComments: hashComment + [Array(";".utf8)],
        strings: [BYOTSyntaxDelimiter("\""), BYOTSyntaxDelimiter("'", escapes: false)],
        identifierExtras: bytes("-."),
        sigils: [0x24: .variable],
        keys: .lineStartEquals,
        highlightsCalls: false,
        hashCommentsNeedBoundary: true
    )

    static let css = BYOTSyntaxGrammar(
        constants: words("inherit initial unset none auto transparent currentColor"),
        lineComments: slashComments,
        blockComments: cBlockComment,
        strings: cStrings,
        identifierStartExtras: bytes("-"),
        identifierExtras: bytes("-"),
        sigils: [0x40: .keyword, 0x24: .variable, 0x23: .constant, 0x21: .keyword],
        keys: .blockColon
    )
}
