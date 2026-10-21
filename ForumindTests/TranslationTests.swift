import XCTest
@testable import Forumind

/// Translation (C3): the reading language setting, when the Translate
/// button shows (NaturalLanguage detects the text's language; same
/// language or iOS 17 means no button), and how Markdown is split so a
/// translation keeps its headings, lists, tables and code. The Translation
/// framework itself needs a device, so it isn't called here.
final class TranslationTests: XCTestCase {
    private let english = "The printer kept shifting layers until the belts were tightened and the stepper current was raised a little."
    private let simplified = "打印机一直出现层偏移，直到把皮带拉紧并把步进电机的电流稍微调高之后才解决。"
    private let traditional = "印表機一直出現層偏移，直到把皮帶拉緊並把步進馬達的電流稍微調高之後才解決。"
    private let japanese = "ベルトを締めてステッピングモーターの電流を少し上げるまで、プリンターは層ずれを起こし続けました。"

    func testTheReadingLanguageDefaultsToTheAppLanguage() {
        XCTAssertEqual(ReadingLanguage.resolved("", appLanguage: "zh-Hant"), "zh-Hant")
        XCTAssertEqual(ReadingLanguage.resolved("  ", appLanguage: "en"), "en")
        XCTAssertEqual(ReadingLanguage.resolved("ja", appLanguage: "en"), "ja")
        XCTAssertEqual(AppSettings().readingLanguage, "")
        XCTAssertTrue(ReadingLanguage.choices.contains("zh-Hans"))
        XCTAssertEqual(ReadingLanguage.displayName("ja", interfaceLanguage: "en"), "Japanese")
    }

    func testLanguagesCompareByLanguageAndScript() {
        XCTAssertTrue(ReadingLanguage.sameLanguage("en", "en-GB"))
        XCTAssertTrue(ReadingLanguage.sameLanguage("pt", "pt-BR"))
        XCTAssertTrue(ReadingLanguage.sameLanguage("zh-Hant", "zh-TW"))
        XCTAssertFalse(ReadingLanguage.sameLanguage("zh-Hans", "zh-Hant"))
        XCTAssertFalse(ReadingLanguage.sameLanguage("en", "ja"))
    }

    func testTheSourceLanguageIsDetected() {
        XCTAssertEqual(ReadingLanguage.detect(english), "en")
        XCTAssertEqual(ReadingLanguage.detect(simplified), "zh-Hans")
        XCTAssertEqual(ReadingLanguage.detect(traditional), "zh-Hant")
        XCTAssertEqual(ReadingLanguage.detect(japanese), "ja")
        XCTAssertNil(ReadingLanguage.detect("12345 !!"))
    }

    func testTheButtonShowsOnlyForAnotherLanguageOnIOS18() {
        XCTAssertFalse(ReadingLanguage.offersTranslation(of: english, into: "en", isAvailable: true), "already in the reading language")
        XCTAssertFalse(ReadingLanguage.offersTranslation(of: english, into: "en-GB", isAvailable: true))
        XCTAssertTrue(ReadingLanguage.offersTranslation(of: english, into: "zh-Hans", isAvailable: true))
        XCTAssertTrue(ReadingLanguage.offersTranslation(of: simplified, into: "zh-Hant", isAvailable: true), "another script is another language")
        XCTAssertFalse(ReadingLanguage.offersTranslation(of: traditional, into: "zh-Hant", isAvailable: true))
        XCTAssertTrue(ReadingLanguage.offersTranslation(of: japanese, into: "en", isAvailable: true))
        XCTAssertFalse(ReadingLanguage.offersTranslation(of: japanese, into: "en", isAvailable: false), "iOS 17: no button")
        XCTAssertFalse(ReadingLanguage.offersTranslation(of: "", into: "en", isAvailable: true), "nothing to translate")
        XCTAssertTrue(ReadingLanguage.offersTranslation(of: "ok", into: "zh-Hans", isAvailable: true), "unsure: the system detects it")
        if #available(iOS 18, *) {
            XCTAssertTrue(ReadingLanguage.isTranslationAvailable)
        } else {
            XCTAssertFalse(ReadingLanguage.isTranslationAvailable)
        }
    }

    func testPostsAlreadyInTheReadingLanguageAreLeftOut() {
        let posts = [
            TranslationSource(id: "1", heading: "#1", text: english),
            TranslationSource(id: "2", heading: "#2", text: japanese),
            TranslationSource(id: "3", heading: "#3", text: simplified)
        ]
        XCTAssertEqual(ReadingLanguage.needingTranslation(posts, into: "en").map(\.id), ["2", "3"])
        XCTAssertEqual(ReadingLanguage.needingTranslation(Array(posts.prefix(1)), into: "en"), [], "all in English: nothing to translate")
        XCTAssertEqual(ReadingLanguage.needingTranslation(posts, into: "ko").map(\.id), ["1", "2", "3"])
    }

    func testMarkdownKeepsItsMarkersAndCode() {
        let markdown = """
        ## Gist
        - The **fix** is tightening belts.
        1. Check current
        > A quote here

        ```
        stepper_x: 40
        ```
        ---
        | Part | Value |
        |---|---|
        | Belt | 40 |
        """
        let segments = TranslationText.segments(of: markdown)
        let requests = TranslationText.requests(segments).map(\.text)
        XCTAssertEqual(requests, ["Gist", "The **fix** is tightening belts.", "Check current", "A quote here", "Part", "Value", "Belt"])

        let translated = Dictionary(uniqueKeysWithValues: TranslationText.requests(segments).map { ($0.index, "<\($0.text)>") })
        XCTAssertEqual(TranslationText.assemble(segments, translations: translated), """
        ## <Gist>
        - <The **fix** is tightening belts.>
        1. <Check current>
        > <A quote here>

        ```
        stepper_x: 40
        ```
        ---
        | <Part> | <Value> |
        |---|---|
        | <Belt> | 40 |
        """)
        XCTAssertEqual(TranslationText.assemble(segments, translations: [:]), markdown, "untranslated pieces come back as they were")
    }
}
