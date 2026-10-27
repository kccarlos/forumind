import XCTest
@testable import Forumind

/// P1 W8: Ask the forum on a WordPress site, end to end through `AppModel`
/// with a scripted model and `WordPressFixtureSite` as the network.
@MainActor
final class WordPressAgentRunTests: XCTestCase {
    private let site = WordPressFixtureSite.siteURL
    private let discourseSite = "https://forum.example.com"

    private struct Harness {
        let app: AppModel
        let planner: ScriptedAgentPlanner
        let wordpress: WordPressFixtureSite
    }

    private func makeHarness(
        wordpress: WordPressFixtureSite = WordPressFixtureSite(commentCount: 250),
        actions: [AgentAction]
    ) -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let snapshot = AppSnapshot(forums: [
            Forum(siteURL: site, kind: .wordpress, name: "Example Blog"),
            Forum(siteURL: discourseSite, kind: .discourse, name: "Forum")
        ])
        try? store.save(snapshot)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let planner = ScriptedAgentPlanner(actions: actions)
        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(
            store: store,
            forumService: wordpress.service(),
            sites: SiteRegistry(adapters: [DiscourseAdapter(), WordPressAdapter()]),
            aiService: ai,
            planner: planner
        )
        app.usesDirectForumRequests = true
        app.allowAllAIProviders()
        var provider = app.settings.configuration(for: .ollama)
        provider.apiKey = ""
        app.setConfiguration(provider, for: .ollama)
        app.selectModel(ModelSelection(provider: .ollama, model: "model-a"), for: .both)
        app.browser.onPageContextChanged = nil
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
        }
        return Harness(app: app, planner: planner, wordpress: wordpress)
    }

    private func finish(_ harness: Harness, goal: String = "What do readers say?", on siteURL: String? = nil) async throws -> AgentRun {
        harness.app.startAgentRun(goal: goal, siteURL: siteURL ?? site)
        let deadline = Date().addingTimeInterval(20)
        while !(harness.app.agentRuns.first?.isFinished ?? false) {
            guard Date() < deadline else {
                XCTFail("Timed out waiting")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(harness.app.agentRuns.first)
    }

    private func call(_ tool: String, _ arguments: [String: String] = [:]) -> AgentAction {
        AgentAction(thought: "", tool: tool, arguments: arguments)
    }

    private func answer(_ text: String) -> AgentAction {
        call(AgentPrompt.finalAnswerTool, ["answer": text])
    }

    func testSearchCommentsThenReadThenCiteBySlugPermalink() async throws {
        let wordpress = WordPressFixtureSite(comments: [
            WordPressFixtureSite.comment(1, author: "bob"),
            ["id": 6001, "post": 1002, "parent": 0, "author_name": "carol", "date_gmt": "2026-06-02T10:00:00",
             "content": ["rendered": "<p>Booked it with points</p>"]]
        ])
        let article = "https://example.com/2026/05/sample-cards-and-notes/"
        let harness = makeHarness(wordpress: wordpress, actions: [
            call("search_comments", ["query": "points"]),
            call("read_topic", ["topic_id": "1001"]),
            answer("Readers booked with points: [Hotel Points Guide](https://example.com/2026/p1002/#comment-6001). "
                + "See [the article](\(article)) and [elsewhere](https://other.example.org/x/).")
        ])
        let run = try await finish(harness)
        XCTAssertEqual(run.result, .completed, run.error)

        let hits = try XCTUnwrap(harness.planner.transcripts[1].last?.content)
        XCTAssertTrue(hits.hasPrefix("OBSERVATION from search_comments:\n- id 1002: Hotel Points Guide"), hits)
        XCTAssertTrue(hits.contains("@carol (2026-06-02): Booked it with points"), hits)
        let read = try XCTUnwrap(harness.planner.transcripts[2].last?.content)
        XCTAssertTrue(read.hasPrefix("OBSERVATION from read_topic:\nTopic: (Update) Sample Cards & Notes – Part 1\nURL: \(article) (article and comments: \(article))"), read)
        XCTAssertTrue(read.contains("Article: (Update) Sample Cards & Notes – Part 1"), read)

        // The run's tools showed these permalinks, so a citation of one resolves to its post.
        XCTAssertEqual(Set(run.knownLinks.values), ["1001", "1002"])
        let parse = harness.app.linkParser(for: run)
        let sources = AgentSources.extract(from: run.answer, run: run, sessions: harness.app.sessions, parse: parse)
        XCTAssertEqual(sources.map(\.topicID), ["1002", "1001", nil])
        XCTAssertEqual(sources.map(\.cited), [true, true, true])
        let adapter = try XCTUnwrap(harness.app.adapter(for: site))
        let items = sources.compactMap { BrowseItem(source: $0, siteURL: site, adapter: adapter) }
        XCTAssertEqual(items.map(\.topicID), ["1002", "1001"], "a link outside the site is not kept")
        // Without the run's map a slug permalink is just a link.
        XCTAssertNil(harness.app.linkParser(siteURL: site)(URL(string: article)!))
        XCTAssertEqual(
            AgentSources.annotate(run.answer, sources: sources, parse: parse)
                .contains("[the article](\(article))"),
            false
        )
    }

    func testAnUnreadListedPostStillResolvesAsASource() async throws {
        let harness = makeHarness(actions: [
            call("list_latest"),
            answer("See [Weekend Deals](https://example.com/2026/p1003).")
        ])
        let run = try await finish(harness)
        let sources = AgentSources.extract(
            from: run.answer, run: run, sessions: harness.app.sessions, parse: harness.app.linkParser(for: run)
        )
        XCTAssertEqual(sources.map(\.topicID), ["1003"], "a missing trailing slash still finds the listed permalink")
    }

    func testAClosedCommentSearchIsAnObservationAndTheRunContinues() async throws {
        let wordpress = WordPressFixtureSite(commentCount: 3)
        wordpress.respond { $0.path.hasSuffix("/comments") && $0.query["search"] != nil ? .init(status: 403, body: Data("{}".utf8)) : nil }
        let harness = makeHarness(wordpress: wordpress, actions: [
            call("search_comments", ["query": "approved"]),
            call("search_forum", ["query": "cards"]),
            answer("Done.")
        ])
        let run = try await finish(harness)
        XCTAssertEqual(run.result, .completed, run.error)
        XCTAssertEqual(
            harness.planner.transcripts[1].last?.content,
            "ERROR from search_comments:\nCOMMENTS_UNAVAILABLE: This site does not allow searching comments. Use search_forum and read_topic instead."
        )
        XCTAssertTrue(harness.planner.transcripts[2].last?.content.hasPrefix("OBSERVATION from search_forum:\n- id 1001:") ?? false)
        XCTAssertEqual(run.steps.map(\.isError), [true, false, false])
    }

    func testABadFilterAndAMissingPostAreRecoverable() async throws {
        let harness = makeHarness(actions: [
            call("search_forum", ["query": "x", "after": "last year"]),
            call("search_forum", ["query": "x", "category": "nothing"]),
            call("read_topic", ["topic_id": "999"]),
            answer("Done.")
        ])
        let run = try await finish(harness)
        XCTAssertEqual(run.result, .completed, run.error)
        let observations = harness.planner.transcripts.dropFirst().compactMap(\.last?.content)
        XCTAssertEqual(observations[0], "ERROR from search_forum:\nInvalid argument \"after\": use the form YYYY-MM-DD.")
        XCTAssertTrue(observations[1].contains("no category matches \"nothing\""), observations[1])
        XCTAssertTrue(observations[2].hasPrefix("ERROR from read_topic:"), observations[2])
    }

    func testALongThreadKeepsTheArticleAndTheNewestComments() async throws {
        let harness = makeHarness(actions: [call("read_topic", ["topic_id": "1001"]), answer("Done.")])
        let run = try await finish(harness)
        XCTAssertEqual(run.result, .completed, run.error)
        let read = try XCTUnwrap(harness.planner.transcripts[1].last?.content)
        XCTAssertTrue(read.contains("Article: (Update) Sample Cards & Notes – Part 1"), "the article is #1")
        XCTAssertTrue(read.contains("#251\nComment number 250 "), "the newest comment")
        XCTAssertEqual(harness.app.sessions.values.first?.totalPosts, 251)
    }

    func testPostTextComesFromTheLookupWhenNoPageIsOpen() async throws {
        let harness = makeHarness(actions: [])
        let ref = BrowseTopicRef(siteURL: site, topicID: "1001")
        let lookup = await harness.app.postText(102, in: ref, facts: TopicFacts(postsCount: 251, highestPostNumber: 251))
        XCTAssertEqual(lookup.text?.number, 102)
        XCTAssertEqual(lookup.text?.username, "user101")
        XCTAssertEqual(lookup.text?.text, "Comment number 101 … worth it?")
        let missing = await harness.app.postText(400, in: ref, facts: TopicFacts(postsCount: 251, highestPostNumber: 251))
        XCTAssertEqual(missing, .missing)
    }

    func testADiscourseRunCannotAskForSearchComments() async throws {
        let harness = makeHarness(actions: [call("search_comments", ["query": "x"]), answer("Done.")])
        let run = try await finish(harness, on: discourseSite)
        XCTAssertEqual(run.result, .completed, run.error)
        let refused = try XCTUnwrap(harness.planner.transcripts[1].last?.content)
        XCTAssertTrue(refused.hasPrefix("ERROR from search_comments:\nUnknown tool \"search_comments\". Available: search_forum, list_latest, read_topic"), refused)
        XCTAssertTrue(harness.wordpress.requests.isEmpty)
    }
}
