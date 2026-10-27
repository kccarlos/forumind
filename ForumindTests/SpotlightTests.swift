import CoreSpotlight
import XCTest
@testable import Forumind

/// Spotlight: which topics are indexed and how their items look, stable
/// identifiers, and that every way of deleting data (a summary, a forum,
/// "clear all", a deletion synced from another device, the switch, reset)
/// takes the items out of the index. A fake index stands in for
/// CoreSpotlight.
@MainActor
final class SpotlightTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let otherSite = "https://other.example.org"

    // MARK: Entries and items

    func testIdentifiersRoundTripThroughTheTopicKey() {
        let key = "forum.example.com/t/42"
        XCTAssertEqual(SpotlightCatalog.identifier(forTopicKey: key), "topic:forum.example.com/t/42")
        XCTAssertEqual(SpotlightCatalog.topicKey(fromIdentifier: "topic:forum.example.com/t/42"), key)
        XCTAssertNil(SpotlightCatalog.topicKey(fromIdentifier: "topic:"))
        XCTAssertNil(SpotlightCatalog.topicKey(fromIdentifier: "forum.example.com/t/42"))
    }

    func testEntriesAreTheListedForumsTopicsSummariesFirst() {
        let forums = [Forum(siteURL: site, kind: .discourse, name: "Example Forum")]
        let old = session("1", title: "Old read", accessed: 100)
        let recent = session("2", title: "Recent read", accessed: 300)
        let summarized = session("3", title: "Summarized", summary: "## Gist\n- The **fix** is in [post 4](https://forum.example.com/t/x/3/4).", accessed: 50)
        let unlisted = TopicSession(siteURL: otherSite, topicID: "9", url: URL(string: "\(otherSite)/t/x/9")!, title: "Elsewhere")
        let untitled = session("4", title: "  ", accessed: 400)

        let entries = SpotlightCatalog.entries(sessions: [old, recent, summarized, unlisted, untitled], forums: forums)

        XCTAssertEqual(entries.map(\.title), ["Summarized", "Recent read", "Old read"])
        XCTAssertEqual(entries.first?.excerpt, "Gist The fix is in post 4.")
        XCTAssertEqual(entries.first?.forumName, "Example Forum")
        XCTAssertEqual(entries[1].excerpt, "")
        XCTAssertEqual(SpotlightCatalog.entries(sessions: [old, recent, summarized], forums: forums, limit: 2).count, 2)
    }

    func testExcerptsAreOneLineCutAtAWord() {
        let long = Array(repeating: "word", count: 200).joined(separator: " ")
        let excerpt = SpotlightCatalog.excerpt(of: long)
        XCTAssertLessThanOrEqual(excerpt.count, SpotlightCatalog.excerptLength + 1)
        XCTAssertTrue(excerpt.hasSuffix("word…"))
        XCTAssertEqual(SpotlightCatalog.excerpt(of: "```\ncode\n```\n> quoted `x`"), "code quoted x")
    }

    func testTheItemCarriesTitleForumExcerptAndDomain() {
        let entry = SpotlightEntry(
            topicKey: "forum.example.com/t/3", siteURL: site, title: "Layer shifts",
            forumName: "Example Forum", excerpt: "Belts were loose.",
            url: URL(string: "\(site)/t/layer-shifts/3/12")!, lastUsed: Date(timeIntervalSince1970: 500),
            iconURL: nil
        )
        let item = SpotlightCatalog.item(for: entry, thumbnail: Data([1, 2, 3]))
        XCTAssertEqual(item.uniqueIdentifier, "topic:forum.example.com/t/3")
        XCTAssertEqual(item.domainIdentifier, site)
        XCTAssertEqual(item.attributeSet.title, "Layer shifts")
        XCTAssertEqual(item.attributeSet.contentDescription, "Example Forum · Belts were loose.")
        XCTAssertEqual(item.attributeSet.contentURL, entry.url)
        XCTAssertEqual(item.attributeSet.thumbnailData, Data([1, 2, 3]))
        XCTAssertEqual(item.attributeSet.keywords, ["Example Forum", "forum.example.com"])
    }

    func testFingerprintsChangeWithWhatTheItemShows() {
        let entry = SpotlightEntry(topicKey: "k", siteURL: site, title: "A", forumName: "F", excerpt: "", url: URL(string: "\(site)/t/a/1")!, lastUsed: Date(), iconURL: nil)
        var later = entry
        later.lastUsed = Date().addingTimeInterval(60)
        XCTAssertEqual(entry.fingerprint, later.fingerprint, "reading a topic again isn't a change")
        later.excerpt = "Now summarized."
        XCTAssertNotEqual(entry.fingerprint, later.fingerprint)
    }

    // MARK: Reconciling

    func testOnlyTheDifferenceIsSentAndANewVersionStartsOver() async {
        let index = FakeSpotlightIndex()
        let baseline = InMemorySpotlightBaseline()
        let indexer = SpotlightIndexer(index: index, baseline: baseline)
        let a = entry("1", "A")
        let b = entry("2", "B")

        await indexer.reconcile([a, b])
        XCTAssertEqual(index.deleteAllCount, 1, "a first run starts from an empty index")
        XCTAssertEqual(index.identifiers, [a.identifier, b.identifier])
        XCTAssertEqual(index.indexCalls, 1)

        await indexer.reconcile([a, b])
        XCTAssertEqual(index.indexCalls, 1, "nothing changed, nothing sent")

        var renamed = b
        renamed.title = "B2"
        await indexer.reconcile([renamed])
        XCTAssertEqual(index.deleted, [[a.identifier]])
        XCTAssertEqual(index.identifiers, [b.identifier])
        XCTAssertEqual(index.items[b.identifier]?.attributeSet.title, "B2")

        baseline.baseline?.version = SpotlightIndexer.version - 1
        await indexer.reconcile([renamed])
        XCTAssertEqual(index.deleteAllCount, 2, "an older index version is rebuilt")
        XCTAssertEqual(index.identifiers, [b.identifier])

        await indexer.reconcile(nil)
        XCTAssertEqual(index.deleteAllCount, 3, "Spotlight off: the whole index goes")
        XCTAssertNil(baseline.baseline)
    }

    func testLargeIndexesGoInBatches() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(index: index, baseline: InMemorySpotlightBaseline())
        await indexer.reconcile((0..<250).map { entry("\($0)", "Topic \($0)") })
        XCTAssertEqual(index.indexCalls, 3)
        XCTAssertEqual(index.identifiers.count, 250)
    }

    func testAFailedDeleteIsTriedAgainNextTime() async {
        let index = FakeSpotlightIndex()
        let indexer = SpotlightIndexer(index: index, baseline: InMemorySpotlightBaseline())
        await indexer.reconcile([entry("1", "A"), entry("2", "B")])
        index.failsDeletes = true
        await indexer.reconcile([entry("2", "B")])
        index.failsDeletes = false
        await indexer.reconcile([entry("2", "B")])
        XCTAssertEqual(index.identifiers, [entry("2", "B").identifier])
    }

    // MARK: The app's data

    func testDeletingASummaryAForumOrEverythingRemovesTheirItems() async throws {
        let index = FakeSpotlightIndex()
        let app = makeApp(index: index, sessions: [
            session("1", title: "One", summary: "First."),
            session("2", title: "Two", summary: "Second."),
            session("3", title: "Three"),
            session("7", title: "Seven", site: otherSite)
        ])
        await settle(app)
        XCTAssertEqual(index.identifiers, ["topic:forum.example.com/t/1", "topic:forum.example.com/t/2", "topic:forum.example.com/t/3", "topic:other.example.org/t/7"])

        app.deleteSession(topicKey: "forum.example.com/t/1")
        await settle(app)
        XCTAssertFalse(index.identifiers.contains("topic:forum.example.com/t/1"))

        let other = try XCTUnwrap(app.forum(for: otherSite))
        app.removeForum(other, deleteData: false)
        await settle(app)
        XCTAssertFalse(index.identifiers.contains("topic:other.example.org/t/7"), "a removed forum's topics leave Spotlight")

        app.clearAllSavedData()
        await settle(app)
        XCTAssertEqual(index.identifiers, [])
    }

    func testADeletionSyncedFromAnotherDeviceRemovesTheItem() async {
        let index = FakeSpotlightIndex()
        let app = makeApp(index: index, sessions: [session("1", title: "One"), session("2", title: "Two")])
        await settle(app)
        var remaining = app.sessions
        remaining.removeValue(forKey: "forum.example.com/t/2")
        app.replaceSyncedData(sessions: remaining, agentRuns: app.agentRuns, watchedTopics: app.watchedTopics, forums: app.forums)
        await settle(app)
        XCTAssertEqual(index.identifiers, ["topic:forum.example.com/t/1"])
    }

    func testTheSwitchDeletesTheWholeIndexAndResetRebuildsIt() async {
        let index = FakeSpotlightIndex()
        let app = makeApp(index: index, sessions: [session("1", title: "One")])
        await settle(app)
        XCTAssertEqual(index.identifiers.count, 1)

        app.settings.spotlightEnabled = false
        await settle(app)
        XCTAssertEqual(index.identifiers, [])
        app.select(topic: ForumTopic(siteURL: site, topicID: "5", url: URL(string: "\(site)/t/five/5")!, title: "Five"))
        await settle(app)
        XCTAssertEqual(index.identifiers, [], "nothing is indexed while the switch is off")

        app.settings.spotlightEnabled = true
        await settle(app)
        XCTAssertEqual(index.identifiers, ["topic:forum.example.com/t/1", "topic:forum.example.com/t/5"])

        let deletesBefore = index.deleteAllCount
        app.resetSettings()
        try? await Task.sleep(for: .milliseconds(50))
        await settle(app)
        XCTAssertGreaterThan(index.deleteAllCount, deletesBefore)
        XCTAssertEqual(index.identifiers.count, 2, "reset rebuilds the index from the saved topics")
        XCTAssertTrue(app.settings.spotlightEnabled)
    }

    func testOpeningAResultLoadsTheTopicAtItsSavedPost() {
        let app = makeApp(index: FakeSpotlightIndex(), sessions: [session("8", title: "Eight", path: "/t/eight/8/23")], forums: [])
        app.openTopic(topicKey: "forum.example.com/t/8")
        XCTAssertEqual(app.browser.currentURL?.absoluteString, "\(site)/t/eight/8/23")
        app.openTopic(topicKey: "forum.example.com/t/404")
        XCTAssertEqual(app.browser.currentURL?.absoluteString, "\(site)/t/eight/8/23", "an unknown topic does nothing")
    }

    func testTheSwitchesAreOnByDefaultAndStayOnTheDevice() throws {
        let settings = AppSettings()
        XCTAssertTrue(settings.spotlightEnabled)
        XCTAssertTrue(settings.donatesTopicActivity)
        XCTAssertTrue(SyncSettings.deviceLocalKeys.isSuperset(of: ["spotlightEnabled", "donatesTopicActivity"]))
        XCTAssertFalse(SyncSettings.deviceLocalKeys.contains("readingLanguage"), "the reading language syncs")
        // Older snapshots have no keys: the defaults.
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(decoded.spotlightEnabled)
        XCTAssertTrue(decoded.donatesTopicActivity)
        XCTAssertEqual(decoded.readingLanguage, "")
    }

    // MARK: Helpers

    private func settle(_ app: AppModel) async {
        app.spotlight.delay = .zero
        app.spotlightDataDidChange()
        await app.spotlight.settle()
    }

    private func entry(_ id: String, _ title: String) -> SpotlightEntry {
        SpotlightEntry(topicKey: "forum.example.com/t/\(id)", siteURL: site, title: title, forumName: "Example",
                       excerpt: "", url: URL(string: "\(site)/t/x/\(id)")!, lastUsed: Date(timeIntervalSince1970: 0), iconURL: nil)
    }

    private func session(_ id: String, title: String, summary: String = "", accessed: TimeInterval = 0, path: String? = nil, site: String? = nil) -> TopicSession {
        let site = site ?? self.site
        var session = TopicSession(siteURL: site, topicID: id, url: URL(string: site + (path ?? "/t/topic/\(id)"))!, title: title)
        session.summary = summary
        session.openedByUserAt = Date(timeIntervalSince1970: 1_000 + accessed)
        return session
    }

    private func makeApp(index: FakeSpotlightIndex, sessions: [TopicSession], forums: [Forum]? = nil) -> AppModel {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("state.json")
        let store = PersistentStore(fileURL: fileURL)
        try? store.save(AppSnapshot(
            sessions: sessions,
            forums: forums ?? [Forum(siteURL: site, kind: .discourse, name: "Example Forum"), Forum(siteURL: otherSite, kind: .discourse, name: "Other")]
        ))
        let app = AppModel(store: store, spotlightIndex: index, topicActivityDonor: FakeTopicActivityDonor())
        app.settingsSaveDelay = .zero
        return app
    }
}

/// Records what the indexer sends; `items` is what Spotlight would hold.
final class FakeSpotlightIndex: SpotlightIndexing {
    private(set) var items: [String: CSSearchableItem] = [:]
    private(set) var indexCalls = 0
    private(set) var deleted: [[String]] = []
    private(set) var deleteAllCount = 0
    var failsDeletes = false

    var identifiers: [String] { items.keys.sorted() }

    func index(_ items: [CSSearchableItem]) async throws {
        indexCalls += 1
        for item in items { self.items[item.uniqueIdentifier] = item }
    }

    func delete(identifiers: [String]) async throws {
        if failsDeletes { throw CocoaError(.fileWriteUnknown) }
        deleted.append(identifiers)
        for identifier in identifiers { items.removeValue(forKey: identifier) }
    }

    func deleteAll() async throws {
        deleteAllCount += 1
        items = [:]
    }
}

@MainActor
final class FakeTopicActivityDonor: TopicActivityDonating {
    private(set) var donated: [String] = []
    private(set) var resignCount = 0
    private(set) var deleteAllCount = 0

    func donate(topicKey: String, title: String, forumName: String, url: URL) { donated.append(topicKey) }
    func resign() { resignCount += 1 }
    func deleteAll() { deleteAllCount += 1 }
}
