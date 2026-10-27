import XCTest
@testable import Forumind

final class RawTopicFormatTests: XCTestCase {
    private func date(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: hour, minute: minute, second: 7))!
    }

    private func block(_ number: Int, _ author: String) -> PostBlock {
        PostBlock(number: number, author: author, date: date(12, number), anchor: "\(number)", score: nil)
    }

    private func rendered(bodyLength: Int = 0) -> String {
        let filler = String(repeating: "word ", count: bodyLength)
        return RawTopicFormat.render([
            (block(1, "alice"), "Opening post. \(filler)"),
            (block(2, "bob smith"), "Reply from bob.\r\n\r\n\r\n\r\nStill bob. \(filler)"),
            (block(3, "alice"), "Alice again. \(filler)")
        ])
    }

    func testRenderThenParseRoundTrips() {
        let text = rendered()
        XCTAssertTrue(text.hasSuffix("\n"))
        let headers = RawTopicFormat.parseHeaders(text)
        XCTAssertEqual(headers.map(\.number), [1, 2, 3])
        XCTAssertEqual(headers.map(\.author), ["alice", "bob_smith", "alice"])
        XCTAssertEqual(headers.map(\.date), [date(12, 1), date(12, 2), date(12, 3)])
        XCTAssertEqual(
            RawTopicFormat.blocks(in: text).map(\.anchor), ["1", "2", "3"]
        )
        XCTAssertEqual(text.components(separatedBy: RawTopicFormat.blockSeparator).count, 3)
        XCTAssertFalse(text.contains("\r"))
        XCTAssertEqual(RawTopicFormat.authorToken("  "), "anonymous")
        XCTAssertEqual(
            RawTopicFormat.headerLine(for: block(1, "alice")),
            "alice | 2026-10-20 12:01:07 UTC | #1"
        )
    }

    func testModerationHidesABlockedAuthorsBlockExactly() {
        let text = rendered()
        let rules = ModerationRules(blockedUsers: ["https://example.com": ["bob_smith"]])
        let filtered = ModerationFilter.filter(text, siteURL: "https://example.com", topicID: "1", rules: rules)
        let expected = RawTopicFormat.render([
            (block(1, "alice"), "Opening post. "),
            (block(3, "alice"), "Alice again. ")
        ])
        XCTAssertEqual(filtered, expected)
    }

    func testChunksCutOnlyAtBlockBoundaries() {
        let text = RawTopicFormat.join((1...6).map { page in
            RawTopicFormat.render([(block(page, "alice"), String(repeating: "x", count: 380))])
        })
        let chunks = PromptBuilder.splitForHierarchicalSummary(text, limit: 1_000)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        for chunk in chunks.dropLast() {
            XCTAssertTrue(chunk.hasSuffix(RawTopicFormat.blockSeparator), "a chunk ends at a block boundary")
        }
    }

    func testLossyDecodeKeepsTheSummaryAndDropsPagesWithoutBlocks() throws {
        var session = TopicSession(
            siteURL: "https://example.com", topicID: "1",
            url: URL(string: "https://example.com/t/1")!, title: "T"
        )
        session.summary = "Kept summary"
        session.apply(
            ForumFetchResult(
                content: "text", rawPages: [RawForumPage(page: 1, content: "text", topicPostCount: 1, blocks: [block(1, "alice")])],
                totalPosts: 1, unchanged: false, newPosts: 1, facts: nil
            ),
            at: Date()
        )
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(try JSONDecoder().decode(TopicSession.self, from: data).rawPages.first?.blocks.count, 1)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var pages = try XCTUnwrap(object["rawPages"] as? [[String: Any]])
        pages[0].removeValue(forKey: "blocks")
        object["rawPages"] = pages
        let old = try JSONDecoder().decode(TopicSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.summary, "Kept summary")
        XCTAssertEqual(old.rawPages, [])
    }

    func testBlocksAreNotSynced() throws {
        var session = TopicSession(
            siteURL: "https://example.com", topicID: "1",
            url: URL(string: "https://example.com/t/1")!, title: "T"
        )
        session.rawPages = [RawForumPage(page: 1, content: "text", blocks: [block(1, "alice")])]
        let units = try XCTUnwrap(CloudSyncEngine.units(session: session, now: Date()))
        let encoded = String(data: try JSONEncoder().encode(units), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("blocks"))
        XCTAssertFalse(encoded.contains("rawPages"))
    }

    /// A read cut short keeps its pages with their blocks; after a relaunch
    /// the saved pages are what the next read reuses, so it asks for nothing.
    func testPagesWithBlocksSurviveAKillAndTheNextReadIsUnchanged() throws {
        var session = TopicSession(
            siteURL: "https://example.com", topicID: "1",
            url: URL(string: "https://example.com/t/1")!, title: "T"
        )
        let content = rendered()
        session.apply(page: RawForumPage(page: 1, content: content, topicPostCount: 3, blocks: RawTopicFormat.blocks(in: content)))
        let relaunched = try JSONDecoder().decode(TopicSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(relaunched.rawPages.first?.blocks.map(\.number), [1, 2, 3])
        XCTAssertEqual(relaunched.source, "", "source is the last complete read: untouched by a page")
        let plan = DiscoursePagePlan.make(
            cachedPages: relaunched.rawPages, knownTotalPosts: 3, currentTotalPosts: 3, totalPages: 1
        )
        XCTAssertEqual(plan, .unchanged)
    }
}
