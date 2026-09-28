import XCTest
@testable import Forumind

// Paced forum requests (ForumRequestPacing.swift): per-host spacing and
// concurrency, Retry-After, cancellation, cached pages, the setting, and
// watched-topic checks. A fake clock stands in for time, so nothing here
// really sleeps.

/// Never waits (tests that don't care about pacing).
struct InstantPacingClock: ForumPacingClock {
    func now() -> TimeInterval { 0 }
    func sleep(until deadline: TimeInterval) async throws {
        try Task.checkCancellation()
    }
}

/// Virtual time: a sleep jumps the clock to its deadline at once. With
/// `blocks`, a sleep to a future deadline waits until the task is cancelled.
final class FakePacingClock: ForumPacingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var deadlines: [TimeInterval] = []
    private let blocks: Bool

    init(blocks: Bool = false) {
        self.blocks = blocks
    }

    /// Future deadlines slept to, in order.
    var sleeps: [TimeInterval] { lock.withLock { deadlines } }

    func now() -> TimeInterval { lock.withLock { current } }

    func sleep(until deadline: TimeInterval) async throws {
        try Task.checkCancellation()
        guard deadline > now() else { return }
        if blocks {
            try await Task.sleep(for: .seconds(3_600))
        }
        lock.withLock {
            deadlines.append(deadline)
            current = max(current, deadline)
        }
        await Task.yield()
    }
}

/// Records what the forum was asked and when (virtual time).
@MainActor
private final class RequestLog {
    struct Entry: Equatable {
        var path: String
        var page: Int?
        var time: TimeInterval
    }

    private(set) var entries: [Entry] = []
    private(set) var maxInFlight = 0
    private var inFlight = 0
    let clock: FakePacingClock
    /// Status (and Retry-After) for the nth request to a path+page; default 200.
    var failures: [String: [(status: Int, retryAfter: String?)]] = [:]
    var postsCount = 450

    init(clock: FakePacingClock) {
        self.clock = clock
    }

    func loader(_ url: URL) async throws -> ForumResourceResponse {
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init)
        entries.append(Entry(path: url.path, page: page, time: clock.now()))
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        // Stay in flight across a few hops so overlapping requests overlap.
        for _ in 0..<5 { await Task.yield() }
        inFlight -= 1

        let key = "\(url.path)#\(page ?? 0)"
        if var queued = failures[key], !queued.isEmpty {
            let failure = queued.removeFirst()
            failures[key] = queued
            return ForumResourceResponse(
                statusCode: failure.status,
                statusText: "Too Many Requests",
                retryAfter: failure.retryAfter,
                data: Data()
            )
        }
        let body = url.path.hasSuffix(".json")
            ? #"{"posts_count":\#(postsCount),"highest_post_number":\#(postsCount),"title":"Topic"}"#
            : "raw-page-\(page ?? 0)"
        return ForumResourceResponse(statusCode: 200, statusText: "OK", retryAfter: nil, data: Data(body.utf8))
    }
}

@MainActor
final class ForumPacingTests: XCTestCase {
    private let site = "https://forum.example.com"

    private func fetch(
        _ service: ForumService,
        log: RequestLog,
        pace: ForumRequestPace,
        site: String? = nil,
        cachedPages: [RawForumPage] = [],
        knownTotalPosts: Int? = nil
    ) async throws -> ForumFetchResult {
        try await service.fetchTopic(
            siteURL: site ?? self.site,
            topicID: "7",
            cachedPages: cachedPages,
            knownTotalPosts: knownTotalPosts,
            cookieHeader: nil,
            resourceLoader: { url in try await log.loader(url) },
            pace: pace
        ) { _ in }
    }

    // MARK: Presets

    func testPresetsAndDefault() {
        XCTAssertEqual(ForumRequestPace.default, .gentle)
        XCTAssertEqual(ForumRequestPace.allCases.map(\.minimumInterval), [1, 0.5, 0])
        XCTAssertEqual(ForumRequestPace.allCases.map(\.maximumConcurrency), [1, 2, 4])
    }

    func testSettingDecodesMissingAndUnknownAsGentleAndRoundTrips() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"systemPrompt":"x"}"#.utf8))
        XCTAssertEqual(old.forumRequestPace, .gentle, "existing users get the polite default")
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"forumRequestPace":"warp"}"#.utf8))
        XCTAssertEqual(unknown.forumRequestPace, .gentle)
        XCTAssertEqual(AppSettings().forumRequestPace, .gentle)

        var settings = AppSettings()
        settings.forumRequestPace = .fast
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.forumRequestPace, .fast)
        // It syncs (not a device-local setting).
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("forumRequestPace"))
        XCTAssertEqual(try SyncSchema.settingsUnits(settings)["forumRequestPace"], .string("fast"))
    }

    // MARK: Spacing and concurrency

    func testGentleIsSequentialOneRequestPerSecondInOrder() async throws {
        let clock = FakePacingClock()
        let log = RequestLog(clock: clock)
        let service = ForumService(pacer: ForumRequestPacer(clock: clock))
        let result = try await fetch(service, log: log, pace: .gentle)

        XCTAssertEqual(result.rawPages.map(\.page), [1, 2, 3, 4, 5])
        XCTAssertEqual(log.entries.map(\.page), [nil, 1, 2, 3, 4, 5], "topic JSON, then pages in order")
        XCTAssertEqual(log.entries.map(\.time), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(log.maxInFlight, 1)
    }

    func testStandardAndFastAllowMoreAtOnce() async throws {
        for (pace, spacing, elapsed) in [(ForumRequestPace.standard, 0.5, 2.5), (.fast, 0, 0)] {
            let clock = FakePacingClock()
            let log = RequestLog(clock: clock)
            let service = ForumService(pacer: ForumRequestPacer(clock: clock))
            let result = try await fetch(service, log: log, pace: pace)
            XCTAssertEqual(result.rawPages.map(\.page), [1, 2, 3, 4, 5])
            XCTAssertLessThanOrEqual(log.maxInFlight, pace.maximumConcurrency, "\(pace)")
            XCTAssertGreaterThan(log.maxInFlight, 1, "\(pace) overlaps requests")
            XCTAssertEqual(clock.now(), elapsed, accuracy: 1e-9, "\(pace)")
            // The start times handed out: every request after the first
            // waited `spacing` more than the one before (none at Fast).
            let starts = clock.sleeps.sorted()
            XCTAssertEqual(starts.count, spacing > 0 ? 5 : 0, "\(pace)")
            for (index, start) in starts.enumerated() {
                XCTAssertEqual(start, spacing * Double(index + 1), accuracy: 1e-9, "\(pace)")
            }
        }
    }

    func testPacerCapsRequestsInFlightPerPace() async throws {
        let pacer = ForumRequestPacer(clock: FakePacingClock())
        let url = URL(string: "https://forum.example.com/t/1.json")!
        for (pace, limit) in [(ForumRequestPace.standard, 2), (.fast, 4)] {
            var held: [String] = []
            for _ in 0..<limit { held.append(try await pacer.acquire(for: url, pace: pace)) }
            let inFlight = await pacer.inFlight(for: url)
            XCTAssertEqual(inFlight, limit)

            let extra = Task { try await pacer.acquire(for: url, pace: pace) }
            try await Task.sleep(for: .milliseconds(50))
            let stillCapped = await pacer.inFlight(for: url)
            XCTAssertEqual(stillCapped, limit, "the next request waits for a slot")

            await pacer.release(held.removeFirst())
            held.append(try await extra.value)
            for host in held { await pacer.release(host) }
            let after = await pacer.inFlight(for: url)
            XCTAssertEqual(after, 0)
        }
    }

    func testHostsArePacedIndependently() async throws {
        let clock = FakePacingClock()
        let pacer = ForumRequestPacer(clock: clock)
        let a = URL(string: "https://one.example.com/t/1.json")!
        let b = URL(string: "https://two.example.org/t/1.json")!

        let first = try await pacer.acquire(for: a, pace: .gentle)
        await pacer.release(first)
        // Another forum starts right away; the same forum waits its second.
        let other = try await pacer.acquire(for: b, pace: .gentle)
        XCTAssertEqual(clock.now(), 0)
        let second = try await pacer.acquire(for: a, pace: .gentle)
        XCTAssertEqual(clock.now(), 1)
        await pacer.release(other)
        await pacer.release(second)

        // Two forums read at the same time: each at its own pace, so both
        // finish in the time one takes (6 requests, 5 s), not twice that.
        let log = RequestLog(clock: FakePacingClock())
        let service = ForumService(pacer: ForumRequestPacer(clock: log.clock))
        async let one = fetch(service, log: log, pace: .gentle, site: "https://one.example.com")
        async let two = fetch(service, log: log, pace: .gentle, site: "https://two.example.org")
        let results = try await [one, two]
        XCTAssertEqual(results.map(\.rawPages.count), [5, 5])
        XCTAssertEqual(log.entries.count, 12)
        XCTAssertEqual(log.clock.now(), 5)
    }

    // MARK: Retry-After, cancellation, cache

    func testRetryAfterIsHonoredOnTopOfThePace() async throws {
        let clock = FakePacingClock()
        let log = RequestLog(clock: clock)
        log.postsCount = 150
        log.failures["/raw/7#1"] = [(429, "5")]
        let service = ForumService(pacer: ForumRequestPacer(clock: clock))
        let result = try await fetch(service, log: log, pace: .gentle)

        XCTAssertEqual(result.rawPages.map(\.page), [1, 2])
        XCTAssertEqual(log.entries.map(\.page), [nil, 1, 1, 2])
        // JSON at 0, page 1 at 1 (429, Retry-After 5), retry at 6, page 2 a second later.
        XCTAssertEqual(log.entries.map(\.time), [0, 1, 6, 7])

        // Without a Retry-After the backoff is exponential (2 s first), and
        // it holds back every request to that forum, even at Fast.
        let fastClock = FakePacingClock()
        let fastLog = RequestLog(clock: fastClock)
        fastLog.postsCount = 50
        fastLog.failures["/raw/7#1"] = [(429, nil)]
        _ = try await fetch(ForumService(pacer: ForumRequestPacer(clock: fastClock)), log: fastLog, pace: .fast)
        XCTAssertEqual(fastLog.entries.map(\.time), [0, 0, 2])
    }

    func testCancellingDuringAWaitStopsPromptlyWithoutRequesting() async throws {
        let clock = FakePacingClock(blocks: true)
        let log = RequestLog(clock: clock)
        let pacer = ForumRequestPacer(clock: clock)
        let service = ForumService(pacer: pacer)
        let task = Task { try await self.fetch(service, log: log, pace: .gentle) }
        try await waitUntil { log.entries.count == 1 }  // topic JSON done; page 1 waits a second

        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertEqual(log.entries.count, 1, "no page was requested after the cancel")
        let inFlight = await pacer.inFlight(for: URL(string: site)!)
        XCTAssertEqual(inFlight, 0, "the slot was given back")
    }

    func testCachedPagesAreNeitherRequestedNorPaced() async throws {
        let clock = FakePacingClock()
        let log = RequestLog(clock: clock)
        let service = ForumService(pacer: ForumRequestPacer(clock: clock))
        let cached = (1...3).map { RawForumPage(page: $0, content: "cached-\($0)") }
        let result = try await fetch(service, log: log, pace: .gentle, cachedPages: cached, knownTotalPosts: 300)

        XCTAssertEqual(result.rawPages.map(\.content), ["cached-1", "cached-2", "cached-3", "raw-page-4", "raw-page-5"])
        XCTAssertEqual(log.entries.map(\.page), [nil, 4, 5])
        XCTAssertEqual(clock.sleeps, [1, 2], "only the requests that were made waited")

        // Nothing new: only the topic JSON is requested.
        let unchangedLog = RequestLog(clock: FakePacingClock())
        let all = (1...5).map { RawForumPage(page: $0, content: "cached-\($0)") }
        let unchanged = try await fetch(
            ForumService(pacer: ForumRequestPacer(clock: unchangedLog.clock)),
            log: unchangedLog, pace: .gentle, cachedPages: all, knownTotalPosts: 450
        )
        XCTAssertTrue(unchanged.unchanged)
        XCTAssertEqual(unchangedLog.entries.map(\.page), [nil])
        XCTAssertEqual(unchangedLog.clock.sleeps, [])
    }

    func testDirectURLSessionRequestsArePacedToo() async throws {
        let clock = FakePacingClock()
        PacingURLStub.reset(clock: clock)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PacingURLStub.self]
        let service = ForumService(session: URLSession(configuration: configuration), pacer: ForumRequestPacer(clock: clock))
        let result = try await service.fetchTopic(
            siteURL: site, topicID: "7", cachedPages: [], knownTotalPosts: nil, cookieHeader: nil, pace: .gentle
        ) { _ in }
        _ = try await service.search(siteURL: site, query: "pacing", cookieHeader: nil, pace: .gentle)
        _ = try await service.latestTopics(siteURL: site, cookieHeader: nil, pace: .gentle)

        XCTAssertEqual(result.rawPages.count, 3)
        XCTAssertEqual(PacingURLStub.times, [0, 1, 2, 3, 4, 5])
    }

    // MARK: Runs and watched topics (AppModel)

    func testRunsCaptureThePaceAndACancelledWaitWritesNothing() async throws {
        let clock = FakePacingClock(blocks: true)
        PacingURLStub.reset(clock: clock)
        let app = makeApp(clock: clock)
        app.settings.forumRequestPace = .gentle
        app.settings.selectedProvider = .ollama
        var configuration = app.settings.configuration(for: .ollama)
        configuration.model = "model-a"
        app.setConfiguration(configuration, for: .ollama)

        let topic = ForumTopic(siteURL: site, topicID: "7", url: URL(string: "\(site)/t/topic/7")!, title: "Topic")
        XCTAssertTrue(app.enqueueSummary(for: topic))
        try await waitUntil { PacingURLStub.times.count == 1 }  // topic JSON; page 1 waits
        let record = try XCTUnwrap(app.activities.first)
        XCTAssertEqual(record.phase, "fetching")
        XCTAssertEqual(record.statusText, "Reading response page 1 of 3…")

        app.cancel(record: record)
        try await waitUntil { app.activities.first?.status == .cancelled }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(PacingURLStub.times.count, 1)
        XCTAssertNil(app.sessions[topic.topicKey], "nothing was written back")
    }

    func testWatchedTopicsAreCheckedOldestFirst() {
        let now = Date()
        func watched(_ id: String, checked: TimeInterval?) -> WatchedTopic {
            var topic = WatchedTopic(siteURL: site, topicID: id, url: URL(string: "\(site)/t/\(id)")!, title: id, knownPostCount: 1)
            topic.lastCheckedAt = checked.map { now.addingTimeInterval(-$0) }
            return topic
        }
        let order = AppModel.watchCheckOrder([
            watched("a", checked: 60), watched("b", checked: nil), watched("c", checked: 600), watched("d", checked: nil)
        ])
        XCTAssertEqual(order.map(\.topicID), ["b", "d", "c", "a"])
    }

    func testBackgroundChecksStopAtTheBudgetAndResumeWithTheRest() async throws {
        let clock = FakePacingClock()
        PacingURLStub.reset(clock: clock)
        let topics = (1...30).map {
            WatchedTopic(siteURL: site, topicID: "\($0)", url: URL(string: "\(site)/t/\($0)")!, title: "Topic \($0)", knownPostCount: 450)
        }
        let app = makeApp(clock: clock, snapshot: AppSnapshot(watchedTopics: topics))
        XCTAssertEqual(app.settings.forumRequestPace, .gentle)

        await app.checkWatchedTopics(reason: .background)
        // One topic a second: stopped before going past the 20 s budget.
        let firstPass = PacingURLStub.paths
        XCTAssertEqual(firstPass.count, 21)
        XCTAssertEqual(firstPass.first, "/t/1.json")
        XCTAssertLessThanOrEqual(clock.now(), AppModel.backgroundWatchCheckBudget)
        XCTAssertEqual(app.watchedTopics.filter { $0.lastCheckedAt == nil }.count, 9)

        // Next time the topics left over go first.
        PacingURLStub.reset(clock: clock)
        await app.checkWatchedTopics(reason: .background)
        XCTAssertEqual(Array(PacingURLStub.paths.prefix(9)), (22...30).map { "/t/\($0).json" })

        // Foreground checks are paced but not cut short.
        PacingURLStub.reset(clock: clock)
        let before = clock.now()
        await app.checkWatchedTopics(reason: .manual)
        XCTAssertEqual(PacingURLStub.paths.count, 30)
        XCTAssertEqual(clock.now() - before, 30, accuracy: 1e-9)
    }

    /// A background check cut short while a request is in flight: URLSession
    /// throws `URLError(.cancelled)`, and that topic must stay due (not be
    /// marked checked, which would send it to the back of the queue).
    func testBackgroundCheckCancelledMidRequestLeavesThatTopicDue() async throws {
        let clock = FakePacingClock()
        PacingURLStub.reset(clock: clock)
        PacingURLStub.hangingPaths = ["/t/2.json"]
        addTeardownBlock { PacingURLStub.hangingPaths = [] }
        let topics = (1...3).map {
            WatchedTopic(siteURL: site, topicID: "\($0)", url: URL(string: "\(site)/t/\($0)")!, title: "Topic \($0)", knownPostCount: 450)
        }
        let app = makeApp(clock: clock, snapshot: AppSnapshot(watchedTopics: topics))
        let check = Task { await app.checkWatchedTopics(reason: .background) }
        try await waitUntil { PacingURLStub.paths.contains("/t/2.json") }
        check.cancel()
        await check.value

        let checked = Dictionary(uniqueKeysWithValues: app.watchedTopics.map { ($0.topicID, $0.lastCheckedAt != nil) })
        XCTAssertEqual(checked, ["1": true, "2": false, "3": false])
        XCTAssertEqual(AppModel.watchCheckOrder(app.watchedTopics).map(\.topicID).prefix(2), ["2", "3"])
    }

    /// A `429` on one request holds back a request that was already waiting
    /// for the same forum's slot: the back-off is set in the same step that
    /// hands the slot on, so the waiter never starts inside the Retry-After.
    /// (`ForumService` used to release, then back off in a second actor
    /// call, so the resumed waiter could read the old start time.)
    func testBackOffIsInPlaceBeforeTheSlotPassesToAWaiter() async throws {
        let clock = FakePacingClock()
        let pacer = ForumRequestPacer(clock: clock)
        let url = URL(string: "https://forum.example.com/t/1.json")!
        let host = try await pacer.acquire(for: url, pace: .gentle)
        let waiter = Task { try await pacer.acquire(for: url, pace: .gentle) }
        try await Task.sleep(for: .milliseconds(50))
        await pacer.release(host, backOff: 30)
        let next = try await waiter.value
        XCTAssertGreaterThanOrEqual(clock.now(), 30)
        await pacer.release(next)
        let inFlight = await pacer.inFlight(for: url)
        XCTAssertEqual(inFlight, 0)
    }

    // MARK: Helpers

    private func makeApp(clock: FakePacingClock, snapshot: AppSnapshot? = nil) -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        if let snapshot { try? store.save(snapshot) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PacingURLStub.self]
        let app = AppModel(
            store: store,
            forumService: ForumService(
                session: URLSession(configuration: configuration),
                pacer: ForumRequestPacer(clock: clock)
            )
        )
        app.usesDirectForumRequests = true
        addTeardownBlock { @MainActor in
            for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
        }
        return app
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// URLSession stub: a 250-post topic (3 pages), search and latest; records
/// each request's path and virtual time.
private final class PacingURLStub: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var clock: FakePacingClock?
    nonisolated(unsafe) private static var log: [(path: String, time: TimeInterval)] = []

    static func reset(clock: FakePacingClock) {
        lock.withLock {
            self.clock = clock
            log = []
        }
    }

    /// Paths that never get an answer (the request stays in flight).
    nonisolated(unsafe) static var hangingPaths: Set<String> = []

    static var times: [TimeInterval] { lock.withLock { log.map(\.time) } }
    static var paths: [String] { lock.withLock { log.map(\.path) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.withLock {
            Self.log.append((url.path, Self.clock?.now() ?? 0))
        }
        if Self.lock.withLock({ Self.hangingPaths.contains(url.path) }) { return }
        let body: String
        if url.path.hasSuffix("/search.json") {
            body = #"{"topics":[],"posts":[]}"#
        } else if url.path.hasSuffix("/latest.json") {
            body = #"{"topic_list":{"topics":[]}}"#
        } else if url.path.hasSuffix(".json") {
            body = #"{"posts_count":250,"highest_post_number":250,"title":"Topic"}"#
        } else {
            body = "raw"
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
