import XCTest
@testable import Forumind

final class AssistantSourcesTests: XCTestCase {
    private let site = "https://meta.discourse.org"

    func testCitationsAreNumberedInOrderAndDeduplicatedByTopic() {
        let answer = """
        First [Unified new](https://meta.discourse.org/t/unified-new/404728), then \
        [Sidebar](https://meta.discourse.org/t/sidebar/413150/3) and again \
        [the same topic](https://meta.discourse.org/t/unified-new/404728/12).
        """
        let sources = AgentSources.extract(from: answer, run: nil, sessions: [:])
        XCTAssertEqual(sources.map(\.number), [1, 2])
        XCTAssertEqual(sources.map(\.title), ["Unified new", "Sidebar"])
        XCTAssertTrue(sources.allSatisfy(\.cited))

        let annotated = AgentSources.annotate(answer, sources: sources)
        XCTAssertTrue(annotated.contains("Unified new [S1](https://meta.discourse.org/t/unified-new/404728)"))
        XCTAssertTrue(annotated.contains("Sidebar [S2](https://meta.discourse.org/t/sidebar/413150/3)"))
        XCTAssertTrue(annotated.contains("the same topic [S1](https://meta.discourse.org/t/unified-new/404728/12)"))
    }

    func testReadButUncitedTopicsFollowCitedOnes() throws {
        let url = try XCTUnwrap(URL(string: "\(site)/t/markdown-endpoints/413006"))
        let session = TopicSession(siteURL: site, topicID: "413006", url: url, title: "Markdown endpoints")
        var run = AgentRun(siteURL: site, goal: "Goal", provider: .openAI, model: "m")
        run.steps = [AgentStep(tool: "read_topic", topicID: "413006", topicKey: session.topicKey)]
        let answer = "See [Unified new](https://meta.discourse.org/t/unified-new/404728)."

        let sources = AgentSources.extract(from: answer, run: run, sessions: [session.topicKey: session])
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[1].label, "S2")
        XCTAssertEqual(sources[1].title, "Markdown endpoints")
        XCTAssertFalse(sources[1].cited)
    }

    func testBareSourceLabelsAreNotDuplicated() {
        let answer = "Backoff helps [S1](https://meta.discourse.org/t/backoff/1)."
        let sources = AgentSources.extract(from: answer, run: nil, sessions: [:])
        XCTAssertEqual(AgentSources.annotate(answer, sources: sources), answer)
    }

    func testAnswerWithoutLinksIsUnchanged() {
        let answer = "No sources here."
        XCTAssertTrue(AgentSources.extract(from: answer, run: nil, sessions: [:]).isEmpty)
        XCTAssertEqual(AgentSources.annotate(answer, sources: []), answer)
    }
}
