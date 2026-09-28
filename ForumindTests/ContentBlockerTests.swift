import Network
import WebKit
import XCTest
@testable import Forumind

// MARK: - Rules, manifest, settings (no web view)

final class ContentBlockerRulesTests: XCTestCase {
    func testManifestDecodesContract() throws {
        let json = """
        {
          "version": "2026.09.25",
          "generatedAt": "2026-09-25T08:00:00Z",
          "sources": [{"name": "EasyList", "url": "https://easylist.to/easylist/easylist.txt",
                       "listVersion": "202609250800", "license": "CC BY-SA 3.0"}],
          "lists": [
            {"identifier": "ads-1", "category": "ads", "file": "ads-1.json", "ruleCount": 120, "sha256": "ab"},
            {"identifier": "privacy-1", "category": "privacy", "file": "privacy-1.json", "ruleCount": 80, "sha256": "cd"},
            {"identifier": "social-1", "category": "social", "file": "social-1.json", "ruleCount": 1, "sha256": "ef"}
          ]
        }
        """
        let manifest = try JSONDecoder().decode(ContentBlockingManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.version, "2026.09.25")
        XCTAssertEqual(manifest.sources.first?.license, "CC BY-SA 3.0")
        XCTAssertEqual(manifest.lists.map(\.knownCategory), [.ads, .privacy, nil])
        XCTAssertEqual(manifest.lists.first?.ruleCount, 120)
        XCTAssertEqual(manifest.generatedDate, ISO8601DateFormatter().date(from: "2026-09-25T08:00:00Z"))

        let fractional = ContentBlockingManifest(version: "1", generatedAt: "2026-09-25T08:00:00.123Z", lists: [])
        XCTAssertNotNil(fractional.generatedDate)
        let minimal = try JSONDecoder().decode(ContentBlockingManifest.self, from: Data(#"{"version":"3"}"#.utf8))
        XCTAssertEqual(minimal.lists, [])
        XCTAssertNil(minimal.generatedDate)
    }

    func testIdentifierCarriesListManifestAndExceptionsVersions() {
        let list = ContentBlockingManifest.List(identifier: "ads-1", category: "ads", file: "ads-1.json")
        let v1 = ContentBlockingRules.identifier(for: list, manifestVersion: "2026.09.25")
        let v2 = ContentBlockingRules.identifier(for: list, manifestVersion: "2026.10.01")
        XCTAssertEqual(v1, "dc-ads-1-2026.09.25-x\(ContentBlockingRules.exceptionsVersion)")
        XCTAssertNotEqual(v1, v2)
        XCTAssertEqual(ContentBlockingRules.exceptionsVersion.count, 8)
    }

    func testExceptionsTailIsAppendedToChunks() throws {
        let tail = #"[{"a":1},{"b":2}]"#
        XCTAssertEqual(ContentBlockingRules.appending(tail: tail, to: #"[{"x":0}]"#), #"[{"x":0},{"a":1},{"b":2}]"#)
        XCTAssertEqual(ContentBlockingRules.appending(tail: tail, to: " [ ] \n"), #"[{"a":1},{"b":2}]"#)
        XCTAssertEqual(
            ContentBlockingRules.appending(tail: tail, to: "[\n  {\"x\":0}\n]\n"),
            "[\n  {\"x\":0}\n,{\"a\":1},{\"b\":2}]"
        )
        XCTAssertNil(ContentBlockingRules.appending(tail: tail, to: #"{"x":0}"#))
        XCTAssertNil(ContentBlockingRules.appending(tail: tail, to: ""))

        // The real tail: every rule is an ignore-previous-rules exception and
        // the appended chunk is valid JSON.
        let combined = try XCTUnwrap(ContentBlockingRules.appendingExceptions(to: #"[{"trigger":{"url-filter":"ads"},"action":{"type":"block"}}]"#))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(combined.utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, 1 + ContentBlockingRules.exceptionRules.count)
        XCTAssertTrue(rules.dropFirst().allSatisfy { ($0["action"] as? [String: String])?["type"] == "ignore-previous-rules" })
    }

    /// The forum requests the app itself makes (in-page `fetch()`) and
    /// Discourse sign-in paths match a first-party exception.
    func testForumEndpointsMatchFirstPartyExceptions() throws {
        let patterns = try ContentBlockingRules.firstPartyPathPatterns.map {
            try NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
        func exempt(_ string: String) -> Bool {
            patterns.contains { $0.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil }
        }
        let site = "https://forum.example.com/community"
        let urls = [
            ForumSite.topicJSONURL(siteURL: site, topicID: "123"),
            ForumSite.rawPageURL(siteURL: site, topicID: "123", page: 2),
            ForumSite.searchURL(siteURL: site, query: "cards"),
            ForumSite.latestURL(siteURL: site, json: true),
            ForumSite.basicInfoURL(siteURL: site),
            ForumSite.aboutURL(siteURL: site),
            ForumSite.loginURL(siteURL: site),
            URL(string: "https://meta.discourse.org/session/csrf"),
            URL(string: "https://meta.discourse.org/auth/google_oauth2/callback?code=1"),
            URL(string: "https://meta.discourse.org/u/sam.json"),
            URL(string: "https://meta.discourse.org/message-bus/abc/poll")
        ]
        for url in urls {
            let string = try XCTUnwrap(url).absoluteString
            XCTAssertTrue(exempt(string), string)
        }
        XCTAssertFalse(exempt("https://news.example.com/ads/banner.js"))
        XCTAssertFalse(exempt("https://news.example.com/t/123"))
    }

    func testSignInResourcesMatchExceptions() throws {
        let patterns = try ContentBlockingRules.signInResourcePatterns.map {
            try NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
        func exempt(_ string: String) -> Bool {
            patterns.contains { $0.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil }
        }
        for url in [
            "https://accounts.google.com/o/oauth2/v2/auth?client_id=1",
            "https://www.google.com/recaptcha/api.js",
            "https://www.gstatic.com/recaptcha/releases/x/recaptcha__en.js",
            "https://challenges.cloudflare.com/turnstile/v0/api.js",
            "https://js.hcaptcha.com/1/api.js",
            "https://hcaptcha.com/checksiteconfig",
            "https://appleid.apple.com/auth/authorize",
            "https://github.com/login/oauth/authorize?client_id=1",
            "https://discord.com/oauth2/authorize",
            "https://discord.com/api/oauth2/authorize",
            "https://www.facebook.com/v19.0/dialog/oauth?client_id=1",
            "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
        ] {
            XCTAssertTrue(exempt(url), url)
        }
        XCTAssertFalse(exempt("https://www.google.com/adsense/x.js"))
        XCTAssertFalse(exempt("https://connect.facebook.net/en_US/fbevents.js"))
        XCTAssertFalse(exempt("https://github.com/sponsors"))
    }

    func testAllowedSitesMatchHostsAndSubdomains() {
        XCTAssertEqual(ContentBlockingRules.normalizedHost("https://WWW.Example.com/forum"), "example.com")
        XCTAssertEqual(ContentBlockingRules.normalizedHost("meta.discourse.org"), "meta.discourse.org")
        XCTAssertEqual(ContentBlockingRules.normalizedHost("meta.discourse.org/latest"), "meta.discourse.org")
        XCTAssertNil(ContentBlockingRules.normalizedHost("  "))

        let allowed = ["example.com"]
        XCTAssertTrue(ContentBlockingRules.isAllowed(URL(string: "https://example.com/a"), allowedSites: allowed))
        XCTAssertTrue(ContentBlockingRules.isAllowed(URL(string: "https://www.example.com/a"), allowedSites: allowed))
        XCTAssertTrue(ContentBlockingRules.isAllowed(URL(string: "https://forum.example.com/"), allowedSites: allowed))
        XCTAssertFalse(ContentBlockingRules.isAllowed(URL(string: "https://notexample.com/"), allowedSites: allowed))
        XCTAssertFalse(ContentBlockingRules.isAllowed(URL(string: "https://example.com.evil.net/"), allowedSites: allowed))
        XCTAssertFalse(ContentBlockingRules.isAllowed(nil, allowedSites: allowed))
    }

    func testSignInPagesPauseBlocking() {
        for url in [
            "https://accounts.google.com/v3/signin/identifier",
            "https://appleid.apple.com/auth/authorize",
            "https://github.com/login/oauth/authorize",
            "https://github.com/session",
            "https://discord.com/oauth2/authorize",
            "https://www.facebook.com/v19.0/dialog/oauth",
            "https://m.facebook.com/login.php",
            "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x"
        ] {
            XCTAssertTrue(ContentBlockingRules.isSignInPage(URL(string: url)), url)
        }
        for url in ["https://github.com/discourse/discourse", "https://www.facebook.com/somepage", "https://discord.com/channels/1"] {
            XCTAssertFalse(ContentBlockingRules.isSignInPage(URL(string: url)), url)
        }
    }

    func testPolicyAndStatus() {
        var policy = ContentBlockingPolicy(allowedSites: ["example.com"])
        let news = URL(string: "https://news.site/story")
        XCTAssertEqual(policy.activeCategories(forTopURL: news), [.ads, .privacy])
        XCTAssertEqual(policy.activeCategories(forTopURL: URL(string: "https://example.com/")), [])
        XCTAssertEqual(policy.activeCategories(forTopURL: URL(string: "https://accounts.google.com/")), [])
        XCTAssertEqual(ContentBlockingStatus.make(policy: policy, url: news), .blocking(ads: true, trackers: true))
        XCTAssertEqual(
            ContentBlockingStatus.make(policy: policy, url: URL(string: "https://www.example.com/")),
            .allowedSite(host: "example.com")
        )
        XCTAssertEqual(ContentBlockingStatus.make(policy: policy, url: URL(string: "https://appleid.apple.com/")), .signInPage)
        policy.blockAds = false
        XCTAssertEqual(policy.activeCategories(forTopURL: news), [.privacy])
        policy.blockTrackers = false
        XCTAssertEqual(ContentBlockingStatus.make(policy: policy, url: news), .off)
    }

    func testSettingsDecodeDefaultsAndRoundTrip() throws {
        // Off by default (respecting forum owners who rely on ads), also for
        // snapshots saved before the setting existed.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"browserBarPosition":"bottom"}"#.utf8))
        XCTAssertFalse(old.contentBlockingEnabled)
        XCTAssertFalse(old.blockTrackers)
        XCTAssertEqual(old.adBlockAllowedSites, [])
        XCTAssertEqual(old.browserBarPosition, .bottom)

        var settings = AppSettings()
        XCTAssertFalse(settings.contentBlockingEnabled)
        XCTAssertFalse(settings.blockTrackers)
        settings.contentBlockingEnabled = true
        settings.blockTrackers = true
        settings.adBlockAllowedSites = ["example.com"]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)

        // Entries saved as site URLs are normalized to hosts.
        let urls = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"adBlockAllowedSites":["https://www.Example.com/forum"," "]}"#.utf8)
        )
        XCTAssertEqual(urls.adBlockAllowedSites, ["example.com"])
    }
}

// MARK: - Library and blocker (temp rule-list store, fixture lists)

/// Fixture lists written to a temp folder, like the bundled `ContentBlocking`.
struct RuleFixture {
    let directory: URL
    let storeURL: URL

    static let adsRules = #"[{"trigger":{"url-filter":"/ads/"},"action":{"type":"block"}}]"#
    static let privacyRules = #"[{"trigger":{"url-filter":"/track/"},"action":{"type":"block"}}]"#
    /// Over-broad rules that would break a forum without the exceptions tail.
    static let overbroadRules = #"[{"trigger":{"url-filter":"\\.json"},"action":{"type":"block"}},"#
        + #"{"trigger":{"url-filter":"/raw/"},"action":{"type":"block"}},"#
        + #"{"trigger":{"url-filter":"/session"},"action":{"type":"block"}}]"#

    init(version: String = "1", extra: [(id: String, category: String, rules: String)] = []) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cb-\(UUID().uuidString)")
        directory = root.appendingPathComponent("ContentBlocking", isDirectory: true)
        storeURL = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        try write(version: version, extra: extra)
    }

    func write(version: String, extra: [(id: String, category: String, rules: String)] = []) throws {
        let chunks = [("ads-1", "ads", Self.adsRules), ("privacy-1", "privacy", Self.privacyRules)] + extra.map { ($0.id, $0.category, $0.rules) }
        var lists: [[String: Any]] = []
        for (id, category, rules) in chunks {
            try rules.write(to: directory.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
            lists.append(["identifier": id, "category": category, "file": "\(id).json", "ruleCount": 1, "sha256": "x"])
        }
        let manifest: [String: Any] = [
            "version": version, "generatedAt": "2026-09-25T08:00:00Z",
            "sources": [["name": "Fixture", "url": "https://example.com", "listVersion": "1", "license": "CC0"]],
            "lists": lists
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
    }

    @MainActor
    func library() -> ContentRuleLibrary {
        ContentRuleLibrary(store: WKContentRuleListStore(url: storeURL), directory: directory)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }
}

@MainActor
final class ContentRuleLibraryTests: XCTestCase {
    func testCompilesLooksUpAndRemovesStaleVersions() async throws {
        let fixture = try RuleFixture(extra: [
            ("broken-1", "ads", #"[{"trigger":{"url-filter":"("},"action":{"type":"block"}}]"#),
            ("social-1", "social", RuleFixture.adsRules)
        ])
        defer { fixture.remove() }

        // First launch: everything compiles; the broken chunk is skipped.
        let first = fixture.library()
        first.start()
        XCTAssertFalse(first.lookupsFinished)
        await first.waitUntilReady()
        XCTAssertEqual(first.phase, .ready)
        XCTAssertEqual(first.lists.map(\.entry.identifier), ["ads-1", "privacy-1"])
        XCTAssertEqual(first.failedIdentifiers.count, 1)
        XCTAssertNotNil(first.lastCompileDuration)

        // Relaunch: lookups only, nothing compiled.
        let second = fixture.library()
        second.start()
        await second.waitForLookups(timeout: .seconds(5))
        XCTAssertEqual(second.lists.map(\.entry.identifier), ["ads-1", "privacy-1"])
        await second.waitUntilReady()
        XCTAssertEqual(second.compiledIdentifiers, [], "A relaunch only looks lists up")
        XCTAssertEqual(first.compiledIdentifiers.count, 2)

        // Updated lists: new identifiers compile, old ones are removed.
        try fixture.write(version: "2")
        let third = fixture.library()
        third.start()
        await third.waitUntilReady()
        let store = WKContentRuleListStore(url: fixture.storeURL)!
        let available = await ContentRuleLibrary.availableIdentifiers(in: store)
        XCTAssertEqual(Set(available), Set(third.lists.map(\.identifier)))
        XCTAssertTrue(available.allSatisfy { $0.contains("-2-x") }, "\(available)")
    }

    func testMissingManifestIsUnavailableAndNeverWaits() async {
        let library = ContentRuleLibrary(store: nil, directory: nil)
        library.start()
        XCTAssertEqual(library.phase, .unavailable)
        XCTAssertTrue(library.lookupsFinished)
        let started = Date()
        await library.waitForLookups(timeout: .seconds(5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testBlockerAddsAndRemovesListsForPolicyAndSite() async throws {
        let fixture = try RuleFixture()
        defer { fixture.remove() }
        let library = fixture.library()
        let controller = WKUserContentController()
        let blocker = ContentBlocker(controller: controller, library: library)
        blocker.prepare(forTopURL: URL(string: "https://news.site/"))
        library.start()
        await library.waitUntilReady()
        // Lists attach as they become ready.
        XCTAssertEqual(blocker.installed.count, 2)

        blocker.policy.blockTrackers = false
        XCTAssertEqual(Set(blocker.installed.keys), Set(library.lists.filter { $0.category == .ads }.map(\.identifier)))

        blocker.policy.allowedSites = ["news.site"]
        XCTAssertTrue(blocker.installed.isEmpty)
        blocker.prepare(forTopURL: URL(string: "https://other.site/"))
        XCTAssertEqual(blocker.installed.count, 1)
        blocker.prepare(forTopURL: URL(string: "https://accounts.google.com/signin"))
        XCTAssertTrue(blocker.installed.isEmpty)
        blocker.prepare(forTopURL: URL(string: "https://other.site/"))
        blocker.policy = ContentBlockingPolicy(blockAds: false, blockTrackers: false)
        XCTAssertTrue(blocker.installed.isEmpty)
    }

    /// Blocking is off by default: nothing is looked up, compiled or
    /// attached, and page loads never wait. Turning it on starts the lists
    /// and attaches them as they're ready.
    func testNothingIsCompiledWhileOffAndTurningOnAttachesLists() async throws {
        let fixture = try RuleFixture()
        defer { fixture.remove() }
        let library = fixture.library()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let browser = ForumBrowserModel(contentRules: library)
        let app = AppModel(store: store, browser: browser)

        XCTAssertEqual(library.phase, .idle, "no lookup or compile at launch while off")
        XCTAssertTrue(library.lists.isEmpty)
        XCTAssertTrue(library.lookupsFinished, "loads don't wait for lists that were never started")
        browser.load(URL(string: "https://www.news.site/story")!)
        XCTAssertTrue(browser.contentBlocker.installed.isEmpty)

        // Settings shows the lists' date without compiling them.
        library.loadManifestIfNeeded()
        XCTAssertNotNil(library.manifest)
        XCTAssertEqual(library.phase, .idle)

        app.turnOnContentBlocking()
        XCTAssertNotEqual(library.phase, .idle)
        await library.waitUntilReady()
        XCTAssertEqual(library.compiledIdentifiers.count, 2)
        XCTAssertEqual(Set(browser.contentBlocker.installed.keys), Set(library.lists.map(\.identifier)))

        // Turning it off again detaches them.
        app.settings.contentBlockingEnabled = false
        app.settings.blockTrackers = false
        XCTAssertTrue(browser.contentBlocker.installed.isEmpty)
    }

    func testAppModelAllowAndBlockSiteAndReloadDecision() throws {
        let fixture = try RuleFixture()
        defer { fixture.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let browser = ForumBrowserModel(contentRules: fixture.library())
        let app = AppModel(store: store, browser: browser)
        XCTAssertFalse(app.settings.contentBlockingEnabled)
        XCTAssertEqual(app.contentBlockingStatus(for: URL(string: "https://www.news.site/story")), .off)
        app.turnOnContentBlocking()
        XCTAssertTrue(app.settings.contentBlockingEnabled)
        XCTAssertTrue(app.settings.blockTrackers)

        let page = URL(string: "https://www.news.site/story")!
        XCTAssertEqual(app.contentBlockingStatus(for: page), .blocking(ads: true, trackers: true))
        app.setAdsAllowed(true, on: page)
        XCTAssertEqual(app.settings.adBlockAllowedSites, ["news.site"])
        app.setAdsAllowed(true, on: URL(string: "https://m.news.site/")!)
        XCTAssertEqual(app.settings.adBlockAllowedSites, ["news.site"], "Already covered by news.site")
        XCTAssertEqual(app.contentBlockingStatus(for: page), .allowedSite(host: "news.site"))
        app.setAdsAllowed(false, on: URL(string: "https://m.news.site/")!)
        XCTAssertEqual(app.settings.adBlockAllowedSites, [])

        // Only a change that affects the page shown asks for a reload.
        browser.load(page)
        XCTAssertFalse(browser.applyContentBlocking(ContentBlockingPolicy(allowedSites: ["other.site"])))
        XCTAssertTrue(browser.applyContentBlocking(ContentBlockingPolicy(allowedSites: ["news.site"])))
        XCTAssertTrue(browser.applyContentBlocking(ContentBlockingPolicy()))
        XCTAssertFalse(browser.applyContentBlocking(ContentBlockingPolicy()))
    }
}

// MARK: - WebKit behavior (runtime, local HTTP server)

@MainActor
final class ContentBlockerWebKitTests: XCTestCase {
    private var server: LocalHTTPServer!
    private var fixture: RuleFixture!

    override func setUp() async throws {
        server = try await LocalHTTPServer.start()
        fixture = try RuleFixture(extra: [("overbroad-1", "ads", RuleFixture.overbroadRules)])
    }

    override func tearDown() async throws {
        server.stop()
        fixture.remove()
    }

    private func compile(_ json: String) async throws -> WKContentRuleList {
        let store = try XCTUnwrap(WKContentRuleListStore(url: fixture.storeURL))
        return try await ContentRuleLibrary.compile(UUID().uuidString, source: json, in: store)
    }

    private func makeWebView(lists: [WKContentRuleList] = []) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        for list in lists { configuration.userContentController.add(list) }
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
    }

    /// Loads `/page` from `pageHost` with an image at `/ads/banner.png` on
    /// `imageHost`; returns whether the image request reached the server.
    private func imageRequested(
        in webView: WKWebView,
        pageHost: String = "localhost",
        imageHost: String = "127.0.0.1",
        tag: String,
        beforeAllow: ((URL) -> Void)? = nil
    ) async throws -> Bool {
        let pageURL = URL(string: "http://\(pageHost):\(server.port)/page?img=\(tag)&imghost=\(imageHost)")!
        try await NavigationWaiter.load(pageURL, in: webView, beforeAllow: beforeAllow)
        try await Task.sleep(for: .milliseconds(300))
        return server.requestedPaths.contains("/ads/banner.png?\(tag)")
    }

    // WebKit facts the design relies on (runtime-verified on the simulator).

    func testHarnessSeesUnblockedLoadAndBlockRuleBlocks() async throws {
        let unblocked = try await imageRequested(in: makeWebView(), tag: "a")
        XCTAssertTrue(unblocked)
        let blocked = try await imageRequested(in: makeWebView(lists: [compile(RuleFixture.adsRules)]), tag: "b")
        XCTAssertFalse(blocked)
    }

    /// `ignore-previous-rules` in one list does not undo another list's
    /// block: exceptions must live in each blocking list (the exceptions
    /// tail), and allowed sites are handled by removing the lists.
    func testIgnorePreviousRulesDoesNotCrossLists() async throws {
        let block = try await compile(RuleFixture.adsRules)
        let allow = try await compile(#"[{"trigger":{"url-filter":".*"},"action":{"type":"ignore-previous-rules"}}]"#)
        let requested = try await imageRequested(in: makeWebView(lists: [block, allow]), tag: "c")
        XCTAssertFalse(requested, "WebKit now applies ignore-previous-rules across lists; a separate allowlist list would work.")
    }

    /// `if-top-url` exceptions work inside one list.
    func testIfTopURLExceptionWorksWithinOneList() async throws {
        let list = try await compile(
            #"[{"trigger":{"url-filter":"/ads/"},"action":{"type":"block"}},"#
                + #"{"trigger":{"url-filter":".*","if-top-url":["^http://localhost:"]},"action":{"type":"ignore-previous-rules"}}]"#
        )
        let requested = try await imageRequested(in: makeWebView(lists: [list]), tag: "d")
        XCTAssertTrue(requested)
    }

    // Our blocker.

    func testAllowedSiteSwitchesListsPerMainFrameNavigation() async throws {
        let library = fixture.library()
        library.start()
        await library.waitUntilReady()
        let webView = makeWebView()
        let blocker = ContentBlocker(controller: webView.configuration.userContentController, library: library)
        blocker.policy = ContentBlockingPolicy(allowedSites: ["localhost"])
        let prepare: (URL) -> Void = { blocker.prepare(forTopURL: $0) }

        // Allowed site: the ad loads.
        let onAllowed = try await imageRequested(in: webView, tag: "e", beforeAllow: prepare)
        XCTAssertTrue(onAllowed)
        // Navigating to a site that is not allowed puts the lists back first.
        let onOther = try await imageRequested(
            in: webView, pageHost: "127.0.0.1", imageHost: "localhost", tag: "f", beforeAllow: prepare
        )
        XCTAssertFalse(onOther)
        // And back again.
        let backOnAllowed = try await imageRequested(in: webView, tag: "g", beforeAllow: prepare)
        XCTAssertTrue(backOnAllowed)
        // Turning blocking off applies to the next load.
        blocker.policy = ContentBlockingPolicy(blockAds: false, blockTrackers: false)
        let off = try await imageRequested(in: webView, pageHost: "127.0.0.1", imageHost: "localhost", tag: "h", beforeAllow: prepare)
        XCTAssertTrue(off)
    }

    /// The app's browser switches lists itself (its `decidePolicyFor`):
    /// none on an allowed site, all of them elsewhere.
    func testForumBrowserSwitchesListsForAllowedSites() async throws {
        let library = fixture.library()
        library.start()
        await library.waitUntilReady()
        let browser = ForumBrowserModel(contentRules: library)
        browser.applyContentBlocking(ContentBlockingPolicy(allowedSites: ["localhost"]))

        func load(_ host: String, tag: String) async throws {
            browser.load(URL(string: "http://\(host):\(server.port)/page?img=\(tag)")!)
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(100))
                if !browser.webView.isLoading, browser.webView.url?.host == host { break }
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        try await load("localhost", tag: "j")
        XCTAssertTrue(browser.contentBlocker.installed.isEmpty)
        XCTAssertTrue(server.requestedPaths.contains("/ads/banner.png?j"))
        try await load("127.0.0.1", tag: "k")
        XCTAssertEqual(browser.contentBlocker.installed.count, library.lists.count)
        XCTAssertFalse(server.requestedPaths.contains("/ads/banner.png?k"))
    }

    /// The bundled EasyList / EasyPrivacy chunks compile (with the
    /// exceptions tail), block ads and trackers, and leave forum requests alone.
    func testBundledListsBlockAdsAndTrackersButNotForumRequests() async throws {
        guard let directory = Bundle.main.url(forResource: "ContentBlocking", withExtension: nil),
              ContentBlockingManifest.load(from: directory) != nil
        else {
            throw XCTSkip("No bundled lists")
        }
        let library = ContentRuleLibrary(store: WKContentRuleListStore(url: fixture.storeURL), directory: directory)
        library.start()
        await library.waitUntilReady()
        XCTAssertEqual(library.failedIdentifiers, [])
        XCTAssertEqual(Set(library.lists.map(\.category)), [.ads, .privacy])

        let webView = makeWebView()
        let blocker = ContentBlocker(controller: webView.configuration.userContentController, library: library)
        try await NavigationWaiter.load(
            URL(string: "http://localhost:\(server.port)/listpage")!,
            in: webView,
            beforeAllow: { blocker.prepare(forTopURL: $0) }
        )
        try await Task.sleep(for: .milliseconds(300))
        let paths = server.requestedPaths
        XCTAssertTrue(paths.contains("/images/logo.png"), "\(paths)")
        XCTAssertFalse(paths.contains("/ads/acctid=1"), "EasyList did not block the ad")
        XCTAssertFalse(paths.contains("/jquery.google-analytics.js"), "EasyPrivacy did not block the tracker")

        let base = "http://localhost:\(server.port)"
        let value = try await webView.callAsyncJavaScript(
            """
            const results = {};
            for (const path of paths) {
              try { results[path] = (await fetch(path, { cache: "no-store" })).status; } catch (e) { results[path] = 0; }
            }
            return results;
            """,
            arguments: ["paths": ["/t/123.json", "/raw/123?page=1", "/search.json?q=ads", "/latest.json"].map { base + $0 }],
            in: nil,
            contentWorld: .page
        )
        let results = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(results.count, 4)
        XCTAssertTrue(results.values.allSatisfy { $0 as? Int == 200 }, "\(results)")
    }

    /// The app's in-page `fetch()` of forum endpoints is never blocked, even
    /// by over-broad rules; the same paths from another site still are.
    func testForumAPIRequestsAreNeverBlocked() async throws {
        let library = fixture.library()
        library.start()
        await library.waitUntilReady()
        XCTAssertEqual(library.failedIdentifiers, [])
        let webView = makeWebView()
        let blocker = ContentBlocker(controller: webView.configuration.userContentController, library: library)
        try await NavigationWaiter.load(
            URL(string: "http://localhost:\(server.port)/page?img=i")!,
            in: webView,
            beforeAllow: { blocker.prepare(forTopURL: $0) }
        )
        XCTAssertEqual(blocker.installed.count, 3)

        let script = """
        const results = {};
        for (const path of paths) {
          try { const r = await fetch(path, { cache: "no-store" }); results[path] = r.status; }
          catch (e) { results[path] = 0; }
        }
        return results;
        """
        let base = "http://localhost:\(server.port)"
        let other = "http://127.0.0.1:\(server.port)"
        let firstParty = [
            "/t/123.json", "/t/some-topic/123.json?print=true", "/raw/123?page=2", "/search.json?q=x",
            "/latest.json", "/site/basic-info.json", "/about.json", "/session/csrf"
        ].map { base + $0 }
        let blockedPaths = [base + "/ads/x.js", other + "/t/123.json", other + "/raw/123"]
        let value = try await webView.callAsyncJavaScript(
            script, arguments: ["paths": firstParty + blockedPaths], in: nil, contentWorld: .page
        )
        let results = try XCTUnwrap(value as? [String: Any])
        for path in firstParty {
            XCTAssertEqual(results[path] as? Int, 200, "\(path) was blocked")
        }
        for path in blockedPaths {
            XCTAssertEqual(results[path] as? Int, 0, "\(path) was not blocked")
        }
    }
}

// MARK: - Test helpers

/// Waits for one main-frame load to finish.
@MainActor
final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    var beforeAllow: ((URL) -> Void)?

    static func load(_ url: URL, in webView: WKWebView, beforeAllow: ((URL) -> Void)? = nil) async throws {
        let waiter = NavigationWaiter()
        waiter.beforeAllow = beforeAllow
        webView.navigationDelegate = waiter
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiter.continuation = continuation
            webView.load(URLRequest(url: url))
        }
        webView.navigationDelegate = nil
        _ = waiter
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url {
            beforeAllow?(url)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// Minimal HTTP/1.1 server on the loopback interface. Records every request
/// path it receives; `/page` returns HTML, `/t/…json` etc. return JSON.
final class LocalHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalHTTPServer")
    private let lock = NSLock()
    private var paths: [String] = []
    private(set) var port: UInt16 = 0

    var requestedPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return paths
    }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start() async throws -> LocalHTTPServer {
        let server = try LocalHTTPServer()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var resumed = false
            server.listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    server.port = server.listener.port?.rawValue ?? 0
                    continuation.resume()
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            server.listener.newConnectionHandler = { connection in
                server.handle(connection)
            }
            server.listener.start(queue: server.queue)
        }
        return server
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let text = String(data: buffer, encoding: .utf8), text.contains("\r\n\r\n") {
                self.respond(to: text, on: connection)
            } else if !done, error == nil {
                self.receive(on: connection, buffer: buffer)
            } else {
                connection.cancel()
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let firstLine = request.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : "/"
        lock.lock(); paths.append(path); lock.unlock()

        let (type, body) = Self.body(for: path, port: port)
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func body(for path: String, port: UInt16) -> (String, Data) {
        if path.hasPrefix("/listpage") {
            // Requests that EasyList / EasyPrivacy block, from another site.
            let html = """
            <!doctype html><html><head><title>Lists</title>
            <script src="http://127.0.0.1:\(port)/jquery.google-analytics.js"></script>
            </head><body>
            <img src="http://127.0.0.1:\(port)/ads/acctid=1" width="10" height="10">
            <img src="http://127.0.0.1:\(port)/images/logo.png" width="10" height="10">
            </body></html>
            """
            return ("text/html; charset=utf-8", Data(html.utf8))
        }
        if path.hasPrefix("/page") {
            let items = URLComponents(string: path)?.queryItems ?? []
            let tag = items.first { $0.name == "img" }?.value ?? "x"
            let host = items.first { $0.name == "imghost" }?.value ?? "127.0.0.1"
            let html = """
            <!doctype html><html><head><title>Fixture</title></head><body>
            <p>Fixture page</p>
            <img src="http://\(host):\(port)/ads/banner.png?\(tag)" width="10" height="10">
            </body></html>
            """
            return ("text/html; charset=utf-8", Data(html.utf8))
        }
        if path.contains(".json") {
            return ("application/json", Data(#"{"ok":true}"#.utf8))
        }
        if path.contains(".png") {
            // 1×1 transparent PNG.
            let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=")!
            return ("image/png", png)
        }
        return ("text/plain", Data("ok".utf8))
    }
}
