import BackgroundTasks
import XCTest
@testable import Forumind

/// The daily digest: settings defaults, which topics go in (dedupe, ranking,
/// cap), the background prefetch's request cap and scheduling, and making
/// the cards (resumable, reusing saved summaries, no provider, offline).
@MainActor
final class DailyDigestTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let other = "https://other.example.org"

    override func setUp() async throws {
        StateForumStub.reset()
    }

    // MARK: Settings

    func testTheDigestIsOffByDefaultAndItsSwitchStaysOnTheDevice() throws {
        let settings = AppSettings()
        XCTAssertFalse(settings.dailyDigestEnabled)
        XCTAssertFalse(settings.dailyDigestNotifies)
        XCTAssertTrue(settings.dailyDigestIncludesWatched)
        XCTAssertTrue(settings.dailyDigestIncludesTrending)
        XCTAssertEqual(settings.dailyDigestMaxCards, 8)

        // Snapshots from before the digest decode with the defaults; an
        // out-of-range cap is clamped.
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(old.dailyDigestEnabled)
        XCTAssertEqual(old.dailyDigestMaxCards, DigestLimits.defaultCards)
        let large = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"dailyDigestMaxCards": 500}"#.utf8))
        XCTAssertEqual(large.dailyDigestMaxCards, DigestLimits.cardRange.upperBound)

        // Turning it on spends credits on this device only; what goes in syncs.
        XCTAssertTrue(SyncSettings.deviceLocalKeys.isSuperset(of: ["dailyDigestEnabled", "dailyDigestNotifies"]))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("dailyDigestMaxCards"))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("dailyDigestIncludesTrending"))
    }

    // MARK: Input selection

    /// The slug of a watched topic's URL, as its adapter reads it.
    private let slug: (WatchedTopic) -> String? = { DiscourseLinks().parse($0.url, basePath: "")?.slug }

    func testWatchedTopicsComeFirstThenTrendingInTurnDedupedAndCapped() {
        let quiet = watched("1", known: 10)
        let few = watched("2", known: 13)
        let many = watched("3", known: 27, slug: "busy-topic")
        let baselines = [quiet.topicKey: 10, few.topicKey: 10, many.topicKey: 20]
        let trending = [
            (siteURL: site, topics: [listing(site, 3), listing(site, 50, pinned: true), listing(site, 51), listing(site, 52)]),
            (siteURL: other, topics: [listing(other, 60), listing(other, 61)])
        ]

        let cards = DigestPlanner.plan(
            watched: [quiet, few, many], baselines: baselines, trending: trending,
            options: .init(maxCards: 5), slug: slug
        )
        // Most new replies first; topic 3 is not repeated as trending; the
        // pinned announcement is skipped; forums take turns; capped at 5.
        XCTAssertEqual(cards.map(\.topicID), ["3", "2", "51", "60", "52"])
        XCTAssertEqual(cards[0].reason, .newReplies(7))
        XCTAssertEqual(cards[0].firstNewPost, 21)
        XCTAssertEqual(cards[0].slug, "busy-topic")
        XCTAssertEqual(cards[1].reason, .newReplies(3))
        XCTAssertEqual(cards[2].reason, .trending)
        XCTAssertNil(cards[2].firstNewPost)

        let watchedOnly = DigestPlanner.plan(
            watched: [quiet, few, many], baselines: baselines, trending: trending,
            options: .init(includesTrending: false), slug: slug
        )
        XCTAssertEqual(watchedOnly.map(\.topicID), ["3", "2"])
        let trendingOnly = DigestPlanner.plan(
            watched: [quiet, few, many], baselines: baselines, trending: trending,
            options: .init(includesWatched: false, maxCards: 3), slug: slug
        )
        XCTAssertEqual(trendingOnly.map(\.topicID), ["3", "60", "51"])
        XCTAssertTrue(trendingOnly.allSatisfy { $0.reason == .trending })
    }

    func testNewRepliesCountFromTheLastDigestElseFromWhatWasSeen() {
        var seen = watched("1", known: 30)
        seen.newReplies = 4
        let fresh = watched("2", known: 12)
        var previous = DailyDigest(day: "2026-10-19", cards: [])
        previous.watchedPostCounts = [fresh.topicKey: 9]

        let baselines = DigestPlanner.baselines(watched: [seen, fresh], previous: previous)
        XCTAssertEqual(baselines[seen.topicKey], 26, "no earlier count: the unseen replies are new")
        XCTAssertEqual(baselines[fresh.topicKey], 9)

        // A fresher post count from the prefetch wins over the last watch check.
        let facts = [fresh.topicKey: DigestTopicFacts(title: "Fresh", slug: "fresh", postCount: 15, acceptedAnswerPost: 4)]
        let cards = DigestPlanner.plan(watched: [seen, fresh], baselines: baselines, trending: [], facts: facts, options: .init(), slug: slug)
        XCTAssertEqual(cards.map(\.topicID), ["2", "1"])
        XCTAssertEqual(cards[0].reason, .newReplies(6))
        XCTAssertEqual(cards[0].postCount, 15)
        XCTAssertEqual(cards[0].acceptedAnswerPost, 4)
        XCTAssertEqual(makeHarness().app.url(for: cards[0], atPost: 4).absoluteString, "\(site)/t/fresh/2/4")
    }

    // MARK: Background prefetch

    func testPrefetchStopsAtTheRequestCap() async throws {
        let forums = (1...10).map { Forum(siteURL: "https://f\($0).example.com", kind: .discourse, name: "F\($0)", isPinned: true, pinOrder: $0) }
        for (index, forum) in forums.enumerated() {
            let ids = (0..<3).map { 1000 * (index + 1) + $0 }
            StateForumStub.lists["\(ForumSite.host(of: forum.siteURL))/top.json"] = topicList(ids)
        }
        var snapshot = AppSnapshot(forums: forums)
        snapshot.settings.dailyDigestMaxCards = 20
        let harness = makeHarness(snapshot: snapshot)

        let prefetch = await harness.app.prefetchDigestInputs(background: true)
        // 8 forums' lists, then topic JSON for the planned cards until the cap.
        XCTAssertEqual(prefetch.requestCount, DigestLimits.prefetchRequestCap)
        XCTAssertEqual(StateForumStub.requests.count, DigestLimits.prefetchRequestCap)
        XCTAssertEqual(StateForumStub.requests.filter { $0 == "/top.json" }.count, DigestLimits.trendingForums)
        XCTAssertEqual(prefetch.trending.count, DigestLimits.trendingForums)
        XCTAssertEqual(prefetch.topics.count, DigestLimits.prefetchRequestCap - DigestLimits.trendingForums)
        XCTAssertEqual(prefetch.failedCount, 0)
        // No AI in the background, and the prefetch is kept for the digest.
        XCTAssertTrue(harness.ai.calls.isEmpty)
        XCTAssertEqual(harness.app.digestPrefetch, prefetch)
        let stored = DigestStore(directory: harness.store.directoryURL).load().prefetch
        XCTAssertEqual(stored?.requestCount, prefetch.requestCount)
        XCTAssertEqual(stored?.topics, prefetch.topics)
    }

    func testPrefetchCountsWhatTheActiveTopicsSourceReports() async throws {
        for used in 0...2 {
            let source = FakeActiveTopics(requests: used)
            let forum = Forum(siteURL: "https://fake.example.com", kind: FakeSiteAdapter.kind, name: "Fake", isPinned: true, pinOrder: 0)
            let harness = makeHarness(
                snapshot: AppSnapshot(forums: [forum]),
                sites: SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter(activeTopics: source)])
            )
            let prefetch = await harness.app.prefetchDigestInputs(background: true)
            XCTAssertEqual(prefetch.requestCount, used)
            XCTAssertEqual(prefetch.failedCount, 0)
            XCTAssertEqual(source.receivedBudgets, [DigestLimits.prefetchRequestCap])
            XCTAssertEqual(prefetch.trending["https://fake.example.com"], [])
            XCTAssertTrue(StateForumStub.requests.isEmpty)
        }
    }

    func testPrefetchHandsEachSourceWhatIsLeftOfTheCap() async throws {
        let forums = (0..<3).map {
            Forum(siteURL: "https://fake\($0).example.com", kind: FakeSiteAdapter.kind, name: "Fake\($0)", isPinned: true, pinOrder: $0)
        }
        // One registry adapter per forum is not possible (the kind is the key),
        // so the three forums share a source that counts its calls.
        let source = FakeActiveTopics(requests: 2)
        let harness = makeHarness(
            snapshot: AppSnapshot(forums: forums),
            sites: SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter(activeTopics: source)])
        )
        let prefetch = await harness.app.prefetchDigestInputs(background: true)
        XCTAssertEqual(prefetch.requestCount, 6)
        let cap = DigestLimits.prefetchRequestCap
        XCTAssertEqual(source.receivedBudgets, [cap, cap - 2, cap - 4])
    }

    func testPrefetchSkipsASiteWithNoAdapterQuietly() async throws {
        let forum = Forum(siteURL: "https://ghost.example.com", kind: SiteKind("ghost"), name: "Ghost", isPinned: true, pinOrder: 0)
        let harness = makeHarness(snapshot: AppSnapshot(forums: [forum]))
        let prefetch = await harness.app.prefetchDigestInputs(background: true)
        XCTAssertEqual(prefetch.requestCount, 0)
        XCTAssertEqual(prefetch.failedCount, 0)
        XCTAssertNil(prefetch.trending[forum.siteURL])
        XCTAssertTrue(StateForumStub.requests.isEmpty)
    }

    func testRepliesSinceTheLastWatchCheckCountWithoutChangingTheWatch() async throws {
        // No watch check has seen the 4 replies that came in overnight.
        let topic = watched("41", known: 10)
        StateForumStub.postCounts["41"] = 14
        let harness = makeHarness(snapshot: AppSnapshot(watchedTopics: [topic]))

        let prefetch = await harness.app.prefetchDigestInputs(background: true)
        XCTAssertEqual(StateForumStub.requests, ["/t/41.json"], "watched topics are read first, once")
        let card = try XCTUnwrap(harness.app.planDigestCards(using: prefetch).cards.first)
        XCTAssertEqual(card.reason, .newReplies(4))
        XCTAssertEqual(card.firstNewPost, 11)
        // The watch check owns new-reply notifications: the watch is unchanged.
        XCTAssertEqual(harness.app.watchedTopics.first?.knownPostCount, 10)
        XCTAssertEqual(harness.app.watchedTopics.first?.newReplies, 0)
    }

    func testPrefetchFallsBackToLatestWhenTopIsUnavailable() async throws {
        StateForumStub.lists["forum.example.com/latest.json"] = topicList([7, 8])
        let harness = makeHarness(snapshot: AppSnapshot(forums: [pinned(site)]))
        let prefetch = await harness.app.prefetchDigestInputs(background: true)
        XCTAssertEqual(StateForumStub.requests.prefix(2), ["/top.json", "/latest.json"])
        XCTAssertEqual(prefetch.trending[site]?.map(\.id), [7, 8])
        XCTAssertEqual(Set(prefetch.topics.keys), ["forum.example.com/t/7", "forum.example.com/t/8"])
    }

    func testThePrefetchIsScheduledOnlyWhileTheDigestIsOn() throws {
        let scheduler = FakeTaskScheduler()
        let harness = makeHarness(scheduler: scheduler)
        let app = harness.app
        XCTAssertTrue(scheduler.submitted.isEmpty, "off by default: nothing scheduled")

        app.settings.dailyDigestEnabled = true
        let request = try XCTUnwrap(scheduler.submitted.last as? BGProcessingTaskRequest)
        XCTAssertEqual(request.identifier, DigestBackgroundPrefetch.identifier)
        XCTAssertTrue(request.requiresNetworkConnectivity)
        XCTAssertTrue(request.requiresExternalPower)
        XCTAssertGreaterThan(request.earliestBeginDate ?? .distantPast, Date())

        app.settings.dailyDigestEnabled = false
        XCTAssertEqual(scheduler.cancelled, [DigestBackgroundPrefetch.identifier])

        // A reset turns it off too; a launch with it on schedules again.
        app.settings.dailyDigestEnabled = true
        app.resetSettings()
        XCTAssertEqual(scheduler.cancelled.count, 2)
        var snapshot = AppSnapshot()
        snapshot.settings.dailyDigestEnabled = true
        let relaunched = FakeTaskScheduler()
        _ = makeHarness(snapshot: snapshot, scheduler: relaunched)
        XCTAssertEqual(relaunched.submitted.map(\.identifier), [DigestBackgroundPrefetch.identifier])
    }

    func testTheAppMayRunTheDigestTask() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        let identifiers = info["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        XCTAssertTrue(identifiers.contains(DigestBackgroundPrefetch.identifier), "\(identifiers)")
        XCTAssertTrue(identifiers.contains(WatchBackgroundRefresh.identifier), "\(identifiers)")
        let modes = info["UIBackgroundModes"] as? [String] ?? []
        XCTAssertTrue(Set(modes).isSuperset(of: ["processing", "fetch", "remote-notification"]), "\(modes)")
    }

    // MARK: Making the digest

    func testGenerationContinuesFromTheCardWhereItStopped() async throws {
        StateForumStub.lists["forum.example.com/top.json"] = topicList([11, 12, 13])
        let harness = makeHarness(snapshot: AppSnapshot(forums: [pinned(site)]))
        let app = harness.app
        connect(app)

        app.makeTodaysDigest()
        try await waitUntil { harness.ai.waiting == 1 }
        XCTAssertEqual(app.todaysDigest?.cards.map(\.state), [.working, .pending, .pending])
        XCTAssertEqual(app.digestActivity, .summarizing("forum.example.com/t/11"))
        harness.ai.releaseAll()
        try await waitUntil { harness.ai.waiting == 1 && app.todaysDigest?.cards.first?.state == .done }
        XCTAssertEqual(app.todaysDigest?.cards.first?.summary, "Summary by openai/gpt-test")
        XCTAssertEqual(app.todaysDigest?.cards.first?.source, .topic)

        // The app goes to the background mid-card: that card waits again.
        app.pauseDigest()
        XCTAssertEqual(app.todaysDigest?.cards.map(\.state), [.done, .pending, .pending])
        XCTAssertEqual(app.digestActivity, .idle)
        app.flushPendingSaves()

        // Relaunch (or a kill): the saved digest continues with card 2.
        let relaunched = makeHarness(directory: harness.store.directoryURL, keys: harness.keys)
        relaunched.ai.gated = false
        let reloaded = relaunched.app
        XCTAssertEqual(reloaded.todaysDigest?.cards.map(\.state), [.done, .pending, .pending])
        reloaded.resumeDigestIfNeeded()
        try await waitUntil { reloaded.todaysDigest?.isComplete == true }
        XCTAssertEqual(relaunched.ai.calls.count, 2, "card 1 is not summarized again")
        XCTAssertEqual(reloaded.todaysDigest?.cards.map(\.state), [.done, .done, .done])
        XCTAssertNotNil(reloaded.todaysDigest?.completedAt)
        XCTAssertEqual(reloaded.digestActivity, .idle)
        // The prompt is the digest's, through the summary pipeline.
        XCTAssertTrue(relaunched.ai.calls.allSatisfy { $0.customPrompt.contains("daily digest") })
    }

    func testACurrentSavedSummaryIsReusedWithoutReadingTheTopic() async throws {
        StateForumStub.lists["forum.example.com/top.json"] = topicList([21, 22])
        var saved = TopicSession(siteURL: site, topicID: "21", url: URL(string: "\(site)/t/topic-21/21")!, title: "Topic 21")
        saved.summary = "## Saved\nThe whole discussion, summarized earlier."
        saved.totalPosts = 2
        saved.summaryPostCount = 2
        let harness = makeHarness(snapshot: AppSnapshot(sessions: [saved], forums: [pinned(site)]))
        harness.ai.gated = false
        let app = harness.app
        connect(app)

        app.makeTodaysDigest()
        try await waitUntil { app.todaysDigest?.isComplete == true }
        let cards = try XCTUnwrap(app.todaysDigest?.cards)
        XCTAssertEqual(cards.map(\.source), [.savedSummary, .topic])
        XCTAssertEqual(StateForumStub.requests.filter { $0 == "/raw/21" }.count, 0, "the saved summary covers every post")
        XCTAssertEqual(StateForumStub.requests.filter { $0 == "/raw/22" }.count, 1)
        XCTAssertEqual(harness.ai.calls.first?.content, saved.summary)
        XCTAssertTrue(harness.ai.calls.first?.customPrompt.contains("existing summary") ?? false)

        // Made again with no new posts: every card keeps its summary, no AI.
        app.makeTodaysDigest(replacing: true)
        try await waitUntil { app.todaysDigest?.isComplete == true && app.digestActivity == .idle }
        XCTAssertEqual(harness.ai.calls.count, 2)
        XCTAssertEqual(app.todaysDigest?.cards.map(\.source), [.earlierDigest, .earlierDigest])
        XCTAssertEqual(app.digests.count, 1)

        // Removing the forum with its data removes its cards.
        app.removeForum(try XCTUnwrap(app.forum(for: site)), deleteData: true)
        XCTAssertEqual(app.todaysDigest?.cards, [])
    }

    func testWithoutAProviderNothingStarts() async throws {
        StateForumStub.lists["forum.example.com/top.json"] = topicList([31])
        var snapshot = AppSnapshot(forums: [pinned(site)])
        snapshot.settings.dailyDigestEnabled = true
        snapshot.settings.hasCompletedOnboarding = true
        let harness = makeHarness(snapshot: snapshot)
        let app = harness.app
        XCTAssertFalse(app.isProviderReady(for: .assistant))

        app.resumeDigestIfNeeded()
        app.makeTodaysDigest()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(app.todaysDigest)
        XCTAssertEqual(app.digestActivity, .idle)
        XCTAssertTrue(StateForumStub.requests.isEmpty)
        XCTAssertNil(app.presentedError)
    }

    func testOfflineShowsUnreachableAndKeepsNoHalfDigest() async throws {
        StateForumStub.offline = true
        let harness = makeHarness(snapshot: AppSnapshot(forums: [pinned(site)]))
        let app = harness.app
        connect(app)

        app.makeTodaysDigest()
        try await waitUntil { app.digestActivity == .unreachable }
        XCTAssertNil(app.todaysDigest)
        XCTAssertNil(app.presentedError, "no alert: the Today page shows the state")
        XCTAssertTrue(harness.ai.calls.isEmpty)
    }


    // MARK: WordPress source (P1 W9)

    /// 16 newer posts and one older than the newest 15; comments on the old
    /// post (3) and on the newest (1), newest comment first.
    private func busyWordPressSite() -> WordPressFixtureSite {
        let site = WordPressFixtureSite(comments: [])
        var posts = (1...16).map {
            WordPressFixtureSite.post(2000 + $0, "Fresh \($0)", String(format: "2026-08-%02dT10:00:00", $0), excerpt: "Excerpt \($0)")
        }
        posts.append(WordPressFixtureSite.post(900, "Old but busy", "2026-01-01T10:00:00"))
        site.posts = posts
        func comment(_ id: Int, post: Int, _ day: Int) -> [String: Any] {
            ["id": id, "post": post, "parent": 0, "author_name": "u\(id)", "date_gmt": "2026-08-\(String(format: "%02d", day))T12:00:00",
             "content": ["rendered": "<p>x</p>"]]
        }
        // Oldest first: the site answers `order=desc` newest first.
        site.comments = [comment(1, post: 900, 1), comment(2, post: 900, 2), comment(3, post: 900, 3), comment(4, post: 2016, 16)]
        return site
    }

    func testWordPressActiveTopicsWithinEachBudget() async {
        let source = WordPressActiveTopics()
        let siteURL = WordPressFixtureSite.siteURL

        let none = busyWordPressSite()
        var result = await source.activeTopics(siteURL: siteURL, budget: 0, net: none.network())
        XCTAssertEqual(result.requests, 0)
        XCTAssertNil(result.topics)
        XCTAssertTrue(none.requests.isEmpty)

        // One request: the newest posts, 15 of the 17.
        let one = busyWordPressSite()
        result = await source.activeTopics(siteURL: siteURL, budget: 1, net: one.network())
        XCTAssertEqual(result.requests, 1)
        XCTAssertEqual(result.failures, 0)
        XCTAssertEqual(result.topics?.map(\.id), Array((2002...2016).reversed()))
        XCTAssertEqual(one.requestLines, ["/wp-json/wp/v2/posts?_fields=id,title,link,date_gmt,excerpt&order=desc&orderby=date&per_page=15"])
        XCTAssertNil(result.topics?.first?.postsCount, "a listing says no count")

        // Two: the recent comments too. The old post is commented most but its
        // title was not fetched, so it is skipped; the newest commented post leads.
        let two = busyWordPressSite()
        result = await source.activeTopics(siteURL: siteURL, budget: 2, net: two.network())
        XCTAssertEqual(result.requests, 2)
        XCTAssertEqual(result.failures, 0)
        XCTAssertEqual(result.topics?.map(\.id), [2016] + Array((2002...2015).reversed()))
        XCTAssertEqual(two.requests.map(\.path), ["/wp-json/wp/v2/posts", "/wp-json/wp/v2/comments"])
        XCTAssertEqual(two.requests[1].query["per_page"], "50")

        // Three: the old post's title, and it comes first (most comments).
        let three = busyWordPressSite()
        result = await source.activeTopics(siteURL: siteURL, budget: 3, net: three.network())
        XCTAssertEqual(result.requests, 3)
        XCTAssertEqual(result.failures, 0)
        XCTAssertEqual(result.topics?.map(\.id), [900, 2016] + Array((2002...2015).reversed()))
        XCTAssertEqual(result.topics?.first?.title, "Old but busy")
        XCTAssertEqual(three.requests[2].query["include"], "900")
        XCTAssertEqual(three.requests[2].query["per_page"], "1")

        // More budget than it needs: nothing to title when every commented post is already listed.
        let covered = WordPressFixtureSite(comments: [WordPressFixtureSite.comment(1)])
        covered.posts = [WordPressFixtureSite.defaultPosts[0]]
        result = await source.activeTopics(siteURL: siteURL, budget: 9, net: covered.network())
        XCTAssertEqual(result.requests, 2)
        XCTAssertEqual(result.topics?.map(\.id), [1001])
    }

    func testWordPressClosedCommentsAreNoActivityNotAFailure() async {
        for status in [401, 403, 404] {
            let site = busyWordPressSite()
            site.respond { $0.path.hasSuffix("/comments") ? .init(status: status, body: Data("{}".utf8)) : nil }
            let result = await WordPressActiveTopics().activeTopics(siteURL: WordPressFixtureSite.siteURL, budget: 3, net: site.network())
            XCTAssertEqual(result.requests, 2, "\(status)")
            XCTAssertEqual(result.failures, 0, "\(status)")
            XCTAssertEqual(result.topics?.count, 15, "\(status): the newest posts")
        }
    }

    func testWordPressFailuresCountOncePerRequestAndKeepWhatWorked() async {
        // The comments request fails: the newest posts stay.
        let comments = busyWordPressSite()
        comments.respond { $0.path.hasSuffix("/comments") ? .init(status: 500, body: Data("{}".utf8)) : nil }
        var result = await WordPressActiveTopics().activeTopics(siteURL: WordPressFixtureSite.siteURL, budget: 3, net: comments.network())
        XCTAssertEqual(result.requests, 2)
        XCTAssertEqual(result.failures, 1)
        XCTAssertEqual(result.topics?.count, 15)

        // The newest posts fail: the commented posts are titled by the third request.
        let posts = busyWordPressSite()
        posts.respond { $0.path.hasSuffix("/posts") && $0.query["include"] == nil ? .init(status: 500, body: Data("{}".utf8)) : nil }
        result = await WordPressActiveTopics().activeTopics(siteURL: WordPressFixtureSite.siteURL, budget: 3, net: posts.network())
        XCTAssertEqual(result.requests, 3)
        XCTAssertEqual(result.failures, 1)
        XCTAssertEqual(result.topics?.map(\.id).sorted(), [900, 2016])

        // Everything fails: no list at all.
        let down = busyWordPressSite()
        down.respond { _ in .init(status: 500, body: Data("{}".utf8)) }
        result = await WordPressActiveTopics().activeTopics(siteURL: WordPressFixtureSite.siteURL, budget: 3, net: down.network())
        XCTAssertNil(result.topics)
        XCTAssertEqual(result.failures, 2, "no titles to fetch without comments")
    }

    func testWordPressACancelledRunCountsNoFailure() async {
        let site = busyWordPressSite()
        let net = site.network()
        let task = Task { await WordPressActiveTopics().activeTopics(siteURL: WordPressFixtureSite.siteURL, budget: 3, net: net) }
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.failures, 0)
        XCTAssertLessThanOrEqual(result.requests, 1, "stops at the first cancelled request")
    }

    func testPrefetchReadsAWordPressForumThroughItsSource() async throws {
        let wordpress = WordPressFixtureSite(commentCount: 3)
        wordpress.posts = [WordPressFixtureSite.defaultPosts[0]]
        let forum = Forum(siteURL: WordPressFixtureSite.siteURL, kind: .wordpress, name: "Example Blog", isPinned: true, pinOrder: 0)
        let harness = makeHarness(
            snapshot: AppSnapshot(forums: [forum]),
            sites: .standard,
            service: wordpress.service()
        )
        let prefetch = await harness.app.prefetchDigestInputs(background: true)

        XCTAssertEqual(prefetch.trending[forum.siteURL]?.map(\.id), [1001])
        XCTAssertEqual(wordpress.requests.prefix(2).map(\.path), ["/wp-json/wp/v2/posts", "/wp-json/wp/v2/comments"])
        // The list's two requests and the card's one overview read.
        XCTAssertEqual(prefetch.requestCount, 3)
        XCTAssertEqual(prefetch.failedCount, 0)
        let facts = try XCTUnwrap(prefetch.topics["example.com/t/1001"])
        XCTAssertEqual(facts.postCount, 4, "three comments and the article")
        let card = try XCTUnwrap(harness.app.planDigestCards(using: prefetch).cards.first)
        XCTAssertEqual(card.topicID, "1001")
        XCTAssertEqual(card.postCount, 4, "the listing had no count; the overview raised it")
        XCTAssertTrue(StateForumStub.requests.isEmpty)
    }

    // MARK: Helpers

    private struct Harness {
        let app: AppModel
        let store: PersistentStore
        let keys: InMemoryProviderKeyStore
        let ai: StateAIStub
    }

    private func makeHarness(
        snapshot: AppSnapshot? = nil,
        directory: URL? = nil,
        keys: InMemoryProviderKeyStore? = nil,
        scheduler: BackgroundTaskScheduling = FakeTaskScheduler(),
        sites: SiteRegistry = .standard,
        service: ForumService? = nil
    ) -> Harness {
        let folder = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let keys = keys ?? InMemoryProviderKeyStore()
        let store = PersistentStore(fileURL: folder.appendingPathComponent("state.json"), keys: keys)
        // Jobs resolve their adapter from the forum record a real session has.
        if var snapshot = snapshot ?? (directory == nil ? AppSnapshot() : nil) {
            snapshot.ensureForum(site)
            try? store.save(snapshot)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StateForumStub.self]
        let ai = StateAIStub()
        let app = AppModel(
            store: store,
            forumService: service ?? ForumService(
                session: URLSession(configuration: configuration),
                pacer: ForumRequestPacer(clock: InstantPacingClock())
            ),
            sites: sites,
            aiService: ai,
            backgroundScheduler: scheduler
        )
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        // Consent has its own tests (AIDataConsentTests).
        app.allowAllAIProviders()
        addTeardownBlock { @MainActor in
            app.pauseDigest()
            ai.gated = false
            ai.releaseAll()
        }
        return Harness(app: app, store: store, keys: keys, ai: ai)
    }

    /// The assistant model on OpenAI with a key, past the walkthrough.
    private func connect(_ app: AppModel) {
        var configuration = app.settings.configuration(for: .openAI)
        configuration.apiKey = "key"
        app.setConfiguration(configuration, for: .openAI)
        app.selectModel(ModelSelection(provider: .openAI, model: "gpt-test"), for: .both)
        app.settings.hasCompletedOnboarding = true
    }

    private func pinned(_ siteURL: String) -> Forum {
        Forum(siteURL: siteURL, kind: .discourse, name: ForumSite.host(of: siteURL), isPinned: true, pinOrder: 0)
    }

    private func watched(_ id: String, known: Int, slug: String = "topic") -> WatchedTopic {
        WatchedTopic(siteURL: site, topicID: id, url: URL(string: "\(site)/t/\(slug)/\(id)")!, title: "Watched \(id)", knownPostCount: known)
    }

    private func listing(_ siteURL: String, _ id: Int, pinned: Bool = false) -> ForumTopicListing {
        ForumTopicListing(
            siteURL: siteURL, id: id, title: "Topic \(id)", slug: "topic-\(id)",
            url: URL(string: "\(siteURL)/t/topic-\(id)/\(id)")!, postsCount: 2, isPinned: pinned
        )
    }

    /// A `/top.json` or `/latest.json` body.
    private func topicList(_ ids: [Int]) -> String {
        let topics = ids.map { #"{"id":\#($0),"title":"Topic \#($0)","slug":"topic-\#($0)","posts_count":2,"pinned":false}"# }
        return #"{"topic_list":{"topics":[\#(topics.joined(separator: ","))]}}"#
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
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

/// Records what the app submits to and cancels in the background task scheduler.
final class FakeTaskScheduler: BackgroundTaskScheduling {
    private(set) var submitted: [BGTaskRequest] = []
    private(set) var cancelled: [String] = []

    func submit(_ taskRequest: BGTaskRequest) throws {
        submitted.append(taskRequest)
    }

    func cancel(taskRequestWithIdentifier identifier: String) {
        cancelled.append(identifier)
    }
}
