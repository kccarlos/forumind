import XCTest
@testable import Forumind

/// Forum reads on a bad connection (ForumService.swift): dropped
/// connections and gateway errors are retried, a request the page could not
/// make goes out directly, and pages already fetched are kept when a read
/// fails part way.
@MainActor
final class ForumRobustnessTests: XCTestCase {
    private let site = "https://forum.example.com"

    override func setUp() async throws {
        FlakyForumStub.reset(posts: 250)
    }

    // MARK: Retries

    func testDroppedConnectionsAndGatewayErrorsAreRetriedWithBackOff() async throws {
        let clock = FakePacingClock()
        FlakyForumStub.fail("/raw/7?page=2", with: [.transport(.networkConnectionLost), .status(503)])
        let result = try await fetch(service(clock: clock))
        XCTAssertEqual(result.rawPages.map(\.page), [1, 2, 3])
        XCTAssertEqual(FlakyForumStub.count(of: "/raw/7?page=2"), 3)
        // Gentle: one request a second; the retries wait 1 s, then 2 s.
        XCTAssertEqual(clock.sleeps, [1, 2, 3, 5, 6])
    }

    func testOfflineIsNotRetriedAndRetriesAreBounded() async throws {
        FlakyForumStub.fail("/raw/7?page=1", with: [.transport(.notConnectedToInternet)])
        do {
            _ = try await fetch(service(clock: FakePacingClock()))
            XCTFail("expected the offline error")
        } catch {
            XCTAssertEqual(NetworkFailure.classify(error), .offline)
        }
        XCTAssertEqual(FlakyForumStub.count(of: "/raw/7?page=1"), 1, "no retry while offline")

        FlakyForumStub.reset(posts: 250)
        FlakyForumStub.fail("/raw/7?page=1", with: Array(repeating: .transport(.timedOut), count: 10))
        do {
            _ = try await fetch(service(clock: FakePacingClock()))
            XCTFail("expected the timeout")
        } catch {
            XCTAssertEqual(NetworkFailure.classify(error), .transient)
        }
        XCTAssertEqual(FlakyForumStub.count(of: "/raw/7?page=1"), 4, "the first try and three retries")
    }

    // MARK: The page's own requests

    /// The page's `fetch()` failing (or the page going away) is not the end:
    /// the request goes to the forum directly.
    func testARequestThePageCouldNotMakeGoesOutDirectly() async throws {
        let result = try await fetch(service(clock: FakePacingClock()), loader: { _ in
            throw URLError(.cancelled)  // what WebKit reports when the page navigates away
        })
        XCTAssertEqual(result.rawPages.map(\.page), [1, 2, 3])
        XCTAssertEqual(FlakyForumStub.count(of: "/t/7.json"), 1)
    }

    // MARK: Partial reads

    /// Pages that arrived before a read failed are handed over (with the
    /// post count they were read at); the next read fetches only the rest,
    /// even when the session's count moved on meanwhile (a watch check).
    func testPagesReadBeforeAFailureAreKeptAndNotFetchedAgain() async throws {
        FlakyForumStub.fail("/raw/7?page=3", with: [.status(404)])
        let kept = PageSink()
        do {
            _ = try await fetch(service(clock: FakePacingClock()), onPage: { await kept.add($0) })
            XCTFail("expected the 404")
        } catch {}
        let pages = kept.pages.sorted { $0.page < $1.page }
        XCTAssertEqual(pages.map(\.page), [1, 2])
        XCTAssertEqual(pages.map(\.topicPostCount), [250, 250])

        FlakyForumStub.reset(posts: 250)
        let result = try await fetch(service(clock: FakePacingClock()), cachedPages: pages, knownTotalPosts: 300)
        XCTAssertEqual(result.rawPages.map(\.page), [1, 2, 3])
        XCTAssertEqual(FlakyForumStub.requests, ["/t/7.json", "/raw/7?page=3"])
    }

    // MARK: Stalls and cancellation

    /// An operation that ignores cancellation (WebKit's script calls) still
    /// returns at once on a cancel, and fails at its timeout.
    func testPromptCancellationDoesNotWaitForTheOperation() async throws {
        let stall = Stall()
        addTeardownBlock { stall.release() }
        let task = Task { try await withPromptCancellation(timeout: .seconds(3_600)) { await stall.wait() } }
        try await waitUntil { stall.isWaiting }
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)

        do {
            _ = try await withPromptCancellation(timeout: .milliseconds(50)) { await stall.wait() }
            XCTFail("expected the timeout")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    /// A page request that never answers: cancelling the read returns at
    /// once and gives the forum's slot back, so the next read goes ahead;
    /// one that stalls past the timeout goes out directly instead.
    func testAStalledPageRequestNeitherHoldsTheSlotNorBlocksTheRead() async throws {
        let stall = Stall()
        addTeardownBlock { stall.release() }
        let pacer = ForumRequestPacer(clock: InstantPacingClock())
        let service = service(pacer: pacer)
        let read = Task { try await self.fetch(service, loader: { _ in await stall.wait() }) }
        try await waitUntil { stall.isWaiting }
        let started = Date()
        read.cancel()
        do {
            _ = try await read.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        let inFlight = await pacer.inFlight(for: URL(string: site)!)
        XCTAssertEqual(inFlight, 0, "the slot was given back")
        let next = try await fetch(service)
        XCTAssertEqual(next.rawPages.count, 3, "the next read goes ahead")

        let impatient = self.service(pacer: pacer, resourceLoaderTimeout: .milliseconds(50))
        FlakyForumStub.reset(posts: 250)
        let direct = try await fetch(impatient, loader: { _ in await stall.wait() })
        XCTAssertEqual(direct.rawPages.count, 3)
        XCTAssertEqual(FlakyForumStub.count(of: "/t/7.json"), 1, "went out directly after the timeout")
    }

    // MARK: Helpers

    private final class PageSink: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [RawForumPage] = []
        var pages: [RawForumPage] { lock.withLock { stored } }
        func add(_ page: RawForumPage) async { lock.withLock { stored.append(page) } }
    }

    private func service(clock: FakePacingClock) -> ForumService {
        service(pacer: ForumRequestPacer(clock: clock))
    }

    private func service(pacer: ForumRequestPacer, resourceLoaderTimeout: Duration = .seconds(75)) -> ForumService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FlakyForumStub.self]
        return ForumService(
            session: URLSession(configuration: configuration),
            pacer: pacer,
            resourceLoaderTimeout: resourceLoaderTimeout
        )
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

    /// Waits, ignoring cancellation, until released (a page that never answers).
    private final class Stall: @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var released = false
        var isWaiting: Bool { lock.withLock { !waiters.isEmpty } }

        func wait() async -> ForumResourceResponse {
            await withCheckedContinuation { continuation in
                let resumeNow: Bool = lock.withLock {
                    if released { return true }
                    waiters.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
            return ForumResourceResponse(statusCode: 500, statusText: "", retryAfter: nil, data: Data())
        }

        func release() {
            let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
                released = true
                defer { waiters = [] }
                return waiters
            }
            pending.forEach { $0.resume() }
        }
    }

    private func fetch(
        _ service: ForumService,
        cachedPages: [RawForumPage] = [],
        knownTotalPosts: Int? = nil,
        loader: (@MainActor (URL) async throws -> ForumResourceResponse)? = nil,
        onPage: (@Sendable (RawForumPage) async -> Void)? = nil
    ) async throws -> ForumFetchResult {
        try await DiscourseAdapter().readTopic(
            TopicReadRequest(
                topic: TopicRef(siteURL: site, topicID: "7"),
                cachedPages: cachedPages,
                knownTotalPosts: knownTotalPosts
            ),
            net: service.net(site, resourceLoader: loader, pace: .gentle),
            progress: { _ in },
            onPage: onPage
        )
    }
}

/// `/t/{id}.json` and `/raw/{id}?page=N` of a topic with `posts` posts;
/// requests can be made to fail, in order, by path and query.
final class FlakyForumStub: URLProtocol {
    enum Failure {
        case transport(URLError.Code)
        case status(Int)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var posts = 250
    nonisolated(unsafe) private static var failures: [String: [Failure]] = [:]
    nonisolated(unsafe) private static var seen: [String] = []

    static func reset(posts: Int) {
        lock.withLock {
            self.posts = posts
            failures = [:]
            seen = []
        }
    }

    static func fail(_ request: String, with failures: [Failure]) {
        lock.withLock { self.failures[request] = failures }
    }

    /// Every request so far, as path?query.
    static var requests: [String] { lock.withLock { seen } }

    static func count(of request: String) -> Int {
        lock.withLock { seen.filter { $0 == request }.count }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let key = url.path + (url.query.map { "?\($0)" } ?? "")
        let (failure, posts): (Failure?, Int) = Self.lock.withLock {
            Self.seen.append(key)
            var queued = Self.failures[key] ?? []
            let next = queued.isEmpty ? nil : queued.removeFirst()
            Self.failures[key] = queued
            return (next, Self.posts)
        }
        var status = 200
        switch failure {
        case .transport(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        case .status(let code):
            status = code
        case nil:
            break
        }
        let body = url.path.hasSuffix(".json")
            ? #"{"posts_count":\#(posts),"highest_post_number":\#(posts),"title":"Topic"}"#
            : "raw \(key)"
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
