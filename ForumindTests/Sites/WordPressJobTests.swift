import XCTest
@testable import Forumind

/// P1 W11: WordPress is registered. Jobs run end to end through `AppModel` on
/// the standard registry with `WordPressFixtureSite` as the network: add forum
/// through the REST root, summary, follow-up chat, watch check and an agent run
/// with `search_comments`; plus the page-context cases and the empty comment
/// pages of real sites.
@MainActor
final class WordPressJobTests: XCTestCase {
    private let siteURL = WordPressFixtureSite.siteURL

    private struct Harness {
        let app: AppModel
        let ai: StateAIStub
        let wordpress: WordPressFixtureSite
    }

    private func makeHarness(
        wordpress: WordPressFixtureSite = WordPressFixtureSite(commentCount: 250),
        forums: [Forum]? = nil,
        watched: [WatchedTopic] = [],
        planner: AgentPlanner? = nil
    ) -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var snapshot = AppSnapshot(
            watchedTopics: watched,
            forums: forums ?? [Forum(siteURL: siteURL, kind: .wordpress, name: "Example Blog")]
        )
        snapshot.settings.watchAutoRefreshSummaries = false
        try? store.save(snapshot)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(
            store: store,
            forumService: wordpress.service(),
            sites: .standard,
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
        return Harness(app: app, ai: ai, wordpress: wordpress)
    }

    private var topic: ForumTopic {
        ForumTopic(
            siteURL: siteURL, topicID: WordPressFixtureSite.postID,
            url: URL(string: "\(siteURL)/2026/05/sample-cards-and-notes/")!, title: "Sample Cards"
        )
    }

    private func waitUntil(timeout: TimeInterval = 20, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: Add forum

    func testAddingAForumFindsWordPressThroughItsRESTRoot() async throws {
        let harness = makeHarness(forums: [])
        let forum = try await harness.app.addForum(fromAddress: "example.com")
        XCTAssertEqual(forum.kind, .wordpress)
        XCTAssertEqual(forum.siteURL, siteURL)
        XCTAssertEqual(forum.name, "Example Blog & Notes")
        XCTAssertEqual(harness.app.forum(for: siteURL)?.kind, .wordpress)
        XCTAssertEqual(harness.app.adapter(for: siteURL)?.kind, .wordpress)
        // Discourse is asked first and refused; the root answers.
        XCTAssertTrue(harness.wordpress.requests.map(\.path).contains("/wp-json/"))

        // A post address finds the same site.
        let again = try await makeHarness(forums: []).app.addForum(fromAddress: "https://example.com/2026/05/slug/")
        XCTAssertEqual(again.kind, .wordpress)
        XCTAssertEqual(again.siteURL, siteURL)
    }

    // MARK: Summary, chat, watch

    func testASummaryThenAFollowUpChatReadTheArticleAndEveryComment() async throws {
        let harness = makeHarness()
        let app = harness.app
        app.select(topic: topic)
        XCTAssertTrue(app.enqueueSummary(for: topic))
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed, app.activities.first?.error ?? "")
        XCTAssertEqual(harness.ai.calls.map(\.kind), ["summary"])
        let content = harness.ai.calls[0].content
        XCTAssertTrue(content.contains("Comment number 250"), "all three comment pages are in the model's input")
        XCTAssertTrue(content.contains("Comment number 101"))
        let session = try XCTUnwrap(app.sessions[topic.topicKey])
        XCTAssertEqual(session.totalPosts, 251)
        XCTAssertEqual(harness.wordpress.commentPages, [1, 2, 3])

        app.drafts.chat = "What do readers think?"
        app.sendChat()
        try await waitUntil { app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(app.activities.first?.status, .completed, app.activities.first?.error ?? "")
        XCTAssertEqual(harness.ai.calls.last?.kind, "chat")
        XCTAssertEqual(app.sessions[topic.topicKey]?.history.last?.content, "Answer by ollama/model-a")
    }

    func testTheWatchCheckCountsNewCommentsFromTheOverview() async throws {
        let watched = WatchedTopic(
            siteURL: siteURL, topicID: WordPressFixtureSite.postID, url: topic.url, title: "Sample Cards", knownPostCount: 201
        )
        let harness = makeHarness(watched: [watched])
        await harness.app.checkWatchedTopics(reason: .manual)
        let checked = try XCTUnwrap(harness.app.watchedTopics.first)
        XCTAssertEqual(checked.newReplies, 50, "251 posts now, 201 known")
        XCTAssertNotNil(checked.lastCheckedAt)
    }

    // MARK: Agent

    func testAnAgentRunSearchesCommentsOnTheStandardRegistry() async throws {
        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "search_comments", arguments: ["query": "number 7"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Found it."])
        ])
        let harness = makeHarness(planner: planner)
        harness.app.startAgentRun(goal: "Who mentions 7?", siteURL: siteURL)
        try await waitUntil { harness.app.agentRuns.first?.isFinished ?? false }
        let run = try XCTUnwrap(harness.app.agentRuns.first)
        XCTAssertEqual(run.result, .completed, run.error)
        XCTAssertTrue(planner.system.contains("search_comments"))
        let hits = try XCTUnwrap(planner.transcripts[1].last?.content)
        XCTAssertTrue(hits.hasPrefix("OBSERVATION from search_comments:"), hits)
        XCTAssertTrue(hits.contains("Comment number 7"), hits)
    }

    // MARK: Page context (separate from the Discourse matrix)

    func testWordPressPageContextStates() throws {
        let registry = SiteRegistry.standard
        let postURL = URL(string: "https://example.com/2026/05/slug/")!
        let facts = PageFacts(
            url: postURL, meta: ["og:site_name": "Example Blog"],
            links: ["https://api.w.org/": "https://example.com/wp-json/", "shortlink": "https://example.com/?p=1001"],
            bodyClass: "post-template-default single postid-1001"
        )
        let post = PageContext.make(url: postURL, title: "Slug", facts: facts, knownForum: nil, registry: registry)
        XCTAssertEqual(post.state, .topic)
        XCTAssertEqual(post.site, .wordpress)
        XCTAssertEqual(post.siteURL, siteURL)
        XCTAssertEqual(post.forumName, "Example Blog")
        XCTAssertEqual(post.topic?.topicID, "1001")
        XCTAssertEqual(post.topic?.url.absoluteString, "https://example.com/2026/05/slug/", "the shown address, not the shortlink")

        let homeURL = URL(string: "https://example.com/")!
        let homeFacts = PageFacts(url: homeURL, links: ["https://api.w.org/": "https://example.com/wp-json/"])
        XCTAssertEqual(
            PageContext.make(url: homeURL, title: nil, facts: homeFacts, knownForum: nil, registry: registry).state,
            .forumHome
        )

        // Unchecked: only a root short link is a maybe; other sites' `?p=` pages are not.
        XCTAssertEqual(
            PageContext.make(url: URL(string: "https://example.com/?p=1001")!, title: nil, facts: nil, knownForum: nil, registry: registry).state,
            .maybe
        )
        for other in ["https://shop.example.org/list?p=3", "https://shop.example.org/forum/search?q=a&p=2"] {
            XCTAssertEqual(
                PageContext.make(url: URL(string: other)!, title: nil, facts: nil, knownForum: nil, registry: registry).state,
                .loading, other
            )
        }
        // A page of another site that was probed and has no WordPress facts is not a forum.
        let plain = URL(string: "https://shop.example.org/list?p=3")!
        XCTAssertEqual(
            PageContext.make(url: plain, title: nil, facts: PageFacts(url: plain), knownForum: nil, registry: registry).state,
            .notForum
        )
    }

    // MARK: Comment pages past the last

    /// Real sites answer a page past the last with 400 or with 200 `[]`: both are empty.
    func testACommentsPagePastTheLastIsEmptyAsA400AndAs200EmptyList() async throws {
        let replies: [WordPressFixtureSite.Reply] = [
            .init(status: 400, body: WordPressFixtureSite.fixture("error-invalid-page")),
            .init(headers: ["X-WP-Total": "150", "X-WP-TotalPages": "2"], body: Data("[]".utf8))
        ]
        for reply in replies {
            // The header promised two pages, the second came back empty.
            let site = WordPressFixtureSite(commentCount: 150)
            site.respond { $0.query["page"] == "2" && $0.path.hasSuffix("/comments") ? reply : nil }
            let result = try await WordPressAdapter().readTopic(
                TopicReadRequest(topic: TopicRef(siteURL: siteURL, topicID: "1001"), cachedPages: [], knownTotalPosts: nil),
                net: site.network(), progress: { _ in }, onPage: nil
            )
            XCTAssertEqual(result.rawPages.map(\.page), [1, 2], "status \(reply.status)")
            XCTAssertEqual(result.rawPages[1].blocks, [], "status \(reply.status)")

            // Without paging headers the probe ends on the empty page too.
            let probed = WordPressFixtureSite(commentCount: 200)
            probed.sendsTotalHeaders = false
            probed.respond { $0.query["page"] == "3" && $0.path.hasSuffix("/comments") ? reply : nil }
            let two = try await WordPressAdapter().readTopic(
                TopicReadRequest(topic: TopicRef(siteURL: siteURL, topicID: "1001"), cachedPages: [], knownTotalPosts: nil),
                net: probed.network(), progress: { _ in }, onPage: nil
            )
            XCTAssertEqual(two.totalPosts, 201, "status \(reply.status)")
            XCTAssertEqual(probed.commentPages, [1, 2, 3], "status \(reply.status)")
        }
    }
}
