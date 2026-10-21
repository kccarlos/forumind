import XCTest
@testable import Forumind

/// Post-level data from Discourse: search hits, topic facts, posts by id,
/// and the topic URLs that open a post or a filtered view.
final class PostLevelTests: XCTestCase {
    private let site = "https://meta.discourse.org"
    private let folder = "https://example.com/forum"

    // MARK: Search hits

    func testSearchKeepsEveryHitInTheForumsOrder() {
        let (hits, topics) = ForumService.parseSearch(Data(DiscourseFixtures.search.utf8), siteURL: site)
        XCTAssertEqual(hits.map(\.topic.id), [240488, 240488, 415035, 240488])
        XCTAssertEqual(hits.map(\.postNumber), [1, 5, 13, 10])
        XCTAssertEqual(hits.map(\.username), ["alice", "bob", "carol", "bob"])
        XCTAssertEqual(hits[1].topic.title, "How can I hide the Badges link in the sidebar?")
        XCTAssertTrue(hits[1].blurb?.hasPrefix("Hello, You can hide it") ?? false)
        XCTAssertEqual(
            hits[1].url.absoluteString,
            "https://meta.discourse.org/t/how-can-i-hide-the-badges-link-in-the-sidebar/240488/5"
        )
        XCTAssertEqual(Set(hits.map(\.id)).count, hits.count)

        // Topic listings are unchanged: one per topic, first hit's blurb.
        XCTAssertEqual(topics.map(\.id), [240488, 415035])
        XCTAssertEqual(topics[0].excerpt, hits[0].blurb)
        XCTAssertEqual(topics[1].excerpt, hits[2].blurb)
        XCTAssertEqual(ForumService.parseSearchResults(Data(DiscourseFixtures.search.utf8), siteURL: site), topics)
    }

    func testSearchHitsAndListingsComeFromOneRequest() async throws {
        PostLevelURLStub.handler = { request in
            PostLevelURLStub.requests.append(request.url!)
            return (200, DiscourseFixtures.search)
        }
        let service = makeService()
        let results = try await service.searchResults(siteURL: folder, query: "badges topic:240488", cookieHeader: nil)
        XCTAssertEqual(results.hits.count, 4)
        XCTAssertEqual(results.topics.count, 2)
        XCTAssertEqual(PostLevelURLStub.requests.count, 1)
        XCTAssertEqual(PostLevelURLStub.requests[0].path, "/forum/search.json")
        XCTAssertEqual(results.hits[0].url.absoluteString,
                       "https://example.com/forum/t/how-can-i-hide-the-badges-link-in-the-sidebar/240488/1")
    }

    func testSearchObservationListsHitsWithPostNumbersAndAuthors() {
        let (hits, topics) = ForumService.parseSearch(Data(DiscourseFixtures.search.utf8), siteURL: site)
        let text = AgentPrompt.format(listings: topics, hits: hits)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 6)
        XCTAssertTrue(lines[0].hasPrefix("- id 240488: How can I hide the Badges link in the sidebar? — 11 posts"))
        XCTAssertTrue(lines[0].hasSuffix("https://meta.discourse.org/t/how-can-i-hide-the-badges-link-in-the-sidebar/240488"))
        XCTAssertTrue(lines[1].hasPrefix("  #1 @alice: I imagine"))
        XCTAssertTrue(lines[2].hasPrefix("  #5 @bob: Hello, You can hide it"))
        XCTAssertTrue(lines[3].hasPrefix("  #10 @bob: "))
        XCTAssertTrue(lines[4].hasPrefix("- id 415035: "))
        XCTAssertTrue(lines[5].hasPrefix("  #13 @carol: "))
        // At most `hitsPerTopic` per topic; listings alone keep the excerpt.
        XCTAssertFalse(AgentPrompt.format(listings: topics, hits: hits, hitsPerTopic: 2).contains("#10 @bob"))
        XCTAssertFalse(AgentPrompt.format(listings: topics).contains("#5 @bob"))
        // A search within one topic shows every hit.
        let single = AgentPrompt.format(listings: [topics[0]], hits: hits, hitsPerTopic: 2)
        XCTAssertTrue(single.contains("#1 @alice") && single.contains("#5 @bob") && single.contains("#10 @bob"))
        XCTAssertTrue(AgentPrompt.format(listings: topics).contains("\n  I imagine that sidebar"))

        let prompt = AgentPrompt.system(
            forumName: "Meta", siteURL: site, maxSteps: 5, maxTopicReads: 2, customInstructions: ""
        )
        XCTAssertTrue(prompt.contains("/t/slug/id/N"))
        XCTAssertTrue(prompt.contains("\"author | date UTC | #N\""))
        XCTAssertTrue(prompt.contains("[title](url/N)"))
    }

    // MARK: Topic facts

    func testTopicFactsFromTheCurrentSolvedPlugin() throws {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(DiscourseFixtures.topic.utf8)) as? [String: Any]
        )
        let facts = ForumService.parseTopicFacts(json)
        XCTAssertEqual(facts.acceptedAnswer, ForumTopicFacts.AcceptedAnswer(postNumber: 5, username: "bob"))
        XCTAssertEqual(facts.postsCount, 10)
        XCTAssertEqual(facts.highestPostNumber, 14)
        XCTAssertEqual(facts.stream.count, 13)
        XCTAssertEqual(facts.openingPoster, "alice")
        XCTAssertEqual(facts.posts.map(\.number), [1, 2, 4, 5, 6, 7])
        // `like_count` is null for visitors; the like action count is used.
        XCTAssertEqual(facts.posts.map(\.likeCount), [2, 1, 1, 6, 3, 0])

        // Ids by number: exact for included posts; past them, counted from
        // the nearest included post (post 3 is gone, so the stream index of
        // post 10 is 8, not 9).
        XCTAssertEqual(facts.postID(forNumber: 5), 1172723)
        XCTAssertNil(facts.postID(forNumber: 3))
        XCTAssertNil(facts.postID(forNumber: 10))
        XCTAssertEqual(facts.likelyPostID(forNumber: 10), 1198342)
        XCTAssertEqual(facts.likelyPostID(forNumber: 99), 1534270)
    }

    func testTopicFactsFromOlderSolvedVersionsAndUnsolvedTopics() throws {
        func facts(_ text: String) throws -> ForumTopicFacts {
            ForumService.parseTopicFacts(
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            )
        }
        // The older plugin sends one `accepted_answer` object.
        let older = try facts(#"""
        {"posts_count":3,"accepted_answer":{"post_number":3,"username":"erin","excerpt":"Fixed"},
         "post_stream":{"stream":[11,12,13],"posts":[{"id":11,"post_number":1,"username":"frank","like_count":4}]}}
        """#)
        XCTAssertEqual(older.acceptedAnswer, ForumTopicFacts.AcceptedAnswer(postNumber: 3, username: "erin"))
        XCTAssertEqual(older.openingPoster, "frank")
        XCTAssertEqual(older.posts.first?.likeCount, 4)

        // Only the post carries the flag.
        let flagged = try facts(#"""
        {"post_stream":{"stream":[21,22],"posts":[
          {"id":21,"post_number":1,"username":"frank","accepted_answer":false,"topic_accepted_answer":true},
          {"id":22,"post_number":2,"username":"grace","accepted_answer":true,"topic_accepted_answer":true}]}}
        """#)
        XCTAssertEqual(flagged.acceptedAnswer, ForumTopicFacts.AcceptedAnswer(postNumber: 2, username: "grace"))
        XCTAssertNil(flagged.posts[0].likeCount)

        // `topic_accepted_answer` alone does not make a post the answer.
        let unsolved = try facts(#"""
        {"post_stream":{"stream":[31],"posts":[{"id":31,"post_number":1,"username":"frank","topic_accepted_answer":true}]}}
        """#)
        XCTAssertNil(unsolved.acceptedAnswer)
        XCTAssertNil(unsolved.postsCount)
    }

    func testOverviewAndFetchCarryTheFactsWithoutAnotherRequest() async throws {
        PostLevelURLStub.handler = { request in
            PostLevelURLStub.requests.append(request.url!)
            switch request.url!.path {
            case "/t/240488.json": return (200, DiscourseFixtures.topic)
            case "/raw/240488": return (200, "alice | 2022-10-02 10:00:00 UTC | #1\n\nHow do I hide it?")
            default: return (404, "missing")
            }
        }
        let service = makeService()
        let overview = try await service.fetchOverview(siteURL: site, topicID: "240488", cookieHeader: nil)
        XCTAssertEqual(overview.facts?.acceptedAnswer?.postNumber, 5)
        XCTAssertEqual(overview.postCount, 14)

        PostLevelURLStub.requests = []
        let fetch = try await service.fetchTopic(
            siteURL: site, topicID: "240488", cachedPages: [], knownTotalPosts: nil, cookieHeader: nil
        ) { _ in }
        XCTAssertEqual(fetch.facts?.openingPoster, "alice")
        XCTAssertEqual(fetch.totalPosts, 14)
        XCTAssertEqual(PostLevelURLStub.requests.map(\.path), ["/t/240488.json", "/raw/240488"])
    }

    // MARK: Posts by id

    func testPostsByIDAreParsedAsPlainTextInPostOrder() async throws {
        PostLevelURLStub.handler = { request in
            PostLevelURLStub.requests.append(request.url!)
            return (200, DiscourseFixtures.posts)
        }
        let service = makeService()
        let posts = try await service.fetchPosts(
            siteURL: folder, topicID: "240488", postIDs: [1198342, 1172723], cookieHeader: "_t=session"
        )
        XCTAssertEqual(posts.map(\.number), [5, 10])
        XCTAssertEqual(posts.map(\.username), ["bob", "bob"])
        XCTAssertEqual(posts.map(\.likeCount), [6, 1])
        XCTAssertEqual(posts[0].text, """
        Hello,

        You can hide it with this.

        .sidebar-section-link-wrapper {
          .sidebar-section-link.sidebar-section-link-badges {
            display: none;
          }
        }
        """)
        XCTAssertEqual(posts[1].text, """
        This still works for me on the latest version.

        Can you share your code? Q&A — thanks…
        """)

        let url = try XCTUnwrap(PostLevelURLStub.requests.first)
        XCTAssertEqual(url.path, "/forum/t/240488/posts.json")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(items, [
            URLQueryItem(name: "post_ids[]", value: "1198342"),
            URLQueryItem(name: "post_ids[]", value: "1172723")
        ])
        XCTAssertEqual(PostLevelURLStub.cookies, ["_t=session"])
    }

    func testPostsByNumberResolveIdsFromTheFactsAndDropWrongGuesses() async throws {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(DiscourseFixtures.topic.utf8)) as? [String: Any]
        )
        let facts = ForumService.parseTopicFacts(json)
        PostLevelURLStub.handler = { request in
            PostLevelURLStub.requests.append(request.url!)
            return (200, DiscourseFixtures.posts)
        }
        let service = makeService()
        // 5 is an included post; 10 is counted from post 7.
        let posts = try await service.fetchPosts(
            siteURL: site, topicID: "240488", numbers: [10, 5], facts: facts, cookieHeader: nil
        )
        XCTAssertEqual(posts.map(\.number), [5, 10])
        let items = URLComponents(url: try XCTUnwrap(PostLevelURLStub.requests.first), resolvingAgainstBaseURL: false)?
            .queryItems?.map(\.value)
        XCTAssertEqual(items, ["1198342", "1172723"])

        // The stub answers with posts 5 and 10 again: 10 was not asked for
        // (as when a guessed id lands on another post), so it is dropped.
        let missing = try await service.fetchPosts(
            siteURL: site, topicID: "240488", numbers: [5, 11], facts: facts, cookieHeader: nil
        )
        XCTAssertEqual(missing.map(\.number), [5])
    }

    // MARK: URL builders

    func testPostAndFilteredTopicURLs() throws {
        for base in [site, folder] {
            let prefix = base + "/t/hide-badges/42"
            XCTAssertEqual(
                ForumSite.topicURL(siteURL: base, topicID: "42", slug: "hide-badges", postNumber: 7)?.absoluteString,
                prefix + "/7"
            )
            XCTAssertEqual(
                ForumSite.topicURL(siteURL: base, topicID: "42", postNumber: 3)?.absoluteString,
                base + "/t/42/3"
            )
            XCTAssertEqual(
                ForumSite.topicURL(siteURL: base, topicID: "42", slug: "hide-badges", filter: .summary)?.absoluteString,
                prefix + "?filter=summary"
            )
            XCTAssertEqual(
                ForumSite.topicURL(siteURL: base, topicID: "42", slug: "hide-badges", filter: .username("bob"))?.absoluteString,
                prefix + "?username_filters=bob"
            )
            XCTAssertEqual(
                ForumSite.topicJSONURL(siteURL: base, topicID: "42", filter: .summary)?.absoluteString,
                base + "/t/42.json?filter=summary"
            )
            XCTAssertEqual(
                ForumSite.topicJSONURL(siteURL: base, topicID: "42", filter: .username("bob"))?.absoluteString,
                base + "/t/42.json?username_filters=bob"
            )
        }
        XCTAssertNil(ForumSite.topicURL(siteURL: site, topicID: "42", postNumber: 0))
        XCTAssertNil(ForumSite.topicURL(siteURL: site, topicID: "x", postNumber: 2))
        XCTAssertNil(ForumSite.topicPostsJSONURL(siteURL: site, topicID: "42", postIDs: []))
        XCTAssertNil(ForumSite.topicPostsJSONURL(siteURL: site, topicID: "42", postIDs: [0]))
        // A name that needs escaping stays one query value.
        let escaped = try XCTUnwrap(ForumSite.topicURL(siteURL: site, topicID: "42", filter: .username("a&b c")))
        XCTAssertEqual(
            URLComponents(url: escaped, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "username_filters", value: "a&b c")]
        )
    }

    func testPostNumberIsReadOnlyRightAfterTheTopicID() {
        func number(_ text: String) -> Int? { ForumSite.postNumber(from: URL(string: text)!) }
        XCTAssertEqual(number("https://f.example/t/slug/42/5"), 5)
        XCTAssertEqual(number("https://f.example/t/42/5"), 5)
        XCTAssertEqual(number("https://f.example/forum/t/slug/42/17/?u=bob#reply"), 17)
        XCTAssertNil(number("https://f.example/t/slug/42"))
        XCTAssertNil(number("https://f.example/t/slug/42/last"))
        XCTAssertNil(number("https://f.example/t/slug/42?page=2"))
        XCTAssertNil(number("https://f.example/latest"))
        // Building and reading agree, with a base path too.
        let url = ForumSite.topicURL(siteURL: folder, topicID: "42", slug: "s", postNumber: 9)!
        XCTAssertEqual(ForumSite.postNumber(from: url), 9)
        XCTAssertEqual(ForumSite.looseTopicID(from: url), "42")
    }

    // MARK: Helpers

    private func makeService() -> ForumService {
        PostLevelURLStub.requests = []
        PostLevelURLStub.cookies = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PostLevelURLStub.self]
        return ForumService(
            session: URLSession(configuration: configuration),
            pacer: ForumRequestPacer(clock: InstantPacingClock())
        )
    }
}

/// Answers with `handler(request)`, recording the URLs and cookies sent.
final class PostLevelURLStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, String))?
    nonisolated(unsafe) static var requests: [URL] = []
    nonisolated(unsafe) static var cookies: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let cookie = request.value(forHTTPHeaderField: "Cookie") { Self.cookies.append(cookie) }
        let (status, body) = Self.handler?(request) ?? (404, "")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
