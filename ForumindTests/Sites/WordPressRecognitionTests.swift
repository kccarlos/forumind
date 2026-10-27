import XCTest
@testable import Forumind

/// P1 W6: recognizing a WordPress page from probe facts, URL-only reading, the
/// links and the Add forum helpers. Port of the extension's
/// `wordpress-page.test.mjs`. Not registered yet (W11), so the recognizer is
/// used directly.
final class WordPressRecognitionTests: XCTestCase {
    private let recognizer = WordPressRecognizer()
    private let fallback = URL(string: "https://fallback.example.com/")!

    private func facts(_ name: String) throws -> PageFacts {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        let probe = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        return PageFacts(probe: probe, fallbackURL: fallback)
    }

    private func post(
        url: String = "https://example.com/hello/",
        restRoot: String? = "https://example.com/wp-json/",
        shortlink: String? = nil,
        bodyClass: String = "",
        siteName: String? = nil
    ) -> (PageFacts, URL) {
        var links: [String: String] = [:]
        if let restRoot { links["https://api.w.org/"] = restRoot }
        if let shortlink { links["shortlink"] = shortlink }
        var meta: [String: String] = [:]
        if let siteName { meta["og:site_name"] = siteName }
        let pageURL = URL(string: url)!
        return (PageFacts(url: pageURL, meta: meta, links: links, bodyClass: bodyClass), pageURL)
    }

    // MARK: Recognition

    func testAPostPageGivesSiteIdAndNameFromTheDocumentNotTheSlug() throws {
        let facts = try facts("wordpress-post")
        XCTAssertEqual(facts.url.absoluteString, "https://example.com/2026/05/hello-from-the-blog/")
        XCTAssertEqual(
            recognizer.recognize(facts: facts, url: facts.url),
            SitePageMatch(
                siteURL: "https://example.com", basePath: "", forumName: "Example Blog",
                kind: .wordpress, platformName: "WordPress", topicID: "1001"
            )
        )
    }

    func testTheIDFallsBackToTheBodyClassAndAPageUsesPageID() {
        var (facts, url) = post(shortlink: nil, bodyClass: "single postid-1001 single-format-standard")
        XCTAssertEqual(recognizer.recognize(facts: facts, url: url)?.topicID, "1001")
        (facts, url) = post(bodyClass: "page page-id-12")
        XCTAssertEqual(recognizer.recognize(facts: facts, url: url)?.topicID, "12")
        (facts, url) = post(shortlink: "https://example.com/?p=abc", bodyClass: "single")
        XCTAssertNil(recognizer.recognize(facts: facts, url: url)?.topicID)
        // Whole tokens only.
        (facts, url) = post(bodyClass: "notpostid-5 xpage-id-6 postid-")
        XCTAssertNil(recognizer.recognize(facts: facts, url: url)?.topicID)
    }

    func testTheShortlinkWinsOverTheBodyClass() {
        let (facts, url) = post(shortlink: "https://example.com/?p=1001", bodyClass: "postid-2002")
        XCTAssertEqual(recognizer.recognize(facts: facts, url: url)?.topicID, "1001")
    }

    func testAClippedBodyClassDoesNotYieldACutID() {
        // The probe cuts the class at 2000 characters: a last token may be cut inside its number.
        let token = " postid-10"
        var (facts, url) = post(bodyClass: String(repeating: "x", count: 1900) + token)
        XCTAssertEqual(recognizer.recognize(facts: facts, url: url)?.topicID, "10", "below the limit it is read")
        (facts, url) = post(bodyClass: String(repeating: "x", count: 2000 - token.count) + token)
        XCTAssertEqual(facts.bodyClass.count, 2000)
        XCTAssertNil(recognizer.recognize(facts: facts, url: url)?.topicID, "a token at the limit may be cut")
        // The page is still the site: it degrades to the forum home.
        XCTAssertNotNil(recognizer.recognize(facts: facts, url: url))
        // An earlier whole token is still read.
        (facts, url) = post(bodyClass: "postid-7 " + String(repeating: "x", count: 1989) + " page-id-1")
        XCTAssertEqual(recognizer.recognize(facts: facts, url: url)?.topicID, "7")
    }

    func testAHomeOrArchivePageIsTheSiteWithoutAPost() throws {
        let facts = try facts("wordpress-home")
        let match = try XCTUnwrap(recognizer.recognize(facts: facts, url: facts.url))
        XCTAssertEqual(match.siteURL, "https://example.com")
        XCTAssertNil(match.topicID)
    }

    func testAWordPressInASubfolderKeepsItsBasePath() throws {
        let facts = try facts("wordpress-subfolder")
        let match = try XCTUnwrap(recognizer.recognize(facts: facts, url: facts.url))
        XCTAssertEqual(match.siteURL, "https://blog.example.com/blog")
        XCTAssertEqual(match.basePath, "/blog")
        XCTAssertEqual(match.topicID, "9")
        XCTAssertEqual(match.forumName, "Example Blog", "the name is trimmed")
    }

    func testPagesWithoutAReadableRESTRootAreNotWordPress() throws {
        let plain = try facts("wordpress-plain-permalink")
        XCTAssertNil(recognizer.recognize(facts: plain, url: plain.url), "plain permalinks are unsupported")
        XCTAssertNil(recognizer.recognize(facts: PageFacts(url: fallback), url: fallback))
        for root in [
            "https://other.example/wp-json/",       // another origin
            "https://example.com/wp-json/?x=1",
            "https://example.com/wp-json/#frag",
            "https://example.com/not-the-api/",
            "",
            "https://example.com/a/../wp-json/"     // base path that does not normalize
        ] {
            let (facts, url) = post(restRoot: root)
            XCTAssertNil(recognizer.recognize(facts: facts, url: url), root)
        }
        // A page outside the REST root's base path is not that site.
        let (facts, url) = post(url: "https://example.com/elsewhere/", restRoot: "https://example.com/blog/wp-json/")
        XCTAssertNil(recognizer.recognize(facts: facts, url: url))
    }

    func testARelativeRESTRootIsResolvedAgainstThePage() {
        let (facts, url) = post(restRoot: "/wp-json/", shortlink: "/?p=7")
        let match = recognizer.recognize(facts: facts, url: url)
        XCTAssertEqual(match?.siteURL, "https://example.com")
        XCTAssertEqual(match?.topicID, "7")
    }

    func testDeclaresExactlyTheKeysItReads() {
        XCTAssertEqual(recognizer.factKeys, PageFactKeys(meta: ["og:site_name"], links: ["https://api.w.org/", "shortlink"]))
    }

    func testDiscourseAndWordPressNeverBothAcceptAPage() throws {
        let recognizers: [any SiteRecognizer] = [DiscourseRecognizer(), WordPressRecognizer()]
        for (name, expected) in [
            ("discourse-topic", SiteKind.discourse), ("wordpress-post", .wordpress), ("wordpress-home", .wordpress),
            ("wordpress-subfolder", .wordpress), ("wordpress-plain-permalink", nil), ("plain-page", nil)
        ] as [(String, SiteKind?)] {
            let facts = try facts(name)
            let kinds = recognizers.filter { $0.recognize(facts: facts, url: facts.url) != nil }.map(\.kind)
            XCTAssertEqual(kinds, expected.map { [$0] } ?? [], name)
        }
    }

    // MARK: URL only

    func testOnlyPAndPageIDQueriesCarryAnID() {
        let base = "https://example.com"
        XCTAssertEqual(recognizer.topicID(fromURL: URL(string: base + "/?p=1001")!, basePath: ""), "1001")
        XCTAssertEqual(recognizer.topicID(fromURL: URL(string: base + "/?page_id=2002")!, basePath: ""), "2002")
        XCTAssertEqual(recognizer.topicID(fromURL: URL(string: base + "/blog/?p=9")!, basePath: "/blog"), "9")
        XCTAssertNil(recognizer.topicID(fromURL: URL(string: base + "/other/?p=9")!, basePath: "/blog"))
        XCTAssertNil(recognizer.topicID(fromURL: URL(string: base + "/2026/05/slug/")!, basePath: ""))
        XCTAssertNil(recognizer.topicID(fromURL: URL(string: base + "/?p=abc")!, basePath: ""))
        XCTAssertNil(recognizer.topicID(fromURL: URL(string: base + "/?p=0")!, basePath: ""))
        XCTAssertNil(recognizer.topicID(fromURL: URL(string: base + "/?p=1234567890123")!, basePath: ""), "13 digits")
        XCTAssertNil(recognizer.topicID(fromURL: URL(string: "ftp://example.com/?p=5")!, basePath: ""))
        XCTAssertNil(recognizer.looseTopicID(in: URL(string: "https://anywhere.example/x/")!))
        XCTAssertNil(recognizer.postNumber(in: URL(string: base + "/?p=5#comment-77")!))
    }

    /// W11 must-fix: before the site is known, `?p=` counts only at the site root.
    func testWithoutAKnownSiteOnlyRootAddressesCarryAnID() {
        func loose(_ text: String) -> String? { recognizer.looseTopicID(in: URL(string: text)!) }
        XCTAssertEqual(loose("https://anywhere.example/?p=5"), "5")
        XCTAssertEqual(loose("https://anywhere.example?p=5"), "5")
        XCTAssertEqual(loose("https://anywhere.example/index.php?p=5"), "5")
        XCTAssertEqual(loose("https://anywhere.example/?page_id=7"), "7")
        // Other sites paginate with `?p=`.
        XCTAssertNil(loose("https://anywhere.example/x/?p=5"))
        XCTAssertNil(loose("https://anywhere.example/search?q=a&p=2"))
        XCTAssertNil(loose("https://anywhere.example/products.php?p=5"))
        XCTAssertNil(loose("ftp://anywhere.example/?p=5"))
        // Registered, an arbitrary `?p=` page is not even a maybe.
        XCTAssertNil(SiteRegistry.standard.looseTopicID(in: URL(string: "https://anywhere.example/list?p=3")!))
        XCTAssertEqual(SiteRegistry.standard.looseTopicID(in: URL(string: "https://anywhere.example/?p=3")!), "3")
    }

    // MARK: Links

    func testWordPressLinksBuildTheGoldenURLs() throws {
        let links = WordPressLinks()
        XCTAssertEqual(links.homeURL(siteURL: "https://example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(links.homeURL(siteURL: "https://example.com/blog")?.absoluteString, "https://example.com/blog")
        XCTAssertEqual(
            links.topicURL(siteURL: "https://example.com", topicID: "1001", slug: "ignored")?.absoluteString,
            "https://example.com/?p=1001"
        )
        let topic = try XCTUnwrap(links.topicURL(siteURL: "https://example.com/blog", topicID: "9", slug: nil))
        XCTAssertEqual(topic.absoluteString, "https://example.com/blog/?p=9")
        XCTAssertNil(links.topicURL(siteURL: "https://example.com", topicID: "abc", slug: nil))
        XCTAssertNil(links.topicURL(siteURL: "not a site", topicID: "9", slug: nil))

        XCTAssertEqual(links.postURL(topicURL: topic, number: 4, anchor: "comment-77").absoluteString, "https://example.com/blog/?p=9#comment-77")
        XCTAssertEqual(links.postURL(topicURL: topic, number: 4, anchor: "").absoluteString, topic.absoluteString)
        XCTAssertEqual(links.postURL(topicURL: topic, number: 4, anchor: nil).absoluteString, topic.absoluteString)
        let permalink = try XCTUnwrap(URL(string: "https://example.com/2026/05/slug/?utm=1#comment-3"))
        XCTAssertEqual(links.postURL(topicURL: permalink, number: 4, anchor: "comment-5").absoluteString, "https://example.com/2026/05/slug/#comment-5")
        XCTAssertNil(links.lastPostURL(topicURL: topic))
    }

    func testTopicPageURLDropsFragmentUnknownQueryAndCommentPages() throws {
        let links = WordPressLinks()
        func page(_ text: String) throws -> String { links.topicPageURL(try XCTUnwrap(URL(string: text))).absoluteString }
        XCTAssertEqual(try page("https://example.com/?p=1001#comment-9"), "https://example.com/?p=1001")
        XCTAssertEqual(try page("https://example.com/?page_id=2&utm=x"), "https://example.com/?page_id=2")
        XCTAssertEqual(try page("https://example.com/2026/05/slug/?utm=x&replytocom=5#respond"), "https://example.com/2026/05/slug/")
        XCTAssertEqual(try page("https://example.com/2026/05/slug/comment-page-2/#comments"), "https://example.com/2026/05/slug/")
        XCTAssertEqual(try page("https://example.com/slug/comment-page-12"), "https://example.com/slug/")
        XCTAssertEqual(try page("https://example.com/blog/comment-page-1/"), "https://example.com/blog/")
        XCTAssertEqual(try page("https://example.com/comment-page-2/"), "https://example.com/")
        XCTAssertEqual(try page("https://example.com/slug/comment-page-x/"), "https://example.com/slug/comment-page-x/")
    }

    func testParseReadsOnlyPAndPageIDLinks() throws {
        let links = WordPressLinks()
        XCTAssertEqual(
            links.parse(try XCTUnwrap(URL(string: "https://example.com/?p=1001#comment-5")), basePath: ""),
            SiteLink(topicID: "1001", slug: nil, postNumber: nil)
        )
        XCTAssertEqual(links.parse(try XCTUnwrap(URL(string: "https://example.com/?page_id=2")), basePath: "")?.topicID, "2")
        XCTAssertNil(links.parse(try XCTUnwrap(URL(string: "https://example.com/2026/05/slug/")), basePath: ""))
    }

    func testTheCanonicalAddressOfAShownPageComesFromTheLinks() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/?p=1001&utm=x#comment-9"))
        let wordpress = ForumTopic.parse(url: url, title: "Hello", topicID: "1001", links: WordPressLinks())
        XCTAssertEqual(wordpress?.url.absoluteString, "https://example.com/?p=1001", "a non-redirecting ?p= page keeps its query")
        let slug = try XCTUnwrap(URL(string: "https://example.com/2026/05/slug/comment-page-2/?x=1#respond"))
        XCTAssertEqual(
            ForumTopic.parse(url: slug, title: nil, topicID: "1001", links: WordPressLinks())?.url.absoluteString,
            "https://example.com/2026/05/slug/"
        )
        // Discourse keeps the path with its post number and drops query and fragment.
        let discourse = try XCTUnwrap(URL(string: "https://forum.example.com/t/example/42/3?x=1#p"))
        XCTAssertEqual(
            ForumTopic.parse(url: discourse, title: nil, topicID: "42", links: DiscourseLinks())?.url.absoluteString,
            "https://forum.example.com/t/example/42/3"
        )
    }

    // MARK: Add forum

    func testCandidatesAreTheDeepestGuessesFirst() {
        XCTAssertEqual(
            WordPressAddress.candidates(fromAddress: "https://example.com/blog/2026/05/slug/"),
            ["https://example.com/blog/2026", "https://example.com/blog", "https://example.com"]
        )
        XCTAssertEqual(WordPressAddress.candidates(fromAddress: "example.com/blog"), ["https://example.com/blog", "https://example.com"])
        XCTAssertEqual(WordPressAddress.candidates(fromAddress: "Example.com"), ["https://example.com"])
        XCTAssertEqual(WordPressAddress.candidates(fromAddress: "  example.com/?p=5 "), ["https://example.com"])
        XCTAssertEqual(WordPressAddress.candidates(fromAddress: "localhost:8080/wp/hello"), ["http://localhost:8080/wp/hello", "http://localhost:8080/wp", "http://localhost:8080"])
        XCTAssertEqual(WordPressAddress.candidates(fromAddress: "not an address"), [])
        XCTAssertEqual(WordPressAddress.candidates(fromAddress: "nodots"), [])
        XCTAssertEqual(WordPressAddress.candidates(fromAddress: "http://example.com/blog"), [])
    }

    func testSiteInfoNeedsTheWPV2NamespaceAndDecodesTheName() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "root-index", withExtension: "json"))
        let info = try XCTUnwrap(WordPressParsing.parseSiteInfo(Data(contentsOf: url)))
        XCTAssertEqual(info.name, "Example Blog & Notes")
        XCTAssertEqual(info.iconURL?.absoluteString, "https://example.com/wp-content/uploads/icon-512.png")

        func parse(_ json: String) -> ForumSiteInfo? { WordPressParsing.parseSiteInfo(Data(json.utf8)) }
        XCTAssertNil(parse(#"{"name":"X","namespaces":["oembed/1.0"]}"#))
        XCTAssertNil(parse(#"{"name":"X"}"#))
        XCTAssertNil(parse("<html>"))
        XCTAssertNil(parse(#"[]"#))
        XCTAssertNil(parse(#"{"name":"X","namespaces":["wp/v2"],"site_icon_url":"javascript:alert(1)"}"#)?.iconURL)
        XCTAssertNil(parse(#"{"name":"X","namespaces":["wp/v2"],"site_icon_url":""}"#)?.iconURL)
    }
}
