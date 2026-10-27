import XCTest
@testable import Forumind

/// What a site does not offer is not offered (S13): every optional capability
/// is read from the page's or the forum's adapter, never from its kind. The
/// fake has them all nil.
@MainActor
final class CapabilityGatingTests: XCTestCase {
    private let fakeSite = "https://fake.example.com"
    private let fakeTopic = ForumTopic(
        siteURL: "https://fake.example.com", topicID: "42",
        url: URL(string: "https://fake.example.com/topic/42")!, title: "Topic 42"
    )

    private func context(_ topic: ForumTopic? = nil, state: PageContext.State = .topic) -> PageContext {
        PageContext(
            url: topic?.url ?? URL(string: fakeSite), site: FakeSiteAdapter.kind, siteURL: fakeSite,
            forumName: "Fake", topic: topic, state: state
        )
    }

    private func makeApp(fake: FakeSiteAdapter = FakeSiteAdapter()) -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try? store.save(AppSnapshot(forums: [
            Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake"),
            Forum(siteURL: "https://meta.example.com", kind: .discourse, name: "Discourse")
        ]))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(store: store, forumService: ForumService(), sites: SiteRegistry(adapters: [DiscourseAdapter(), fake]))
        app.browser.onPageContextChanged = nil
        return app
    }

    // MARK: topicFilters

    func testFocusOnASiteWithoutFiltersIsUnavailableWithoutARequest() async {
        let app = makeApp()
        app.browser.setPageContext(context(fakeTopic))
        for focus in [BrowseFocus.user("alice"), .op, .top] {
            let result = await app.focus(focus)
            XCTAssertEqual(result.status, .unavailable, "\(focus)")
        }
    }

    func testTopLandingAndDigestTopPostsFallBackWithoutFilters() {
        let app = makeApp()
        let links = FakeLinks()
        let plan = BrowseNavigation.plan(
            adapter: FakeSiteAdapter(), siteURL: fakeSite, topicID: "42", slug: nil, landing: .top,
            facts: nil
        )
        XCTAssertEqual(plan?.url, links.topicURL(siteURL: fakeSite, topicID: "42", slug: nil))
        let card = DigestCard(siteURL: fakeSite, topicID: "42", title: "T", reason: .trending, postCount: 99)
        XCTAssertNil(app.topPostsURL(for: card))
    }

    // MARK: postLookup

    func testAPostNotOnThePageIsMissingWithoutALookup() async {
        let app = makeApp()
        app.browser.setPageContext(context(fakeTopic))
        let ref = BrowseTopicRef(siteURL: fakeSite, topicID: "42")
        let facts = TopicFacts(postsCount: 2, highestPostNumber: 2, stream: [1, 2], posts: [.init(id: 1, number: 1, username: "alice")])
        let lookup = await app.postText(1, in: ref, facts: facts)
        XCTAssertEqual(lookup, .missing)
    }

    // MARK: pageBridge

    func testNoScriptGoesIntoAPageWithoutABridge() async {
        let browser = ForumBrowserModel(sites: SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()]))
        var scripts: [String] = []
        browser.scriptSpy = { scripts.append($0) }
        browser.setPageContext(context(fakeTopic))
        XCTAssertNil(browser.pageBridge)

        browser.applyModerationToPage()
        _ = await browser.highlight([1])
        await browser.clearHighlight()
        _ = await browser.postsOnScreen()
        _ = await browser.postText(1)
        _ = await browser.scrollToPost(1)
        _ = await browser.visiblePosts()
        XCTAssertEqual(scripts, [], "no bridge call, no moderation call")
    }

    func testAPageWithABridgeGetsItsScripts() async {
        var fake = FakeSiteAdapter()
        fake.pageBridge = PageBridgeProfile(bridgeInstaller: "", moderationInstaller: "")
        let browser = ForumBrowserModel(sites: SiteRegistry(adapters: [DiscourseAdapter(), fake]))
        var scripts: [String] = []
        browser.scriptSpy = { scripts.append($0) }
        browser.setPageContext(context(fakeTopic))
        XCTAssertNotNil(browser.pageBridge)

        browser.applyModerationToPage()
        _ = await browser.visiblePosts()
        _ = await browser.highlight([1])
        XCTAssertEqual(scripts.count, 3)
        XCTAssertTrue(scripts[0].contains("__forumindModeration"))
    }

    func testAPageThatIsNoForumHasNoBridge() {
        let browser = ForumBrowserModel()
        XCTAssertNil(browser.pageBridge)
        browser.setPageContext(PageContext(url: URL(string: "https://www.example.com"), state: .notForum))
        XCTAssertNil(browser.pageBridge)
    }

    // MARK: loginURL / searchPageURL

    func testSignInAndSearchEntriesFollowTheCapability() {
        let app = makeApp()
        app.browser.homeSiteURL = fakeSite
        XCTAssertNil(app.loginURL)
        XCTAssertFalse(app.loadLogin())
        XCTAssertNil(app.searchPageURL(query: "fees"))

        app.browser.homeSiteURL = "https://meta.example.com"
        XCTAssertEqual(app.loginURL?.absoluteString, "https://meta.example.com/login")
        XCTAssertEqual(app.searchPageURL(query: "fees")?.absoluteString, "https://meta.example.com/search?q=fees")
    }

    // MARK: firstPartyPathPatterns

    func testTheContentBlockersExemptionsAreTheRegisteredSitesUnion() {
        let discourse = DiscourseAdapter.firstPartyPathPatterns
        XCTAssertEqual(SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()]).firstPartyPathPatterns, discourse)
        XCTAssertEqual(SiteRegistry.standard.firstPartyPathPatterns, discourse)
        XCTAssertEqual(ContentBlockingRules.firstPartyPathPatterns, discourse)
    }
}
