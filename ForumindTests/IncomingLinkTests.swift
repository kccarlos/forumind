import XCTest
@testable import Forumind

final class IncomingLinkTests: XCTestCase {
    private var inboxDirectory: URL!

    override func setUpWithError() throws {
        inboxDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncomingLinkTests-\(UUID().uuidString)", isDirectory: true)
        SharedInbox.storageURLOverride = inboxDirectory
            .appendingPathComponent(SharedInbox.fileName, isDirectory: false)
    }

    override func tearDownWithError() throws {
        SharedInbox.storageURLOverride = nil
        try? FileManager.default.removeItem(at: inboxDirectory)
    }

    // MARK: - URL building and parsing

    func testRoundTripPreservesAwkwardURLAndTitle() throws {
        let pageURL = try XCTUnwrap(
            URL(string: "https://meta.discourse.org/t/some-topic/123/4?u=a&b=1+2&q=%E2%9C%93#post_4")
        )
        let request = IncomingLinkRequest(
            url: pageURL,
            action: .summary,
            title: "Cards & Points = Fun + Games ✓"
        )

        let link = IncomingLink.url(for: request)
        XCTAssertEqual(link.scheme, "forumind")
        XCTAssertEqual(link.host, "open")

        let parsed = try XCTUnwrap(IncomingLink.parse(link, now: request.createdAt))
        XCTAssertEqual(parsed, request)
    }

    func testEveryActionRoundTrips() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://forum.example.com/latest"))
        for action in IncomingLinkRequest.Action.allCases {
            let request = IncomingLinkRequest(url: pageURL, action: action)
            let parsed = IncomingLink.parse(IncomingLink.url(for: request))
            XCTAssertEqual(parsed?.action, action)
            XCTAssertEqual(parsed?.id, request.id)
            XCTAssertNil(parsed?.title)
        }
    }

    func testParsesMinimalLinkWithDefaultAction() throws {
        let link = try XCTUnwrap(
            URL(string: "forumind://open?url=https%3A%2F%2Fforum.example.com%2Ft%2Ftopic%2F42")
        )
        let parsed = try XCTUnwrap(IncomingLink.parse(link))
        XCTAssertEqual(parsed.url.absoluteString, "https://forum.example.com/t/topic/42")
        XCTAssertEqual(parsed.action, .open)
        XCTAssertNil(parsed.title)
    }

    func testUnknownActionFallsBackToOpen() throws {
        let link = try XCTUnwrap(
            URL(string: "forumind://open?url=https://a.example/t/1&action=explode")
        )
        XCTAssertEqual(IncomingLink.parse(link)?.action, .open)
        let upper = try XCTUnwrap(
            URL(string: "forumind://open?url=https://a.example/t/1&action=CHAT")
        )
        XCTAssertEqual(IncomingLink.parse(upper)?.action, .chat)
    }

    func testRejectsNonWebPagesAndForeignLinks() throws {
        let rejected = [
            "forumind://open?url=javascript%3Aalert(1)",
            "forumind://open?url=file%3A%2F%2F%2Fetc%2Fpasswd",
            "forumind://open?url=ftp%3A%2F%2Fexample.com",
            "forumind://open?url=https%3A%2F%2F",
            "forumind://open?action=summary",
            "forumind://open",
            "forumind://settings?url=https%3A%2F%2Fa.example",
            "https://open?url=https%3A%2F%2Fa.example",
            "otherapp://open?url=https%3A%2F%2Fa.example"
        ]
        for string in rejected {
            let link = try XCTUnwrap(URL(string: string), string)
            XCTAssertNil(IncomingLink.parse(link), string)
        }
    }

    func testParseNormalizesTitleAndIgnoresBadID() throws {
        let link = try XCTUnwrap(
            URL(string: "forumind://open?url=https://a.example/t/1&title=%20%20Hello%0A%20world%20&id=nope")
        )
        let parsed = try XCTUnwrap(IncomingLink.parse(link))
        XCTAssertEqual(parsed.title, "Hello world")
    }

    // MARK: - Shared text

    func testExtractsURLFromChromeStyleText() {
        XCTAssertEqual(
            IncomingLink.extractWebURL(from: "Great thread\nhttps://meta.discourse.org/t/abc/99")?
                .absoluteString,
            "https://meta.discourse.org/t/abc/99"
        )
        XCTAssertEqual(
            IncomingLink.extractWebURL(from: "  https://a.example/t/x/1?page=2  ")?.absoluteString,
            "https://a.example/t/x/1?page=2"
        )
        XCTAssertEqual(
            IncomingLink.extractWebURL(from: "See (https://a.example/t/x/1).")?.host,
            "a.example"
        )
    }

    func testExtractIgnoresTextWithoutWebURL() {
        XCTAssertNil(IncomingLink.extractWebURL(from: ""))
        XCTAssertNil(IncomingLink.extractWebURL(from: "just some words"))
        XCTAssertNil(IncomingLink.extractWebURL(from: "mailto:someone@example.com"))
    }

    // MARK: - Shared inbox

    func testInboxDrainsOldestFirstAndEmpties() throws {
        let now = Date()
        let first = makeRequest(createdAt: now.addingTimeInterval(-60), action: .chat)
        let second = makeRequest(createdAt: now.addingTimeInterval(-30), action: .agent)

        XCTAssertTrue(SharedInbox.enqueue(second, now: now))
        XCTAssertTrue(SharedInbox.enqueue(first, now: now))

        XCTAssertEqual(SharedInbox.drainAll(now: now), [first, second])
        XCTAssertEqual(SharedInbox.drainAll(now: now), [])
    }

    func testInboxDropsExpiredEntries() {
        let now = Date()
        let stale = makeRequest(createdAt: now.addingTimeInterval(-(SharedInbox.maximumAge + 60)))
        let fresh = makeRequest(createdAt: now.addingTimeInterval(-60))
        SharedInbox.enqueue(stale, now: stale.createdAt)
        SharedInbox.enqueue(fresh, now: now)

        XCTAssertEqual(SharedInbox.drainAll(now: now), [fresh])
    }

    func testInboxRemoveByIDAndDeduplicatesEnqueue() {
        let now = Date()
        let kept = makeRequest(createdAt: now.addingTimeInterval(-20))
        var removed = makeRequest(createdAt: now.addingTimeInterval(-10))
        SharedInbox.enqueue(kept, now: now)
        SharedInbox.enqueue(removed, now: now)
        removed.action = .summary
        SharedInbox.enqueue(removed, now: now)

        SharedInbox.remove(id: removed.id)
        XCTAssertEqual(SharedInbox.drainAll(now: now), [kept])
    }

    func testInboxCapsStoredEntries() {
        let now = Date()
        let requests = (0..<(SharedInbox.maximumCount + 5)).map {
            makeRequest(createdAt: now.addingTimeInterval(TimeInterval($0 - 100)))
        }
        requests.forEach { SharedInbox.enqueue($0, now: now) }

        let drained = SharedInbox.drainAll(now: now)
        XCTAssertEqual(drained.count, SharedInbox.maximumCount)
        XCTAssertEqual(drained.last, requests.last)
    }

    func testInboxIgnoresCorruptFile() throws {
        let fileURL = try XCTUnwrap(SharedInbox.storageURL)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: fileURL)

        XCTAssertEqual(SharedInbox.drainAll(), [])
        let request = makeRequest(createdAt: Date())
        XCTAssertTrue(SharedInbox.enqueue(request))
        XCTAssertEqual(SharedInbox.drainAll(), [request])
    }

    func testInboxRemoveReportsWhetherTheRequestWasQueued() {
        let now = Date()
        let queued = makeRequest(createdAt: now.addingTimeInterval(-5))
        let other = makeRequest(createdAt: now.addingTimeInterval(-4))
        SharedInbox.enqueue(queued, now: now)
        SharedInbox.enqueue(other, now: now)

        XCTAssertTrue(SharedInbox.remove(id: queued.id, now: now))
        XCTAssertFalse(SharedInbox.remove(id: queued.id, now: now))
        XCTAssertFalse(SharedInbox.remove(id: UUID(), now: now))
        // An expired entry does not vouch for a link.
        XCTAssertFalse(
            SharedInbox.remove(id: other.id, now: now.addingTimeInterval(SharedInbox.maximumAge + 60))
        )
    }

    // MARK: - Deep links and AI work

    /// Any app or page can open `forumind://open?...&action=summary`;
    /// without a matching inbox entry it opens the Assistant but spends no credits.
    @MainActor
    func testDeepLinkWithoutInboxEntryDoesNotStartASummary() throws {
        let app = makeReadyApp()
        let request = IncomingLinkRequest(url: topicURL, action: .summary)

        app.handleDeepLink(IncomingLink.url(for: request))
        deliverTopicPage(to: app)

        XCTAssertTrue(app.presentAssistant)
        XCTAssertEqual(app.assistantMode, .summary)
        XCTAssertEqual(app.currentTopic?.topicKey, "forum.example.com/t/42")
        XCTAssertFalse(app.activities.contains { $0.type == .summary })
    }

    @MainActor
    func testShareExtensionDeepLinkStartsTheSummary() throws {
        let app = makeReadyApp()
        let request = IncomingLinkRequest(url: topicURL, action: .summary)
        XCTAssertTrue(SharedInbox.enqueue(request))

        app.handleDeepLink(IncomingLink.url(for: request))
        deliverTopicPage(to: app)

        XCTAssertTrue(app.activities.contains {
            $0.type == .summary && $0.topicKey == "forum.example.com/t/42"
        })
        XCTAssertEqual(SharedInbox.drainAll(), [])
        for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
    }

    private let topicURL = URL(string: "https://forum.example.com/t/topic/42")!

    @MainActor
    private func makeReadyApp() -> AppModel {
        let app = AppModel(
            store: PersistentStore(
                fileURL: inboxDirectory.appendingPathComponent("state.json")
            )
        )
        app.settings.selectedProvider = .ollama
        var configuration = app.settings.configuration(for: .ollama)
        configuration.model = "llama3.2"
        app.settings.setConfiguration(configuration, for: .ollama)
        XCTAssertTrue(app.isProviderReady)
        return app
    }

    /// What the browser reports once the shared topic has loaded.
    @MainActor
    private func deliverTopicPage(to app: AppModel) {
        let siteURL = "https://forum.example.com"
        let topic = ForumTopic(siteURL: siteURL, topicID: "42", url: topicURL, title: "Topic")
        app.browser.onPageContextChanged?(
            PageContext(
                url: topicURL,
                isDiscourse: true,
                siteURL: siteURL,
                forumName: "Example",
                topic: topic,
                state: .topic
            )
        )
    }

    private func makeRequest(
        createdAt: Date,
        action: IncomingLinkRequest.Action = .open
    ) -> IncomingLinkRequest {
        IncomingLinkRequest(
            url: URL(string: "https://forum.example.com/t/topic/\(Int.random(in: 1...9999))")!,
            action: action,
            title: "Topic",
            createdAt: createdAt
        )
    }
}
