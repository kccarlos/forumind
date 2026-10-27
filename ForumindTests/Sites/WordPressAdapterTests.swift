import XCTest
@testable import Forumind

/// P1 W7: reading a WordPress post and its comments through the REST API,
/// against `WordPressFixtureSite`. Port of the extension's
/// `wordpress-adapter.test.mjs`, in the shared raw text shape.
final class WordPressAdapterTests: XCTestCase {
    private let adapter = WordPressAdapter()
    private let siteURL = WordPressFixtureSite.siteURL

    private func read(
        _ site: WordPressFixtureSite,
        id: String = WordPressFixtureSite.postID,
        cached: [RawForumPage] = [],
        known: Int? = nil,
        cookie: String? = nil,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void = { _ in },
        onPage: (@Sendable (RawForumPage) async -> Void)? = nil
    ) async throws -> ForumFetchResult {
        try await adapter.readTopic(
            TopicReadRequest(topic: TopicRef(siteURL: siteURL, topicID: id), cachedPages: cached, knownTotalPosts: known),
            net: site.network(cookieHeader: cookie), progress: progress, onPage: onPage
        )
    }

    private func headers(_ result: ForumFetchResult) -> [RawTopicFormat.Header] {
        RawTopicFormat.parseHeaders(result.content)
    }

    private func assertHTTP<T>(_ expected: Int, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
        do {
            _ = try await work()
            XCTFail("expected HTTP \(expected)", file: file, line: line)
        } catch AssistantError.http(let status, _) {
            XCTAssertEqual(status, expected, file: file, line: line)
        } catch {
            XCTFail("expected HTTP \(expected), got \(error)", file: file, line: line)
        }
    }

    // MARK: Reading

    func test205CommentsArePagesOf100100And5PlusTheArticle() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        let progress = ProgressLog()
        let result = try await read(site, progress: { await progress.add($0) })

        XCTAssertEqual(result.rawPages.map(\.page), [1, 2, 3])
        XCTAssertEqual(result.rawPages.map(\.blocks.count), [101, 100, 5])
        XCTAssertEqual(result.totalPosts, 206, "the article counts as the first post")
        XCTAssertFalse(result.unchanged)
        XCTAssertEqual(result.newPosts, 206)
        XCTAssertEqual(result.rawPages.map(\.topicPostCount), [206, 206, 206])
        XCTAssertEqual(result.rawPages.map(\.revision), ["2026-10-25 11:50 UTC", nil, nil])
        XCTAssertEqual(headers(result).map(\.number), Array(1...206))
        XCTAssertTrue(result.content.hasPrefix("alice | 2026-05-14 16:00:00 UTC | #1\nArticle: (Update) Sample Cards & Notes – Part 1\n"))
        XCTAssertTrue(result.content.contains("URL: https://example.com/2026/05/sample-cards-and-notes/\nUpdated: 2026-10-25 11:50 UTC\n\nOpening post: the card is offering 10x & more…\n\n- United\n- Dunkin"))
        XCTAssertTrue(result.content.contains("user1 | 2026-05-14 10:01:05 UTC | #2\nComment number 1 … worth it?"))
        XCTAssertTrue(result.content.contains("user205 | 2026-05-14 13:25:05 UTC | #206"))
        XCTAssertEqual(result.facts?.postsCount, 206)
        XCTAssertEqual(result.facts?.highestPostNumber, 206)
        XCTAssertEqual(result.facts?.openingPoster, "alice")

        let lastProgress = await progress.last
        let last = try XCTUnwrap(lastProgress)
        XCTAssertEqual(last.completedPages, 3)
        XCTAssertEqual(last.totalPages, 3)
        XCTAssertEqual(last.totalPosts, 206)
    }

    func testRequestsStayOnTheSiteInOrderAndSendTheSession() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        _ = try await read(site, cookie: "wordpress_logged_in=abc")
        let requests = site.requests
        XCTAssertEqual(requests.first?.line,
            "/wp-json/wp/v2/posts/1001?_embed=author&_fields=id,title,link,date_gmt,modified_gmt,content,author,_embedded,_links")
        XCTAssertEqual(requests.dropFirst().first?.path, "/wp-json/wp/v2/comments", "the article first, then comments page 1")
        XCTAssertEqual(site.commentPages.sorted(), [1, 2, 3])
        for request in requests.filter({ $0.path.hasSuffix("/comments") }) {
            XCTAssertEqual(request.query["post"], "1001")
            XCTAssertEqual(request.query["per_page"], "100")
            XCTAssertEqual(request.query["order"], "asc")
            XCTAssertEqual(request.query["orderby"], "date_gmt")
            XCTAssertEqual(request.query["_fields"], "id,parent,author_name,date_gmt,content")
        }
        XCTAssertTrue(requests.allSatisfy { $0.cookie == "wordpress_logged_in=abc" })
        XCTAssertEqual(requests.count, 4)
    }

    func testAnArticleWithoutCommentsIsOnePageAndUnchangedOnTheSecondRead() async throws {
        let site = WordPressFixtureSite(commentCount: 0)
        let first = try await read(site)
        XCTAssertEqual(first.rawPages.count, 1)
        XCTAssertEqual(first.totalPosts, 1)
        XCTAssertEqual(headers(first).map(\.number), [1])
        let again = try await read(site, cached: first.rawPages, known: first.totalPosts)
        XCTAssertTrue(again.unchanged)
    }

    func testNothingNewReadsOnlyTheArticleAndTheFirstCommentPage() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        let first = try await read(site)
        site.clearRequests()
        let fetched = Counter()
        let again = try await read(site, cached: first.rawPages, known: first.totalPosts, onPage: { _ in await fetched.add() })
        XCTAssertTrue(again.unchanged)
        XCTAssertEqual(again.newPosts, 0)
        XCTAssertEqual(again.rawPages.count, 3)
        XCTAssertEqual(again.content, first.content)
        XCTAssertEqual(site.requests.count, 2)
        let pages = await fetched.value
        XCTAssertEqual(pages, 0)
    }

    func testNewCommentsReReadOnlyThePagesThatCanHaveChanged() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        let first = try await read(site)
        site.addComments(10)
        site.clearRequests()
        let again = try await read(site, cached: first.rawPages, known: first.totalPosts)
        XCTAssertFalse(again.unchanged)
        XCTAssertEqual(again.newPosts, 10)
        XCTAssertEqual(again.totalPosts, 216)
        XCTAssertEqual(headers(again).map(\.number), Array(1...216))
        XCTAssertEqual(site.commentPages.sorted(), [1, 3], "page 2 was full and is reused")
    }

    func testAnExactlyFullPageGainsItsNextPage() async throws {
        let site = WordPressFixtureSite(commentCount: 100)
        let first = try await read(site)
        XCTAssertEqual(first.rawPages.count, 1)
        site.addComments(1)
        site.clearRequests()
        let again = try await read(site, cached: first.rawPages, known: first.totalPosts)
        XCTAssertEqual(again.rawPages.count, 2)
        XCTAssertEqual(site.commentPages.sorted(), [1, 2])
    }

    func testAnEditedArticleIsReadAgainEvenWithTheSameCommentCount() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        let first = try await read(site)
        site.modified = "2026-10-26T09:00:00"
        let again = try await read(site, cached: first.rawPages, known: first.totalPosts)
        XCTAssertFalse(again.unchanged)
        XCTAssertEqual(again.newPosts, 0)
        XCTAssertTrue(again.content.contains("Updated: 2026-10-26 09:00 UTC"))
        XCTAssertFalse(again.content.contains("Updated: 2026-10-25"))
        XCTAssertEqual(again.rawPages.first?.revision, "2026-10-26 09:00 UTC")
    }

    func testFewerCommentsThanBeforeReReadEverything() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        let first = try await read(site)
        site.comments = Array(site.comments.dropFirst(120))
        site.clearRequests()
        let again = try await read(site, cached: first.rawPages, known: first.totalPosts)
        XCTAssertFalse(again.unchanged)
        XCTAssertEqual(again.totalPosts, 86)
        XCTAssertEqual(again.rawPages.count, 1)
        XCTAssertEqual(headers(again).count, 86)
        XCTAssertEqual(again.newPosts, 0)
    }

    func testAnUnknownPreviousCountReReadsEverything() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        let first = try await read(site)
        site.clearRequests()
        let again = try await read(site, cached: first.rawPages, known: nil)
        XCTAssertFalse(again.unchanged)
        XCTAssertEqual(site.commentPages.sorted(), [1, 2, 3])
    }

    func testAMissingCachedPageIsFetchedLikeANewOne() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        let first = try await read(site)
        site.clearRequests()
        let again = try await read(site, cached: first.rawPages.filter { $0.page != 2 }, known: first.totalPosts)
        XCTAssertEqual(again.content, first.content)
        XCTAssertEqual(site.commentPages.sorted(), [1, 2, 3], "the last page may have grown and is read again")
    }

    func testOnPageIsCalledOncePerFetchedPageAndCachedPagesAreNotRefetched() async throws {
        let site = WordPressFixtureSite(commentCount: 250)
        let fetched = PageLog()
        let first = try await read(site, onPage: { await fetched.add($0.page) })
        let pages = await fetched.pages
        XCTAssertEqual(pages.sorted(), [1, 2, 3])
        site.addComments(1)
        site.clearRequests()
        let more = PageLog()
        _ = try await read(site, cached: first.rawPages, known: first.totalPosts, onPage: { await more.add($0.page) })
        let refetched = await more.pages
        XCTAssertEqual(refetched.sorted(), [1, 3])
        XCTAssertEqual(site.commentPages.sorted(), [1, 3])
    }

    func testAWordPressPageIsReadThroughThePagesEndpoint() async throws {
        let site = WordPressFixtureSite(comments: [WordPressFixtureSite.comment(1, post: 2002)])
        let result = try await read(site, id: WordPressFixtureSite.pageID)
        XCTAssertTrue(result.content.hasPrefix("anonymous | 2026-01-02 08:30:00 UTC | #1\nArticle: About\n"))
        XCTAssertEqual(result.totalPosts, 2)
        XCTAssertEqual(site.requests.prefix(2).map(\.path), ["/wp-json/wp/v2/posts/2002", "/wp-json/wp/v2/pages/2002"])
        XCTAssertNil(result.facts?.openingPoster, "no embedded author")
    }

    // MARK: Errors

    func testAMissingPostIsAFinal404AfterPostsAndPages() async throws {
        let site = WordPressFixtureSite()
        await assertHTTP(404) { try await read(site, id: "999") }
        XCTAssertEqual(site.requests.map(\.path), ["/wp-json/wp/v2/posts/999", "/wp-json/wp/v2/pages/999"])
    }

    func testALoginWallAChallengePageAndAServerErrorFailTheRead() async throws {
        let site = WordPressFixtureSite()
        site.respond { _ in .init(status: 401, body: Data(#"{"code":"rest_forbidden"}"#.utf8)) }
        await assertHTTP(401) { try await read(site) }
        site.respond { _ in .init(status: 403, contentType: "text/html", body: Data("<html>Just a moment...</html>".utf8)) }
        await assertHTTP(403) { try await read(site) }
        site.respond { _ in .init(status: 200, contentType: "text/html", body: Data("<html>Checking your browser</html>".utf8)) }
        do {
            _ = try await read(site)
            XCTFail("a non-JSON article is not an article")
        } catch AssistantError.invalidResponse {
        }
        site.respond { _ in .init(status: 500, body: Data("oops".utf8)) }
        await assertHTTP(500) { try await read(site) }
    }

    func testBadIDsFailBeforeAnyRequest() async throws {
        let site = WordPressFixtureSite()
        for id in ["abc", "12/../3", "", "0", "007", "1234567890123", "-5"] {
            do {
                _ = try await read(site, id: id)
                XCTFail("\(id) should fail")
            } catch AssistantError.invalidResponse {
            }
        }
        XCTAssertTrue(site.requests.isEmpty)
    }

    func testASiteThatClosesTheCommentsEndpointIsReadFromTheArticleAlone() async throws {
        for status in [401, 403, 404] {
            let site = WordPressFixtureSite()
            site.respond { $0.path.hasSuffix("/comments") ? .init(status: status, body: Data(#"{"code":"rest_no_route"}"#.utf8)) : nil }
            let result = try await read(site)
            XCTAssertEqual(result.totalPosts, 1, "\(status)")
            XCTAssertEqual(result.rawPages.count, 1)
            XCTAssertEqual(headers(result).map(\.number), [1])
            XCTAssertTrue(result.content.contains("Article: "))
        }
    }

    func testARefusalOnALaterCommentPageFailsTheReadInsteadOfTruncatingIt() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        site.respond { $0.query["page"] == "2" && $0.path.hasSuffix("/comments") ? .init(status: 403, body: Data("{}".utf8)) : nil }
        await assertHTTP(403) { try await read(site) }
        site.respond { $0.query["page"] == "2" && $0.path.hasSuffix("/comments") ? .init(status: 500, body: Data("{}".utf8)) : nil }
        await assertHTTP(500) { try await read(site) }
    }

    func testAPastTheLastPage400IsAnEmptyPage() async throws {
        // Comments deleted between page 1 and page 2: the header promised two pages.
        let site = WordPressFixtureSite(commentCount: 150)
        site.respond { request in
            guard request.query["page"] == "2", request.path.hasSuffix("/comments") else { return nil }
            return .init(status: 400, body: WordPressFixtureSite.fixture("error-invalid-page"))
        }
        let result = try await read(site)
        XCTAssertEqual(result.rawPages.map(\.page), [1, 2])
        XCTAssertEqual(result.rawPages[1].content, "")
        XCTAssertEqual(result.rawPages[1].blocks, [])
        XCTAssertEqual(headers(result).count, 101)
    }

    // MARK: Headers stripped

    func testASiteWithoutTotalHeadersIsReadFromWhatTheFirstPageHolds() async throws {
        let site = WordPressFixtureSite(commentCount: 3)
        site.sendsTotalHeaders = false
        let result = try await read(site)
        XCTAssertEqual(result.totalPosts, 4)
        XCTAssertEqual(result.rawPages.count, 1)
        XCTAssertEqual(site.commentPages, [1])
    }

    func testAFullFirstPageWithoutHeadersIsProbedForward() async throws {
        let site = WordPressFixtureSite(commentCount: 250)
        site.sendsTotalHeaders = false
        let result = try await read(site)
        XCTAssertEqual(result.totalPosts, 251)
        XCTAssertEqual(result.rawPages.map(\.page), [1, 2, 3])
        XCTAssertEqual(site.commentPages, [1, 2, 3], "each page once: the probe's pages are the pages read")
        XCTAssertEqual(headers(result).map(\.number), Array(1...251))

        // Exactly two full pages: the probe ends on the 400 of page 3.
        let exact = WordPressFixtureSite(commentCount: 200)
        exact.sendsTotalHeaders = false
        let two = try await read(exact)
        XCTAssertEqual(two.totalPosts, 201)
        XCTAssertEqual(two.rawPages.map(\.page), [1, 2])
        XCTAssertEqual(exact.commentPages, [1, 2, 3])
    }

    func testTheProbeStopsAtThePageLimitAndSaysSo() async throws {
        let site = WordPressFixtureSite(commentCount: 5100)
        site.sendsTotalHeaders = false
        let progress = ProgressLog()
        let result = try await read(site, progress: { await progress.add($0) })
        XCTAssertEqual(result.rawPages.count, WordPressAPI.probePageLimit)
        XCTAssertEqual(result.totalPosts, 5001)
        XCTAssertEqual(site.commentPages.count, WordPressAPI.probePageLimit)
        let messages = await progress.messages
        XCTAssertTrue(messages.contains { $0.contains("50") && $0.contains("total") }, "\(messages.prefix(3))")
    }

    // MARK: Text shape

    func testTheSampleCommentsRenderInTheSharedShape() throws {
        let article = try XCTUnwrap(WordPressParsing.parseArticle(WordPressFixtureSite.fixtureObject("article-1001")))
        let comments = WordPressParsing.parseComments(WordPressFixtureSite.fixtureComments())
        XCTAssertEqual(comments.count, 5)
        let page = WordPressParsing.page(1, article: article, comments: comments, revision: "r")
        XCTAssertEqual(page.content, """
        alice | 2026-05-14 16:00:00 UTC | #1
        Article: (Update) Sample Cards & Notes – Part 1
        URL: https://example.com/2026/05/sample-cards-and-notes/
        Updated: 2026-10-25 11:50 UTC

        Opening post: the card is offering 10x & more…

        - United
        - Dunkin


        bob | 2026-05-14 17:02:05 UTC | #2
        Got the 10x on my first try.


        carol | 2026-05-14 17:30:00 UTC | #3
        [Reply to #2]
        Confirmed – same here, & it posted instantly.


        anonymous | 2026-05-14 18:00:00 UTC | #4
        (no text)


        Jane_&_Doe | 2026-05-14 18:15:00 UTC | #5
        [Reply to an earlier comment]
        Replying to a comment on an earlier page.


        bob | 1970-01-01 00:00:00 UTC | #6
        [Reply to #4]
        No date on this one.

        """)
        XCTAssertEqual(page.blocks.map(\.number), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(page.blocks.map(\.author), ["alice", "bob", "carol", "anonymous", "Jane_&_Doe", "bob"])
        XCTAssertEqual(page.blocks.map(\.anchor), ["", "comment-301", "comment-302", "comment-303", "comment-304", "comment-305"])
        XCTAssertNil(page.blocks[5].date)
        XCTAssertEqual(RawTopicFormat.blocks(in: page.content).map(\.number), [1, 2, 3, 4, 5, 6])
        XCTAssertFalse(page.content.dropLast().contains("\n\n\n\n"))
    }

    func testCommentNumbersAreFixedByTheirPageAndAReplyNeverCrossesAPage() throws {
        let comments = [
            WordPressParsing.parseComments([["id": 11, "parent": 0, "author_name": "a", "content": ["rendered": "x"]],
                                            ["id": 12, "parent": 11, "author_name": "b", "content": ["rendered": "y"]]]),
        ][0]
        let second = WordPressParsing.page(2, article: nil, comments: comments, revision: nil)
        XCTAssertEqual(second.blocks.map(\.number), [102, 103])
        XCTAssertTrue(second.content.contains("b | 1970-01-01 00:00:00 UTC | #103\n[Reply to #102]\ny"))
        XCTAssertEqual(second.revision, nil)
        // The same comment alone on the page: its parent is not here.
        let alone = WordPressParsing.page(3, article: nil, comments: [comments[1]], revision: nil)
        XCTAssertTrue(alone.content.contains("#202\n[Reply to an earlier comment]\ny"))
    }

    func testAnArticleWithoutATitleOrRevisionStillReads() throws {
        let article = try XCTUnwrap(WordPressParsing.parseArticle(["id": 5, "content": ["rendered": "<p>x</p>"]]))
        XCTAssertEqual(WordPressParsing.revision(of: article), "unknown")
        let page = WordPressParsing.page(1, article: article, comments: [], revision: "unknown")
        XCTAssertEqual(page.content, "anonymous | 1970-01-01 00:00:00 UTC | #1\nArticle: (untitled)\nUpdated: unknown\n\nx\n")
        XCTAssertNil(WordPressParsing.parseArticle(["title": ["rendered": "no id"]]))
        XCTAssertEqual(WordPressParsing.timestamp("2026-05-14T17:02:05"), "2026-05-14 17:02 UTC")
        XCTAssertNil(WordPressParsing.timestamp("yesterday"))
        XCTAssertNil(WordPressParsing.date(gmt: ""))
    }

    func testTheTextSurvivesModerationAndTheChunker() async throws {
        let site = WordPressFixtureSite(comments: [
            WordPressFixtureSite.comment(1, author: "bob"), WordPressFixtureSite.comment(2, parent: 5001, author: "carol")
        ])
        let result = try await read(site)
        let rules = ModerationRules(blockedUsers: [siteURL: ["bob"]])
        let filtered = ModerationFilter.filter(result.content, siteURL: siteURL, topicID: "1001", rules: rules)
        XCTAssertFalse(filtered.contains("bob | "))
        XCTAssertTrue(filtered.contains("carol | "))
        XCTAssertTrue(filtered.contains("[Reply to #2]"), "a reply to a hidden comment keeps naming it")
    }

    // MARK: Overview

    func testOverviewReadsTheTitleLinkAndCommentCount() async throws {
        let site = WordPressFixtureSite(commentCount: 205)
        let overview = try await adapter.overview(TopicRef(siteURL: siteURL, topicID: "1001"), net: site.network())
        XCTAssertEqual(overview.title, "(Update) Sample Cards & Notes – Part 1")
        XCTAssertEqual(overview.postCount, 206)
        XCTAssertEqual(overview.slug, "")
        XCTAssertEqual(overview.url.absoluteString, "https://example.com/2026/05/sample-cards-and-notes/")
        XCTAssertEqual(overview.facts?.postsCount, 206)
        XCTAssertEqual(overview.facts?.highestPostNumber, 206)
        XCTAssertEqual(site.requestLines, [
            "/wp-json/wp/v2/posts/1001?_fields=id,title,link,modified_gmt",
            "/wp-json/wp/v2/comments?_fields=id&order=asc&orderby=date_gmt&page=1&per_page=1&post=1001"
        ])
    }

    func testOverviewOfAPageCostsThreeRequestsAndClosedCommentsCountAsNone() async throws {
        let site = WordPressFixtureSite(comments: [
            WordPressFixtureSite.comment(1, post: 2002), WordPressFixtureSite.comment(2, post: 2002)
        ])
        let page = try await adapter.overview(TopicRef(siteURL: siteURL, topicID: "2002"), net: site.network())
        XCTAssertEqual(page.title, "About")
        XCTAssertEqual(page.postCount, 3)
        XCTAssertEqual(site.requests.count, 3)

        site.respond { $0.path.hasSuffix("/comments") ? .init(status: 403, body: Data("{}".utf8)) : nil }
        let closed = try await adapter.overview(TopicRef(siteURL: siteURL, topicID: "1001"), net: site.network())
        XCTAssertEqual(closed.postCount, 1)
    }

    func testOverviewWithoutTheTotalHeaderCountsTheFirstPage() async throws {
        let site = WordPressFixtureSite(commentCount: 7)
        site.sendsTotalHeaders = false
        let overview = try await adapter.overview(TopicRef(siteURL: siteURL, topicID: "1001"), net: site.network())
        XCTAssertEqual(overview.postCount, 8)
    }

    // MARK: Add forum

    func testSiteInfoReadsTheRESTIndexAndRefusesOtherJSON() async throws {
        let site = WordPressFixtureSite()
        let info = try await adapter.siteInfo(siteURL: siteURL, net: site.network())
        XCTAssertEqual(info.name, "Example Blog & Notes")
        XCTAssertEqual(site.requestLines, ["/wp-json/?_fields=name,namespaces,home,site_icon_url"])

        site.respond { _ in .init(body: Data(#"{"name":"Not WordPress","namespaces":["oembed/1.0"]}"#.utf8)) }
        do {
            _ = try await adapter.siteInfo(siteURL: siteURL, net: site.network())
            XCTFail("a REST index without wp/v2 is not WordPress")
        } catch AssistantError.invalidResponse {
        }
    }

    func testSiteInfoNeverUsesTheInPageLoader() async throws {
        let site = WordPressFixtureSite()
        let calls = Counter()
        let base = site.network()
        var context = base.context
        context.resourceLoader = { _ in
            await calls.add()
            return ForumResourceResponse(statusCode: 200, statusText: "OK", headers: [:], data: Data())
        }
        let net = SiteNetwork(service: base.service, siteURL: base.siteURL, context: context)
        _ = try await adapter.siteInfo(siteURL: siteURL, net: net)
        let used = await calls.value
        XCTAssertEqual(used, 0)
    }

    // MARK: Plan

    func testThePagePlanFollowsTheCachedPagesAndTheRevision() {
        func page(_ number: Int, revision: String? = nil) -> RawForumPage {
            RawForumPage(page: number, content: "p", revision: revision)
        }
        let cached = [page(1, revision: "r"), page(2), page(3)]
        XCTAssertEqual(WordPressPagePlan.make(cachedPages: cached, knownTotalPosts: 206, currentComments: 205, articleRevision: "r", totalPages: 3), .unchanged)
        XCTAssertEqual(
            WordPressPagePlan.make(cachedPages: cached, knownTotalPosts: 206, currentComments: 205, articleRevision: "new", totalPages: 3),
            .fetch(reusablePages: [page(2)], pageNumbers: [1, 3])
        )
        XCTAssertEqual(
            WordPressPagePlan.make(cachedPages: cached, knownTotalPosts: 206, currentComments: 215, articleRevision: "r", totalPages: 3),
            .fetch(reusablePages: [page(2)], pageNumbers: [1, 3])
        )
        XCTAssertEqual(
            WordPressPagePlan.make(cachedPages: cached, knownTotalPosts: 206, currentComments: 100, articleRevision: "r", totalPages: 1),
            .fetch(reusablePages: [], pageNumbers: [1])
        )
        XCTAssertEqual(
            WordPressPagePlan.make(cachedPages: cached, knownTotalPosts: nil, currentComments: 205, articleRevision: "r", totalPages: 3),
            .fetch(reusablePages: [], pageNumbers: [1, 2, 3])
        )
        XCTAssertEqual(
            WordPressPagePlan.make(cachedPages: [], knownTotalPosts: nil, currentComments: 0, articleRevision: "unknown", totalPages: 1),
            .fetch(reusablePages: [], pageNumbers: [1])
        )
    }

    // MARK: Links, capabilities, profile

    func testCapabilitiesAreNilOrWorking() throws {
        let capabilities = adapter.capabilities
        XCTAssertNil(capabilities.topicFilters)
        XCTAssertNil(capabilities.pageBridge)
        XCTAssertNil(capabilities.loginURL)
        XCTAssertNil(capabilities.session)
        XCTAssertEqual(
            capabilities.searchPageURL?("https://example.com/blog", "sapphire bonus")?.absoluteString,
            "https://example.com/blog/?s=sapphire%20bonus"
        )
        for pattern in capabilities.firstPartyPathPatterns {
            XCTAssertNoThrow(try NSRegularExpression(pattern: pattern), pattern)
        }
    }

    func testTheProfileMapsToolArgumentsToQueries() throws {
        let agent = adapter.agent
        XCTAssertEqual(agent.siteTools.map(\.name), ["search_forum", "search_comments", "list_latest"])
        var options = SearchOptions()
        options.category = "Deals"
        options.page = 2
        options.after = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")
        XCTAssertEqual(
            try agent.query(.searchForum, ["query": " bonus ", "category": "Deals", "page": "2", "after": "2026-01-01"]),
            .search(text: "bonus", scope: .forum, options: options)
        )
        XCTAssertEqual(try agent.query(.searchComments, ["query": "x", "category": "Deals"]), .search(text: "x", scope: .comments))
        XCTAssertEqual(try agent.query(.listLatest, [:]), .latest)
        for bad in [["query": "x", "after": "2026-1-1"], ["query": "x", "before": "tomorrow"], ["query": "x", "page": "4"], ["query": "x", "page": "0"]] {
            XCTAssertThrowsError(try agent.query(.searchForum, bad), "\(bad)") { error in
                guard case AgentError.invalidArgument = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertThrowsError(try agent.query(.searchForum, ["query": " "]))
        XCTAssertEqual(agent.postLinkHint(URL(string: "https://example.com/slug/")!), "(article and comments: https://example.com/slug/)")
    }

    func testAnAdapterRegistryRecognizesEachPlatformFromItsOwnFacts() throws {
        let registry = SiteRegistry(adapters: [DiscourseAdapter(), WordPressAdapter()])
        func match(_ name: String) throws -> SiteKind? {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"))
            let probe = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            let facts = PageFacts(probe: probe, fallbackURL: URL(string: "https://fallback.example.com/")!)
            return registry.recognize(facts: facts, url: facts.url)?.adapter.kind
        }
        XCTAssertEqual(try match("discourse-topic"), .discourse)
        XCTAssertEqual(try match("wordpress-post"), .wordpress)
        XCTAssertEqual(try match("wordpress-subfolder"), .wordpress)
        XCTAssertNil(try match("wordpress-plain-permalink"))
        XCTAssertNil(try match("plain-page"))
        XCTAssertEqual(registry.looseTopicID(in: URL(string: "https://x.example.com/?p=5")!), "5")
        XCTAssertEqual(
            registry.firstPartyPathPatterns.filter { $0.contains("wp-") }.count, 3
        )
    }
}

private actor Counter {
    private(set) var value = 0
    func add() { value += 1 }
}

private actor PageLog {
    private(set) var pages: [Int] = []
    func add(_ page: Int) { pages.append(page) }
}

private actor ProgressLog {
    private(set) var all: [ForumFetchProgress] = []
    var last: ForumFetchProgress? { all.last }
    var messages: [String] { all.map(\.message) }
    func add(_ progress: ForumFetchProgress) { all.append(progress) }
}
