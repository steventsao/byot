import Foundation
import Testing
@testable import byot

@Suite("Localization (#97)")
struct BYOTLocalizationTests {
    private static let chinese = "zh-Hans"

    private static func table(_ name: String, localization: String = chinese) -> [String: String] {
        guard let url = Bundle.main.url(forResource: name, withExtension: "strings", subdirectory: nil,
                                        localization: localization),
              let table = NSDictionary(contentsOf: url) as? [String: String]
        else { return [:] }
        return table
    }

    /// Format specifiers by argument position, so a translation may reorder
    /// them but never drop, add or retype one.
    private static func arguments(_ format: String) -> [Int: String] {
        let pattern = /%(?:(\d+)\$)?(lld|ld|d|@|lf|f|%)/
        var result: [Int: String] = [:]
        var next = 0
        for match in format.matches(of: pattern) where match.output.2 != "%" {
            let position = match.output.1.flatMap { Int($0) } ?? { next += 1; return next }()
            result[position] = String(match.output.2)
        }
        return result
    }

    @Test("The app ships Simplified Chinese next to English")
    func shipsChinese() {
        #expect(Bundle.main.developmentLocalization == "en")
        #expect(Bundle.main.localizations.contains(Self.chinese))
        let strings = Self.table("Localizable")
        #expect(strings["Cancel"] == "取消")
        #expect(strings["New session"] == "新会话")
        #expect(Self.table("InfoPlist")["NSCameraUsageDescription"]?.contains("相机") == true)
    }

    @Test("Every Chinese string keeps the placeholders of its English source")
    func placeholdersMatch() {
        let strings = Self.table("Localizable")
        #expect(strings.count > 1_000)
        for (key, value) in strings {
            #expect(Self.arguments(key) == Self.arguments(value), "\(key) → \(value)")
            #expect(!value.isEmpty, "\(key)")
        }
    }

    @Test("Counts and names land in the Chinese sentence, reordered where Chinese needs it")
    func formatsChinese() throws {
        let strings = Self.table("Localizable")
        let sessions = try #require(strings["%lld sessions"])
        #expect(String(format: sessions, 3) == "3 个会话")
        let runsIn = try #require(strings["Runs in %@ on %@"])
        #expect(String(format: runsIn, "web", "Studio") == "在 Studio 上的 web 中运行")
    }

    @Test("Siri phrases are translated and keep the app name")
    func siriPhrases() {
        let phrases = Self.table("AppShortcuts")
        #expect(phrases.count >= 10)
        for phrase in phrases.values {
            #expect(phrase.contains("${applicationName}"), "\(phrase)")
        }
    }
}
