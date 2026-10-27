import XCTest
@testable import Forumind

/// Jobs read through the site adapter (S4): a summary runs end to end on a
/// made-up platform, and a site with no adapter fails foreground work with
/// `noForum` and is skipped by the watch check.
@MainActor
final class SiteJobTests: XCTestCase {
    private let fakeSite = "https://fake.example.com"
    private let ghostSite = "https://ghost.example.com"

    private struct Harness {
        let app: AppModel
        let ai: StateAIStub
    }

    private func makeHarness(
        forums: [Forum],
        watched: [WatchedTopic] = [],
        fake: FakeSiteAdapter = FakeSiteAdapter(),
        planner: AgentPlanner? = nil
    ) -> Harness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var snapshot = AppSnapshot(watchedTopics: watched, forums: forums)
        snapshot.settings.watchAutoRefreshSummaries = false
        try? store.save(snapshot)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(
            store: store,
            forumService: ForumService(),
            sites: SiteRegistry(adapters: [DiscourseAdapter(), fake]),
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
        return Harness(app: app, ai: ai)
    }

    private func topic(_ site: String, id: String = "42") -> ForumTopic {
        ForumTopic(siteURL: site, topicID: id, url: URL(string: "\(site)/topic/\(id)")!, title: "Topic \(id)")
    }

    func testFakeAdapterReadDrivesASummaryEndToEnd() async throws {
        let harness = makeHarness(forums: [Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake")])
        XCTAssertTrue(harness.app.enqueueSummary(for: topic(fakeSite)))
        try await waitUntil { harness.app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(harness.app.activities.first?.status, .completed)
        XCTAssertEqual(harness.ai.calls.map(\.kind), ["summary"])
        XCTAssertTrue(harness.ai.calls[0].content.contains("Opening post of the fake topic."))
        let session = try XCTUnwrap(harness.app.sessions.values.first)
        XCTAssertEqual(session.rawPages.map(\.content), [FakeSiteAdapter.pageContent])
        XCTAssertEqual(session.totalPosts, 2)
    }

    func testRemovingTheForumMidReadLetsTheJobFinishAndFailsQueuedWork() async throws {
        let gate = ReadGate()
        var fake = FakeSiteAdapter()
        fake.readGate = gate
        let harness = makeHarness(forums: [Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake")], fake: fake)
        XCTAssertTrue(harness.app.enqueueSummary(for: topic(fakeSite, id: "42")))
        try await waitUntil { gate.hasWaiter }
        XCTAssertTrue(harness.app.enqueueSummary(for: topic(fakeSite, id: "43")))
        XCTAssertEqual(harness.app.activities.first { $0.topicID == "43" }?.status, .queued)

        harness.app.removeForum(try XCTUnwrap(harness.app.forum(for: fakeSite)), deleteData: false)
        gate.release()
        try await waitUntil { harness.app.activities.allSatisfy(\.status.isTerminal) }

        // The running job kept its adapter and finished; the queued one never started.
        let running = try XCTUnwrap(harness.app.activities.first { $0.topicID == "42" })
        XCTAssertEqual(running.status, .completed, running.error)
        XCTAssertEqual(harness.app.sessions.values.first { $0.topicID == "42" }?.totalPosts, 2)
        let queued = try XCTUnwrap(harness.app.activities.first { $0.topicID == "43" })
        XCTAssertEqual(queued.status, .failed)
        XCTAssertEqual(queued.error, AssistantError.noForum.localizedDescription)
    }

    func testAPlaceholderForumIsNeverStoredPinnedOrOpened() throws {
        let harness = makeHarness(forums: [Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake")])
        let app = harness.app
        app.openForum(try XCTUnwrap(app.forum(for: fakeSite)))
        let placeholder = app.forumInfo(siteURL: ghostSite)
        XCTAssertEqual(placeholder.kind, .unknown)

        app.pin(placeholder)
        app.openForum(placeholder)
        XCTAssertNil(app.forum(for: ghostSite))
        XCTAssertEqual(app.currentSiteURL, fakeSite)
        XCTAssertEqual(app.browser.homeSiteURL, fakeSite)

        // The directory refuses it, and repairs a stored one when the real kind arrives.
        var directory = ForumDirectory()
        XCTAssertNil(directory.upsert(siteURL: ghostSite, kind: .unknown, name: "Ghost", iconURL: nil))
        XCTAssertTrue(directory.forums.isEmpty)
        directory.forums = [Forum(siteURL: ghostSite, kind: .unknown, name: "Ghost")]
        let repaired = directory.upsert(siteURL: ghostSite, kind: .discourse, name: nil, iconURL: nil)
        XCTAssertEqual(repaired?.kind, .discourse)
        directory.upsert(siteURL: ghostSite, kind: .unknown, name: nil, iconURL: nil)
        XCTAssertEqual(directory.forum(siteURL: ghostSite)?.kind, .discourse)
    }

    func testSummaryOnASiteWithoutAnAdapterFailsWithNoForum() async throws {
        let harness = makeHarness(forums: [Forum(siteURL: ghostSite, kind: SiteKind("ghost"), name: "Ghost")])
        XCTAssertTrue(harness.app.enqueueSummary(for: topic(ghostSite)))
        try await waitUntil { harness.app.activities.allSatisfy(\.status.isTerminal) }
        let record = try XCTUnwrap(harness.app.activities.first)
        XCTAssertEqual(record.status, .failed)
        XCTAssertEqual(record.error, AssistantError.noForum.localizedDescription)
        XCTAssertTrue(harness.ai.calls.isEmpty)
    }

    func testAgentRunOnASiteWithoutAnAdapterFailsWithNoForum() async throws {
        let harness = makeHarness(forums: [Forum(siteURL: ghostSite, kind: SiteKind("ghost"), name: "Ghost")])
        harness.app.startAgentRun(goal: "What is new?", siteURL: ghostSite)
        try await waitUntil { harness.app.agentRuns.first?.isFinished ?? false }
        XCTAssertEqual(harness.app.agentRuns.first?.result, .failed)
        XCTAssertEqual(harness.app.agentRuns.first?.error, AssistantError.noForum.localizedDescription)
        XCTAssertEqual(harness.app.activities.first?.status, .failed)
    }

    func testWatchCheckReadsThroughTheAdapterAndSkipsASiteWithoutOne() async throws {
        func watched(_ site: String) -> WatchedTopic {
            WatchedTopic(siteURL: site, topicID: "42", url: URL(string: "\(site)/topic/42")!, title: "Topic 42", knownPostCount: 1)
        }
        let harness = makeHarness(
            forums: [
                Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake"),
                Forum(siteURL: ghostSite, kind: SiteKind("ghost"), name: "Ghost")
            ],
            watched: [watched(fakeSite), watched(ghostSite)]
        )
        await harness.app.checkWatchedTopics(reason: .manual)
        let fake = try XCTUnwrap(harness.app.watchedTopics.first { $0.siteURL == fakeSite })
        XCTAssertEqual(fake.newReplies, 1, "the fake adapter's overview says 2 posts")
        XCTAssertNotNil(fake.lastCheckedAt)
        let ghost = try XCTUnwrap(harness.app.watchedTopics.first { $0.siteURL == ghostSite })
        XCTAssertEqual(ghost.newReplies, 0)
        XCTAssertNil(ghost.lastCheckedAt, "skipped quietly, not marked as a failed check")
    }

    // MARK: Agent (S10)

    func testAnAgentRunOnAnotherToolsetOffersAndRunsThatToolset() async throws {
        var fake = FakeSiteAdapter()
        fake.queryResult = SiteQueryResult(topics: [
            ForumTopicListing(
                siteURL: fakeSite, id: 42, title: "Topic 42", slug: "42",
                url: URL(string: "\(fakeSite)/topic/42")!, postsCount: 2
            )
        ])
        let planner = ScriptedAgentPlanner(actions: [
            // Not this site's tool: refused, with the run's own list.
            AgentAction(thought: "", tool: "list_latest", arguments: [:]),
            AgentAction(thought: "", tool: "search_comments", arguments: ["query": "fees"]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "42"]),
            AgentAction(
                thought: "", tool: AgentPrompt.finalAnswerTool,
                arguments: ["answer": "See [Topic 42](\(fakeSite)/topic/42#p2) and [again](\(fakeSite)/topic/42)."]
            )
        ])
        let harness = makeHarness(
            forums: [Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake")],
            fake: fake,
            planner: planner
        )
        harness.app.startAgentRun(goal: "What is said about fees?", siteURL: fakeSite)
        try await waitUntil { harness.app.agentRuns.first?.isFinished ?? false }
        let run = try XCTUnwrap(harness.app.agentRuns.first)
        XCTAssertEqual(run.result, .completed, run.error)

        // The prompt is the profile's, with the fake's tool and no Discourse one.
        let system = planner.system
        XCTAssertTrue(system.contains("(\(fakeSite)), a fake site."))
        XCTAssertTrue(system.contains("- search_comments — Search the comments of this site."))
        XCTAssertTrue(system.contains("Prefer search_comments first"))
        XCTAssertTrue(system.contains("Cite a specific post as the thread url plus #pN."))
        XCTAssertFalse(system.contains("list_latest"))
        XCTAssertFalse(system.contains("search_forum"))
        XCTAssertFalse(system.contains("Discourse"))

        // A tool outside the run's set is an error that lists the run's own tools.
        let refused = try XCTUnwrap(planner.transcripts[1].last?.content)
        XCTAssertEqual(
            refused,
            "ERROR from list_latest:\nUnknown tool \"list_latest\". Available: search_comments, read_topic, "
                + "summarize_topic, saved_summaries, watch_topic, final_answer"
        )
        // The site tool ran through the fake's query and result, the read through its link hint.
        let search = try XCTUnwrap(planner.transcripts[2].last?.content)
        XCTAssertTrue(search.contains("- id 42: Topic 42"), search)
        let read = try XCTUnwrap(planner.transcripts[3].last?.content)
        XCTAssertTrue(read.contains("(post N: \(fakeSite)/topic/42#pN)"), read)
        XCTAssertEqual(run.steps.map(\.tool), ["list_latest", "search_comments", "read_topic", AgentPrompt.finalAnswerTool])

        // The answer's links parse through the fake's `links`: the post and the topic fold.
        let parse = harness.app.linkParser(siteURL: fakeSite)
        let sources = AgentSources.extract(from: run.answer, run: run, sessions: harness.app.sessions, parse: parse)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources.first?.postNumber, 2)
        XCTAssertEqual(parse(try XCTUnwrap(sources.first?.url))?.topicID, "42")
    }

    /// Items, digest cards and podcast chapters of another platform build that
    /// platform's URLs (a post is `#pN`, a topic has no slug).
    func testLinksOfAnItemACardAndAChapterComeFromTheirSitesAdapter() {
        let app = makeHarness(forums: [Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake")]).app
        let item = BrowseItem(kind: .post, siteURL: fakeSite, topicID: "42", slug: "ignored", postNumber: 2, title: "T")
        XCTAssertEqual(app.url(for: item)?.absoluteString, "\(fakeSite)/topic/42#p2")
        var topicItem = item
        topicItem.postNumber = nil
        XCTAssertEqual(app.url(for: topicItem)?.absoluteString, "\(fakeSite)/topic/42")

        let card = DigestCard(siteURL: fakeSite, topicID: "42", title: "T", reason: .trending, postCount: 99)
        XCTAssertEqual(app.url(for: card).absoluteString, "\(fakeSite)/topic/42")
        XCTAssertEqual(app.url(for: card, atPost: 3).absoluteString, "\(fakeSite)/topic/42#p3")
        XCTAssertNil(app.topPostsURL(for: card), "The fake has no filtered views")

        var chapter = PodcastChapter(card: card)
        chapter.postNumber = 4
        XCTAssertEqual(app.url(for: chapter)?.absoluteString, "\(fakeSite)/topic/42#p4")

        // No adapter: no link, and a card falls back to the forum's address.
        let ghost = makeHarness(forums: [Forum(siteURL: ghostSite, kind: SiteKind("ghost"), name: "Ghost")]).app
        XCTAssertNil(ghost.url(for: BrowseItem(kind: .post, siteURL: ghostSite, topicID: "1", postNumber: 1, title: "")))
        XCTAssertEqual(ghost.url(for: DigestCard(siteURL: ghostSite, topicID: "1", title: "", reason: .trending, postCount: 1)).absoluteString, ghostSite)
    }

    func testAgentSourcesParseThroughTheGivenAdapter() {
        let post = URL(string: "\(fakeSite)/topic/42#p3")!
        let parse = AgentSources.Parse { FakeLinks().parse($0, basePath: "") }
        let answer = "[a](\(post.absoluteString)) [b](\(fakeSite)/topic/42) [c](\(fakeSite)/topic/7)"
        let sources = AgentSources.extract(from: answer, run: nil, sessions: [:], parse: parse)
        XCTAssertEqual(sources.map(\.postNumber), [3, nil])
        XCTAssertEqual(sources.map(\.title), ["a", "c"])
        // Discourse's parser knows nothing of this site's URLs: every link is its own source.
        let discourse = AgentSources.Parse { DiscourseLinks().parse($0, basePath: "") }
        XCTAssertEqual(AgentSources.extract(from: answer, run: nil, sessions: [:], parse: discourse).count, 3)
    }

    private func waitUntil(
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Plays the model's actions in order, then answers; records the prompt and every turn's transcript.
private final class ScriptedAgentPlanner: AgentPlanner, @unchecked Sendable {
    private var actions: [AgentAction]
    private(set) var system = ""
    private(set) var transcripts: [[ChatMessage]] = []

    init(actions: [AgentAction]) {
        self.actions = actions
    }

    func nextAction(
        system: String,
        transcript: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws -> AgentAction {
        self.system = system
        transcripts.append(transcript)
        guard !actions.isEmpty else {
            return AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "n/a"])
        }
        return actions.removeFirst()
    }
}
