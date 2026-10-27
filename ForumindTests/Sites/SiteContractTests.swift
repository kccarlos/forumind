import XCTest
@testable import Forumind

// S1 of the site-adapter refactor (dev/docs/SITE_ADAPTERS_PLAN.md §8.1): one
// generic suite run over every adapter (`DiscourseAdapter`, the made-up
// `FakeSiteAdapter` and, from P1 W7, `WordPressAdapter`). Each adapter supplies a `SiteFixture`. The suite grows
// with each step; recognition, blocks and the shared raw format join later.

// MARK: Discourse fixture server

/// Records every request as `path?query` (relative to the forum's base path)
/// and answers like a small Discourse forum at `https://example.com/forum`.
private final class ContractStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String] = []

    static func reset() { lock.withLock { recorded = [] } }
    static var requests: [String] { lock.withLock { recorded } }

    static let rawPage = """
    alice | 2026-10-20 12:00:00 UTC | #1
    Opening post.


    bob | 2026-10-20 12:05:00 UTC | #2
    A reply.

    """

    static let topicJSON = """
    {"id":123,"title":"Topic 123","slug":"topic-123","posts_count":2,"highest_post_number":2,
     "details":{"created_by":{"username":"alice"}},
     "post_stream":{"stream":[1001,1002],"posts":[
       {"id":1001,"post_number":1,"username":"alice","like_count":2},
       {"id":1002,"post_number":2,"username":"bob","like_count":0}]}}
    """

    static let emptyList = #"{"topic_list":{"topics":[]}}"#
    static let list = #"{"topic_list":{"topics":[{"id":5,"title":"Five","slug":"five","posts_count":2}]}}"#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = components.path.hasPrefix("/forum") ? String(components.path.dropFirst("/forum".count)) : components.path
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        Self.lock.withLock { Self.recorded.append(path + query) }

        let parts = path.split(separator: "/").map(String.init)
        var status = 200
        var body = ""
        if parts == ["top.json"] {
            body = Self.emptyList
        } else if parts == ["latest.json"] {
            body = Self.list
        } else if parts == ["search.json"] {
            body = #"{"posts":[],"topics":[]}"#
        } else if parts == ["site", "basic-info.json"] {
            body = #"{"title":"Example Forum"}"#
        } else if parts.count == 2, parts[0] == "t", parts[1].hasSuffix(".json") {
            body = Self.topicJSON
        } else if parts.count == 3, parts[0] == "t", parts[2] == "posts.json" {
            body = DiscourseFixtures.posts
        } else if parts.count == 2, parts[0] == "raw" {
            body = Self.rawPage
        } else {
            status = 404
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: Fixtures

/// What the generic suite needs from one adapter.
private struct SiteFixture {
    let name: String
    let adapter: any SiteAdapter
    let siteURL: String
    let basePath: String
    let topicID: String
    let slug: String
    /// Forum requests a first read makes, and a second read with its pages.
    let firstReadRequests: Int
    let cachedReadRequests: Int
    /// Whether a post link carries the post number (Discourse `/N`); anchored platforms don't.
    let linksCarryPostNumbers: Bool
    /// Post numbers `postLookup` finds in the fixture.
    var lookupNumbers = [5, 10]
    /// A fresh network (and request log) for one test.
    let network: () -> SiteNetwork
    let requests: () -> [String]
}

private func discourseFixture() -> SiteFixture {
    SiteFixture(
        name: "discourse",
        adapter: DiscourseAdapter(),
        siteURL: "https://example.com/forum",
        basePath: "/forum",
        topicID: "123",
        slug: "topic-123",
        firstReadRequests: 2,   // topic JSON, one /raw page
        cachedReadRequests: 1,  // topic JSON only
        linksCarryPostNumbers: true,
        network: {
            ContractStub.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ContractStub.self]
            let service = ForumService(
                session: URLSession(configuration: configuration),
                pacer: ForumRequestPacer(clock: InstantPacingClock())
            )
            return SiteNetwork(service: service, siteURL: "https://example.com/forum", context: SiteRequestContext(pace: .fast))
        },
        requests: { ContractStub.requests }
    )
}

private func fakeFixture() -> SiteFixture {
    SiteFixture(
        name: "fake",
        adapter: FakeSiteAdapter(),
        siteURL: "https://fake.example.com",
        basePath: "",
        topicID: "7",
        slug: "seven",
        firstReadRequests: 0,
        cachedReadRequests: 0,
        linksCarryPostNumbers: true,
        network: {
            SiteNetwork(service: ForumService(), siteURL: "https://fake.example.com", context: SiteRequestContext())
        },
        requests: { [] }
    )
}

/// WordPress at `https://example.com`: the article by alice, one comment by bob.
private func wordpressFixture() -> SiteFixture {
    SiteFixture(
        name: "wordpress",
        adapter: WordPressAdapter(),
        siteURL: WordPressFixtureSite.siteURL,
        basePath: "",
        topicID: WordPressFixtureSite.postID,
        slug: "",
        firstReadRequests: 2,   // the article, comment page 1
        cachedReadRequests: 2,  // the same: the revision and count are compared
        linksCarryPostNumbers: false,
        lookupNumbers: [2],
        network: {
            var reply = WordPressFixtureSite.comment(1, author: "bob")
            reply["content"] = ["rendered": "<p>A reply.</p>"]
            let site = WordPressFixtureSite(comments: [reply])
            WordPressFixtureSite.latest = site
            return site.network()
        },
        requests: { WordPressFixtureSite.latest?.requestLines ?? [] }
    )
}

private func allFixtures() -> [SiteFixture] { [discourseFixture(), fakeFixture(), wordpressFixture()] }

// MARK: Tests

final class SiteContractTests: XCTestCase {
    private func isHeader(_ line: Substring) -> Bool {
        !RawTopicFormat.parseHeaders(String(line)).isEmpty
    }

    private func readRequest(_ fixture: SiteFixture, cached: [RawForumPage] = [], known: Int? = nil) -> TopicReadRequest {
        TopicReadRequest(
            topic: TopicRef(siteURL: fixture.siteURL, topicID: fixture.topicID),
            cachedPages: cached,
            knownTotalPosts: known
        )
    }

    // MARK: Registry

    func testRegistryKindsAreUniqueAndReachable() {
        let adapters = allFixtures().map(\.adapter)
        let registry = SiteRegistry(adapters: adapters)
        XCTAssertEqual(Set(adapters.map(\.kind)).count, adapters.count)
        for adapter in adapters {
            XCTAssertEqual(registry.adapter(for: adapter.kind)?.kind, adapter.kind)
        }
        XCTAssertNil(registry.adapter(for: SiteKind("unknown")))
        XCTAssertNil(SiteRegistry(adapters: []).adapter(for: .discourse))
    }

    func testStandardRegistryHoldsDiscourseThenWordPress() {
        let registry = SiteRegistry.standard
        XCTAssertEqual(registry.adapters.map(\.kind), [.discourse, .wordpress])
        XCTAssertEqual(
            registry.allAgentToolNames,
            ["search_forum", "list_latest", "search_comments", "read_topic", "summarize_topic",
             "saved_summaries", "watch_topic", "final_answer"]
        )
        XCTAssertEqual(SiteRecognizers.standard.map(\.kind), registry.adapters.map(\.kind))
        XCTAssertEqual(registry.firstPartyPathPatterns, ContentBlockingRules.firstPartyPathPatterns)
    }

    func testSiteKindCodesAsAPlainString() throws {
        let data = try JSONEncoder().encode([SiteKind.discourse])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"["discourse"]"#)
        XCTAssertEqual(try JSONDecoder().decode([SiteKind].self, from: data), [.discourse])
    }

    func testAgentToolNamesCoverEveryAdaptersSiteTools() {
        let registry = SiteRegistry(adapters: allFixtures().map(\.adapter))
        let names = registry.allAgentToolNames
        XCTAssertEqual(Set(names).count, names.count)
        for fixture in allFixtures() {
            for tool in fixture.adapter.agent.siteTools {
                XCTAssertTrue(names.contains(tool.name), "\(fixture.name): \(tool.name)")
                XCTAssertNotNil(AgentToolName(rawValue: tool.name), "\(fixture.name): \(tool.name)")
            }
        }
        for name in names {
            XCTAssertNotNil(AgentToolName(rawValue: name), name)
        }
        for tool in AgentToolName.appTools {
            XCTAssertTrue(names.contains(tool.rawValue))
        }
    }

    func testSiteToolsRunThroughQueries() throws {
        for fixture in allFixtures() {
            let agent = fixture.adapter.agent
            XCTAssertTrue(fixture.adapter.supportsAgent, fixture.name)
            for spec in agent.siteTools {
                let tool = try XCTUnwrap(AgentToolName(rawValue: spec.name))
                let arguments = Dictionary(uniqueKeysWithValues: spec.parameters.filter(\.required).map { ($0.name, "words") })
                XCTAssertNoThrow(try agent.query(tool, arguments), "\(fixture.name): \(spec.name)")
                for required in spec.parameters where required.required {
                    XCTAssertThrowsError(try agent.query(tool, [:]), "\(fixture.name): \(spec.name) needs \(required.name)")
                }
            }
        }
    }

    // MARK: Links

    func testLinksRoundTrip() throws {
        for fixture in allFixtures() {
            let links = fixture.adapter.links
            let topic = try XCTUnwrap(
                links.topicURL(siteURL: fixture.siteURL, topicID: fixture.topicID, slug: fixture.slug),
                fixture.name
            )
            let parsed = try XCTUnwrap(links.parse(topic, basePath: fixture.basePath), fixture.name)
            XCTAssertEqual(parsed.topicID, fixture.topicID, fixture.name)
            XCTAssertNil(parsed.postNumber, fixture.name)

            let post = links.postURL(topicURL: topic, number: 7, anchor: "p7")
            XCTAssertEqual(links.parse(post, basePath: fixture.basePath)?.postNumber, fixture.linksCarryPostNumbers ? 7 : nil, fixture.name)
            XCTAssertEqual(links.parse(post, basePath: fixture.basePath)?.topicID, fixture.topicID, fixture.name)
            XCTAssertEqual(links.topicPageURL(post), topic, fixture.name)
            XCTAssertNotNil(links.homeURL(siteURL: fixture.siteURL), fixture.name)
        }
    }

    func testDiscourseLinksKeepTheSlug() throws {
        let links = DiscourseAdapter().links
        let topic = try XCTUnwrap(links.topicURL(siteURL: "https://example.com/forum", topicID: "123", slug: "topic-123"))
        XCTAssertEqual(links.parse(topic, basePath: "/forum")?.slug, "topic-123")
        XCTAssertEqual(links.lastPostURL(topicURL: topic)?.absoluteString, "https://example.com/forum/t/topic-123/123/last")
        XCTAssertNil(links.parse(try XCTUnwrap(URL(string: "https://example.com/forum/latest")), basePath: "/forum"))
    }

    func testTopicKeyFormat() {
        XCTAssertEqual(
            TopicRef(siteURL: "https://example.com/forum", topicID: "123").topicKey,
            "example.com/forum/t/123"
        )
        XCTAssertEqual(TopicRef(siteURL: "https://example.com", topicID: "9").topicKey, "example.com/t/9")
        XCTAssertNil(TopicRef(siteURL: "https://example.com", topicID: "abc").topicKey)
    }

    // MARK: Reading

    func testReadTopicProducesTheRawShape() async throws {
        for fixture in allFixtures() {
            let net = fixture.network()
            let result = try await fixture.adapter.readTopic(
                readRequest(fixture), net: net, progress: { _ in }, onPage: nil
            )
            XCTAssertEqual(result.totalPosts, 2, fixture.name)
            XCTAssertFalse(result.unchanged, fixture.name)
            XCTAssertEqual(result.content, RawTopicFormat.join(result.rawPages.map(\.content)), fixture.name)
            var previous = 0
            for page in result.rawPages {
                XCTAssertTrue(page.content.hasSuffix("\n"), fixture.name)
                let blocks = page.content.components(separatedBy: RawTopicFormat.blockSeparator)
                // The page's blocks match its headers in number and order.
                XCTAssertEqual(page.blocks.map(\.number), RawTopicFormat.parseHeaders(page.content).map(\.number), fixture.name)
                XCTAssertEqual(page.blocks.map(\.author), RawTopicFormat.parseHeaders(page.content).map(\.author), fixture.name)
                XCTAssertEqual(page.blocks.count, blocks.count, fixture.name)
                for block in blocks {
                    // Every block starts with a header and holds exactly one.
                    let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                    XCTAssertTrue(isHeader(lines[0]), "\(fixture.name): \(lines[0])")
                    XCTAssertEqual(lines.filter(isHeader).count, 1, fixture.name)
                    let number = Int(lines[0].split(separator: "#").last ?? "") ?? 0
                    XCTAssertGreaterThan(number, previous, fixture.name)
                    previous = number
                }
            }
            XCTAssertEqual(fixture.requests().count, fixture.firstReadRequests, fixture.name)
        }
    }

    func testModerationHidesABlockedAuthorsBlockExactly() async throws {
        for fixture in allFixtures() {
            let result = try await fixture.adapter.readTopic(
                readRequest(fixture), net: fixture.network(), progress: { _ in }, onPage: nil
            )
            let rules = ModerationRules(blockedUsers: [fixture.siteURL: ["bob"]])
            let filtered = ModerationFilter.filter(
                result.content, siteURL: fixture.siteURL, topicID: fixture.topicID, rules: rules
            )
            XCTAssertTrue(filtered.contains("alice | "), fixture.name)
            XCTAssertFalse(filtered.contains("bob | "), fixture.name)
            XCTAssertFalse(filtered.contains("A reply."), fixture.name)
            XCTAssertTrue(filtered.contains("Opening post"), fixture.name)
        }
    }

    func testSecondReadWithCachedPagesMakesTheDeclaredRequests() async throws {
        for fixture in allFixtures() {
            let first = try await fixture.adapter.readTopic(
                readRequest(fixture), net: fixture.network(), progress: { _ in }, onPage: nil
            )
            let net = fixture.network()
            let pagesFetched = Counter()
            let second = try await fixture.adapter.readTopic(
                readRequest(fixture, cached: first.rawPages, known: first.totalPosts),
                net: net, progress: { _ in }, onPage: { _ in await pagesFetched.add() }
            )
            XCTAssertEqual(second.content, first.content, fixture.name)
            XCTAssertEqual(fixture.requests().count, fixture.cachedReadRequests, fixture.name)
            if second.unchanged {
                let fetched = await pagesFetched.value
                XCTAssertEqual(fetched, 0, fixture.name)
            }
        }
    }

    func testOnPageIsCalledOncePerFetchedPage() async throws {
        for fixture in allFixtures() {
            let pagesFetched = Counter()
            let result = try await fixture.adapter.readTopic(
                readRequest(fixture), net: fixture.network(), progress: { _ in }, onPage: { _ in await pagesFetched.add() }
            )
            let fetched = await pagesFetched.value
            XCTAssertEqual(fetched, result.rawPages.count, fixture.name)
        }
    }

    func testOverviewReadsTitleAndCount() async throws {
        for fixture in allFixtures() {
            let overview = try await fixture.adapter.overview(
                TopicRef(siteURL: fixture.siteURL, topicID: fixture.topicID), net: fixture.network()
            )
            XCTAssertEqual(overview.postCount, 2, fixture.name)
            XCTAssertFalse(overview.title.isEmpty, fixture.name)
        }
    }

    // MARK: Capabilities (present means working)

    func testPresentCapabilitiesWork() async throws {
        for fixture in allFixtures() {
            let capabilities = fixture.adapter.capabilities
            let topic = TopicRef(siteURL: fixture.siteURL, topicID: fixture.topicID)
            if let login = capabilities.loginURL {
                XCTAssertNotNil(login(fixture.siteURL), fixture.name)
            }
            if let search = capabilities.searchPageURL {
                XCTAssertNotNil(search(fixture.siteURL, "words"), fixture.name)
            }
            if let bridge = capabilities.pageBridge {
                XCTAssertFalse(bridge.bridgeInstaller.isEmpty, fixture.name)
                XCTAssertFalse(bridge.moderationInstaller.isEmpty, fixture.name)
            }
            if let filters = capabilities.topicFilters {
                for filter in [TopicFilter.top, .author("alice")] {
                    let url = try XCTUnwrap(filters.url(topic: topic, slug: nil, filter: filter), fixture.name)
                    XCTAssertTrue(filters.isFiltered(url), fixture.name)
                    let plain = try XCTUnwrap(
                        fixture.adapter.links.topicURL(siteURL: fixture.siteURL, topicID: fixture.topicID, slug: fixture.slug)
                    )
                    XCTAssertFalse(filters.isFiltered(plain), fixture.name)
                    let overview = try await filters.overview(topic, filter: filter, net: fixture.network())
                    XCTAssertEqual(overview.postCount, 2, fixture.name)
                }
            }
            if let source = capabilities.activeTopics {
                let net = fixture.network()
                let result = await source.activeTopics(siteURL: fixture.siteURL, budget: 2, net: net)
                XCTAssertNotNil(result.topics, fixture.name)
                XCTAssertLessThanOrEqual(result.requests, 2, fixture.name)
            }
            if let lookup = capabilities.postLookup {
                let facts = TopicFacts(
                    stream: [1198342, 1172723],
                    posts: [
                        .init(id: 1198342, number: 10, username: "bob", likeCount: nil),
                        .init(id: 1172723, number: 5, username: "bob", likeCount: nil)
                    ]
                )
                let posts = try await lookup.posts(fixture.lookupNumbers, in: topic, facts: facts, net: fixture.network())
                XCTAssertEqual(Set(posts.map(\.number)), Set(fixture.lookupNumbers), fixture.name)
            }
        }
    }

    func testAdaptersWithoutCapabilitiesHaveNoneToCall() {
        let capabilities = FakeSiteAdapter().capabilities
        XCTAssertNil(capabilities.activeTopics)
        XCTAssertNil(capabilities.postLookup)
        XCTAssertNil(capabilities.topicFilters)
        XCTAssertNil(capabilities.pageBridge)
        XCTAssertNil(capabilities.loginURL)
        XCTAssertNil(capabilities.searchPageURL)
        XCTAssertTrue(capabilities.firstPartyPathPatterns.isEmpty)
    }

    // MARK: Discourse operations

    func testDiscourseActiveTopicsFallsBackToLatestWithinTheBudget() async {
        let fixture = discourseFixture()
        let source = DiscourseActiveTopics()
        var result = await source.activeTopics(siteURL: fixture.siteURL, budget: 0, net: fixture.network())
        XCTAssertEqual(result.requests, 0)
        XCTAssertNil(result.topics)

        result = await source.activeTopics(siteURL: fixture.siteURL, budget: 1, net: fixture.network())
        XCTAssertEqual(result.requests, 1)
        XCTAssertEqual(fixture.requests(), ["/top.json?period=daily"])

        result = await source.activeTopics(siteURL: fixture.siteURL, budget: 2, net: fixture.network())
        XCTAssertEqual(result.requests, 2)
        XCTAssertEqual(result.failures, 0)
        XCTAssertEqual(result.topics?.map(\.id), [5])
        XCTAssertEqual(fixture.requests(), ["/top.json?period=daily", "/latest.json"])
    }

    func testDiscourseRunsSearchAndLatest() async throws {
        let fixture = discourseFixture()
        let adapter = DiscourseAdapter()
        let net = fixture.network()
        _ = try await adapter.run(.search(text: "sidebar", scope: .forum), net: net)
        _ = try await adapter.run(.search(text: "sidebar", scope: .topic(id: "123")), net: net)
        let latest = try await adapter.run(.latest, net: net)
        XCTAssertEqual(latest.topics.map(\.id), [5])
        XCTAssertEqual(fixture.requests(), [
            "/search.json?q=sidebar",
            "/search.json?q=sidebar%20topic:123",
            "/latest.json"
        ])
        do {
            _ = try await adapter.run(.search(text: "x", scope: .comments), net: net)
            XCTFail("Discourse has no comment search")
        } catch {
            XCTAssertEqual(error as? SiteQueryError, .unsupported)
        }
    }

    func testDiscourseSiteInfoAndCandidates() async throws {
        let fixture = discourseFixture()
        let info = try await DiscourseAdapter().siteInfo(siteURL: fixture.siteURL, net: fixture.network())
        XCTAssertEqual(info.name, "Example Forum")
        XCTAssertEqual(
            DiscourseAdapter().siteURLCandidates(fromAddress: "example.com/forum/latest"),
            ["https://example.com/forum", "https://example.com"]
        )
    }

    func testDiscourseAgentQueries() throws {
        let agent = DiscourseAdapter().agent
        XCTAssertEqual(agent.siteTools.map(\.name), ["search_forum", "list_latest"])
        XCTAssertEqual(try agent.query(.searchForum, ["query": "  hello "]), .search(text: "hello", scope: .forum))
        XCTAssertEqual(try agent.query(.listLatest, [:]), .latest)
        XCTAssertThrowsError(try agent.query(.searchForum, ["query": " "]))
        XCTAssertThrowsError(try agent.query(.readTopic, [:]))
        XCTAssertEqual(
            agent.postLinkHint(URL(string: "https://example.com/forum/t/topic-123/123/4")!),
            "(post N: https://example.com/forum/t/topic-123/123/N)"
        )
    }

    // MARK: Network scoping

    func testSiteNetworkRefusesAUrlOutsideTheSite() async throws {
        for fixture in allFixtures() {
            let net = fixture.network()
            for text in ["https://other.example.org/t/1.json", "http://\(URL(string: fixture.siteURL)!.host!)/x"] {
                do {
                    _ = try await net.data(URL(string: text)!)
                    XCTFail("\(fixture.name): \(text) should be refused")
                } catch {
                    XCTAssertEqual(error as? SiteNetworkError, .outsideSite(URL(string: text)!), fixture.name)
                }
            }
            XCTAssertTrue(fixture.requests().isEmpty, fixture.name)
        }
    }

    func testSiteNetworkDecodesJSON() async throws {
        let fixture = discourseFixture()
        let net = fixture.network()
        let json = try await net.json(URL(string: "https://example.com/forum/t/123.json")!)
        XCTAssertEqual(json["id"] as? Int, 123)
        do {
            _ = try await net.json(URL(string: "https://example.com/forum/raw/123?page=1")!)
            XCTFail("raw text is not a JSON object")
        } catch AssistantError.invalidResponse {
        } catch {
            XCTFail("expected invalidResponse, got \(error)")
        }
    }
}

private actor Counter {
    private(set) var value = 0
    func add() { value += 1 }
}
