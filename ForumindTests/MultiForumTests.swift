import XCTest
@testable import Forumind

/// Forum identity, the forum directory, page detection, snapshot decoding,
/// and per-forum networking.
final class MultiForumTests: XCTestCase {
    private let netForum = "https://www.example.net"
    private let meta = "https://meta.discourse.org"
    private let folder = "https://example.com/forum"

    // MARK: ForumSite

    func testSiteURLParsingAndNormalization() {
        XCTAssertEqual(ForumSite.normalizeSiteURL("https://Meta.Discourse.org/"), meta)
        XCTAssertEqual(ForumSite.normalizeSiteURL("https://example.com/forum/"), folder)
        XCTAssertEqual(ForumSite.normalizeSiteURL("https://example.com:443/forum"), folder)
        XCTAssertEqual(ForumSite.normalizeSiteURL("https://example.com:8443"), "https://example.com:8443")
        XCTAssertEqual(ForumSite.normalizeSiteURL("http://localhost:3000"), "http://localhost:3000")
        XCTAssertNil(ForumSite.normalizeSiteURL("http://example.com"))
        XCTAssertNil(ForumSite.normalizeSiteURL("https://example.com/forum?x=1"))
        XCTAssertNil(ForumSite.normalizeSiteURL("https://user:pw@example.com"))
        XCTAssertNil(ForumSite.normalizeSiteURL("https://example.com/a b"))
        XCTAssertNil(ForumSite.normalizeSiteURL("ftp://example.com"))
        XCTAssertNil(ForumSite.normalizeSiteURL(""))

        XCTAssertEqual(ForumSite.normalizeBasePath("forum/"), "/forum")
        XCTAssertEqual(ForumSite.normalizeBasePath("/a/b"), "/a/b")
        XCTAssertEqual(ForumSite.normalizeBasePath("/a/../b"), "")
        XCTAssertEqual(ForumSite.normalizeBasePath(nil), "")

        let page = URL(string: "https://example.com/forum/t/x/5")!
        XCTAssertEqual(ForumSite.siteURL(fromPage: page, basePath: "/forum"), folder)
        XCTAssertEqual(ForumSite.siteURL(fromPage: page), "https://example.com")
        XCTAssertNil(ForumSite.siteURL(fromPage: URL(string: "https://example.com/other")!, basePath: "/forum"))
    }

    func testTopicKeysAndURLBuilders() {
        XCTAssertEqual(ForumSite.topicKey(siteURL: netForum, topicID: "517303"), "www.example.net/t/517303")
        XCTAssertEqual(ForumSite.topicKey(siteURL: meta, topicID: "12"), "meta.discourse.org/t/12")
        XCTAssertEqual(ForumSite.topicKey(siteURL: folder, topicID: "7"), "example.com/forum/t/7")
        XCTAssertEqual(ForumSite.topicKey(siteURL: "http://localhost:3000", topicID: "7"), "localhost:3000/t/7")
        XCTAssertNil(ForumSite.topicKey(siteURL: meta, topicID: "0"))
        XCTAssertNil(ForumSite.topicKey(siteURL: meta, topicID: "abc"))
        XCTAssertNil(ForumSite.topicKey(siteURL: "nope", topicID: "1"))
        // Same id on two forums → two keys.
        XCTAssertNotEqual(
            ForumSite.topicKey(siteURL: netForum, topicID: "1"),
            ForumSite.topicKey(siteURL: meta, topicID: "1")
        )
        // Agent work records keep their `agent:` id as the key.
        XCTAssertEqual(TopicIdentity.key(siteURL: meta, topicID: "agent:X"), "agent:X")

        XCTAssertEqual(ForumSite.topicURL(siteURL: folder, topicID: "7")?.absoluteString, "https://example.com/forum/t/7")
        XCTAssertEqual(
            ForumSite.topicURL(siteURL: meta, topicID: "7", slug: "hello-world")?.absoluteString,
            "https://meta.discourse.org/t/hello-world/7"
        )
        XCTAssertEqual(ForumSite.topicJSONURL(siteURL: folder, topicID: "7")?.absoluteString, "https://example.com/forum/t/7.json")
        XCTAssertEqual(ForumSite.rawPageURL(siteURL: folder, topicID: "7", page: 2)?.absoluteString, "https://example.com/forum/raw/7?page=2")
        XCTAssertNil(ForumSite.rawPageURL(siteURL: folder, topicID: "7", page: 0))
        XCTAssertEqual(
            ForumSite.searchURL(siteURL: meta, query: "a b #c")?.absoluteString,
            "https://meta.discourse.org/search.json?q=a%20b%20%23c"
        )
        XCTAssertEqual(ForumSite.latestURL(siteURL: folder)?.absoluteString, "https://example.com/forum/latest")
        XCTAssertEqual(ForumSite.latestURL(siteURL: meta, json: true)?.absoluteString, "https://meta.discourse.org/latest.json")
    }

    func testSameForumAndDisplayName() {
        XCTAssertTrue(ForumSite.isSameForum(url: URL(string: "https://example.com/forum/t/a/1")!, siteURL: folder))
        XCTAssertTrue(ForumSite.isSameForum(url: URL(string: "https://example.com/forum")!, siteURL: folder))
        XCTAssertFalse(ForumSite.isSameForum(url: URL(string: "https://example.com/forums/t/a/1")!, siteURL: folder))
        XCTAssertFalse(ForumSite.isSameForum(url: URL(string: "https://example.com/t/a/1")!, siteURL: folder))
        // No www folding.
        XCTAssertFalse(ForumSite.isSameForum(url: URL(string: "https://example.net/t/a/1")!, siteURL: netForum))
        XCTAssertFalse(ForumSite.isSameForum(url: URL(string: "https://meta.discourse.org.evil.com/")!, siteURL: meta))

        XCTAssertEqual(ForumSite.displayName(siteURL: meta, name: "  Discourse Meta "), "Discourse Meta")
        XCTAssertEqual(ForumSite.displayName(siteURL: folder, name: ""), "example.com")
        XCTAssertEqual(ForumSite.host(of: folder), "example.com/forum")
    }

    func testTopicIDExtractionMirrorsTopicRoute() {
        func id(_ string: String, _ basePath: String = "") -> String? {
            ForumSite.extractTopicID(from: URL(string: string)!, basePath: basePath)
        }
        XCTAssertEqual(id("https://x.org/t/slug/12"), "12")
        XCTAssertEqual(id("https://x.org/t/12"), "12")
        XCTAssertEqual(id("https://x.org/t/slug/12/5"), "12")
        XCTAssertEqual(id("https://x.org/forum/t/slug/12", "/forum"), "12")
        XCTAssertNil(id("https://x.org/forum/t/slug/12"))
        XCTAssertNil(id("https://x.org/latest"))
        XCTAssertNil(id("https://x.org/t/slug"))
        XCTAssertEqual(ForumSite.looseTopicID(from: URL(string: "https://x.org/forum/t/slug/12")!), "12")
    }

    func testCookieFilteringOnlyMatchesTheForumHost() {
        XCTAssertTrue(ForumSite.cookieDomain("meta.discourse.org", matchesHost: "meta.discourse.org"))
        XCTAssertTrue(ForumSite.cookieDomain(".discourse.org", matchesHost: "meta.discourse.org"))
        XCTAssertTrue(ForumSite.cookieDomain("example.net", matchesHost: "www.example.net"))
        XCTAssertFalse(ForumSite.cookieDomain("www.example.net", matchesHost: "example.net"))
        XCTAssertFalse(ForumSite.cookieDomain("example.net", matchesHost: "meta.discourse.org"))
        XCTAssertFalse(ForumSite.cookieDomain("ple.net", matchesHost: "www.example.net"))
        XCTAssertFalse(ForumSite.cookieDomain(".", matchesHost: "a.com"))

        func cookie(_ domain: String, _ name: String) -> HTTPCookie {
            HTTPCookie(properties: [.domain: domain, .path: "/", .name: name, .value: "v"])!
        }
        let jar = [
            cookie(".example.net", "_t_net"),
            cookie("meta.discourse.org", "_t_meta"),
            cookie("example.com", "_t_example")
        ]
        XCTAssertEqual(ForumSite.cookies(jar, forHost: "www.example.net").map(\.name), ["_t_net"])
        XCTAssertEqual(ForumSite.cookies(jar, forHost: "meta.discourse.org").map(\.name), ["_t_meta"])
        XCTAssertEqual(ForumSite.cookies(jar, forHost: "example.com").map(\.name), ["_t_example"])
    }

    // MARK: Page context

    func testPageContextStatesMirrorPageGuidance() {
        let topicURL = URL(string: "https://example.com/forum/t/hello/77")!
        let homeURL = URL(string: "https://example.com/forum/latest")!

        XCTAssertEqual(PageContext.make(url: nil, title: nil, probe: nil, knownForum: nil).state, .loading)
        // Unchecked /t/…/id URL → maybe; other unchecked pages → loading.
        XCTAssertEqual(PageContext.make(url: topicURL, title: nil, probe: nil, knownForum: nil).state, .maybe)
        XCTAssertEqual(PageContext.make(url: homeURL, title: nil, probe: nil, knownForum: nil).state, .loading)

        let probe = PageProbe(url: topicURL, isDiscourse: true, basePath: "/forum", forumName: "Example")
        let topic = PageContext.make(url: topicURL, title: "Hello - Example", probe: probe, knownForum: nil)
        XCTAssertEqual(topic.state, .topic)
        XCTAssertTrue(topic.isDiscourse)
        XCTAssertEqual(topic.siteURL, folder)
        XCTAssertEqual(topic.basePath, "/forum")
        XCTAssertEqual(topic.forumName, "Example")
        XCTAssertEqual(topic.topic?.topicKey, "example.com/forum/t/77")

        let homeProbe = PageProbe(url: homeURL, isDiscourse: true, basePath: "/forum")
        let home = PageContext.make(url: homeURL, title: nil, probe: homeProbe, knownForum: nil)
        XCTAssertEqual(home.state, .forumHome)
        XCTAssertEqual(home.forumName, "example.com")

        let other = URL(string: "https://news.example.org/t/a/1")!
        XCTAssertEqual(
            PageContext.make(url: other, title: nil, probe: PageProbe(url: other, isDiscourse: false), knownForum: nil).state,
            .notForum
        )
        // A probe for a different page does not apply.
        XCTAssertEqual(PageContext.make(url: other, title: nil, probe: probe, knownForum: nil).state, .maybe)

        // A directory forum is Discourse before the probe reports.
        let known = KnownForumSite(siteURL: netForum, name: "Example Net Forum", iconURL: nil)
        let netTopic = URL(string: "https://www.example.net/t/x/517303")!
        let early = PageContext.make(url: netTopic, title: nil, probe: nil, knownForum: known)
        XCTAssertEqual(early.state, .topic)
        XCTAssertEqual(early.topic?.title, "Example Net Forum topic 517303")
    }

    // MARK: Forum directory

    func testForumDirectoryPinsReordersAndRemoves() {
        var directory = ForumDirectory()
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        directory.upsert(siteURL: "https://meta.discourse.org/", name: "Meta", iconURL: nil, visitedAt: old)
        directory.upsert(siteURL: netForum, name: "", iconURL: nil, visitedAt: new)
        directory.upsert(siteURL: folder, name: "Folder", iconURL: nil, visitedAt: nil)
        XCTAssertNil(directory.upsert(siteURL: "not a url", name: nil, iconURL: nil))
        XCTAssertEqual(directory.forums.count, 3)
        XCTAssertEqual(directory.forum(siteURL: meta)?.name, "Meta")
        XCTAssertEqual(directory.forum(siteURL: netForum)?.name, "www.example.net")

        // Re-visiting refreshes instead of duplicating.
        directory.upsert(siteURL: meta, name: "Discourse Meta", iconURL: URL(string: "https://m/icon.png"), visitedAt: new)
        XCTAssertEqual(directory.forums.count, 3)
        XCTAssertEqual(directory.forum(siteURL: meta)?.name, "Discourse Meta")

        directory.setPinned(true, siteURL: folder)
        directory.setPinned(true, siteURL: meta)
        directory.setPinned(true, siteURL: netForum)
        XCTAssertEqual(directory.pinned.map(\.siteURL), [folder, meta, netForum])
        directory.movePinned(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(directory.pinned.map(\.siteURL), [netForum, folder, meta])
        directory.setPinned(false, siteURL: folder)
        XCTAssertEqual(directory.pinned.map(\.siteURL), [netForum, meta])
        XCTAssertEqual(directory.pinned.map(\.pinOrder), [0, 1])
        XCTAssertEqual(directory.recent.map(\.siteURL), [folder])
        directory.remove(siteURL: netForum)
        XCTAssertEqual(directory.pinned.map(\.siteURL), [meta])
        XCTAssertEqual(directory.pinned.first?.pinOrder, 0)

        // Longest matching base path wins for page lookup.
        directory.upsert(siteURL: "https://example.com", name: "Root", iconURL: nil)
        XCTAssertEqual(directory.forum(containing: URL(string: "https://example.com/forum/t/a/1")!)?.siteURL, folder)
        XCTAssertEqual(directory.forum(containing: URL(string: "https://example.com/t/a/1")!)?.siteURL, "https://example.com")
    }

    func testAddForumAddressCandidates() {
        XCTAssertEqual(ForumDirectory.candidateSiteURLs(fromAddress: "meta.discourse.org"), [meta])
        XCTAssertEqual(ForumDirectory.candidateSiteURLs(fromAddress: " https://meta.discourse.org/t/x/5 "), [meta])
        XCTAssertEqual(
            ForumDirectory.candidateSiteURLs(fromAddress: "https://example.com/forum/t/hello/77"),
            [folder, "https://example.com"]
        )
        XCTAssertEqual(ForumDirectory.candidateSiteURLs(fromAddress: "example.com/forum"), [folder, "https://example.com"])
        XCTAssertEqual(ForumDirectory.candidateSiteURLs(fromAddress: "localhost:3000"), ["http://localhost:3000"])
        XCTAssertEqual(ForumDirectory.candidateSiteURLs(fromAddress: "hello world"), [])
        XCTAssertEqual(ForumDirectory.candidateSiteURLs(fromAddress: "hello"), [])
        XCTAssertEqual(ForumDirectory.candidateSiteURLs(fromAddress: "http://example.com"), [])
        XCTAssertEqual(AppModel.suggestedForums.count, 5)
        XCTAssertTrue(AppModel.suggestedForums.allSatisfy { ForumSite.normalizeSiteURL($0.siteURL) == $0.siteURL })
    }

    @MainActor
    func testAddForumValidatesWithBasicInfo() async throws {
        let session = stubbedSession { request in
            let url = try XCTUnwrap(request.url)
            switch (url.host, url.path) {
            case ("meta.discourse.org", "/site/basic-info.json"):
                return Self.response(request, 200, #"{"title":"Discourse Meta","apple_touch_icon_url":"/uploads/icon.png"}"#)
            case ("example.com", "/forum/site/basic-info.json"):
                return Self.response(request, 404, "missing")
            case ("example.com", "/forum/about.json"):
                return Self.response(request, 200, #"{"about":{"title":"Folder Forum"}}"#)
            default:
                return Self.response(request, 404, "<html>not discourse</html>")
            }
        }
        let app = AppModel(store: temporaryStore(), forumService: ForumService(session: session))

        let added = try await app.addForum(fromAddress: "meta.discourse.org/t/some/1", pin: true)
        XCTAssertEqual(added.siteURL, meta)
        XCTAssertEqual(added.name, "Discourse Meta")
        XCTAssertEqual(added.iconURL?.absoluteString, "https://meta.discourse.org/uploads/icon.png")
        XCTAssertEqual(app.pinnedForums.map(\.siteURL), [meta])

        let subfolder = try await app.addForum(fromAddress: "https://example.com/forum/latest")
        XCTAssertEqual(subfolder.siteURL, folder)
        XCTAssertEqual(subfolder.name, "Folder Forum")
        XCTAssertEqual(app.recentForums.map(\.siteURL), [folder])

        do {
            _ = try await app.addForum(fromAddress: "news.example.org")
            XCTFail("A non-Discourse site was added")
        } catch let error as ForumDirectoryError {
            XCTAssertEqual(error, .notDiscourse("news.example.org"))
        }
        do {
            _ = try await app.addForum(fromAddress: "not an address")
            XCTFail("An invalid address was accepted")
        } catch let error as ForumDirectoryError {
            XCTAssertEqual(error, .invalidAddress)
        }

        app.togglePin(subfolder)
        XCTAssertEqual(app.pinnedForums.map(\.siteURL), [meta, folder])
        app.movePinned(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(app.pinnedForums.map(\.siteURL), [folder, meta])
        app.unpin(added)
        XCTAssertEqual(app.pinnedForums.map(\.siteURL), [folder])
        app.removeForum(added, deleteData: true)
        XCTAssertNil(app.forum(for: meta))
    }

    @MainActor
    func testRemoveForumDeletesOnlyItsData() throws {
        let store = temporaryStore()
        let netSession = TopicSession(siteURL: netForum, topicID: "1", url: URL(string: "\(netForum)/t/a/1")!, title: "U")
        let metaSession = TopicSession(siteURL: meta, topicID: "1", url: URL(string: "\(meta)/t/a/1")!, title: "M")
        let metaWatch = WatchedTopic(siteURL: meta, topicID: "1", url: metaSession.url, title: "M", knownPostCount: 1)
        try store.save(
            AppSnapshot(
                sessions: [netSession, metaSession],
                watchedTopics: [metaWatch],
                forums: [Forum(siteURL: netForum, name: "U"), Forum(siteURL: meta, name: "M")]
            )
        )
        let app = AppModel(store: store)
        // Same topic id on two forums → two sessions.
        XCTAssertEqual(Set(app.sessions.keys), ["www.example.net/t/1", "meta.discourse.org/t/1"])

        app.removeForum(try XCTUnwrap(app.forum(for: meta)), deleteData: true)
        XCTAssertEqual(Array(app.sessions.keys), ["www.example.net/t/1"])
        XCTAssertTrue(app.watchedTopics.isEmpty)
        XCTAssertEqual(store.load().forums.map(\.siteURL), [netForum])
    }

    // MARK: Snapshot decoding

    func testSnapshotDecodingToleratesMissingKeys() throws {
        let fresh = try JSONDecoder().decode(AppSnapshot.self, from: Data("{}".utf8))
        XCTAssertTrue(fresh.forums.isEmpty)
        XCTAssertTrue(fresh.sessions.isEmpty)
        XCTAssertFalse(fresh.settings.hasCompletedOnboarding)
        XCTAssertFalse(AppSnapshot().settings.hasCompletedOnboarding)

        let partial = #"{"settings":{"selectedProvider":"groq","browserBarPosition":"bottom"},"sessions":[],"activities":[]}"#
        let decoded = try JSONDecoder().decode(AppSnapshot.self, from: Data(partial.utf8))
        XCTAssertEqual(decoded.settings.selectedProvider, .groq)
        XCTAssertEqual(decoded.settings.browserBarPosition, .bottom)
        XCTAssertEqual(decoded.settings.forumContextLimit, AppSettings().forumContextLimit)
        XCTAssertTrue(decoded.forums.isEmpty)
        XCTAssertTrue(decoded.agentRuns.isEmpty)
        XCTAssertTrue(decoded.watchedTopics.isEmpty)
        XCTAssertFalse(decoded.settings.hasCompletedOnboarding)
    }

    // MARK: Networking and agent on a second forum

    func testForumServiceUsesTheSubfolderSite() async throws {
        var requested: [String] = []
        let session = stubbedSession { request in
            let url = try XCTUnwrap(request.url)
            requested.append(url.absoluteString)
            if url.path.hasSuffix(".json") {
                return Self.response(request, 200, #"{"posts_count":2}"#)
            }
            return Self.response(request, 200, "raw")
        }
        let service = ForumService(session: session)
        let result = try await service.fetchTopic(
            siteURL: folder,
            topicID: "77",
            cachedPages: [],
            knownTotalPosts: nil,
            cookieHeader: nil
        ) { _ in }
        XCTAssertEqual(result.totalPosts, 2)
        XCTAssertEqual(requested, ["https://example.com/forum/t/77.json", "https://example.com/forum/raw/77?page=1"])

        let overview = try await service.fetchOverview(siteURL: folder, topicID: "77", cookieHeader: nil)
        XCTAssertEqual(overview.url.absoluteString, "https://example.com/forum/t/77")
    }

    @MainActor
    func testAgentRunStaysOnItsForum() async throws {
        var hosts: Set<String> = []
        let session = stubbedSession { request in
            let url = try XCTUnwrap(request.url)
            hosts.insert(url.host ?? "")
            switch url.path {
            case "/latest.json":
                return Self.response(request, 200, #"{"topic_list":{"topics":[{"id":5,"title":"Plugin API","slug":"plugin-api","posts_count":1}]}}"#)
            case "/t/5.json":
                return Self.response(request, 200, #"{"title":"Plugin API","slug":"plugin-api","posts_count":1}"#)
            case "/raw/5":
                return Self.response(request, 200, "Use the plugin API.")
            default:
                return Self.response(request, 404, "missing")
            }
        }
        let planner = RecordingPlanner(actions: [
            AgentAction(thought: "", tool: "list_latest", arguments: [:]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "5"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done"])
        ])
        let app = AppModel(
            store: temporaryStore(),
            forumService: ForumService(session: session),
            aiService: AIService(session: session),
            planner: planner
        )
        app.usesDirectForumRequests = true
        useLocalProvider(app)

        app.startAgentRun(goal: "What is new?", siteURL: "https://meta.discourse.org/")
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !(app.agentRuns.first?.status.isTerminal ?? false) {
            try await Task.sleep(for: .milliseconds(50))
        }
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.siteURL, meta)
        XCTAssertEqual(hosts, ["meta.discourse.org"])
        XCTAssertEqual(app.sessions["meta.discourse.org/t/5"]?.url.absoluteString, "https://meta.discourse.org/t/plugin-api/5")
        XCTAssertEqual(run.steps[1].topicKey, "meta.discourse.org/t/5")
        XCTAssertTrue(planner.system.contains("research agent for meta.discourse.org (https://meta.discourse.org)"))
        XCTAssertTrue(app.activities.contains {
            $0.type == .agent && $0.siteURL == meta && $0.url.absoluteString == "https://meta.discourse.org/latest"
        })
    }

    @MainActor
    func testAgentRunNeedsAForum() {
        let app = AppModel(store: temporaryStore())
        app.startAgentRun(goal: "Anything?")
        XCTAssertTrue(app.agentRuns.isEmpty)
        XCTAssertEqual(app.presentedError, "Open a Discourse forum first.")
        XCTAssertEqual(AssistantError.noTopic.localizedDescription, "Open a Discourse topic first.")
    }

    func testSummaryAndChatPromptsAreForumNeutral() {
        let summary = PromptBuilder.summarySystem(custom: "")
        XCTAssertTrue(summary.contains("Discourse forum discussion"))
        XCTAssertTrue(summary.contains("same language as the discussion"))
        XCTAssertFalse(summary.contains("Use Chinese"))
        XCTAssertTrue(PromptBuilder.summarySystem(custom: "Be brief.").hasPrefix("Be brief."))
        XCTAssertFalse(PromptBuilder.chunkPrompt.contains("中文"))
        let chat = PromptBuilder.chatSystem(custom: "", source: "s", summary: "")
        XCTAssertTrue(chat.contains("Discourse forum discussion"))
        XCTAssertTrue(chat.contains("same language as the user's question"))
    }

    // MARK: Review fixes

    func testRedirectsToAnotherOriginDropTheForumCookies() {
        func request(_ url: String) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.setValue("_t=session", forHTTPHeaderField: "Cookie")
            request.setValue("Bearer x", forHTTPHeaderField: "Authorization")
            return request
        }
        let original = request("https://meta.discourse.org/t/5")
        let sameOrigin = ForumRedirectGuard.redirectRequest(
            request("https://meta.discourse.org/t/plugin-api/5"),
            from: original
        )
        XCTAssertEqual(sameOrigin.value(forHTTPHeaderField: "Cookie"), "_t=session")

        for target in [
            "https://evil.example/t/5",
            "https://cdn.meta.discourse.org/t/5",
            "http://meta.discourse.org/t/5",
            "https://meta.discourse.org:8443/t/5"
        ] {
            let redirected = ForumRedirectGuard.redirectRequest(request(target), from: original)
            XCTAssertNil(redirected.value(forHTTPHeaderField: "Cookie"), target)
            XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"), target)
            XCTAssertFalse(redirected.httpShouldHandleCookies, target)
        }
        XCTAssertNil(
            ForumRedirectGuard.redirectRequest(request("https://meta.discourse.org/x"), from: nil)
                .value(forHTTPHeaderField: "Cookie")
        )
    }

    func testRouteMessagesMustDescribeTheShownDocument() {
        let page = URL(string: "https://meta.discourse.org/latest")!
        func accepts(_ reported: String, _ shown: URL? = page) -> Bool {
            ForumBrowserModel.isRouteMessage(from: URL(string: reported)!, forPageAt: shown)
        }
        XCTAssertTrue(accepts("https://meta.discourse.org/t/plugin-api/5"))
        XCTAssertTrue(accepts("https://META.discourse.org:443/t/5"))
        XCTAssertFalse(accepts("https://www.example.net/t/x/1"))
        XCTAssertFalse(accepts("http://meta.discourse.org/t/5"))
        XCTAssertFalse(accepts("https://meta.discourse.org:8443/t/5"))
        XCTAssertFalse(accepts("https://meta.discourse.org/t/5", nil))
    }

    func testUnreadableSnapshotIsKeptBeforeStartingEmpty() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("state.json")
        let unreadable = Data(#"{"sessions":[{"topicID":1}]}"#.utf8)
        try unreadable.write(to: file)

        let snapshot = PersistentStore(fileURL: file).load()
        XCTAssertTrue(snapshot.sessions.isEmpty)
        let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("state.unreadable-") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: directory.appendingPathComponent(copies[0])),
            unreadable
        )
    }

    /// Removing a forum with its data while its agent run is finishing must
    /// not bring the run back.
    @MainActor
    func testRemovedForumRunIsNotResurrectedByItsFinishingTask() async throws {
        let session = stubbedSession { request in
            Self.response(request, 200, #"{"topic_list":{"topics":[]}}"#)
        }
        let planner = GatedPlanner()
        let app = AppModel(
            store: temporaryStore(),
            forumService: ForumService(session: session),
            aiService: AIService(session: session),
            planner: planner
        )
        app.usesDirectForumRequests = true
        useLocalProvider(app)
        app.recordVisit(siteURL: meta, name: "Meta", iconURL: nil)

        app.startAgentRun(goal: "Anything new?", siteURL: meta)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !planner.isWaiting {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(planner.isWaiting)
        app.removeForum(try XCTUnwrap(app.forum(for: meta)), deleteData: true)
        XCTAssertTrue(app.agentRuns.isEmpty)
        // The planner ignores cancellation and answers: the old code stored
        // the run again at this point.
        planner.release()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(app.agentRuns.isEmpty)
        XCTAssertTrue(app.activities.isEmpty)
    }

    // MARK: Helpers

    /// Work only starts with a connected provider; a local one needs no key.
    @MainActor
    private func useLocalProvider(_ app: AppModel) {
        app.settings.selectedProvider = .ollama
        var configuration = app.settings.configuration(for: .ollama)
        configuration.model = "test-model"
        app.setConfiguration(configuration, for: .ollama)
    }

    private func temporaryStore() -> PersistentStore {
        PersistentStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("state.json")
        )
    }

    private func stubbedSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        MultiForumURLStub.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MultiForumURLStub.self]
        return URLSession(configuration: configuration)
    }

    private static func response(_ request: URLRequest, _ status: Int, _ body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!,
            Data(body.utf8)
        )
    }
}

private final class RecordingPlanner: AgentPlanner, @unchecked Sendable {
    private var actions: [AgentAction]
    private(set) var system = ""

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
        guard !actions.isEmpty else {
            return AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "n/a"])
        }
        return actions.removeFirst()
    }
}

/// Blocks its first answer until released, ignoring task cancellation.
private final class GatedPlanner: AgentPlanner, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?

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
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                waiting = true
            }
        }
        return AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Late"])
    }
}

private final class MultiForumURLStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
