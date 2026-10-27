import JavaScriptCore
import UniformTypeIdentifiers
import XCTest
@testable import Forumind

/// The share extension's detection: the shipped Safari preprocessing script
/// and the loader that classifies what it reports.
final class SharedPageTests: XCTestCase {
    private let topic = URL(string: "https://forum.example.com/t/a-topic/42/3")!

    // MARK: The shipped script

    private func shippedScript() throws -> String {
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL).appendingPathComponent("ForumindShare.appex")
        return try String(contentsOf: appex.appendingPathComponent("PageFactsProbe.js"), encoding: .utf8)
    }

    func testTheShippedScriptIsTheAppProbeForTheDeclaredKeys() throws {
        let script = try shippedScript()
        let expression = PageFactsProbe.expression(keys: SiteRecognizers.factKeys)
        XCTAssertTrue(
            script.contains(expression),
            "ForumindShare/PageFactsProbe.js is out of date: run scripts/generate-share-probe.sh"
        )
    }

    func testBothScriptsCoverEveryDeclaredKey() throws {
        let keys = SiteRecognizers.factKeys
        XCTAssertFalse(keys.meta.isEmpty)
        let appProbe = SiteRegistry.standard.probeExpression
        for script in [appProbe, try shippedScript()] {
            for key in keys.meta + keys.links + keys.selectors { XCTAssertTrue(script.contains(key), key) }
            for (id, entries) in keys.elements {
                XCTAssertTrue(script.contains(id), id)
                for entry in entries { XCTAssertTrue(script.contains(entry), entry) }
            }
        }
    }

    func testTheRegistryIsDerivedFromTheExtensionsListSoEveryKindHasAnAdapter() {
        // One list of platforms (SiteRecognizers.standard); the registry pairs each kind with its adapter.
        let kinds = SiteRecognizers.standard.map(\.kind)
        XCTAssertEqual(kinds, SiteRegistry.standard.adapters.map(\.kind))
        XCTAssertEqual(Set(SiteRegistry.adapterFactories.keys), Set(kinds), "a factory without a recognizer, or the reverse")
        for adapter in SiteRegistry.standard.adapters {
            XCTAssertEqual(adapter.recognizer.kind, adapter.kind)
        }
        XCTAssertEqual(SiteRecognizers.factKeys, SiteRegistry.standard.factKeys)
    }

    func testThePageTitleFallsBackToOGTitle() async throws {
        XCTAssertTrue(SiteRecognizers.factKeys.meta.contains("og:title"))
        XCTAssertTrue(SiteRegistry.standard.probeExpression.contains("og:title"))
        XCTAssertTrue(try shippedScript().contains("og:title"))
        let results: [String: Any] = [
            "url": "https://example.com/blog",
            "title": "",
            "meta": ["og:title": "  Shared   headline "]
        ]
        let loaded = await load([probeItem(results)])
        let page = try XCTUnwrap(loaded)
        XCTAssertEqual(page.title, "Shared headline")
        XCTAssertEqual(page.displayTitle, "Shared headline")
        // The document title wins when there is one.
        let titled = try XCTUnwrap(SharedPageLoader.page(fromProbeResults: [
            "url": "https://example.com/blog", "title": "Blog", "meta": ["og:title": "Other"]
        ]))
        XCTAssertEqual(titled.title, "Blog")
        // Neither: the host shows.
        let bare = try XCTUnwrap(SharedPageLoader.page(fromProbeResults: ["url": "https://example.com/blog"]))
        XCTAssertEqual(bare.displayTitle, "example.com")
    }

    func testTheInfoPlistNamesTheShippedScript() throws {
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL).appendingPathComponent("ForumindShare.appex")
        let info = try XCTUnwrap(Bundle(url: appex)?.infoDictionary)
        let extensionInfo = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        let attributes = try XCTUnwrap(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        let name = try XCTUnwrap(attributes["NSExtensionJavaScriptPreprocessingFile"] as? String)
        XCTAssertTrue(FileManager.default.fileExists(atPath: appex.appendingPathComponent("\(name).js").path))
    }

    func testTheShippedScriptRunsAndReportsAPropertyList() throws {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, exception in XCTFail("script error: \(String(describing: exception))") }
        context.evaluateScript("""
        var window = { location: { href: "https://forum.example.com/t/a-topic/42" } };
        var document = {
          title: "A topic",
          documentElement: { className: "desktop-view" },
          body: { className: "" },
          querySelector: function (selector) {
            if (selector.indexOf('"generator"') >= 0) return { getAttribute: function () { return "Discourse 3.4" } };
            return null;
          },
          getElementById: function () { return null; }
        };
        var captured = null;
        """)
        context.evaluateScript(try shippedScript())
        context.evaluateScript("ExtensionPreprocessingJS.run({ completionFunction: function (r) { captured = r; } });")
        let reported = try XCTUnwrap(context.objectForKeyedSubscript("captured")?.toDictionary() as? [String: Any])
        let data = try PropertyListSerialization.data(fromPropertyList: reported, format: .binary, options: 0)
        let results = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let page = try XCTUnwrap(SharedPageLoader.page(fromProbeResults: results))
        XCTAssertEqual(page.url.absoluteString, "https://forum.example.com/t/a-topic/42")
        XCTAssertEqual(page.title, "A topic")
        guard case .site(let match) = page.detection else { return XCTFail("not detected: \(page.detection)") }
        XCTAssertEqual(match.siteURL, "https://forum.example.com")
    }

    // MARK: A property list with dropped nulls

    func testAResultWithOnlyAURLReadsAsAPlainPage() throws {
        // Safari drops null and undefined, so every other key may be missing.
        let page = try XCTUnwrap(SharedPageLoader.page(fromProbeResults: ["url": "https://example.com/post"]))
        XCTAssertEqual(page.detection, .notDetected)
        XCTAssertNil(page.title)
        XCTAssertNil(SharedPageLoader.page(fromProbeResults: ["title": "No url"]))
        XCTAssertNil(SharedPageLoader.page(fromProbeResults: ["url": "ftp://example.com/file"]))
    }

    func testFactsMissingKeysReadAsEmpty() {
        let facts = PageFacts(probe: ["url": "https://example.com/", "meta": ["generator": "Discourse 3"]], fallbackURL: topic)
        XCTAssertEqual(facts.meta, ["generator": "Discourse 3"])
        XCTAssertTrue(facts.links.isEmpty)
        XCTAssertTrue(facts.elements.isEmpty)
        XCTAssertTrue(facts.matches.isEmpty)
        XCTAssertEqual(facts.htmlClass, "")
        XCTAssertEqual(facts.bodyClass, "")
        XCTAssertNil(facts.iconURL)
        XCTAssertEqual(PageFacts(probe: [:], fallbackURL: topic).url, topic)
    }

    // MARK: The loader

    private func load(_ items: [NSExtensionItem]) async -> SharedPage? {
        await withCheckedContinuation { continuation in
            SharedPageLoader.load(from: items) { continuation.resume(returning: $0) }
        }
    }

    private func item(_ object: NSSecureCoding, type: UTType, title: String? = nil) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = [NSItemProvider(item: object, typeIdentifier: type.identifier)]
        if let title { item.attributedTitle = NSAttributedString(string: title) }
        return item
    }

    private func probeItem(_ results: [String: Any]) -> NSExtensionItem {
        let dictionary = [NSExtensionJavaScriptPreprocessingResultsKey: results] as NSDictionary
        return item(dictionary, type: .propertyList)
    }

    func testADiscourseFactsDictionaryIsASite() async throws {
        let results: [String: Any] = [
            "url": topic.absoluteString,
            "title": "  A   topic ",
            "meta": ["generator": "Discourse 3.4.0", "og:site_name": "Example Forum"],
            "elements": ["data-discourse-setup": ["baseUri": ""]]
        ]
        let loaded = await load([probeItem(results)])
        let page = try XCTUnwrap(loaded)
        XCTAssertEqual(page.title, "A topic")
        guard case .site(let match) = page.detection else { return XCTFail("not detected: \(page.detection)") }
        XCTAssertEqual(match.forumName, "Example Forum")
        XCTAssertEqual(match.siteURL, "https://forum.example.com")
    }

    func testADiscourseForumWithoutASiteNameUsesTheHost() async throws {
        let results: [String: Any] = ["url": "https://www.forum.example.com/latest", "meta": ["generator": "Discourse"]]
        let loaded = await load([probeItem(results)])
        let page = try XCTUnwrap(loaded)
        guard case .site(let match) = page.detection else { return XCTFail("not detected") }
        XCTAssertEqual(match.forumName, "forum.example.com")
    }

    func testAPlainPageIsNotDetected() async throws {
        let results: [String: Any] = ["url": "https://example.com/blog", "title": "Blog", "meta": ["generator": "WordPress 6"]]
        let loaded = await load([probeItem(results)])
        let page = try XCTUnwrap(loaded)
        XCTAssertEqual(page.detection, .notDetected)
        XCTAssertEqual(page.displayTitle, "Blog")
    }

    func testAURLOnlyShareIsUnknown() async throws {
        let loaded = await load([item(topic as NSURL, type: .url, title: "From Chrome")])
        let page = try XCTUnwrap(loaded)
        XCTAssertEqual(page.detection, .unknown)
        XCTAssertEqual(page.url, topic)
        XCTAssertEqual(page.title, "From Chrome")
    }

    func testSharedTextWithAURLIsUnknown() async throws {
        let text = "Look at this https://forum.example.com/t/a-topic/42 please"
        let loaded = await load([item(text as NSString, type: .plainText)])
        let page = try XCTUnwrap(loaded)
        XCTAssertEqual(page.detection, .unknown)
        XCTAssertEqual(page.url.absoluteString, "https://forum.example.com/t/a-topic/42")
    }
}
