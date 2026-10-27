import XCTest
@testable import Forumind

/// P1 W8: the agent's WordPress tools (search, comment search, latest, a post by
/// number), against `WordPressFixtureSite`. Port of the extension's
/// `wordpress-tools.test.mjs`.
final class WordPressToolsTests: XCTestCase {
    private let adapter = WordPressAdapter()

    private func options(
        category: String? = nil, after: String? = nil, before: String? = nil, page: Int = 1
    ) -> SearchOptions {
        func date(_ text: String?) -> Date? {
            text.flatMap { ISO8601DateFormatter().date(from: $0 + "T00:00:00Z") }
        }
        return SearchOptions(category: category, after: date(after), before: date(before), page: page)
    }

    private func comment(_ id: Int, post: Int, _ text: String, author: String? = nil, date: String = "2026-05-14T17:05:00") -> [String: Any] {
        [
            "id": id, "post": post, "parent": 0, "author_name": author ?? "user\(id)", "date_gmt": date,
            "content": ["rendered": "<p>\(text)</p>"]
        ]
    }

    private func searchSite() -> WordPressFixtureSite {
        WordPressFixtureSite(comments: [
            comment(5001, post: 1001, "Got <b>approved</b> instantly &#8211; no DP"),
            comment(5002, post: 1002, "Approved after a week", date: "2026-05-20T09:00:00"),
            comment(5003, post: 1002, "Declined", date: "2026-05-21T09:00:00")
        ])
    }

    // MARK: Tool set and prompt

    func testTheToolSetAddsSearchCommentsAndKeepsTheSharedNames() {
        let names = AgentPrompt.tools(for: adapter.agent).map(\.name)
        XCTAssertEqual(names, ["search_forum", "search_comments", "list_latest", "read_topic", "summarize_topic", "saved_summaries", "watch_topic", "final_answer"])
        XCTAssertFalse(AgentPrompt.tools(for: DiscourseAdapter().agent).map(\.name).contains("search_comments"))
        for tool in adapter.agent.siteTools {
            XCTAssertTrue(tool.description.contains("Example: {\"tool\": \"\(tool.name)\""), tool.name)
        }
    }

    func testThePromptTalksAboutPostsAndCommentsNotDiscourse() {
        let prompt = AgentPrompt.system(
            profile: adapter.agent, forumName: "Example Blog", siteURL: "https://example.com",
            maxSteps: 8, maxTopicReads: 3, customInstructions: ""
        )
        XCTAssertTrue(prompt.contains("a research agent for Example Blog (https://example.com), a WordPress site."))
        XCTAssertTrue(prompt.contains("- search_comments — "))
        XCTAssertTrue(prompt.contains("#1 is the article and later numbers are reader comments"))
        XCTAssertFalse(prompt.contains("Discourse"))
    }

    func testArgumentsBecomeQueriesAndBadFiltersAreRecoverableErrors() throws {
        let agent = adapter.agent
        XCTAssertEqual(
            try agent.query(.searchForum, ["query": " paze ", "category": "chase", "after": "2026-01-01", "page": "2"]),
            .search(text: "paze", scope: .forum, options: options(category: "chase", after: "2026-01-01", page: 2))
        )
        XCTAssertEqual(
            try agent.query(.searchComments, ["query": "x", "category": "ignored"]),
            .search(text: "x", scope: .comments, options: options())
        )
        XCTAssertEqual(try agent.query(.listLatest, [:]), .latest)
        for (arguments, name) in [(["after": "last year"], "after"), (["before": "2026-13-45"], "before"), (["page": "4"], "page")] {
            XCTAssertThrowsError(try agent.query(.searchForum, ["query": "x"].merging(arguments) { $1 })) { error in
                guard case AgentError.invalidArgument(let argument, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(argument, name)
            }
        }
    }

    // MARK: Search posts

    func testSearchForumSendsDateAndCategoryFilters() async throws {
        let site = WordPressFixtureSite()
        let result = try await adapter.run(
            .search(text: "cards", scope: .forum, options: options(category: "credit-cards", after: "2026-01-01", before: "2026-06-30")),
            net: site.network()
        )
        XCTAssertEqual(result.topics.map(\.id), [1001])
        let listing = try XCTUnwrap(result.topics.first)
        XCTAssertEqual(listing.title, "(Update) Sample Cards & Notes – Part 1")
        XCTAssertEqual(listing.url.absoluteString, "https://example.com/2026/05/sample-cards-and-notes/")
        XCTAssertNil(listing.postsCount)
        XCTAssertEqual(listing.lastPostedAt, "2026-05-14 16:00 UTC")
        XCTAssertEqual(listing.excerpt, "Opening post: the card is offering 10x & more…")

        XCTAssertEqual(site.requestLines, [
            "/wp-json/wp/v2/categories?_fields=id,name,slug&per_page=10&search=credit-cards",
            "/wp-json/wp/v2/posts?_fields=id,title,link,date_gmt,excerpt&after=2026-01-01T00:00:00&before=2026-06-30T00:00:00"
                + "&categories=7&page=1&per_page=20&search=cards"
        ])
    }

    func testACategoryNameMatchesExactlyElseTheFirstResult() async throws {
        let site = WordPressFixtureSite()
        _ = try await adapter.run(.search(text: "deals", scope: .forum, options: options(category: "Travel")), net: site.network())
        XCTAssertEqual(site.requests.last?.query["categories"], "8", "exact name or slug")
        _ = try await adapter.run(.search(text: "deals", scope: .forum, options: options(category: "cards")), net: site.network())
        XCTAssertEqual(site.requests.last?.query["categories"], "7", "otherwise the first match")
    }

    func testAnUnknownCategoryIsARecoverableErrorBeforeTheSearch() async {
        let site = WordPressFixtureSite()
        do {
            _ = try await adapter.run(.search(text: "x", scope: .forum, options: options(category: "nothing")), net: site.network())
            XCTFail("expected an error")
        } catch AgentError.invalidArgument(let name, let reason) {
            XCTAssertEqual(name, "category")
            XCTAssertTrue(reason.contains("no category matches \"nothing\". Search without category"), reason)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(site.requests.count, 1, "no post search after the failed lookup")
    }

    func testAPlusInSearchTextReachesTheSiteAsAPlus() async throws {
        let site = WordPressFixtureSite()
        _ = try await adapter.run(.search(text: "c++ & tips", scope: .forum), net: site.network())
        XCTAssertEqual(site.requests.first?.query["search"], "c++ & tips")
    }

    func testAListingWithAForeignLinkKeepsTheSiteAddress() async throws {
        let site = WordPressFixtureSite()
        site.posts = [WordPressFixtureSite.post(1005, "Elsewhere", "2026-08-01T00:00:00", link: "https://evil.example/phish")]
        let result = try await adapter.run(.latest, net: site.network())
        XCTAssertEqual(result.topics.first?.url.absoluteString, "https://example.com/?p=1005")
    }

    // MARK: Search comments

    func testSearchCommentsListsNewestFirstWithTheirPostsInOneTitleRequest() async throws {
        let site = searchSite()
        let result = try await adapter.run(.search(text: "approved", scope: .comments, options: options(after: "2026-05-01")), net: site.network())

        XCTAssertEqual(site.requests.count, 2)
        XCTAssertEqual(site.requestLines[0], "/wp-json/wp/v2/comments?_fields=id,post,parent,author_name,date_gmt,content&after=2026-05-01T00:00:00"
            + "&order=desc&orderby=date_gmt&page=1&per_page=10&search=approved")
        XCTAssertEqual(site.requests[1].path, "/wp-json/wp/v2/posts")
        XCTAssertEqual(site.requests[1].query["include"], "1002,1001")
        XCTAssertEqual(result.hits.map(\.id), [
            "https://example.com/2026/p1002/#comment-5002",
            "https://example.com/2026/05/sample-cards-and-notes/#comment-5001"
        ], "newest first")
        XCTAssertEqual(result.topics.map(\.id), [1002, 1001])
        let hit = try XCTUnwrap(result.hits.last)
        XCTAssertNil(hit.postNumber)
        XCTAssertEqual(hit.username, "user5001")
        XCTAssertEqual(hit.blurb, "Got approved instantly – no DP")
        XCTAssertEqual(hit.postedAt, "2026-05-14 17:05 UTC")
        XCTAssertEqual(hit.topic.title, "(Update) Sample Cards & Notes – Part 1")

        // What the model reads: the post, then the comment as `@author (date): text`.
        let text = AgentPrompt.format(listings: result.topics, hits: result.hits)
        XCTAssertTrue(text.contains("- id 1001: (Update) Sample Cards & Notes – Part 1"), text)
        XCTAssertTrue(text.contains("  @user5001 (2026-05-14): Got approved instantly – no DP"), text)
        XCTAssertTrue(text.hasSuffix(AgentPrompt.unnumberedHitsNote), text)
        XCTAssertTrue(text.contains("read_topic its post (topic_id = the id above)"), text)
        // Listings without comment hits carry no note.
        XCTAssertFalse(AgentPrompt.format(listings: result.topics).contains("untrusted"))
    }

    func testAClosedCommentSearchIsUnavailableForEveryRefusal() async {
        for status in [401, 403, 404] {
            let site = searchSite()
            site.respond { $0.path.hasSuffix("/comments") ? .init(status: status, body: Data(#"{"code":"rest_forbidden"}"#.utf8)) : nil }
            do {
                _ = try await adapter.run(.search(text: "x", scope: .comments), net: site.network())
                XCTFail("expected an error")
            } catch AgentError.commentsUnavailable {
                XCTAssertTrue(AgentError.commentsUnavailable.modelDescription.hasPrefix("COMMENTS_UNAVAILABLE: "))
            } catch {
                XCTFail("\(status): \(error)")
            }
        }
    }

    func testCommentHitsSurviveAFailedTitleLookup() async throws {
        let site = searchSite()
        site.respond { $0.query["include"] != nil ? .init(status: 500, body: Data("{}".utf8)) : nil }
        let result = try await adapter.run(.search(text: "approved", scope: .comments), net: site.network())
        XCTAssertEqual(result.topics.map(\.title), ["Post 1002", "Post 1001"])
        XCTAssertEqual(result.hits.count, 2)
        XCTAssertEqual(result.hits.last?.url.absoluteString, "https://example.com/?p=1001#comment-5001")
    }

    func testCommentHitsDoNotNeedTheTotalHeader() async throws {
        let site = searchSite()
        site.sendsTotalHeaders = false
        let result = try await adapter.run(.search(text: "approved", scope: .comments), net: site.network())
        XCTAssertEqual(result.hits.count, 2)
    }

    func testNoMatchingCommentsIsAnEmptyResult() async throws {
        let result = try await adapter.run(.search(text: "zzz", scope: .comments), net: searchSite().network())
        XCTAssertTrue(result.hits.isEmpty)
        XCTAssertTrue(result.topics.isEmpty)
    }

    // MARK: List latest and scope

    func testListLatestIsTheNewest30() async throws {
        let site = WordPressFixtureSite()
        site.posts = (1...35).map { WordPressFixtureSite.post(2000 + $0, "Post title \($0)", String(format: "2026-07-%02dT10:00:00", $0)) }
        let result = try await adapter.run(.latest, net: site.network())
        XCTAssertEqual(result.topics.count, 30)
        XCTAssertEqual(result.topics.first?.id, 2035)
        XCTAssertEqual(result.topics.last?.id, 2006)
        XCTAssertEqual(site.requestLines, ["/wp-json/wp/v2/posts?_fields=id,title,link,date_gmt,excerpt&order=desc&orderby=date&per_page=30"])
    }

    func testSearchInsideOneTopicIsNotOffered() async {
        do {
            _ = try await adapter.run(.search(text: "x", scope: .topic(id: "1001")), net: WordPressFixtureSite().network())
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SiteQueryError, .unsupported)
        }
    }

    // MARK: Post by number

    func testPostLookupIsPageArithmeticAndReadsOnePagePerRequest() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        let lookup = try XCTUnwrap(adapter.capabilities.postLookup)
        let topic = TopicRef(siteURL: WordPressFixtureSite.siteURL, topicID: "1001")
        let posts = try await lookup.posts([2, 102, 103, 206, 207], in: topic, facts: TopicFacts(postsCount: 206), net: site.network())

        XCTAssertEqual(posts.map(\.number), [2, 102, 103, 206], "#207 is past the last comment: dropped")
        XCTAssertEqual(posts.map(\.id), [5001, 5101, 5102, 5205])
        XCTAssertEqual(posts.first?.username, "user1")
        XCTAssertEqual(posts.first?.text, "Comment number 1 … worth it?")
        XCTAssertEqual(site.commentPages, [1, 2, 3], "one request per page, not per number")
    }

    func testPostLookupAgreesWithTheNumbersOfARead() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        let read = try await adapter.readTopic(
            TopicReadRequest(topic: TopicRef(siteURL: WordPressFixtureSite.siteURL, topicID: "1001"), cachedPages: [], knownTotalPosts: nil),
            net: site.network(), progress: { _ in }, onPage: nil
        )
        let lookup = try XCTUnwrap(adapter.capabilities.postLookup)
        let topic = TopicRef(siteURL: WordPressFixtureSite.siteURL, topicID: "1001")
        for post in try await lookup.posts([2, 101, 102, 201, 202, 206], in: topic, facts: TopicFacts(), net: site.network()) {
            XCTAssertTrue(read.content.contains("\(post.username) | 2026-05-14"), "#\(post.number)")
            XCTAssertTrue(read.content.contains("#\(post.number)\n\(post.text)"), "#\(post.number)")
        }
    }

    func testPostOneIsTheArticleAndClosedCommentsHaveNoOthers() async throws {
        let site = WordPressFixtureSite(commentCount: 5)
        site.respond { $0.path.hasSuffix("/comments") ? .init(status: 403, body: Data("{}".utf8)) : nil }
        let lookup = try XCTUnwrap(adapter.capabilities.postLookup)
        let topic = TopicRef(siteURL: WordPressFixtureSite.siteURL, topicID: "1001")
        let posts = try await lookup.posts([1, 2], in: topic, facts: TopicFacts(), net: site.network())
        XCTAssertEqual(posts.map(\.number), [1])
        XCTAssertEqual(posts.first?.username, "alice")
        XCTAssertTrue(posts.first?.text.hasPrefix("Opening post: the card is offering 10x & more…") ?? false)
    }

    // MARK: Voice

    func testTheVoiceOffersOnlyTheFocusModesAWordPressSiteHas() {
        XCTAssertEqual(VoiceSite(adapter: adapter).focusModes, ["top", "posts", "clear"])
    }

    // MARK: Overview link

    func testAnOverviewLinkOutsideTheSiteIsReplacedByOneBuiltFromIt() async throws {
        let site = WordPressFixtureSite(commentCount: 1)
        site.respond { request in
            guard request.path == "/wp-json/wp/v2/posts/1001" else { return nil }
            var article = WordPressFixtureSite.fixtureObject("article-1001")
            article["link"] = "https://evil.example/phish"
            return .init(body: try! JSONSerialization.data(withJSONObject: article))
        }
        let overview = try await adapter.overview(TopicRef(siteURL: WordPressFixtureSite.siteURL, topicID: "1001"), net: site.network())
        XCTAssertEqual(overview.url.absoluteString, "https://example.com/?p=1001")
    }
}
