import XCTest
@testable import Forumind

final class AssistantSourcesTests: XCTestCase {
    private let site = "https://meta.discourse.org"
    private let parse = AgentSources.Parse { DiscourseLinks().parse($0, basePath: "") }

    func testTwoForumsOnOneHostAreDifferentTopics() {
        // The same topic id under two subfolders (or two hosts) is not one source.
        let folderA = AgentSources.Parse(basePath: "/a") { DiscourseLinks().parse($0, basePath: "/a") }
        let answer = "[x](https://example.com/a/t/s/5) [y](https://example.com/a/t/s/5/2) [z](https://example.com/b/t/s/5)"
        XCTAssertEqual(
            AgentSources.topicIdentity(of: URL(string: "https://example.com/a/t/s/5")!, parse: folderA),
            AgentSources.topicIdentity(of: URL(string: "https://EXAMPLE.com/a/t/other/5/9")!, parse: folderA)
        )
        XCTAssertNotEqual(
            AgentSources.topicIdentity(of: URL(string: "https://example.com/a/t/s/5")!, parse: folderA),
            AgentSources.topicIdentity(of: URL(string: "https://other.example.com/a/t/s/5")!, parse: folderA)
        )
        // /b/ is not under /a: it does not parse, so it stays its own source by address.
        XCTAssertEqual(AgentSources.extract(from: answer, run: nil, sessions: [:], parse: folderA).count, 3)
    }

    func testCitationsAreNumberedInOrderAndDeduplicated() {
        let answer = """
        First [Unified new](https://meta.discourse.org/t/unified-new/404728), then \
        [Sidebar](https://meta.discourse.org/t/sidebar/413150/3) and again \
        [the same topic](https://meta.discourse.org/t/unified-new/404728?u=bob) and \
        [the same post](https://meta.discourse.org/t/sidebar/413150/3/).
        """
        let sources = AgentSources.extract(from: answer, run: nil, sessions: [:], parse: parse)
        XCTAssertEqual(sources.map(\.number), [1, 2])
        XCTAssertEqual(sources.map(\.title), ["Unified new", "Sidebar"])
        XCTAssertEqual(sources.map(\.postNumber), [nil, 3])
        XCTAssertEqual(sources.map { parse($0.url)?.topicID }, ["404728", "413150"])
        XCTAssertTrue(sources.allSatisfy(\.cited))

        let annotated = AgentSources.annotate(answer, sources: sources, parse: parse)
        XCTAssertTrue(annotated.contains("Unified new [S1](https://meta.discourse.org/t/unified-new/404728)"))
        XCTAssertTrue(annotated.contains("Sidebar [S2](https://meta.discourse.org/t/sidebar/413150/3)"))
        XCTAssertTrue(annotated.contains("the same topic [S1](https://meta.discourse.org/t/unified-new/404728?u=bob)"))
        XCTAssertTrue(annotated.contains("the same post [S2](https://meta.discourse.org/t/sidebar/413150/3/)"))
    }

    func testDifferentPostsOfOneTopicAreDifferentSources() {
        let answer = """
        The fix is in [post 5](https://meta.discourse.org/t/hide-badges/240488/5); \
        [post 10](https://meta.discourse.org/t/hide-badges/240488/10) confirms it.
        """
        let sources = AgentSources.extract(from: answer, run: nil, sessions: [:], parse: parse)
        XCTAssertEqual(sources.map(\.postNumber), [5, 10])
        XCTAssertEqual(sources.map(\.url.absoluteString), [
            "https://meta.discourse.org/t/hide-badges/240488/5",
            "https://meta.discourse.org/t/hide-badges/240488/10"
        ])
        let annotated = AgentSources.annotate(answer, sources: sources, parse: parse)
        XCTAssertTrue(annotated.contains("post 5 [S1]("))
        XCTAssertTrue(annotated.contains("post 10 [S2]("))
    }

    func testTopicLevelCitationsFoldIntoTheTopicsFirstSource() {
        // Post first: a later link to the whole topic reuses it.
        let postFirst = """
        [The fix](https://meta.discourse.org/t/hide-badges/240488/5), see \
        [the thread](https://meta.discourse.org/t/hide-badges/240488).
        """
        let folded = AgentSources.extract(from: postFirst, run: nil, sessions: [:], parse: parse)
        XCTAssertEqual(folded.map(\.postNumber), [5])
        XCTAssertTrue(AgentSources.annotate(postFirst, sources: folded, parse: parse).contains("the thread [S1]("))

        // Topic first: a later post keeps its own number.
        let topicFirst = """
        [The thread](https://meta.discourse.org/t/hide-badges/240488) has \
        [the fix](https://meta.discourse.org/t/hide-badges/240488/5) and \
        [the thread again](https://meta.discourse.org/t/240488).
        """
        let separate = AgentSources.extract(from: topicFirst, run: nil, sessions: [:], parse: parse)
        XCTAssertEqual(separate.map(\.postNumber), [nil, 5])
        let annotated = AgentSources.annotate(topicFirst, sources: separate, parse: parse)
        XCTAssertTrue(annotated.contains("the fix [S2]("))
        XCTAssertTrue(annotated.contains("the thread again [S1]("))
    }

    func testReadTopicsAlreadyCitedAtPostLevelAreNotAddedAgain() throws {
        let url = try XCTUnwrap(URL(string: "\(site)/t/hide-badges/240488"))
        let session = TopicSession(siteURL: site, topicID: "240488", url: url, title: "Hide badges")
        var run = AgentRun(siteURL: site, goal: "Goal", provider: .openAI, model: "m")
        run.steps = [AgentStep(tool: "read_topic", topicID: "240488", topicKey: session.topicKey)]
        let answer = "Use [the CSS](https://meta.discourse.org/t/hide-badges/240488/5)."

        let sources = AgentSources.extract(from: answer, run: run, sessions: [session.topicKey: session], parse: parse)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].postNumber, 5)
        XCTAssertTrue(sources[0].cited)
    }

    func testReadButUncitedTopicsFollowCitedOnes() throws {
        let url = try XCTUnwrap(URL(string: "\(site)/t/markdown-endpoints/413006"))
        let session = TopicSession(siteURL: site, topicID: "413006", url: url, title: "Markdown endpoints")
        var run = AgentRun(siteURL: site, goal: "Goal", provider: .openAI, model: "m")
        run.steps = [AgentStep(tool: "read_topic", topicID: "413006", topicKey: session.topicKey)]
        let answer = "See [Unified new](https://meta.discourse.org/t/unified-new/404728)."

        let sources = AgentSources.extract(from: answer, run: run, sessions: [session.topicKey: session], parse: parse)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[1].label, "S2")
        XCTAssertEqual(sources[1].title, "Markdown endpoints")
        XCTAssertNil(sources[1].postNumber)
        XCTAssertFalse(sources[1].cited)
    }

    func testBareSourceLabelsAreNotDuplicated() {
        let answer = "Backoff helps [S1](https://meta.discourse.org/t/backoff/1)."
        let sources = AgentSources.extract(from: answer, run: nil, sessions: [:], parse: parse)
        XCTAssertEqual(AgentSources.annotate(answer, sources: sources, parse: parse), answer)
    }

    func testAnswerWithoutLinksIsUnchanged() {
        let answer = "No sources here."
        XCTAssertTrue(AgentSources.extract(from: answer, run: nil, sessions: [:], parse: parse).isEmpty)
        XCTAssertEqual(AgentSources.annotate(answer, sources: [], parse: parse), answer)
    }
}
