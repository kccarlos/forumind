import XCTest
@testable import Forumind

/// Checks the String Catalogs in the source tree (the built app only has the
/// compiled .strings files): every string is translated into Simplified and
/// Traditional Chinese, format specifiers agree, and counts have plural
/// variations. `scripts/i18n/check-catalogs.py` reports the same problems
/// from the command line; see docs/DEVELOPMENT.md#localization.
final class LocalizationCatalogTests: XCTestCase {
    private static let languages = ["zh-Hans", "zh-Hant"]
    private static let catalogPaths = [
        "Forumind/Localizable.xcstrings",
        "Forumind/InfoPlist.xcstrings",
        "ForumindShare/Localizable.xcstrings",
        "ForumindShare/InfoPlist.xcstrings"
    ]

    /// The repository root, from this file's compile-time path.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private struct Catalog {
        var path: String
        var strings: [String: [String: Any]]
    }

    private func catalogs() throws -> [Catalog] {
        try Self.catalogPaths.map { path in
            let url = Self.repositoryRoot.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("Source catalogs aren't reachable from this test run (\(path)).")
            }
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            XCTAssertEqual(json?["sourceLanguage"] as? String, "en", path)
            return Catalog(path: path, strings: json?["strings"] as? [String: [String: Any]] ?? [:])
        }
    }

    /// Every string unit of a localization: the plain one, or each plural /
    /// device case.
    private func units(_ localization: Any?) -> [[String: Any]] {
        guard let localization = localization as? [String: Any] else { return [] }
        var result: [[String: Any]] = []
        if let unit = localization["stringUnit"] as? [String: Any] { result.append(unit) }
        for variation in (localization["variations"] as? [String: [String: Any]] ?? [:]).values {
            for variationCase in variation.values { result += units(variationCase) }
        }
        return result
    }

    private func pluralCases(_ localization: Any?) -> Set<String>? {
        guard let variations = (localization as? [String: Any])?["variations"] as? [String: Any],
              let plural = variations["plural"] as? [String: Any] else { return nil }
        return Set(plural.keys)
    }

    /// Format specifiers without positional indices, sorted: "%1$@ · %2$lld"
    /// → ["%@", "%lld"]. Translations may reorder arguments.
    static func specifiers(_ text: String) -> [String] {
        let pattern = #"%(?:\d+\$)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSaAp]"#
        let cleaned = text.replacingOccurrences(of: "%%", with: "")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        return regex.matches(in: cleaned, range: range).compactMap { match in
            Range(match.range, in: cleaned).map {
                String(cleaned[$0]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
            }
        }.sorted()
    }

    private func translatableEntries(_ catalog: Catalog) -> [(String, [String: Any])] {
        catalog.strings.filter { $0.value["shouldTranslate"] as? Bool != false }.sorted { $0.key < $1.key }
    }

    // MARK: (a) Complete

    func testEveryStringIsTranslatedIntoBothChineseScripts() throws {
        for catalog in try catalogs() {
            XCTAssertFalse(catalog.strings.isEmpty, "\(catalog.path) is empty")
            for (key, entry) in catalog.strings {
                let state = entry["extractionState"] as? String
                XCTAssertNotEqual(state, "stale", "\(catalog.path): \(key.debugDescription) is no longer in the code; run scripts/i18n/sync-catalogs.sh")
            }
            for (key, entry) in translatableEntries(catalog) {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                for language in Self.languages {
                    let found = units(localizations[language])
                    XCTAssertFalse(found.isEmpty, "\(catalog.path): \(key.debugDescription) has no \(language) translation")
                    for unit in found {
                        XCTAssertEqual(unit["state"] as? String, "translated",
                                       "\(catalog.path): \(key.debugDescription) [\(language)] isn't marked translated")
                        XCTAssertFalse((unit["value"] as? String ?? "").isEmpty,
                                       "\(catalog.path): \(key.debugDescription) [\(language)] is empty")
                    }
                }
            }
        }
    }

    // MARK: (b) Format specifiers

    func testFormatSpecifiersMatchEnglish() throws {
        for catalog in try catalogs() {
            for (key, entry) in translatableEntries(catalog) {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                let englishValues = units(localizations["en"]).compactMap { $0["value"] as? String }
                let expected = Self.specifiers(englishValues.last ?? key)
                // A key with its own English value may be an identifier
                // ("forumPill.prefixAndName"); otherwise the value keeps the
                // key's specifiers.
                if englishValues.isEmpty || key.contains("%") {
                    XCTAssertEqual(Self.specifiers(key), expected,
                                   "\(catalog.path): English value of \(key.debugDescription) changes its specifiers")
                }
                for language in Self.languages {
                    for unit in units(localizations[language]) {
                        let value = unit["value"] as? String ?? ""
                        XCTAssertEqual(Self.specifiers(value), expected,
                                       "\(catalog.path): \(key.debugDescription) [\(language)] = \(value.debugDescription)")
                    }
                }
            }
        }
    }

    // MARK: (c) Plurals

    /// Keys whose count governs an English noun ("%lld posts", "Read %lld
    /// posts", "%lld new replies in a watched topic.").
    private static let countedNoun = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?lld (?:new |newer |chat |saved |synced |pinned |middle )?(?:posts|topics|steps|forums|messages|sources|items|replies|models|lines|points)\b"#
    )

    func testCountsHavePluralVariations() throws {
        var checked = 0
        for catalog in try catalogs() {
            for (key, entry) in translatableEntries(catalog) {
                let localizations = entry["localizations"] as? [String: Any] ?? [:]
                let englishPlural = pluralCases(localizations["en"])
                let range = NSRange(key.startIndex..., in: key)
                if Self.countedNoun.firstMatch(in: key, range: range) != nil {
                    checked += 1
                    XCTAssertEqual(englishPlural, ["one", "other"],
                                   "\(catalog.path): \(key.debugDescription) needs English one/other plural variations")
                }
                guard englishPlural != nil else { continue }
                for language in Self.languages {
                    // Chinese has a single plural category: "other" (or a
                    // plain string).
                    let cases = pluralCases(localizations[language])
                    XCTAssertTrue(cases == nil ? !units(localizations[language]).isEmpty : cases!.contains("other"),
                                  "\(catalog.path): \(key.debugDescription) [\(language)] lacks the plural \"other\" case")
                }
            }
        }
        XCTAssertGreaterThan(checked, 10, "expected the count keys to be found")
    }

    func testTheBuiltAppHasBothChineseLocalizations() {
        let localizations = Set(Bundle.main.localizations)
        XCTAssertTrue(localizations.isSuperset(of: ["en", "zh-Hans", "zh-Hant"]), "\(localizations)")
        XCTAssertEqual(Bundle.main.developmentLocalization, "en")
    }

    func testEnglishPluralsResolveThroughTheCatalog() throws {
        guard AppLanguage.current == "en" else { throw XCTSkip("The test host isn't running in English.") }
        XCTAssertEqual(String(localized: "\(1) posts"), "1 post")
        XCTAssertEqual(String(localized: "\(3) posts"), "3 posts")
        XCTAssertEqual(String(localized: "Read \(1) posts"), "Read 1 post")
    }

    func testChineseTranslationsResolveFromTheBundle() throws {
        for (language, expected) in [("zh-Hans", "论坛"), ("zh-Hant", "論壇")] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Forums", value: nil, table: nil), expected)
        }
    }

    // MARK: AI answer language

    func testAnswersFollowTheAppLanguage() {
        // English: unchanged behavior (summaries follow the discussion,
        // chat follows the question).
        XCTAssertTrue(PromptBuilder.summarySystem(custom: "", appLanguage: "en").contains("same language as the discussion"))
        XCTAssertTrue(PromptBuilder.chatSystem(custom: "", source: "s", summary: "", appLanguage: "en")
            .contains("same language as the user's question"))
        // Chinese app: answers default to the app's language; prompts stay English.
        let hans = PromptBuilder.summarySystem(custom: "", appLanguage: "zh-Hans")
        XCTAssertTrue(hans.contains("Respond in Simplified Chinese"))
        XCTAssertTrue(hans.contains("Discourse forum discussion"))
        XCTAssertTrue(PromptBuilder.chatSystem(custom: "", source: "s", summary: "", appLanguage: "zh-Hant")
            .contains("Respond in Traditional Chinese"))
        XCTAssertTrue(PromptBuilder.questionLanguageInstruction(appLanguage: "zh-Hant")
            .contains("unless the user writes in another language"))
    }
}
