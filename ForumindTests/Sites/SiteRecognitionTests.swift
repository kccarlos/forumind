import WebKit
import XCTest
@testable import Forumind

/// Detection (S8): page facts from a recorded probe dictionary, the
/// recognizers, the registry's order, the declared-key allowlist behind the
/// probe, and the route observer's delivery rules.
final class SiteRecognitionTests: XCTestCase {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private let fallback = URL(string: "https://fallback.example.com/")!

    // MARK: Facts

    func testRecordedDiscoursePageParsesIntoFacts() throws {
        let facts = PageFacts(probe: try fixture("discourse-topic"), fallbackURL: fallback)
        XCTAssertEqual(facts.url.absoluteString, "https://forum.example.com/forum/t/welcome-to-the-forum/42/3")
        XCTAssertEqual(facts.title, "Welcome to the forum - Example Forum")
        XCTAssertEqual(facts.meta["og:site_name"], "Example Forum")
        XCTAssertEqual(facts.elements["data-discourse-setup"]?["baseUri"], "/forum")
        XCTAssertEqual(facts.matches, [".current-user"])
        XCTAssertTrue(facts.hasClass("logged-in"))
        XCTAssertFalse(facts.hasClass("logged"), "whole class tokens only")
        XCTAssertEqual(facts.iconURL?.lastPathComponent, "icon-180.png")

        let (adapter, match) = try XCTUnwrap(SiteRegistry.standard.recognize(facts: facts, url: facts.url))
        XCTAssertEqual(adapter.kind, .discourse)
        XCTAssertEqual(match, SitePageMatch(
            siteURL: "https://forum.example.com/forum", basePath: "/forum", forumName: "Example Forum",
            kind: .discourse, platformName: "Discourse", topicID: "42"
        ))
        let session = try XCTUnwrap(adapter.capabilities.session).session(from: facts)
        XCTAssertTrue(session.authenticated)
        XCTAssertEqual(session.username, "alice")
    }

    func testAMalformedBaseURIFallsBackToThePageOrigin() throws {
        let url = URL(string: "https://forum.example.com/t/hello/42")!
        // Base paths that do not normalize are dropped (the page origin is the site). A well-formed
        // base path the page is not under stays "not that forum" (pinned by the page-context golden).
        for baseURI in ["/a/../b", "not a path", "https://elsewhere.example.org/x"] {
            let facts = PageFacts(url: url, title: "Hello", meta: ["discourse-base-uri": baseURI])
            let (adapter, match) = try XCTUnwrap(SiteRegistry.standard.recognize(facts: facts, url: url), baseURI)
            XCTAssertEqual(adapter.kind, .discourse)
            XCTAssertEqual(match.siteURL, "https://forum.example.com", baseURI)
            XCTAssertEqual(match.basePath, "", baseURI)
        }
    }

    func testAPlainPageIsNoSiteAndNobodyIsSignedIn() throws {
        let facts = PageFacts(probe: try fixture("plain-page"), fallbackURL: fallback)
        XCTAssertNil(SiteRegistry.standard.recognize(facts: facts, url: facts.url))
        let session = try XCTUnwrap(DiscourseAdapter().capabilities.session).session(from: facts)
        XCTAssertFalse(session.authenticated)
        XCTAssertNil(session.username)
    }

    func testMissingKeysReadAsEmpty() throws {
        // A property list drops null and undefined values: any key may be absent.
        let empty = PageFacts(probe: [:], fallbackURL: fallback)
        XCTAssertEqual(empty, PageFacts(url: fallback))
        XCTAssertEqual(empty.title, "")
        XCTAssertTrue(empty.meta.isEmpty && empty.links.isEmpty && empty.elements.isEmpty && empty.matches.isEmpty)
        XCTAssertEqual(empty.htmlClass + empty.bodyClass, "")
        XCTAssertNil(empty.iconURL)
        XCTAssertFalse(empty.hasClass("logged-in"))
        XCTAssertNil(DiscourseRecognizer().recognize(facts: empty, url: fallback))

        // Wrong types and unsafe icon schemes are ignored, not fatal.
        let odd = PageFacts(
            probe: ["url": 5, "meta": ["generator": 3], "elements": ["data-preloaded": "x"], "matches": [1, ".current-user"],
                    "iconURL": "javascript:alert(1)"],
            fallbackURL: fallback
        )
        XCTAssertEqual(odd.url, fallback)
        XCTAssertTrue(odd.meta.isEmpty)
        XCTAssertEqual(odd.elements["data-preloaded"], [:])
        XCTAssertEqual(odd.matches, [".current-user"])
        XCTAssertNil(odd.iconURL)

        // The Discourse fixture with the optional keys dropped is still Discourse
        // (from the generator), with no name, no user and the base path from the meta.
        var probe = try fixture("discourse-topic")
        for key in ["links", "elements", "matches", "htmlClass", "bodyClass", "iconURL", "title"] { probe[key] = nil }
        probe["meta"] = ["generator": "Discourse 3.4.0", "discourse-base-uri": "/forum"]
        let facts = PageFacts(probe: probe, fallbackURL: fallback)
        let match = try XCTUnwrap(DiscourseRecognizer().recognize(facts: facts, url: facts.url))
        XCTAssertEqual(match.siteURL, "https://forum.example.com/forum")
        XCTAssertEqual(match.forumName, "")
        let session = DiscourseSession().session(from: facts)
        XCTAssertFalse(session.authenticated)
        XCTAssertNil(session.username)
    }

    func testDiscourseRuleIsGeneratorOrBaseURIMetaOrSetupElement() {
        let url = URL(string: "https://example.com/forum/latest")!
        func recognizes(_ facts: PageFacts) -> String? {
            DiscourseRecognizer().recognize(facts: facts, url: url)?.basePath
        }
        XCTAssertEqual(recognizes(PageFacts(url: url, meta: ["generator": "discourse 3"])), "")
        XCTAssertNil(recognizes(PageFacts(url: url, meta: ["generator": "Discourses 3"])), "a whole word")
        XCTAssertEqual(recognizes(PageFacts(url: url, meta: ["discourse-base-uri": "/forum"])), "/forum")
        XCTAssertEqual(recognizes(PageFacts(url: url, meta: ["discourse-base-uri": ""])), "", "present but empty still counts")
        XCTAssertEqual(recognizes(PageFacts(url: url, elements: ["data-discourse-setup": [:]])), "")
        // The setup element's base path wins; an empty one falls through to the meta.
        XCTAssertEqual(recognizes(PageFacts(
            url: url, meta: ["discourse-base-uri": "/meta"], elements: ["data-discourse-setup": ["baseUri": "/forum"]]
        )), "/forum")
        XCTAssertEqual(recognizes(PageFacts(
            url: url, meta: ["discourse-base-uri": "/forum"], elements: ["data-discourse-setup": ["baseUri": ""]]
        )), "/forum")
        // A page outside the base path is not that forum.
        XCTAssertNil(DiscourseRecognizer().recognize(
            facts: PageFacts(url: url, meta: ["discourse-base-uri": "/other"]), url: url
        ))
    }

    func testSignedInFromTheClassTheCurrentUserElementOrNeither() {
        let url = URL(string: "https://forum.example.com/")!
        func state(_ facts: PageFacts) -> Bool { DiscourseSession().session(from: facts).authenticated }
        XCTAssertTrue(state(PageFacts(url: url, htmlClass: "desktop logged-in")))
        XCTAssertTrue(state(PageFacts(url: url, bodyClass: "logged-in")))
        XCTAssertTrue(state(PageFacts(url: url, matches: ["[data-current-user]"])))
        XCTAssertFalse(state(PageFacts(url: url, htmlClass: "anon", bodyClass: "not-logged-in")))
        // A name without the signed-in signals is not a session.
        XCTAssertNil(DiscourseSession().session(from: PageFacts(
            url: url, elements: ["data-preloaded": [DiscourseRecognizer.preloadedUsername: ""]]
        )).username)
    }

    // MARK: Registry

    func testAFakeRecognizerWinsAndLosesByRegistryOrder() throws {
        let facts = PageFacts(probe: try fixture("discourse-topic"), fallbackURL: fallback)
        let generator = try XCTUnwrap(facts.meta["generator"])
        let greedy = FakeSiteAdapter(generator: generator)

        let fakeFirst = SiteRegistry(adapters: [greedy, DiscourseAdapter()])
        XCTAssertEqual(fakeFirst.recognize(facts: facts, url: facts.url)?.adapter.kind, FakeSiteAdapter.kind)
        let discourseFirst = SiteRegistry(adapters: [DiscourseAdapter(), greedy])
        XCTAssertEqual(discourseFirst.recognize(facts: facts, url: facts.url)?.adapter.kind, .discourse)

        // The page context follows the winner.
        let first = PageContext.make(url: facts.url, title: nil, facts: facts, knownForum: nil, registry: discourseFirst)
        XCTAssertEqual(first.site, .discourse)
        XCTAssertEqual(first.state, .topic)

        // A page only the fake knows.
        let fakeURL = URL(string: "https://fake.example.com/topic/7")!
        let fakeFacts = PageFacts(url: fakeURL, meta: ["generator": "FakeCMS", "fake-site": "Fake Site"])
        let registry = SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()])
        let context = PageContext.make(url: fakeURL, title: "Seven", facts: fakeFacts, knownForum: nil, registry: registry)
        XCTAssertEqual(context.site, FakeSiteAdapter.kind)
        XCTAssertEqual(context.state, .topic)
        XCTAssertEqual(context.topic?.topicID, "7")
        XCTAssertEqual(context.forumName, "Fake Site")
        // The standard registry has no fake: the same facts are not a forum.
        let plain = PageContext.make(url: fakeURL, title: "Seven", facts: fakeFacts, knownForum: nil, registry: .standard)
        XCTAssertEqual(plain.state, .notForum)
        XCTAssertNil(plain.site)
        XCTAssertEqual(registry.looseTopicID(in: fakeURL), "7")
    }

    func testAMatchCarriesTheTopicIdAndTheContextUsesIt() {
        let registry = SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()])
        // An id that exists only in the facts: the URL has none.
        let slug = URL(string: "https://fake.example.com/2026/some-slug/")!
        let withID = PageFacts(url: slug, meta: ["generator": "FakeCMS", "fake-topic": "9"])
        let (_, match) = registry.recognize(facts: withID, url: slug)!
        XCTAssertEqual(match.topicID, "9")
        XCTAssertEqual(match.kind, FakeSiteAdapter.kind)
        XCTAssertEqual(match.platformName, "FakeCMS")
        let context = PageContext.make(url: slug, title: "Slug", facts: withID, knownForum: nil, registry: registry)
        XCTAssertEqual(context.state, .topic)
        XCTAssertEqual(context.topic?.topicID, "9")
        XCTAssertEqual(context.topic?.topicKey, "fake.example.com/t/9")
        // Without it the page is the forum's home, and a URL-only reading finds nothing either.
        let bare = PageFacts(url: slug, meta: ["generator": "FakeCMS"])
        XCTAssertNil(registry.recognize(facts: bare, url: slug)?.match.topicID)
        XCTAssertEqual(PageContext.make(url: slug, title: "Slug", facts: bare, knownForum: nil, registry: registry).state, .forumHome)
        // Discourse fills the match from the URL.
        let topicURL = URL(string: "https://meta.example.org/t/hello/55/3")!
        let discourse = registry.recognize(facts: .discourse(topicURL), url: topicURL)!.match
        XCTAssertEqual(discourse.topicID, "55")
        XCTAssertEqual(discourse.platformName, "Discourse")
        XCTAssertNil(registry.recognize(facts: .discourse(URL(string: "https://meta.example.org/latest")!), url: URL(string: "https://meta.example.org/latest")!)?.match.topicID)
    }

    func testAKnownForumOfAnUnregisteredKindIsNotAForumHere() {
        let url = URL(string: "https://ghost.example.com/topic/7")!
        let ghost = KnownForumSite(siteURL: "https://ghost.example.com", name: "Ghost", iconURL: nil, kind: SiteKind("ghost"))
        let context = PageContext.make(url: url, title: nil, facts: nil, knownForum: ghost, registry: .standard)
        XCTAssertNil(context.site)
        XCTAssertEqual(context.state, .loading)
        // A registered kind decides how the known forum's URL is read.
        let fake = KnownForumSite(siteURL: "https://ghost.example.com", name: "Fake", iconURL: nil, kind: FakeSiteAdapter.kind)
        let early = PageContext.make(
            url: url, title: nil, facts: nil, knownForum: fake,
            registry: SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()])
        )
        XCTAssertEqual(early.site, FakeSiteAdapter.kind)
        XCTAssertEqual(early.topic?.topicID, "7")
    }

    func testTheRegistryClaimsAHostFirstAndTheLooseLookupsFollowRegistryOrder() {
        let registry = SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter(claimedHost: "claimed.example.com")])
        XCTAssertEqual(registry.claimedSite(forHost: "claimed.example.com")?.adapter.kind, FakeSiteAdapter.kind)
        XCTAssertEqual(registry.claimedSite(forHost: "claimed.example.com")?.siteURL, "https://claimed.example.com")
        XCTAssertNil(registry.claimedSite(forHost: "forum.example.com"))
        XCTAssertNil(SiteRegistry.standard.claimedSite(forHost: "claimed.example.com"))
        XCTAssertEqual(registry.looseTopicID(in: URL(string: "https://x.org/t/slug/12")!), "12")
        XCTAssertEqual(registry.postNumber(in: URL(string: "https://x.org/t/slug/12/4")!), 4)
        XCTAssertNil(registry.looseTopicID(in: URL(string: "https://x.org/latest")!))
    }

    @MainActor
    func testTheAdapterOfAHostTheRegistryClaimsComesBeforeTheDirectory() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try? store.save(AppSnapshot(forums: [Forum(siteURL: "https://claimed.example.com", kind: .discourse, name: "Claimed")]))
        let app = AppModel(
            store: store,
            sites: SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter(claimedHost: "claimed.example.com")])
        )
        XCTAssertEqual(app.forum(for: "https://claimed.example.com")?.kind, .discourse)
        XCTAssertEqual(app.adapter(for: "https://claimed.example.com")?.kind, FakeSiteAdapter.kind)
    }

    // MARK: The probe's allowlist

    func testTheProbeIsBuiltFromTheRecognizersDeclaredKeys() {
        let registry = SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()])
        let keys = registry.factKeys
        // The union, in registry order, without repeats.
        XCTAssertEqual(keys.meta, ["og:title", "generator", "discourse-base-uri", "og:site_name", "fake-site", "fake-topic"])
        XCTAssertEqual(keys.selectors, DiscourseRecognizer.currentUserSelectors)
        XCTAssertEqual(Set(keys.elements.keys), ["data-discourse-setup", "data-preloaded"])
        var standardKeys = PageFactKeys.common
        standardKeys.formUnion(DiscourseRecognizer().factKeys)
        standardKeys.formUnion(WordPressRecognizer().factKeys)
        XCTAssertEqual(SiteRegistry.standard.factKeys, standardKeys)

        let script = registry.probeExpression
        for key in keys.meta + keys.selectors { XCTAssertTrue(script.contains(key), key) }
        for (id, entries) in keys.elements {
            XCTAssertTrue(script.contains(id), id)
            for entry in entries { XCTAssertTrue(script.contains(entry), entry) }
        }
        // Another registry asks for other keys only.
        XCTAssertFalse(SiteRegistry.standard.probeExpression.contains("fake-site"))
    }

    func testTheRouteObserverHoldsTheProbeBackWhileTheDocumentLoads() {
        let script = ForumBrowserModel.routeObserverScript(probeExpression: SiteRegistry.standard.probeExpression)
        XCTAssertTrue(script.contains(#"document.readyState !== "loading""#))
        XCTAssertTrue(script.contains("probe: sendFacts ? probe() : null"))
        XCTAssertTrue(script.contains("generator"), "the registry's probe is inside the observer")
        // The message is the route and the facts, nothing else.
        XCTAssertFalse(script.contains("authenticated:"))
        XCTAssertFalse(script.contains("username:"))
    }
}

// MARK: - Route observer in a real web view

/// The observer's delivery rules against WebKit: no facts while the document
/// loads, facts once per document, URL-only messages for later routes.
@MainActor
final class RouteObserverWebKitTests: XCTestCase {
    private final class Recorder: NSObject, WKScriptMessageHandler {
        var messages: [[String: Any]] = []

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }

        var facts: [[String: Any]] { messages.compactMap { $0["probe"] as? [String: Any] } }
    }

    private let html = """
    <!doctype html><html class="desktop-view logged-in"><head>
    <meta name="generator" content="Discourse 3.4.0.beta2">
    <meta property="og:site_name" content="Example Forum">
    <title>Hello</title></head>
    <body class="category-general">
    <div id="data-discourse-setup" data-base-uri="/forum"></div>
    <div id="data-preloaded" data-preloaded='{"currentUser":"{\\"username\\":\\"alice\\"}"}'></div>
    <script>history.replaceState({}, "", "/forum/t/hello/42/2");</script>
    </body></html>
    """

    private func makeWebView(_ recorder: Recorder) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let script = ForumBrowserModel.routeObserverScript(probeExpression: SiteRegistry.standard.probeExpression)
        configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
        configuration.userContentController.add(recorder, name: "dcRouteChanged")
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for \(what)")
    }

    func testFactsArriveOncePerDocumentAndLaterRoutesCarryOnlyTheURL() async throws {
        let recorder = Recorder()
        let webView = makeWebView(recorder)
        webView.loadHTMLString(html, baseURL: URL(string: "https://forum.example.com/forum/")!)
        try await waitUntil("the facts") { !recorder.facts.isEmpty }

        // Every message is the route and, once, the facts. (Whether the first one
        // is still "loading" depends on WebKit's timing; the readyState guard is
        // pinned in the script test above.)
        XCTAssertTrue(recorder.messages.allSatisfy { Set($0.keys) == ["url", "title", "probe"] })
        XCTAssertEqual(recorder.facts.count, 1)

        let facts = PageFacts(probe: try XCTUnwrap(recorder.facts.first), fallbackURL: URL(string: "https://fallback.example.com")!)
        XCTAssertEqual(facts.url.path, "/forum/t/hello/42/2")
        XCTAssertEqual(facts.title, "Hello")
        let (adapter, match) = try XCTUnwrap(SiteRegistry.standard.recognize(facts: facts, url: facts.url))
        XCTAssertEqual(adapter.kind, .discourse)
        XCTAssertEqual(match.siteURL, "https://forum.example.com/forum")
        XCTAssertEqual(match.forumName, "Example Forum")
        XCTAssertEqual(adapter.recognizer.topicID(fromURL: facts.url, basePath: match.basePath), "42")
        let session = try XCTUnwrap(adapter.capabilities.session).session(from: facts)
        XCTAssertTrue(session.authenticated)
        XCTAssertEqual(session.username, "alice")

        // A route change of the same document: the URL only.
        let before = recorder.messages.count
        _ = try await webView.evaluateJavaScript("history.pushState({}, '', '/forum/t/other/9')")
        try await waitUntil("the route") { recorder.messages.count > before }
        XCTAssertEqual(recorder.facts.count, 1)
        let route = try XCTUnwrap(recorder.messages.last)
        XCTAssertEqual((route["url"] as? String).flatMap(URL.init(string:))?.path, "/forum/t/other/9")
        XCTAssertTrue(route["probe"] is NSNull)

        // The signed-in state lives in the classes: a change posts the facts again.
        let routes = recorder.messages.count
        _ = try await webView.evaluateJavaScript("document.documentElement.classList.remove('logged-in')")
        try await waitUntil("the new facts") { recorder.facts.count == 2 && recorder.messages.count > routes }
        let again = PageFacts(probe: try XCTUnwrap(recorder.facts.last), fallbackURL: facts.url)
        XCTAssertFalse(DiscourseSession().session(from: again).authenticated)
    }
}
