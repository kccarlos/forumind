import XCTest
@testable import Forumind

// S0 of the site-adapter refactor (dev/docs/SITE_ADAPTERS_PLAN.md): the
// ordered list of forum requests each flow makes today, recorded through a
// URLProtocol stub and pinned. Moving reads behind the site adapter (S4, S5)
// and moving the implementation (S6) must leave every sequence unchanged:
// same URLs, same order, same count. Never edit an expected list to make a
// later step pass.
//
// Requests are recorded as `host/path?query` (no scheme). The forum is a
// subfolder install on a reserved host, so base-path handling is covered and
// the browser's own loads can never reach a real server. Pacing is the
// default (one request at a time) with an instant clock, so the order is
// deterministic.

/// Records every request URL in order and answers from `respond`.
private final class SequenceStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [String] = []
    nonisolated(unsafe) private static var handler: (@Sendable (URL) -> (Int, String))?

    static func reset(_ handler: @escaping @Sendable (URL) -> (Int, String)) {
        lock.withLock {
            recorded = []
            self.handler = handler
        }
    }

    static var requests: [String] { lock.withLock { recorded } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let respond = Self.lock.withLock { () -> (Int, String) in
            let text = url.absoluteString
            Self.recorded.append(text.hasPrefix("https://") ? String(text.dropFirst("https://".count)) : text)
            return Self.handler?(url) ?? (404, "")
        }
        let response = HTTPURLResponse(url: url, statusCode: respond.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(respond.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Discourse answers for the forum under test: topic JSON (its post count
/// per topic id), `/raw` pages, filtered topic JSON, posts by id and the two
/// topic lists. Anything else is a 404.
private struct SequenceForum: @unchecked Sendable {
    /// Post counts by topic id; other topics have 2 posts.
    var postCounts: [String: Int] = [:]
    var top: (Int, String) = (200, SequenceForum.list([]))
    var latest: (Int, String) = (200, SequenceForum.list([]))

    static let basePath = "/forum"

    static func list(_ ids: [Int]) -> String {
        let topics = ids.map {
            #"{"id":\#($0),"title":"Topic \#($0)","slug":"topic-\#($0)","posts_count":2,"pinned":false}"#
        }
        return #"{"topic_list":{"topics":[\#(topics.joined(separator: ","))]}}"#
    }

    static func topicJSON(id: String, count: Int) -> String {
        """
        {"id":\(id),"title":"Topic \(id)","slug":"topic-\(id)","posts_count":\(count),"highest_post_number":\(count),
         "details":{"created_by":{"username":"alice"}},
         "post_stream":{"stream":[1001,1002,1003],"posts":[
           {"id":1001,"post_number":1,"username":"alice","like_count":2},
           {"id":1002,"post_number":2,"username":"bob","like_count":0}]}}
        """
    }

    /// `/t/{id}.json?username_filters=alice`: the opening poster's posts.
    static func filteredJSON(id: String) -> String {
        """
        {"id":\(id),"title":"Topic \(id)","slug":"topic-\(id)","posts_count":2,"highest_post_number":2,
         "details":{"created_by":{"username":"alice"}},
         "post_stream":{"stream":[1001],"posts":[{"id":1001,"post_number":1,"username":"alice","like_count":2}]}}
        """
    }

    func answer(_ url: URL) -> (Int, String) {
        var path = url.path
        guard path.hasPrefix(Self.basePath) else { return (404, "") }
        path = String(path.dropFirst(Self.basePath.count))
        let parts = path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if parts == ["top.json"] { return top }
        if parts == ["latest.json"] { return latest }
        if parts == ["site", "basic-info.json"] { return (200, #"{"title":"Sequence Forum"}"#) }
        if parts.count == 2, parts[0] == "t", parts[1].hasSuffix(".json") {
            let id = String(parts[1].dropLast(5))
            if query.contains(where: { $0.name == "username_filters" }) {
                return (200, Self.filteredJSON(id: id))
            }
            return (200, Self.topicJSON(id: id, count: postCounts[id] ?? 2))
        }
        if parts.count == 3, parts[0] == "t", parts[2] == "posts.json" {
            return (200, DiscourseFixtures.posts)
        }
        if parts.count == 2, parts[0] == "raw" {
            let page = query.first { $0.name == "page" }?.value ?? "1"
            return (200, "alice | 2026-10-20 | #\(page)\nPage \(page) of topic \(parts[1])")
        }
        return (404, "")
    }
}

@MainActor
final class SiteRequestSequenceTests: XCTestCase {
    private let site = "https://forum.example/forum"
    private let host = "forum.example/forum"

    private struct Harness {
        let app: AppModel
        let ai: StateAIStub
        /// Hands a page context to the model as the browser would.
        let deliver: (PageContext) -> Void
    }

    private func makeHarness(
        forum: SequenceForum = SequenceForum(),
        snapshot: AppSnapshot? = nil,
        planner: AgentPlanner? = nil
    ) -> Harness {
        SequenceStub.reset { forum.answer($0) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        // Jobs resolve their site's adapter from the forum record, which a
        // real session always has.
        var seeded = snapshot ?? AppSnapshot()
        if seeded.forums.isEmpty { seeded.forums = [Forum(siteURL: site, kind: .discourse, name: "Sequence Forum")] }
        try? store.save(seeded)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SequenceStub.self]
        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(
            store: store,
            forumService: ForumService(
                session: URLSession(configuration: configuration),
                pacer: ForumRequestPacer(clock: InstantPacingClock())
            ),
            aiService: ai,
            planner: planner
        )
        app.usesDirectForumRequests = true
        app.allowAllAIProviders()
        var provider = app.settings.configuration(for: .ollama)
        provider.apiKey = ""
        app.setConfiguration(provider, for: .ollama)
        app.selectModel(ModelSelection(provider: .ollama, model: "model-a"), for: .both)
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
        }
        return Harness(app: app, ai: ai, deliver: { app.browser.setPageContext($0); handler?($0) })
    }

    private func topic(_ id: String) -> ForumTopic {
        ForumTopic(
            siteURL: site,
            topicID: id,
            url: URL(string: "\(site)/t/topic-\(id)/\(id)")!,
            title: "Topic \(id)"
        )
    }

    private func topicPage(_ topic: ForumTopic) -> PageContext {
        PageContext(
            url: topic.url,
            site: .discourse,
            siteURL: topic.siteURL,
            basePath: "/forum",
            forumName: "Sequence Forum",
            topic: topic,
            state: .topic
        )
    }

    // MARK: Reads

    /// Pull: the topic JSON (post count), then every raw page in order.
    func testPullTopic() async throws {
        let harness = makeHarness(forum: SequenceForum(postCounts: ["123": 250]))
        harness.deliver(topicPage(topic("123")))
        harness.app.pullTopic()
        try await waitUntil { harness.app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(harness.app.activities.first?.status, .completed)
        XCTAssertEqual(SequenceStub.requests, Expected.pull)
    }

    /// Summary: the same reads as a pull, then the AI call (not a forum request).
    func testSummary() async throws {
        let harness = makeHarness(forum: SequenceForum(postCounts: ["123": 250]))
        XCTAssertTrue(harness.app.enqueueSummary(for: topic("123")))
        try await waitUntil { harness.app.activities.allSatisfy(\.status.isTerminal) }
        XCTAssertEqual(harness.app.activities.first?.status, .completed)
        XCTAssertEqual(harness.ai.calls.map(\.kind), ["summary"])
        XCTAssertEqual(SequenceStub.requests, Expected.summary)
    }

    /// Agent `read_topic`: the topic's reads, one tool call.
    func testAgentReadTopic() async throws {
        let planner = SequencePlanner(actions: [
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "123"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done"])
        ])
        let harness = makeHarness(forum: SequenceForum(postCounts: ["123": 250]), planner: planner)
        harness.app.startAgentRun(goal: "What is in topic 123?", siteURL: site)
        try await waitUntil { harness.app.agentRuns.first?.isFinished ?? false }
        XCTAssertEqual(harness.app.agentRuns.first?.result, .completed)
        XCTAssertEqual(SequenceStub.requests, Expected.agentReadTopic)
    }

    /// The watch check: one topic JSON per watched topic, checked longest ago
    /// first (never-checked topics before the rest), nothing else.
    func testWatchCheck() async throws {
        func watched(_ id: String, checked: Date?) -> WatchedTopic {
            var topic = WatchedTopic(
                siteURL: site, topicID: id, url: URL(string: "\(site)/t/topic-\(id)/\(id)")!,
                title: "Topic \(id)", knownPostCount: 1
            )
            topic.lastCheckedAt = checked
            return topic
        }
        var snapshot = AppSnapshot(watchedTopics: [
            watched("30", checked: Date(timeIntervalSince1970: 2_000)),
            watched("20", checked: Date(timeIntervalSince1970: 1_000)),
            watched("10", checked: nil)
        ])
        snapshot.settings.watchAutoRefreshSummaries = false
        let harness = makeHarness(forum: SequenceForum(postCounts: ["10": 4, "20": 3, "30": 9]), snapshot: snapshot)
        await harness.app.checkWatchedTopics(reason: .manual)
        let replies = Dictionary(uniqueKeysWithValues: harness.app.watchedTopics.map { ($0.topicID, $0.newReplies) })
        XCTAssertEqual(replies, ["10": 3, "20": 2, "30": 8])
        XCTAssertEqual(SequenceStub.requests, Expected.watchCheck)
    }

    // MARK: Digest prefetch

    private func pinned() -> AppSnapshot {
        AppSnapshot(forums: [Forum(siteURL: site, kind: .discourse, name: "Sequence Forum", isPinned: true, pinOrder: 0)])
    }

    /// `/top.json?period=daily` answers: the planned cards' topic JSON follows.
    func testDigestPrefetchWithATopList() async throws {
        let harness = makeHarness(forum: SequenceForum(top: (200, SequenceForum.list([7, 8]))), snapshot: pinned())
        let prefetch = await harness.app.prefetchDigestInputs(background: true)
        XCTAssertEqual(prefetch.trending[site]?.map(\.id), [7, 8])
        XCTAssertEqual(SequenceStub.requests, Expected.digestTop)
    }

    /// `/top.json` unavailable: `/latest.json` is asked next.
    func testDigestPrefetchFallsBackToLatestWhenTopFails() async throws {
        let harness = makeHarness(
            forum: SequenceForum(top: (404, "missing"), latest: (200, SequenceForum.list([7, 8]))),
            snapshot: pinned()
        )
        let prefetch = await harness.app.prefetchDigestInputs(background: true)
        XCTAssertEqual(prefetch.trending[site]?.map(\.id), [7, 8])
        XCTAssertEqual(SequenceStub.requests, Expected.digestLatestAfterFailure)
    }

    /// `/top.json` empty on a quiet day: `/latest.json` is asked next too.
    func testDigestPrefetchFallsBackToLatestWhenTopIsEmpty() async throws {
        let harness = makeHarness(forum: SequenceForum(latest: (200, SequenceForum.list([7]))), snapshot: pinned())
        let prefetch = await harness.app.prefetchDigestInputs(background: true)
        XCTAssertEqual(prefetch.trending[site]?.map(\.id), [7])
        XCTAssertEqual(SequenceStub.requests, Expected.digestLatestAfterEmpty)
    }

    // MARK: Navigation

    /// Voice and navigation `focus(.op)`: the topic's overview (for the
    /// opening poster), then the opening poster's filtered JSON, then the
    /// text of the first post it lists.
    func testFocusOpeningPoster() async throws {
        let harness = makeHarness()
        harness.deliver(topicPage(topic("123")))
        let result = await harness.app.focus(.op)
        XCTAssertEqual(result.status, .focused)
        XCTAssertEqual(SequenceStub.requests, Expected.focusOP)
    }

    // MARK: Helpers

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

/// Plays the given actions in order, then finishes.
private final class SequencePlanner: AgentPlanner, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [AgentAction]

    init(actions: [AgentAction]) {
        self.actions = actions
    }

    func nextAction(
        system: String,
        transcript: [ChatMessage],
        configuration: ProviderConfiguration,
        provider: AIProvider
    ) async throws -> AgentAction {
        lock.withLock {
            actions.isEmpty
                ? AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "n/a"])
                : actions.removeFirst()
        }
    }
}

// MARK: - Expected sequences (recorded from the pre-P0 code; do not edit)

private enum Expected {
    static let pull: [String] = [
        "forum.example/forum/t/123.json",
        "forum.example/forum/raw/123?page=1",
        "forum.example/forum/raw/123?page=2",
        "forum.example/forum/raw/123?page=3"
    ]
    static let summary: [String] = [
        "forum.example/forum/t/123.json",
        "forum.example/forum/raw/123?page=1",
        "forum.example/forum/raw/123?page=2",
        "forum.example/forum/raw/123?page=3"
    ]
    static let agentReadTopic: [String] = [
        "forum.example/forum/t/123.json",
        "forum.example/forum/t/123.json",
        "forum.example/forum/raw/123?page=1",
        "forum.example/forum/raw/123?page=2",
        "forum.example/forum/raw/123?page=3"
    ]
    static let watchCheck: [String] = [
        "forum.example/forum/t/10.json",
        "forum.example/forum/t/20.json",
        "forum.example/forum/t/30.json"
    ]
    static let digestTop: [String] = [
        "forum.example/forum/top.json?period=daily",
        "forum.example/forum/t/7.json",
        "forum.example/forum/t/8.json"
    ]
    static let digestLatestAfterFailure: [String] = [
        "forum.example/forum/top.json?period=daily",
        "forum.example/forum/latest.json",
        "forum.example/forum/t/7.json",
        "forum.example/forum/t/8.json"
    ]
    static let digestLatestAfterEmpty: [String] = [
        "forum.example/forum/top.json?period=daily",
        "forum.example/forum/latest.json",
        "forum.example/forum/t/7.json"
    ]
    static let focusOP: [String] = [
        "forum.example/forum/t/123.json",
        "forum.example/forum/t/123.json?username_filters=alice",
        "forum.example/forum/t/123/posts.json?post_ids%5B%5D=1001"
    ]
}
