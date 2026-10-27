import XCTest
@testable import Forumind

/// `Forum.kind` and how a site URL resolves to its adapter (S2). Sync of the
/// kind is in CloudSyncTests; the pre-P0 snapshot loading is in SiteGoldenTests.
@MainActor
final class ForumKindTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let fakeSite = "https://fake.example.com"
    private let ghostSite = "https://ghost.example.com"

    private func makeApp(
        sites: SiteRegistry,
        forums: [Forum] = [],
        forumService: ForumService = ForumService()
    ) -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try? store.save(AppSnapshot(forums: forums))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(store: store, forumService: forumService, sites: sites)
        app.browser.onPageContextChanged = nil
        return app
    }

    // MARK: Decoding

    func testForumWithoutKindDecodesAsDiscourse() throws {
        let json = #"{"siteURL":"https://forum.example.com","name":"Example","isPinned":true,"pinOrder":2}"#
        let forum = try JSONDecoder().decode(Forum.self, from: Data(json.utf8))
        XCTAssertEqual(forum.kind, SiteKind.discourse)
        XCTAssertEqual(forum.name, "Example")
        XCTAssertTrue(forum.isPinned)
        XCTAssertEqual(forum.pinOrder, 2)
    }

    func testKindRoundTripsAndAnUnknownKindIsKept() throws {
        let forum = Forum(siteURL: ghostSite, kind: SiteKind("ghost"), name: "Ghost")
        let decoded = try JSONDecoder().decode(Forum.self, from: JSONEncoder().encode(forum))
        XCTAssertEqual(decoded.kind, SiteKind("ghost"))
        XCTAssertEqual(decoded, forum)
    }

    func testEveryForumOfThePreP0SnapshotIsDiscourse() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "state", withExtension: "json"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data(contentsOf: url).write(to: directory.appendingPathComponent("state.json"))
        let snapshot = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore()).load()
        XCTAssertEqual(snapshot.forums.count, 3)
        XCTAssertEqual(snapshot.forums.map(\.kind), Array(repeating: SiteKind.discourse, count: 3))
    }

    // MARK: Directory

    func testUpsertKeepsTheStoredKindAndAddForumMayOverwriteIt() {
        var directory = ForumDirectory()
        directory.upsert(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake", iconURL: nil)
        // Same kind: refreshes name and icon, keeps everything else.
        directory.upsert(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Renamed", iconURL: nil, visitedAt: Date())
        XCTAssertEqual(directory.forums.count, 1)
        XCTAssertEqual(directory.forums[0].kind, FakeSiteAdapter.kind)
        XCTAssertEqual(directory.forums[0].name, "Renamed")
        // A site the user just validated as another platform takes the new kind.
        directory.upsert(siteURL: fakeSite, kind: .discourse, name: nil, iconURL: nil, overwritingKind: true)
        XCTAssertEqual(directory.forums[0].kind, .discourse)
        XCTAssertEqual(directory.forums[0].name, "Renamed")
    }

    func testRecordVisitStoresTheKind() {
        let app = makeApp(sites: SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()]))
        app.recordVisit(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake", iconURL: nil)
        XCTAssertEqual(app.forum(for: fakeSite)?.kind, FakeSiteAdapter.kind)
    }

    // MARK: Resolution

    func testAdapterLookupOrder() {
        let app = makeApp(
            sites: SiteRegistry(adapters: [DiscourseAdapter(), FakeSiteAdapter()]),
            forums: [
                Forum(siteURL: site, kind: .discourse, name: "Discourse one"),
                Forum(siteURL: fakeSite, kind: FakeSiteAdapter.kind, name: "Fake"),
                Forum(siteURL: ghostSite, kind: SiteKind("ghost"), name: "Ghost")
            ]
        )
        // (1) the directory forum's kind
        XCTAssertEqual(app.adapter(for: site)?.kind, .discourse)
        XCTAssertEqual(app.adapter(for: fakeSite)?.kind, FakeSiteAdapter.kind)
        XCTAssertEqual(app.adapter(for: fakeSite + "/")?.kind, FakeSiteAdapter.kind, "a site URL is normalized first")
        // A kind this build does not know is unsupported: nil, never Discourse, never deleted.
        XCTAssertNil(app.adapter(for: ghostSite))
        XCTAssertNotNil(app.forum(for: ghostSite))
        // No forum and no open page: nil.
        XCTAssertNil(app.adapter(for: "https://unknown.example.net"))

        // (2) the open page's detected site, for a forum with no record (removed while its page is open)
        let page = PageContext(
            url: URL(string: "https://unknown.example.net/latest"), site: .discourse,
            siteURL: "https://unknown.example.net", forumName: "Unknown", state: .forumHome
        )
        app.browser.setPageContext(page)
        XCTAssertEqual(app.adapter(for: "https://unknown.example.net")?.kind, .discourse)
        XCTAssertNil(app.adapter(for: "https://elsewhere.example.net"), "only the page's own site")
        // The directory wins over the page.
        let fakePage = PageContext(
            url: URL(string: fakeSite + "/latest"), site: .discourse, siteURL: fakeSite, forumName: "Fake", state: .forumHome
        )
        app.browser.setPageContext(fakePage)
        XCTAssertEqual(app.adapter(for: fakeSite)?.kind, FakeSiteAdapter.kind)
    }

    func testARemovedForumHasNoAdapterOnceItsPageIsGone() {
        let app = makeApp(
            sites: SiteRegistry(adapters: [DiscourseAdapter()]),
            forums: [Forum(siteURL: site, kind: .discourse, name: "Example")]
        )
        XCTAssertNotNil(app.adapter(for: site))
        app.removeForum(app.forums[0], deleteData: false)
        XCTAssertNil(app.forum(for: site))
        XCTAssertNil(app.adapter(for: site))
    }

    func testNetworkCarriesTheJobsPaceAndOnlyUsesThePageLoaderWhenAsked() async {
        let app = makeApp(sites: SiteRegistry(adapters: [DiscourseAdapter()]))
        let plain = await app.network(for: site, pace: .gentle, inPage: false)
        XCTAssertEqual(plain.siteURL, site)
        XCTAssertEqual(plain.context.pace, .gentle)
        XCTAssertNil(plain.context.resourceLoader)
        app.usesDirectForumRequests = true
        let direct = await app.network(for: site, pace: .fast)
        XCTAssertNil(direct.context.resourceLoader, "direct requests have no in-page loader")
        app.usesDirectForumRequests = false
        let inPage = await app.network(for: site, pace: .fast)
        XCTAssertNotNil(inPage.context.resourceLoader)
    }

    // MARK: Add forum

    func testAddForumGoesThroughTheAdaptersAndStoresItsKind() async throws {
        let app = makeApp(sites: SiteRegistry(adapters: [FakeSiteAdapter()]))
        XCTAssertEqual(app.addForumPhase, .idle)
        let forum = try await app.addForum(fromAddress: "fake.example.com", pin: true)
        XCTAssertEqual(forum.siteURL, fakeSite)
        XCTAssertEqual(forum.kind, FakeSiteAdapter.kind)
        XCTAssertEqual(forum.name, "Fake Site")
        XCTAssertTrue(forum.isPinned)
        XCTAssertEqual(app.forum(for: forum.siteURL)?.kind, FakeSiteAdapter.kind)
        XCTAssertEqual(app.adapter(for: forum.siteURL)?.kind, FakeSiteAdapter.kind)
        XCTAssertEqual(app.addForumPhase, .recognized(kind: FakeSiteAdapter.kind, siteURL: forum.siteURL))

        // An address no adapter accepts is invalid and adds nothing.
        do {
            _ = try await app.addForum(fromAddress: "news.example.org")
            XCTFail("An address no adapter accepts was added")
        } catch let error as ForumDirectoryError {
            XCTAssertEqual(error, .invalidAddress)
        }
        XCTAssertEqual(app.addForumPhase, .idle)
        XCTAssertEqual(app.forums.count, 1)
    }
}
