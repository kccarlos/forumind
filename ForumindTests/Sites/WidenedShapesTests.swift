import XCTest
@testable import Forumind

/// The shapes a second platform needs (P1 W5): search options, numberless
/// hits and listings, `invalidArgument`, the page revision and the tool
/// presentation table. Discourse's own output is pinned by the S0 goldens.
final class WidenedShapesTests: XCTestCase {
    private let site = "https://fake.example.com"

    private func listing(id: Int = 1, count: Int? = nil, last: String? = nil, excerpt: String? = nil) -> ForumTopicListing {
        ForumTopicListing(
            siteURL: site, id: id, title: "Title \(id)", slug: "s", url: URL(string: "\(site)/topic/\(id)")!,
            postsCount: count, lastPostedAt: last, excerpt: excerpt
        )
    }

    func testListingsPrintPostsOnlyWhenKnown() {
        XCTAssertEqual(
            AgentPrompt.format(listings: [listing(count: 12, last: "2026-10-01T10:00:00Z")]),
            "- id 1: Title 1 — 12 posts, last activity 2026-10-01 — \(site)/topic/1"
        )
        XCTAssertEqual(AgentPrompt.format(listings: [listing(count: 12)]), "- id 1: Title 1 — 12 posts — \(site)/topic/1")
        XCTAssertEqual(
            AgentPrompt.format(listings: [listing(last: "2026-10-01T10:00:00Z")]),
            "- id 1: Title 1 — last activity 2026-10-01 — \(site)/topic/1"
        )
        XCTAssertEqual(AgentPrompt.format(listings: [listing(excerpt: "Hi")]), "- id 1: Title 1 — \(site)/topic/1\n  Hi")
    }

    func testHitsPrintTheirNumberOrTheirAuthorAndDate() {
        func hit(_ number: Int?, user: String?, date: String? = nil, blurb: String? = "Text") -> ForumSearchHit {
            ForumSearchHit(
                topic: listing(count: 3), postNumber: number, username: user, blurb: blurb, postedAt: date,
                url: URL(string: "\(site)/topic/1#c\(number ?? 0)")!
            )
        }
        let text = AgentPrompt.format(listings: [listing(count: 3)], hits: [
            hit(4, user: "alice", date: "2026-10-02T00:00:00Z"),
            hit(nil, user: "bob", date: "2026-10-03T00:00:00Z"),
            hit(nil, user: nil, date: nil),
            hit(7, user: nil, blurb: nil)
        ])
        XCTAssertEqual(text, """
            - id 1: Title 1 — 3 posts — \(site)/topic/1
              #4 @alice: Text
              @bob (2026-10-03): Text
              Text
              #7

            \(AgentPrompt.unnumberedHitsNote)
            """)
    }

    func testHitIdentityFallsBackToTheURLWithoutANumber() {
        let numbered = ForumSearchHit(topic: listing(), postNumber: 5, url: URL(string: "\(site)/a")!)
        let comment = ForumSearchHit(topic: listing(), postNumber: nil, url: URL(string: "\(site)/a#comment-9")!)
        XCTAssertEqual(numbered.id, "1/5")
        XCTAssertEqual(comment.id, "\(site)/a#comment-9")
    }

    func testSearchOptionsDefaultToNothingAndTheCaseDefaultsThem() {
        XCTAssertEqual(SearchOptions(), SearchOptions(category: nil, after: nil, before: nil, page: 1))
        XCTAssertEqual(
            SiteQuery.search(text: "a", scope: .forum),
            SiteQuery.search(text: "a", scope: .forum, options: SearchOptions())
        )
        XCTAssertNotEqual(
            SiteQuery.search(text: "a", scope: .forum),
            SiteQuery.search(text: "a", scope: .forum, options: SearchOptions(page: 2))
        )
    }

    func testTheFakeProfileValidatesOptions() throws {
        let query = FakeSiteAdapter().agent.query
        guard case .search(_, _, let options) = try query(.searchComments, ["query": "q", "category": "News", "page": "3", "after": "2026-01-31"])
        else { return XCTFail() }
        XCTAssertEqual(options.category, "News")
        XCTAssertEqual(options.page, 3)
        XCTAssertNotNil(options.after)
        XCTAssertNil(options.before)
        for (arguments, name) in [
            (["query": "q", "page": "0"], "page"), (["query": "q", "page": "x"], "page"),
            (["query": "q", "before": "2026-1-5"], "before"), (["query": "q", "after": "2026-13-45"], "after")
        ] {
            XCTAssertThrowsError(try query(.searchComments, arguments), name) { error in
                guard case AgentError.invalidArgument(let invalid, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(invalid, name)
            }
        }
    }

    func testInvalidArgumentReadsTheSameToTheUserAndTheModel() {
        let error = AgentError.invalidArgument("page", reason: "use a number from 1 to 3.")
        XCTAssertEqual(error.modelDescription, "Invalid argument \"page\": use a number from 1 to 3.")
        XCTAssertEqual(error.errorDescription, error.modelDescription, "the test language is English")
    }

    func testARawPageRevisionRoundTripsAndOldDataLacksIt() throws {
        let page = RawForumPage(page: 1, content: "x", topicPostCount: 1, revision: "r1")
        let decoded = try JSONDecoder().decode(RawForumPage.self, from: JSONEncoder().encode(page))
        XCTAssertEqual(decoded.revision, "r1")
        let old = #"{"page":1,"content":"x","blocks":[]}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(RawForumPage.self, from: old).revision)
    }

    func testAListingWithoutACountDecodesAndEncodes() throws {
        let decoded = try JSONDecoder().decode(ForumTopicListing.self, from: JSONEncoder().encode(listing()))
        XCTAssertNil(decoded.postsCount)
        let legacy = try JSONDecoder().decode(ForumTopicListing.self, from: JSONEncoder().encode(listing(count: 4)))
        XCTAssertEqual(legacy.postsCount, 4)
    }

    func testEveryToolHasAPresentationRow() {
        for tool in AgentToolName.allCases {
            XCTAssertFalse(tool.symbol.isEmpty, tool.rawValue)
            XCTAssertFalse(tool.title(query: "q", topic: { "T" }).isEmpty, tool.rawValue)
        }
        XCTAssertEqual(AgentToolName.searchComments.symbol, "text.bubble")
        XCTAssertEqual(AgentToolName.searchComments.title(query: "fees", topic: { "T" }), "Searched comments for “fees”")
        XCTAssertEqual(AgentToolName.searchForum.title(query: "fees", topic: { "T" }), "Searched “fees”")
        XCTAssertEqual(AgentToolName.listLatest.title(query: "", topic: { "T" }), "Listed the latest")
        XCTAssertEqual(AgentToolName.readTopic.title(query: "", topic: { "T" }), "Read T")
        XCTAssertEqual(AgentToolName.finalAnswer.rawValue, AgentPrompt.finalAnswerTool)
        // Titles need no tool-specific string in the panel any more.
        XCTAssertEqual(AgentToolName.searchComments.tint, .search)
    }
}
