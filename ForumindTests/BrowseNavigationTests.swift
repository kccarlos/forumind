import Combine
import XCTest
@testable import Forumind

/// Post-level browsing: the current list, landing URLs, the page position,
/// the debounced page changes, find / read / research through AppModel, and
/// the trimmed results the voice layer will speak.
final class BrowseNavigationTests: XCTestCase {
    /// A reserved name that never resolves: the browser's loads fail at once.
    private let site = "https://forum.example"
    private let folder = "https://example.com/forum"

    // MARK: BrowseCursor

    func testCursorMovesAlongTheListAndStopsAtTheEnds() {
        var cursor = BrowseCursor()
        XCTAssertNil(cursor.next())
        XCTAssertNil(cursor.previous())
        XCTAssertNil(cursor.current)
        XCTAssertFalse(cursor.hasNext)

        cursor.replace(with: items(3), origin: .search("q"))
        XCTAssertEqual(cursor.cards, .expanded)
        // After a search nothing is current; next opens the first hit.
        XCTAssertNil(cursor.current)
        XCTAssertNil(cursor.positionText)
        XCTAssertNil(cursor.previous())
        XCTAssertEqual(cursor.next()?.postNumber, 1)
        XCTAssertEqual(cursor.positionText, "1 of 3")
        XCTAssertNil(cursor.previous(), "No wrap at the start")
        XCTAssertEqual(cursor.index, 0)
        XCTAssertEqual(cursor.next()?.postNumber, 2)
        XCTAssertEqual(cursor.next()?.postNumber, 3)
        XCTAssertFalse(cursor.hasNext)
        XCTAssertNil(cursor.next(), "No wrap at the end")
        XCTAssertEqual(cursor.index, 2)
        XCTAssertEqual(cursor.previous()?.postNumber, 2)
        XCTAssertTrue(cursor.hasPrevious)

        XCTAssertEqual(cursor.select(0)?.postNumber, 1)
        XCTAssertNil(cursor.select(3))
        XCTAssertEqual(cursor.index, 0)

        // Research opens its first source: it starts current.
        cursor.replace(with: items(2), origin: .research("why"), current: 0)
        XCTAssertEqual(cursor.current?.postNumber, 1)
        XCTAssertEqual(cursor.next()?.postNumber, 2)

        cursor.replace(with: [], origin: .focus)
        XCTAssertEqual(cursor.cards, .hidden)
        XCTAssertNil(cursor.next())
        cursor.replace(with: items(1), origin: .focus, current: 5)
        XCTAssertNil(cursor.index, "An out-of-range start is ignored")
        cursor.clear()
        XCTAssertTrue(cursor.isEmpty)
        XCTAssertNil(cursor.origin)
    }

    @MainActor
    func testItemsFromHitsAndSources() throws {
        let app = makeApp()
        let (hits, _) = DiscourseParsing.parseSearch(Data(DiscourseFixtures.search.utf8), siteURL: folder)
        let item = BrowseItem(hit: hits[1])
        XCTAssertEqual(item.kind, .searchHit)
        XCTAssertEqual(item.postNumber, 5)
        XCTAssertEqual(item.username, "bob")
        XCTAssertEqual(item.slug, "how-can-i-hide-the-badges-link-in-the-sidebar")
        XCTAssertEqual(app.url(for: item)?.absoluteString, folder + "/t/how-can-i-hide-the-badges-link-in-the-sidebar/240488/5")
        XCTAssertFalse(item.excerpt.contains("\n"))

        let source = AgentSources.Source(
            number: 1, title: "Fix", url: URL(string: folder + "/t/hide-badges/240488/5")!, postNumber: 5, cited: true
        )
        let fromSource = try XCTUnwrap(BrowseItem(source: source, siteURL: folder, adapter: DiscourseAdapter()))
        XCTAssertEqual(fromSource.kind, .source)
        XCTAssertEqual(fromSource.topicID, "240488")
        XCTAssertEqual(fromSource.slug, "hide-badges")
        XCTAssertEqual(app.url(for: fromSource)?.absoluteString, folder + "/t/hide-badges/240488/5")
        // Another forum's link is not a source of this one.
        XCTAssertNil(BrowseItem(source: source, siteURL: "https://other.example", adapter: DiscourseAdapter()))
    }

    // MARK: Landing URLs

    func testLandingURLsOnAForumWithABasePath() throws {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(DiscourseFixtures.topic.utf8)) as? [String: Any]
        )
        let facts = DiscourseParsing.parseTopicFacts(json)
        func plan(_ landing: BrowseLanding, facts: TopicFacts? = nil, newSince: Int? = nil) -> BrowseNavigation.Plan? {
            BrowseNavigation.plan(adapter: DiscourseAdapter(), siteURL: folder, topicID: "42", slug: "hide", landing: landing, facts: facts, newSince: newSince)
        }
        let topic = folder + "/t/hide/42"

        XCTAssertEqual(plan(.post(7)), .init(url: URL(string: topic + "/7")!, postNumber: 7))
        XCTAssertEqual(plan(.post(0))?.postNumber, 1)
        XCTAssertEqual(plan(.solution, facts: facts), .init(url: URL(string: topic + "/5")!, postNumber: 5))
        XCTAssertEqual(plan(.solution), .init(url: URL(string: topic)!, postNumber: nil, status: .noSolution))
        XCTAssertEqual(plan(.last, facts: facts), .init(url: URL(string: topic + "/14")!, postNumber: 14))
        XCTAssertEqual(plan(.last), .init(url: URL(string: topic + "/last")!, postNumber: nil))
        XCTAssertEqual(plan(.top), .init(url: URL(string: topic + "?filter=summary")!, postNumber: nil))
        XCTAssertEqual(plan(.firstNew, facts: facts, newSince: 10), .init(url: URL(string: topic + "/11")!, postNumber: 11))
        XCTAssertEqual(plan(.firstNew, facts: facts, newSince: 14), .init(url: URL(string: topic)!, postNumber: nil))
        XCTAssertEqual(plan(.firstNew), .init(url: URL(string: topic)!, postNumber: nil))
        // No slug: the id alone, still under the base path.
        XCTAssertEqual(
            BrowseNavigation.plan(adapter: DiscourseAdapter(), siteURL: folder, topicID: "42", slug: nil, landing: .post(3), facts: nil)?.url.absoluteString,
            folder + "/t/42/3"
        )
        XCTAssertNil(BrowseNavigation.plan(adapter: DiscourseAdapter(), siteURL: folder, topicID: "x", slug: nil, landing: .post(3), facts: nil))
    }

    // MARK: Page position

    func testPageContextReadsThePostNumberDiscourseWritesIntoTheURL() throws {
        func context(_ text: String, basePath: String = "/forum") -> PageContext {
            let url = URL(string: text)!
            return PageContext.make(
                url: url, title: "Hide badges",
                facts: .discourse(url, basePath: basePath), knownForum: nil, registry: .standard
            )
        }
        let atPost = context(folder + "/t/hide/42/17")
        XCTAssertEqual(atPost.state, .topic)
        XCTAssertEqual(atPost.topic?.topicID, "42")
        XCTAssertEqual(atPost.postNumber, 17)
        XCTAssertEqual(atPost.currentPost, 17)
        XCTAssertNil(context(folder + "/t/hide/42").postNumber)
        XCTAssertNil(context(folder + "/t/hide/42/last").postNumber)
        XCTAssertNil(context(folder + "/latest").postNumber)
        XCTAssertEqual(context("https://forum.example/t/hide/42/3?u=bob", basePath: "").postNumber, 3)

        // The bridge's report and the facts merge only into their own topic.
        let report = BrowseBridgeReport(url: URL(string: folder + "/t/hide/42/17")!, visible: [17, 18], highlighted: [17])
        var facts = TopicFacts()
        facts.postsCount = 120
        facts.acceptedAnswer = .init(postNumber: 30, username: "bob")
        let merged = atPost.merging(report: report, facts: facts, registry: .standard)
        XCTAssertEqual(merged.visiblePosts, [17, 18])
        XCTAssertEqual(merged.highlightedPosts, [17])
        XCTAssertEqual(merged.postsCount, 120)
        XCTAssertEqual(merged.acceptedAnswerPost, 30)
        XCTAssertTrue(merged.sameDocument(as: atPost), "Position fields don't make a new page")
        XCTAssertFalse(merged.sameDocument(as: context(folder + "/t/hide/42/18")))
        let other = BrowseBridgeReport(url: URL(string: folder + "/t/other/43")!, visible: [1], highlighted: [])
        XCTAssertEqual(atPost.merging(report: other, facts: nil, registry: .standard).visiblePosts, [])
        XCTAssertEqual(context(folder + "/latest").merging(report: report, facts: facts, registry: .standard), context(folder + "/latest"))
        var unrendered = PageContext()
        unrendered.visiblePosts = [4, 5]
        XCTAssertEqual(unrendered.currentPost, 4)
    }

    func testBridgeReportsAreDecodedDefensively() {
        let report = ForumBrowserModel.bridgeReport(from: [
            "url": folder + "/t/hide/42/3",
            "visible": [3, 4, "x", -1],
            "highlighted": [3]
        ] as [String: Any])
        XCTAssertEqual(report?.visible, [3, 4])
        XCTAssertEqual(report?.highlighted, [3])
        XCTAssertNil(ForumBrowserModel.bridgeReport(from: ["visible": [1]]))
        XCTAssertNil(ForumBrowserModel.bridgeReport(from: "nope"))
    }

    /// Scrolling produces many position updates; the stream reports the
    /// last one once the page settles. A position change selects no topic.
    @MainActor
    func testPageChangesAreDebouncedWhileScrolling() async throws {
        let app = makeApp()
        app.pageChangeDelay = .milliseconds(80)
        var received: [PageContext] = []
        let done = expectation(description: "settled")
        let subscription = app.pageChanges.sink { context in
            received.append(context)
            done.fulfill()
        }
        defer { subscription.cancel() }
        let topic = topicContext(post: 1)
        var appChanges = 0
        let appToken = app.objectWillChange.sink { appChanges += 1 }
        defer { appToken.cancel() }
        // Back to back on the main actor: the debounce can't fire in between.
        for number in 1...6 {
            var context = topic
            context.visiblePosts = [number, number + 1]
            app.browser.setPageContext(context)
            app.handlePagePosition(context)
        }
        XCTAssertEqual(appChanges, 0, "scrolling never republishes the app model")
        XCTAssertEqual(app.pageContext.visiblePosts, [6, 7], "the browser holds the position")
        await fulfillment(of: [done], timeout: 3)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.visiblePosts, [6, 7])
        XCTAssertNil(app.currentTopic, "A position update doesn't select or save a topic")
    }

    // MARK: Find and read

    @MainActor
    func testFindFillsTheCursorWithoutHiddenAuthors() async throws {
        PostLevelURLStub.handler = { request in
            PostLevelURLStub.requests.append(request.url!)
            return (200, DiscourseFixtures.search)
        }
        let app = makeApp()
        app.recordVisit(siteURL: site, kind: .discourse, name: "Example", iconURL: nil)
        app.browser.moderationRules = ModerationRules(blockedUsers: [site: ["carol"]])

        let result = await app.find("badges")
        XCTAssertEqual(result.status, .found)
        XCTAssertEqual(app.browseCursor.items.map(\.postNumber), [1, 5, 10])
        XCTAssertFalse(app.browseCursor.items.contains { $0.username == "carol" })
        XCTAssertNil(app.browseCursor.index)
        XCTAssertEqual(app.browseCursor.origin, .search("badges"))
        XCTAssertEqual(app.browseCursor.cards, .expanded)
        XCTAssertEqual(result.hits?.map(\.number), [1, 2, 3])
        XCTAssertEqual(result.hits?.first?.username, "alice")
        XCTAssertEqual(PostLevelURLStub.requests.first?.path, "/search.json")

        // Within the open topic: `topic:<id>`.
        app.browser.setPageContext(topicContext(post: 1))
        _ = await app.find("hide it", scope: .topic)
        let query = URLComponents(url: try XCTUnwrap(PostLevelURLStub.requests.last), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value
        XCTAssertEqual(query, "hide it topic:240488")

        // Next walks the hits; the end says so.
        let first = await app.next()
        XCTAssertEqual(first.status, .moved)
        XCTAssertTrue(first.shown.hasPrefix("1 of 3: "), first.shown)
        _ = await app.next()
        _ = await app.next()
        let end = await app.next()
        XCTAssertEqual(end.status, .endOfList)
        XCTAssertEqual(app.browseCursor.index, 2)
    }

    @MainActor
    func testReadFallsBackToPostsJSONAndRespectsModeration() async throws {
        PostLevelURLStub.handler = { request in
            PostLevelURLStub.requests.append(request.url!)
            switch request.url!.path {
            case "/t/240488.json": return (200, DiscourseFixtures.topic)
            case "/t/240488/posts.json": return (200, DiscourseFixtures.posts)
            default: return (404, "")
            }
        }
        let app = makeApp()
        app.browser.setPageContext(topicContext(post: 5))

        let result = await app.read()
        XCTAssertEqual(result.status, .read)
        XCTAssertEqual(result.shown, "Post 5 of 10 by bob (accepted answer)")
        XCTAssertTrue(result.content?.hasPrefix("bob, post 5:\nHello,") ?? false, result.content ?? "")
        // The facts are fetched once per topic.
        _ = await app.read(post: 10)
        XCTAssertEqual(PostLevelURLStub.requests.filter { $0.path == "/t/240488.json" }.count, 1)

        app.browser.moderationRules = ModerationRules(blockedUsers: [site: ["bob"]])
        let blocked = await app.read(post: 5)
        XCTAssertEqual(blocked.status, .hidden)
        app.browser.moderationRules = ModerationRules(filteredWords: ["hide it"])
        let filtered = await app.read(post: 5)
        XCTAssertEqual(filtered.status, .hidden)
        app.browser.moderationRules = .none
        let missing = await app.read(post: 2)
        XCTAssertEqual(missing.status, .notFound)
    }

    // MARK: Research

    /// A new request cancels the running one, which hands back `.cancelled`
    /// and never fills the list; the newer answer's sources do, at source 1.
    @MainActor
    func testResearchRunsOneAtATime() async throws {
        let planner = BrowsePlanner(answer: "Use CSS ([fix](\(site)/t/hide-badges/240488/5)) or [this](\(site)/t/hide-badges/240488/10).")
        let app = makeApp(planner: planner)
        useLocalProvider(app)

        let slow = Task { await app.research("slow: anything new?", siteURL: site) }
        try await waitUntil { planner.isWaiting }
        XCTAssertTrue(app.isResearching)
        let fast = await app.research("How do I hide the badges link?", siteURL: site)
        let replaced = await slow.value
        planner.release()

        XCTAssertEqual(replaced.status, .cancelled)
        XCTAssertEqual(fast.status, .answered)
        XCTAssertTrue(fast.content?.hasPrefix("Use CSS") ?? false)
        XCTAssertEqual(fast.hits?.map(\.postNumber), [5, 10])
        XCTAssertEqual(app.browseCursor.origin, .research("How do I hide the badges link?"))
        XCTAssertEqual(app.browseCursor.items.map(\.postNumber), [5, 10])
        XCTAssertEqual(app.browseCursor.index, 0)
        XCTAssertFalse(app.isResearching)
        let runs = app.agentRuns.map(\.result)
        XCTAssertEqual(runs.filter { $0 == .cancelled }.count, 1)
        XCTAssertEqual(runs.filter { $0 == .completed }.count, 1)
    }

    @MainActor
    func testCancellingResearchStopsTheRun() async throws {
        let planner = BrowsePlanner(answer: "n/a")
        let app = makeApp(planner: planner)
        useLocalProvider(app)
        XCTAssertEqual(app.cancelResearch().status, .unavailable)

        let running = Task { await app.research("slow: never mind", siteURL: site) }
        try await waitUntil { planner.isWaiting }
        XCTAssertEqual(app.cancelResearch().status, .cancelled)
        let result = await running.value
        planner.release()
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertTrue(app.browseCursor.isEmpty)
        try await waitUntil { app.agentRuns.first?.result == .cancelled }
    }

    // MARK: Results

    func testResultContentIsTrimmedAtASentence() throws {
        let sentence = "This sentence is about forty-five characters. "
        let long = String(repeating: sentence, count: 100)
        let trimmed = BrowseText.trimmed(long)
        XCTAssertLessThanOrEqual(trimmed.count, BrowseText.contentLimit + 1)
        XCTAssertGreaterThan(trimmed.count, BrowseText.contentLimit * 4 / 5)
        XCTAssertTrue(trimmed.hasSuffix("characters.…"), String(trimmed.suffix(20)))
        XCTAssertEqual(BrowseText.trimmed("  Short post. \n"), "Short post.")
        // No break near the end: a hard cut.
        let word = String(repeating: "x", count: 4_000)
        XCTAssertEqual(BrowseText.trimmed(word).count, BrowseText.contentLimit + 1)

        let result = BrowseResult(status: .opened, shown: "Post 3 of 9 by bob", content: long)
        XCTAssertEqual(result.content, trimmed)
        let json = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(object["status"] as? String, "opened")
        XCTAssertEqual(object["shown"] as? String, "Post 3 of 9 by bob")
        XCTAssertEqual(try JSONDecoder().decode(BrowseResult.self, from: json), result)

        XCTAssertEqual(
            BrowseText.postDescription(number: 37, total: 120, username: "alice", acceptedAnswer: 37),
            "Post 37 of 120 by alice (accepted answer)"
        )
        XCTAssertEqual(BrowseText.postDescription(number: 3, total: nil, username: nil, acceptedAnswer: 5), "Post 3")
        XCTAssertEqual(BrowseText.oneLine("a\n\n b\tc"), "a b c")
    }

    // MARK: Helpers

    private func items(_ count: Int) -> [BrowseItem] {
        (1...count).map {
            BrowseItem(kind: .searchHit, siteURL: site, topicID: "240488", postNumber: $0, title: "Topic \($0)")
        }
    }

    private func topicContext(post: Int?) -> PageContext {
        let text = site + "/t/how-can-i-hide-the-badges-link-in-the-sidebar/240488" + (post.map { "/\($0)" } ?? "")
        let url = URL(string: text)!
        return PageContext.make(
            url: url, title: "How can I hide the Badges link in the sidebar?",
            facts: .discourse(url), knownForum: nil, registry: .standard
        )
    }

    @MainActor
    private func makeApp(planner: AgentPlanner? = nil) -> AppModel {
        PostLevelURLStub.requests = []
        PostLevelURLStub.cookies = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PostLevelURLStub.self]
        let session = URLSession(configuration: configuration)
        let store = PersistentStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("state.json")
        )
        var seeded = AppSnapshot()
        seeded.ensureForum(site)
        seeded.ensureForum(folder)
        try? store.save(seeded)
        let app = AppModel(
            store: store,
            forumService: ForumService(session: session, pacer: ForumRequestPacer(clock: InstantPacingClock())),
            aiService: AIService(session: session),
            planner: planner
        )
        app.usesDirectForumRequests = true
        return app
    }

    @MainActor
    private func useLocalProvider(_ app: AppModel) {
        app.selectModel(ModelSelection(provider: .ollama, model: "test-model"), for: .both)
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "Timed out")
    }
}

/// Answers at once, except a goal starting "slow:", which waits until
/// released (ignoring task cancellation, as a slow provider would).
private final class BrowsePlanner: AgentPlanner, @unchecked Sendable {
    private let answer: String
    private let lock = NSLock()
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(answer: String) {
        self.answer = answer
    }

    var isWaiting: Bool { lock.withLock { waiting } }

    func release() {
        lock.withLock {
            continuation?.resume()
            continuation = nil
        }
    }

    func nextAction(
        system: String,
        transcript: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws -> AgentAction {
        if transcript.first?.content.contains("slow:") == true {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    self.continuation = continuation
                    waiting = true
                }
            }
            return AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Late"])
        }
        return AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": answer])
    }
}
