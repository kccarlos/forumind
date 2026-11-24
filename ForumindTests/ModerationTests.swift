import XCTest
import WebKit
@testable import Forumind

/// Guideline 1.2 moderation: blocking, word filters, the developer's list,
/// reports, and the Terms of Use setting.
@MainActor
final class ModerationTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let other = "https://other.example.org"

    private let raw = """
    alice | 2026-01-01 10:00:00 UTC | #1

    Welcome to the topic.

    -------------------------

    Bob | 2026-01-01 11:00:00 UTC | #2

    This is spam, buy now.

    -------------------------

    carol | 2026-01-01 12:00:00 UTC | #3

    A helpful reply.

    -------------------------
    """

    // MARK: Filter

    func testNoRulesLeavesTheTextAlone() {
        XCTAssertEqual(ModerationFilter.filter(raw, siteURL: site, topicID: "1", rules: .none), raw)
    }

    func testBlockedUsersPostsAreRemovedOnTheirForumOnly() {
        let rules = ModerationRules(blockedUsers: [site: ["bob"]])
        let filtered = ModerationFilter.filter(raw, siteURL: site, topicID: "1", rules: rules)
        XCTAssertFalse(filtered.contains("buy now"))
        XCTAssertFalse(filtered.contains("Bob |"))
        XCTAssertTrue(filtered.contains("Welcome to the topic."))
        XCTAssertTrue(filtered.contains("A helpful reply."))
        // Another forum's Bob is someone else.
        XCTAssertEqual(ModerationFilter.filter(raw, siteURL: other, topicID: "1", rules: rules), raw)
    }

    func testFilteredWordsRemoveMatchingPostsCaseInsensitively() {
        let rules = ModerationRules(filteredWords: ModerationRules.normalizedWords(["  SPAM ", "spam", ""]))
        XCTAssertEqual(rules.filteredWords, ["spam"])
        let filtered = ModerationFilter.filter(raw, siteURL: site, topicID: "1", rules: rules)
        XCTAssertFalse(filtered.contains("buy now"))
        XCTAssertTrue(filtered.contains("A helpful reply."))
    }

    func testDevelopersListHidesPostsAndUsersEverywhere() {
        let list = RemoteModerationList(
            users: [RemoteModerationList.User(site: nil, username: "Carol")],
            posts: [RemoteModerationList.Post(site: site + "/", topic: 7, post: 1)]
        )
        let rules = ModerationRules(settings: AppSettings(), remote: list)
        let filtered = ModerationFilter.filter(raw, siteURL: site, topicID: "7", rules: rules)
        XCTAssertFalse(filtered.contains("Welcome to the topic."), "Post #1 of topic 7 is on the list.")
        XCTAssertFalse(filtered.contains("A helpful reply."), "Carol is hidden on every forum.")
        XCTAssertTrue(filtered.contains("buy now"))
        // Post #1 of another topic stays.
        XCTAssertTrue(ModerationFilter.filter(raw, siteURL: site, topicID: "8", rules: rules).contains("Welcome"))
    }

    func testTextThatIsNotRawIsHiddenOnlyForAFilteredWord() {
        let rules = ModerationRules(filteredWords: ["spam"])
        XCTAssertEqual(ModerationFilter.filter("just text", siteURL: site, topicID: "1", rules: rules), "just text")
        XCTAssertEqual(ModerationFilter.filter("some spam here", siteURL: site, topicID: "1", rules: rules), "")
    }

    func testRemoteListDecodesWithMissingKeys() throws {
        let list = try JSONDecoder().decode(RemoteModerationList.self, from: Data(#"{"users":[{"username":"x"}]}"#.utf8))
        XCTAssertEqual(list.users, [RemoteModerationList.User(site: nil, username: "x")])
        XCTAssertTrue(list.posts.isEmpty)
        XCTAssertTrue(list.words.isEmpty)
    }

    func testTopicTitlesFollowCurrentRulesAcrossAllSitesAndCachedSources() {
        for siteURL in [site, "https://wordpress.example.org", "https://news.ycombinator.com"] {
            let key = TopicIdentity.key(siteURL: siteURL, topicID: "1")
            let url = URL(string: siteURL + "/?p=1")!
            let title = "Opening title"
            var session = TopicSession(siteURL: siteURL, topicID: "1", url: url, title: title)
            session.source = "alice | 2026-01-01 10:00:00 UTC | #1\nOpening text"
            session.openedByUserAt = Date()
            let app = makeApp(sessions: [session])
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), title)
            // Some adapters supply only the post list, rather than openingPoster.
            app.topicOverviews[key] = ForumTopicOverview(
                siteURL: siteURL, topicID: "1", title: title, slug: "", url: url, postCount: 2,
                facts: TopicFacts(postsCount: 2, posts: [.init(id: 1, number: 1, username: "bob")])
            )
            app.block("bob", on: siteURL)
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), "")
            app.topicOverviews[key] = nil
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), title)
            app.block("alice", on: siteURL)
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), "")
            // A cached digest title also stays out of the podcast's intro.
            let card = DigestCard(siteURL: siteURL, topicID: "1", title: title, reason: .trending, postCount: 2)
            XCTAssertEqual(app.sanitizedDigestCard(card).title, "")
            app.settings.blockedUsers = []
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), title)
            app.blockPost(1, topicID: "1", on: siteURL)
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), "")
            app.settings.blockedPosts = []
            _ = app.addFilteredWord("opening")
            XCTAssertEqual(app.moderatedTopicTitle(title, siteURL: siteURL, topicID: "1"), "")
            app.settings.filteredWords = []
        }
    }

    // MARK: Browser script config

    func testScriptConfigCoversTheCurrentForumOnly() {
        let rules = ModerationRules(
            blockedUsers: [site: ["bob"], other: ["dave"]],
            filteredWords: ["spam"],
            globallyHiddenUsers: ["eve"],
            hiddenPosts: ["\(site)|7": [3, 1], "\(other)|7": [2]]
        )
        let config = ModerationScript.config(rules: rules, siteURL: site)
        XCTAssertEqual(config.users, ["bob", "eve"])
        XCTAssertEqual(config.words, ["spam"])
        XCTAssertEqual(config.posts, ["7": [1, 3]])
        XCTAssertEqual(ModerationScript.config(rules: rules, siteURL: nil).users, ["eve"])
    }

    // MARK: Reports

    func testReportEmailNamesThePostAndReason() throws {
        let target = ReportTarget(
            siteURL: site,
            forumName: "Example",
            topicTitle: "A topic",
            topicURL: URL(string: "https://forum.example.com/t/a-topic/42/9?u=me"),
            kind: .post(number: 3, username: "bob")
        )
        let subject = ModerationReport.subject(for: target, blocked: false)
        XCTAssertEqual(subject, "Forumind report: post #3 by @bob on forum.example.com")
        let body = ModerationReport.body(for: target, reason: .harassment, note: " rude ", blocked: false, adapter: DiscourseAdapter(), appVersion: "1.0 (1)")
        XCTAssertTrue(body.contains("Post URL: https://forum.example.com/t/a-topic/42/3"))
        XCTAssertTrue(body.contains("Reason: harassment"))
        XCTAssertTrue(body.contains("Details:\nrude"))
        XCTAssertTrue(ModerationReport.subject(for: target, blocked: true).hasPrefix("Forumind block:"))

        let mailto = try XCTUnwrap(ModerationReport.mailtoURL(subject: subject, body: body))
        XCTAssertEqual(mailto.scheme, "mailto")
        XCTAssertTrue(mailto.absoluteString.hasPrefix("mailto:\(ModerationTerms.reportEmail)?subject="))
    }

    func testPostURLKeepsTheTopicPathOnly() {
        let url = { (string: String) in URL(string: string)! }
        XCTAssertEqual(
            DiscourseLinks().postURL(topicURL: url("https://f.example/t/slug/42"), number: 5, anchor: nil).absoluteString,
            "https://f.example/t/slug/42/5"
        )
        XCTAssertEqual(
            DiscourseLinks().postURL(topicURL: url("https://f.example/forum/t/slug/42/17/"), number: 5, anchor: nil).absoluteString,
            "https://f.example/forum/t/slug/42/5"
        )
    }

    func testReportEmailLinksToNativeComment() throws {
        let cases: [(any SiteAdapter, String, String)] = [
            (HackerNewsAdapter(), "https://news.ycombinator.com/item?id=42", "https://news.ycombinator.com/item?id=42#101"),
            (WordPressAdapter(), "https://wp.example/?p=42", "https://wp.example/?p=42#comment-101")
        ]
        for (adapter, topicURL, expected) in cases {
            let target = ReportTarget(siteURL: "https://example.com", forumName: "Example",
                topicTitle: "Topic", topicURL: try XCTUnwrap(URL(string: topicURL)),
                kind: .post(number: 101, username: "alice"))
            let draft = ModerationReport.draft(for: target, reason: nil, note: "", blocked: false, adapter: adapter)
            XCTAssertTrue(draft.body.contains("Post URL: \(expected)"), draft.body)
        }
    }

    // MARK: Settings and sync

    func testOlderSettingsDecodeWithNoBlocksAndNoAcceptedTerms() throws {
        let data = try JSONEncoder().encode(AppSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["blockedUsers", "filteredWords", "acceptedTermsVersion"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.blockedUsers.isEmpty)
        XCTAssertTrue(decoded.filteredWords.isEmpty)
        XCTAssertFalse(decoded.hasAcceptedCurrentTerms)
    }

    func testBlocksSyncButTermsAcceptanceStaysOnTheDevice() throws {
        var settings = AppSettings()
        settings.blockedUsers = [BlockedUser(siteURL: site, username: "bob")]
        settings.filteredWords = ["spam"]
        settings.acceptedTermsVersion = ModerationTerms.currentVersion
        let units = try SyncSchema.settingsUnits(settings)
        XCTAssertNotNil(units["blockedUsers"])
        XCTAssertNotNil(units["filteredWords"])
        XCTAssertNil(units["acceptedTermsVersion"])
        XCTAssertTrue(SyncSettings.deviceLocalKeys.contains("acceptedTermsVersion"))
    }

    func testBlockingFiltersPromptsAndSurvivesAReset() throws {
        let app = makeApp()
        app.block("@Bob ", on: site)
        app.block("bob", on: site)
        XCTAssertEqual(app.settings.blockedUsers.map(\.username), ["Bob"], "Blocking twice keeps one entry.")
        XCTAssertTrue(app.isBlocked("BOB", on: site))
        XCTAssertFalse(app.moderated(raw, siteURL: site, topicID: "1").contains("buy now"))
        XCTAssertTrue(app.browser.moderationRules.hidesUser("bob", siteURL: site), "The browser gets the new rules.")

        XCTAssertTrue(app.addFilteredWord("helpful"))
        XCTAssertFalse(app.addFilteredWord("HELPFUL"))
        XCTAssertFalse(app.moderated(raw, siteURL: site, topicID: "1").contains("A helpful reply."))

        app.acceptTerms()
        app.resetSettings()
        XCTAssertTrue(app.isBlocked("bob", on: site))
        XCTAssertEqual(app.settings.filteredWords, ["helpful"])
        XCTAssertFalse(app.needsTermsAcceptance)

        app.unblock(try XCTUnwrap(app.settings.blockedUsers.first))
        app.removeFilteredWords(atOffsets: [0])
        XCTAssertEqual(app.moderated(raw, siteURL: site, topicID: "1"), raw)
    }

    func testNewInstallsMustAcceptTheTerms() {
        let app = makeApp()
        XCTAssertTrue(app.needsTermsAcceptance)
        app.acceptTerms()
        XCTAssertFalse(app.needsTermsAcceptance)
        XCTAssertEqual(app.settings.acceptedTermsVersion, ModerationTerms.currentVersion)
    }

    func testPostPreviewAndExportFilterBlockedUsersAndWords() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moderation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PersistentStore(
            fileURL: directory.appendingPathComponent("state.json"),
            keys: InMemoryProviderKeyStore()
        )
        let url = try XCTUnwrap(URL(string: "\(site)/t/a-topic/1"))
        let topic = ForumTopic(siteURL: site, topicID: "1", url: url, title: "A topic")
        var session = TopicSession(siteURL: site, topicID: "1", url: url, title: "A topic")
        session.seedSource(raw)
        session.summary = "Clean summary."
        var snapshot = AppSnapshot()
        snapshot.sessions = [session]
        try store.save(snapshot)

        let app = AppModel(store: store)
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        let page = PageContext(url: url, site: .discourse, siteURL: site, forumName: "Example", topic: topic, state: .topic)
        app.browser.setPageContext(page)
        handler?(page)

        app.block("bob", on: site)
        XCTAssertTrue(app.addFilteredWord("helpful"))

        let preview = PostPreviewView(app: app).source
        XCTAssertTrue(preview.contains("Welcome to the topic."))
        XCTAssertFalse(preview.contains("Bob |"), "Blocked author leaked into Post & Responses preview.")
        XCTAssertFalse(preview.contains("buy now"), "Blocked author's text leaked into Post & Responses preview.")
        XCTAssertFalse(preview.contains("A helpful reply."), "Filtered word post leaked into Post & Responses preview.")

        let exported = AssistantPanel(app: app, onExpand: { _ in }).payload.text(options: ExportOptions())
        XCTAssertTrue(exported.contains("Clean summary."))
        XCTAssertTrue(exported.contains("Welcome to the topic."))
        XCTAssertFalse(exported.contains("Bob |"), "Blocked author leaked into default Copy/Share/Export.")
        XCTAssertFalse(exported.contains("buy now"), "Blocked author's text leaked into default Copy/Share/Export.")
        XCTAssertFalse(exported.contains("A helpful reply."), "Filtered word post leaked into default Copy/Share/Export.")

        app.unblock(try XCTUnwrap(app.settings.blockedUsers.first))
        app.removeFilteredWords(atOffsets: [0])
        XCTAssertEqual(PostPreviewView(app: app).source, raw)
    }

    func testCurrentModeratedSourceCachesPerTopicAndInvalidates() throws {
        let url1 = try XCTUnwrap(URL(string: "\(site)/t/topic-one/1"))
        let topic1 = ForumTopic(siteURL: site, topicID: "1", url: url1, title: "Topic One")
        var session1 = TopicSession(siteURL: site, topicID: "1", url: url1, title: "Topic One")
        session1.seedSource(raw)
        session1.openedByUserAt = Date()

        let raw2 = """
        dave | 2026-01-02 10:00:00 UTC | #1

        Second topic opening post.

        -------------------------

        Bob | 2026-01-02 11:00:00 UTC | #2

        Another bob post.

        -------------------------

        erin | 2026-01-02 12:00:00 UTC | #3

        Second topic reply.

        -------------------------
        """
        let url2 = try XCTUnwrap(URL(string: "\(site)/t/topic-two/2"))
        let topic2 = ForumTopic(siteURL: site, topicID: "2", url: url2, title: "Topic Two")
        var session2 = TopicSession(siteURL: site, topicID: "2", url: url2, title: "Topic Two")
        session2.seedSource(raw2)
        session2.openedByUserAt = Date()

        let app = makeApp(sessions: [session1, session2])
        app.select(topic: topic1)
        app.block("bob", on: site)

        let expectedBobBlocked = ModerationFilter.filter(
            raw, siteURL: site, topicID: "1",
            rules: app.topicModerationRules(siteURL: site, topicID: "1")
        )

        // 20 reads with one blocked user invoke ModerationFilter.filter once.
        ModerationFilter.debugFilterCallCount = 0
        var firstResult = ""
        for _ in 0..<20 {
            firstResult = app.currentModeratedSource
            XCTAssertEqual(firstResult, expectedBobBlocked)
        }
        XCTAssertEqual(ModerationFilter.debugFilterCallCount, 1)
        XCTAssertFalse(firstResult.contains("buy now"))

        // Adding another block recomputes and removes newly blocked posts (stale cache cannot show blocked posts).
        app.block("carol", on: site)
        let expectedBothBlocked = ModerationFilter.filter(
            raw, siteURL: site, topicID: "1",
            rules: app.topicModerationRules(siteURL: site, topicID: "1")
        )
        ModerationFilter.debugFilterCallCount = 0
        let afterSecondBlock = app.currentModeratedSource
        XCTAssertEqual(ModerationFilter.debugFilterCallCount, 1)
        XCTAssertNotEqual(afterSecondBlock, firstResult)
        XCTAssertEqual(afterSecondBlock, expectedBothBlocked)
        XCTAssertFalse(afterSecondBlock.contains("A helpful reply."))
        // Subsequent read hits cache.
        XCTAssertEqual(app.currentModeratedSource, expectedBothBlocked)
        XCTAssertEqual(ModerationFilter.debugFilterCallCount, 1)

        // Unblocking recomputes and restores posts (stale cache cannot hide unblocked posts).
        let carolBlock = try XCTUnwrap(app.settings.blockedUsers.first { $0.username.caseInsensitiveCompare("carol") == .orderedSame })
        app.unblock(carolBlock)
        ModerationFilter.debugFilterCallCount = 0
        let afterUnblockCarol = app.currentModeratedSource
        XCTAssertEqual(ModerationFilter.debugFilterCallCount, 1)
        XCTAssertNotEqual(afterUnblockCarol, afterSecondBlock)
        XCTAssertEqual(afterUnblockCarol, expectedBobBlocked)
        XCTAssertTrue(afterUnblockCarol.contains("A helpful reply."))

        // Unblocking the last blocked user restores the full source.
        let bobBlock = try XCTUnwrap(app.settings.blockedUsers.first { $0.username.caseInsensitiveCompare("bob") == .orderedSame })
        app.unblock(bobBlock)
        let expectedUnblocked = ModerationFilter.filter(
            raw, siteURL: site, topicID: "1",
            rules: app.topicModerationRules(siteURL: site, topicID: "1")
        )
        ModerationFilter.debugFilterCallCount = 0
        let afterUnblockAll = app.currentModeratedSource
        XCTAssertEqual(ModerationFilter.debugFilterCallCount, 1)
        XCTAssertNotEqual(afterUnblockAll, afterUnblockCarol)
        XCTAssertEqual(afterUnblockAll, expectedUnblocked)
        XCTAssertEqual(afterUnblockAll, raw)

        // Re-block bob and switch topic: must recompute and match uncached filter for topic 2.
        app.block("bob", on: site)
        _ = app.currentModeratedSource
        app.select(topic: topic2)
        let expectedTopic2 = ModerationFilter.filter(
            raw2, siteURL: site, topicID: "2",
            rules: app.topicModerationRules(siteURL: site, topicID: "2")
        )
        ModerationFilter.debugFilterCallCount = 0
        let topic2Result = app.currentModeratedSource
        XCTAssertEqual(ModerationFilter.debugFilterCallCount, 1)
        XCTAssertNotEqual(topic2Result, expectedBobBlocked)
        XCTAssertEqual(topic2Result, expectedTopic2)
        XCTAssertFalse(topic2Result.contains("Another bob post."))
        XCTAssertTrue(topic2Result.contains("Second topic opening post."))
        // Subsequent read of topic 2 hits cache.
        XCTAssertEqual(app.currentModeratedSource, expectedTopic2)
        XCTAssertEqual(ModerationFilter.debugFilterCallCount, 1)
    }

    // MARK: Reporting AI digests, podcasts, and voice answers

    func testReportingAIDigestsPodcastsAndVoiceAnswers() throws {
        let app = makeApp()
        app.selectModel(ModelSelection(provider: .openAI, model: "gpt-test"), for: .both)

        var card = DigestCard(
            siteURL: site,
            topicID: "42",
            title: "Digest Topic",
            slug: "digest-topic",
            reason: .trending,
            postCount: 15,
            summary: "## Digest Summary\n- Point #1",
            state: .done
        )
        let digest = DailyDigest(day: "2026-11-06", cards: [card])

        let cardReport = try XCTUnwrap(app.aiOutputReport(for: card, digest: digest))
        XCTAssertEqual(cardReport.topicTitle, "Digest Topic")
        if case .aiOutput(let out) = cardReport.kind {
            XCTAssertEqual(out.feature, .digest)
            XCTAssertTrue(out.text.contains("Point #1"))
        } else {
            XCTFail("Expected .aiOutput(.digest)")
        }
        XCTAssertTrue(ModerationReport.subject(for: cardReport, blocked: false).contains("daily digest"))

        let digestReport = try XCTUnwrap(app.aiOutputReport(for: digest))
        if case .aiOutput(let out) = digestReport.kind {
            XCTAssertEqual(out.feature, .digest)
        } else {
            XCTFail("Expected .aiOutput(.digest)")
        }
        card.summary = ""
        XCTAssertNil(app.aiOutputReport(for: card, digest: digest))

        var chapter = PodcastChapter(card: digest.cards[0])
        chapter.turns = [
            PodcastTurn(speaker: .a, text: "Welcome to the chapter."),
            PodcastTurn(speaker: .b, text: "Here is what happened.")
        ]
        var entry = PodcastEpisode.Entry(chapter: chapter)
        entry.state = .ready
        let episode = PodcastEpisode(
            digestID: digest.id,
            day: digest.day,
            title: "Today's Podcast",
            language: "en",
            hosts: PodcastHosts(a: "A", b: "B"),
            engine: .onDevice,
            voices: PodcastVoices(a: "A", b: "B"),
            minutesPerChapter: 1,
            entries: [entry]
        )

        let chapterReport = try XCTUnwrap(app.aiOutputReport(for: episode, chapter: chapter))
        if case .aiOutput(let out) = chapterReport.kind {
            XCTAssertEqual(out.feature, .podcast)
            XCTAssertTrue(out.text.contains("Here is what happened."))
        } else {
            XCTFail("Expected .aiOutput(.podcast)")
        }
        XCTAssertTrue(ModerationReport.subject(for: chapterReport, blocked: false).contains("podcast"))

        let episodeReport = try XCTUnwrap(app.aiOutputReport(for: episode))
        if case .aiOutput(let out) = episodeReport.kind {
            XCTAssertEqual(out.feature, .podcast)
            XCTAssertTrue(out.text.contains("Digest Topic"))
        } else {
            XCTFail("Expected .aiOutput(.podcast)")
        }

        let voiceSession = VoiceSession(
            configuration: .init(endpoint: .aiStudio, apiKey: "k", settings: VoiceSettings(), hasConsent: true),
            transport: { FakeLiveTransport() },
            audio: FakeVoiceAudio(),
            navigator: FakeVoiceNavigator(),
            runsLoop: false
        )
        XCTAssertNil(app.aiOutputReport(for: voiceSession), "Empty voice answer is not reportable")
        voiceSession.receive(Data(#"{"serverContent":{"outputTranscription":{"text":"The accepted answer is in post #4."}}}"#.utf8))
        let voiceReport = try XCTUnwrap(app.aiOutputReport(for: voiceSession))
        if case .aiOutput(let out) = voiceReport.kind {
            XCTAssertEqual(out.feature, .voiceAnswer)
            XCTAssertEqual(out.text, "The accepted answer is in post #4.")
        } else {
            XCTFail("Expected .aiOutput(.voiceAnswer)")
        }
        XCTAssertTrue(ModerationReport.subject(for: voiceReport, blocked: false).contains("voice answer"))
    }

    // MARK: Blocked posts and accounts excluded across every AI path

    func testBlockedPostAndBlockedUserAreExcludedFromSummaryAndChat() async throws {
        final class CapturingAI: AIService, @unchecked Sendable {
            var summaryContents: [String] = []
            var chatSources: [String] = []

            override func generateSummary(
                content: String,
                configuration: ProviderConfiguration,
                provider: AIProvider,
                customPrompt: String,
                discussion: DiscussionProfile,
                batchLimit: Int = SummaryBatchLimit.default,
                onDelta: @escaping @MainActor (String) -> Void,
                onProgress: @escaping @MainActor (SummaryProgressEvent) -> Void = { _ in }
            ) async throws -> String {
                summaryContents.append(content)
                return "## Summary\n- Done"
            }

            override func answer(
                source: String,
                summary: String,
                history: [ChatMessage],
                contextLimit: Int,
                customPrompt: String,
                discussion: DiscussionProfile,
                configuration: ProviderConfiguration,
                provider: AIProvider,
                onDelta: @escaping @MainActor (String) -> Void,
                summaryIsStale: Bool = false
            ) async throws -> String {
                chatSources.append(source)
                return "Chat answer."
            }
        }

        ModerationURLStub.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/t/1.json") {
                body = #"{"title":"A topic","slug":"a-topic","posts_count":3,"highest_post_number":3}"#
            } else if path.hasSuffix("/raw/1") {
                body = self.raw
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": path.hasSuffix(".json") ? "application/json" : "text/plain"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ModerationURLStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let ai = CapturingAI()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moderation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let url = try XCTUnwrap(URL(string: "\(site)/t/a-topic/1"))
        let topic = ForumTopic(siteURL: site, topicID: "1", url: url, title: "A topic")
        var session = TopicSession(siteURL: site, topicID: "1", url: url, title: "A topic")
        session.seedSource(raw)
        try store.save(AppSnapshot(sessions: [session], forums: [Forum(siteURL: site, kind: .discourse, name: "Example")]))

        let app = AppModel(store: store, forumService: forumService, aiService: ai)
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama"), for: .both)
        app.select(topic: topic)

        // Block user Bob (#2) and block post #3 (carol).
        app.block("bob", on: site)
        app.blockPost(3, topicID: "1", on: site)
        XCTAssertTrue(app.isPostBlocked(3, topicID: "1", on: site))

        // 1. Summary path
        XCTAssertTrue(app.enqueueSummary(for: topic))
        let deadline = Date().addingTimeInterval(5)
        while app.activities.first?.status != .completed, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let summaryInput = try XCTUnwrap(ai.summaryContents.first)
        XCTAssertTrue(summaryInput.contains("Welcome to the topic."))
        XCTAssertFalse(summaryInput.contains("buy now"), "Blocked user's post leaked to summary model")
        XCTAssertFalse(summaryInput.contains("A helpful reply."), "Blocked post #3 leaked to summary model")

        // 2. Chat path
        app.drafts.chat = "What was said?"
        app.sendChat()
        while app.activities.contains(where: { $0.type == .chat && !$0.status.isTerminal }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let chatInput = try XCTUnwrap(ai.chatSources.first)
        XCTAssertTrue(chatInput.contains("Welcome to the topic."))
        XCTAssertFalse(chatInput.contains("buy now"), "Blocked user's post leaked to chat model")
        XCTAssertFalse(chatInput.contains("A helpful reply."), "Blocked post #3 leaked to chat model")
    }

    func testBlockedPostAndBlockedUserAreExcludedFromAgentPaths() async throws {
        ModerationURLStub.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/search.json") {
                body = #"""
                {
                  "topics": [
                    {"id": 1, "title": "Topic One", "slug": "topic-one", "posts_count": 3},
                    {"id": 2, "title": "Topic Two", "slug": "topic-two", "posts_count": 2}
                  ],
                  "posts": [
                    {"id": 10, "topic_id": 1, "post_number": 2, "username": "bob", "blurb": "Bob spam blurb"},
                    {"id": 11, "topic_id": 1, "post_number": 3, "username": "carol", "blurb": "Carol blocked post blurb"},
                    {"id": 12, "topic_id": 2, "post_number": 1, "username": "alice", "blurb": "Alice clean blurb"}
                  ]
                }
                """#
            } else if path.hasSuffix("/t/1.json") {
                body = #"{"title":"Topic One","slug":"topic-one","posts_count":3,"highest_post_number":3}"#
            } else if path.hasSuffix("/raw/1") {
                body = self.raw
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": path.hasSuffix(".json") ? "application/json" : "text/plain"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ModerationURLStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "search_forum", arguments: ["query": "blurb"]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "1"]),
            AgentAction(thought: "", tool: "read_topic", arguments: ["topic_id": "1", "query": "helpful"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done."])
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try store.save(AppSnapshot(forums: [Forum(siteURL: site, kind: .discourse, name: "Example")]))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(store: store, forumService: forumService, aiService: ai, planner: planner)
        app.usesDirectForumRequests = true
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama"), for: .both)
        app.browser.onPageContextChanged = nil

        app.block("bob", on: site)
        app.blockPost(3, topicID: "1", on: site)

        app.startAgentRun(goal: "Check forum", siteURL: site)
        let deadline = Date().addingTimeInterval(10)
        while !(app.agentRuns.first?.isFinished ?? false), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.result, .completed, run.error)

        // 1. Agent search_forum observation excludes blocked user bob and blocked post #3 (leaving only Topic Two).
        let searchObs = try XCTUnwrap(planner.transcripts[1].last?.content)
        XCTAssertFalse(searchObs.contains("Bob spam blurb"), searchObs)
        XCTAssertFalse(searchObs.contains("Carol blocked post blurb"), searchObs)
        XCTAssertFalse(searchObs.contains("Topic One"), "Topic whose only search hits were blocked must not appear in search observation")
        XCTAssertTrue(searchObs.contains("Alice clean blurb"), searchObs)

        // 2. Agent read_topic observation excludes blocked user bob and blocked post #3.
        let readObs = try XCTUnwrap(planner.transcripts[2].last?.content)
        XCTAssertTrue(readObs.contains("Welcome to the topic."))
        XCTAssertFalse(readObs.contains("buy now"))
        XCTAssertFalse(readObs.contains("A helpful reply."))

        // 3. Agent read_topic(query: "helpful") finds 0 matching posts because post #3 is blocked.
        let queryObs = try XCTUnwrap(planner.transcripts[3].last?.content)
        XCTAssertTrue(queryObs.contains("Showing: 0 matching posts for \"helpful\""), queryObs)
        XCTAssertFalse(queryObs.contains("A helpful reply."), queryObs)
    }

    func testBlockedPostAndBlockedUserAreExcludedFromDigestAndPodcast() {
        let app = makeApp()
        app.block("bob", on: site)
        app.blockPost(3, topicID: "1", on: site)
        let rules = app.browser.moderationRules

        let facts = TopicFacts(
            postsCount: 4,
            highestPostNumber: 4,
            stream: [10, 11, 12, 13],
            openingPoster: "alice",
            acceptedAnswer: TopicFacts.AcceptedAnswer(postNumber: 3, username: "carol"),
            posts: [
                TopicFacts.Post(id: 10, number: 1, username: "alice", likeCount: 1),
                TopicFacts.Post(id: 11, number: 2, username: "bob", likeCount: 50),
                TopicFacts.Post(id: 12, number: 3, username: "carol", likeCount: 30),
                TopicFacts.Post(id: 13, number: 4, username: "dave", likeCount: 5)
            ]
        )
        let overview = ForumTopicOverview(
            siteURL: site,
            topicID: "1",
            title: "Digest Topic",
            slug: "digest-topic",
            url: URL(string: "\(site)/t/digest-topic/1")!,
            postCount: 4,
            facts: facts
        )

        // DigestTopicFacts excludes blocked post #3 from acceptedAnswerPost and blocked user bob (#2) + blocked post #3 from topPost.
        let digestFacts = DigestTopicFacts(overview: overview, rules: rules)
        XCTAssertNil(digestFacts.acceptedAnswerPost, "Blocked post #3 must not be selected as acceptedAnswerPost")
        XCTAssertEqual(digestFacts.topPost, 4, "Blocked user bob (#2) and blocked post #3 must not be selected as topPost")

        // Podcast multi-page rawPages moderation when session.source is empty.
        var session = TopicSession(siteURL: site, topicID: "1", url: overview.url, title: overview.title)
        session.rawPages = [
            RawForumPage(page: 1, content: "alice | 2026-01-01 10:00:00 UTC | #1\nOpening post\n\n\nBob | 2026-01-01 11:00:00 UTC | #2\nSpam on page 1\n"),
            RawForumPage(page: 2, content: "carol | 2026-01-01 12:00:00 UTC | #3\nBlocked post on page 2\n\n\ndave | 2026-01-01 13:00:00 UTC | #4\nClean reply on page 2\n")
        ]
        session.source = ""
        let joined = RawTopicFormat.join(session.rawPages.map(\.content))
        let moderatedPodcastSource = app.moderated(joined, siteURL: site, topicID: "1")
        XCTAssertTrue(moderatedPodcastSource.contains("Opening post"))
        XCTAssertTrue(moderatedPodcastSource.contains("Clean reply on page 2"))
        XCTAssertFalse(moderatedPodcastSource.contains("Spam on page 1"), "Blocked user leaked in multi-page podcast source")
        XCTAssertFalse(moderatedPodcastSource.contains("Blocked post on page 2"), "Blocked post #3 leaked in multi-page podcast source")
    }

    func testBlockedPostAndBlockedUserAreExcludedFromVoiceAndTranslation() async throws {
        ModerationURLStub.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/t/1.json") {
                body = #"""
                {
                  "title": "Voice Topic",
                  "slug": "voice-topic",
                  "posts_count": 4,
                  "highest_post_number": 4,
                  "accepted_answer": {"post_number": 3, "username": "carol"},
                  "post_stream": {
                    "stream": [10, 11, 12, 13],
                    "posts": [
                      {"id": 10, "post_number": 1, "username": "alice", "cooked": "<p>Opening post</p>", "actions_summary": []},
                      {"id": 11, "post_number": 2, "username": "bob", "cooked": "<p>Bob post</p>", "actions_summary": [{"id": 2, "count": 20}]},
                      {"id": 12, "post_number": 3, "username": "carol", "cooked": "<p>Carol post</p>", "actions_summary": [{"id": 2, "count": 15}]},
                      {"id": 13, "post_number": 4, "username": "dave", "cooked": "<p>Dave post</p>", "actions_summary": [{"id": 2, "count": 5}]}
                    ]
                  }
                }
                """#
            } else if path.hasSuffix("/posts.json") {
                let ids = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
                    .queryItems?.filter { $0.name == "post_ids[]" }.compactMap { $0.value } ?? []
                if ids == ["13"] {
                    body = #"{"post_stream":{"posts":[{"id":13,"post_number":4,"username":"dave","cooked":"<p>Dave clean reply</p>"}]}}"#
                } else {
                    body = #"{"post_stream":{"posts":[{"id":10,"post_number":1,"username":"alice","cooked":"<p>Opening post</p>"}]}}"#
                }
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ModerationURLStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        try store.save(AppSnapshot(forums: [Forum(siteURL: site, kind: .discourse, name: "Example")]))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let app = AppModel(store: store, forumService: forumService)
        app.usesDirectForumRequests = true
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        let url = URL(string: "\(site)/t/voice-topic/1")!
        let topic = ForumTopic(siteURL: site, topicID: "1", url: url, title: "Voice Topic")
        let page = PageContext(url: url, site: .discourse, siteURL: site, forumName: "Example", topic: topic, state: .topic)
        app.browser.setPageContext(page)
        handler?(page)

        app.block("bob", on: site)
        app.blockPost(3, topicID: "1", on: site)

        // 1. Voice brief excludes blocked user bob (#2) and blocked post #3 from solution and topPosts.
        let rawBrief = await app.voiceTopicBrief()
        let brief = try XCTUnwrap(rawBrief)
        XCTAssertNil(brief.solution, "Blocked post #3 must not appear as VoiceTopicBrief.solution")
        XCTAssertEqual(brief.topPosts.map(\.number), [4], "Blocked user bob (#2) and blocked post #3 must not appear in VoiceTopicBrief.topPosts")

        // 2. Voice postsOnScreen and Translation postsToTranslate exclude blocked user and blocked post.
        app.browser.visiblePostsOverride = [
            VisiblePost(number: 1, username: "alice", excerpt: "Opening post"),
            VisiblePost(number: 2, username: "bob", excerpt: "Bob spam"),
            VisiblePost(number: 3, username: "carol", excerpt: "Carol blocked post"),
            VisiblePost(number: 4, username: "dave", excerpt: "Dave clean reply")
        ]

        let visible = await app.postsOnScreen()
        XCTAssertEqual(visible.map(\.number), [1, 4], "postsOnScreen must exclude blocked user (#2) and blocked post (#3)")

        let toTranslate = await app.postsToTranslate()
        XCTAssertEqual(toTranslate.map(\.number), [1, 4], "postsToTranslate must exclude blocked user (#2) and blocked post (#3)")
    }

    func testWordPressBlockedCommentAndBlockedArticleExcludedFromSearchTools() async throws {
        let wpSite = "https://wp.example.com"
        ModerationURLStub.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/wp-json/wp/v2/comments") {
                body = #"[{"id":102,"post":42,"parent":0,"author_name":"bob","date_gmt":"2026-10-20T12:05:00","content":{"rendered":"<p>WP_BLOCKED_COMMENT_SECRET</p>"}}]"#
            } else if path.hasSuffix("/wp-json/wp/v2/posts") {
                body = #"[{"id":42,"title":{"rendered":"WP_BLOCKED_ARTICLE_TITLE"},"link":"https://wp.example.com/?p=42","date_gmt":"2026-10-20T12:00:00","excerpt":{"rendered":"<p>WP_BLOCKED_ARTICLE_EXCERPT</p>"}}]"#
            } else {
                body = "[]"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ModerationURLStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "search_comments", arguments: ["query": "secret"]),
            AgentAction(thought: "", tool: "search_forum", arguments: ["query": "article"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done."])
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = AppSnapshot()
        seeded.ensureForum(wpSite, kind: .wordpress)
        try store.save(seeded)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(store: store, forumService: forumService, aiService: ai, planner: planner)
        app.usesDirectForumRequests = true
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .both)
        app.browser.onPageContextChanged = nil

        // Blocks use the native comment ID; zero identifies the article.
        app.blockPost(102, topicID: "42", on: wpSite)
        app.blockPost(0, topicID: "42", on: wpSite)
        app.block("mallory", on: wpSite)

        _ = try await app.performAgentRun(goal: "Find secrets", siteURL: wpSite)
        let transcript = planner.transcripts.flatMap { $0 }.map(\.content).joined(separator: "\n")

        XCTAssertFalse(transcript.contains("WP_BLOCKED_COMMENT_SECRET"))
        XCTAssertFalse(transcript.contains("WP_BLOCKED_ARTICLE_EXCERPT"))
        XCTAssertFalse(transcript.contains("WP_BLOCKED_ARTICLE_TITLE"))
    }

    func testBlockedFirstNewPostAndBlockedUserAcceptedPostExcludedFromDigestAndPodcast() async throws {
        ModerationURLStub.handler = { request in
            let path = request.url?.path ?? ""
            let body: String
            if path.hasSuffix("/t/50.json") {
                body = #"{"title":"Topic 50","slug":"topic-50","posts_count":3,"accepted_answer":{"post_number":3,"username":"mallory"},"post_stream":{"posts":[{"id":1,"post_number":1,"username":"alice","like_count":0},{"id":2,"post_number":2,"username":"bob","like_count":0},{"id":3,"post_number":3,"username":"mallory","like_count":25}]}}"#
            } else if path.hasSuffix("/raw/50") {
                body = "alice | 2026-10-20 12:00:00 UTC | #1\nPost 1\n\n\nbob | 2026-10-20 12:05:00 UTC | #2\nBlocked post 2\n\n\nmallory | 2026-10-20 12:10:00 UTC | #3\nBlocked user post 3\n"
            } else {
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": path.hasSuffix(".json") ? "application/json" : "text/plain"]
            )!
            return (response, Data(body.utf8))
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [ModerationURLStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let watched = WatchedTopic(siteURL: site, topicID: "50", url: URL(string: "\(site)/t/topic-50/50")!, title: "Topic 50", knownPostCount: 1)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = AppSnapshot(watchedTopics: [watched])
        seeded.ensureForum(site)
        try store.save(seeded)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let ai = StateAIStub()
        ai.gated = false
        let app = AppModel(store: store, forumService: forumService, aiService: ai)
        app.usesDirectForumRequests = true
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .both)
        app.browser.onPageContextChanged = nil

        var prefetch = DigestPrefetch(day: DailyDigest.dayKey(for: Date()))
        let refKey = TopicIdentity.key(siteURL: site, topicID: "50")
        prefetch.topics[refKey] = DigestTopicFacts(title: "Topic 50", slug: "topic-50", postCount: 3, acceptedAnswerPost: 3, topPost: 3)
        app.digestPrefetch = prefetch

        app.blockPost(2, topicID: "50", on: site)
        app.block("mallory", on: site)

        app.makeTodaysDigest()
        let deadline = Date().addingTimeInterval(5)
        while app.todaysDigest?.isComplete != true, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let card = try XCTUnwrap(app.todaysDigest?.cards.first)
        let digestInstructions = try XCTUnwrap(ai.calls.last(where: { $0.kind == "summary" })?.customPrompt)
        let podcastPrompt = PodcastPrompt.content(
            for: PodcastPrompt.Chapter(card: card, forumName: "Stub", index: 1, count: 1, previousTitle: nil, topicText: "")
        )

        XCTAssertNotEqual(card.firstNewPost, 2)
        XCTAssertNil(card.acceptedAnswerPost)
        XCTAssertNil(card.topPost)
        XCTAssertFalse(digestInstructions.contains("#2"))
        XCTAssertFalse(podcastPrompt.contains("post #3") || podcastPrompt.contains("post #2"))
    }

    func testPostSummaryBlockExcludesPreBlockSummaryFromDownstreamAIContext() async throws {
        StateForumStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StateForumStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let planner = ScriptedAgentPlanner(actions: [
            AgentAction(thought: "", tool: "saved_summaries", arguments: ["query": "Topic"]),
            AgentAction(thought: "", tool: AgentPrompt.finalAnswerTool, arguments: ["answer": "Done."])
        ])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = AppSnapshot()
        seeded.ensureForum(site)
        // Seeded, not `app.watch`: that asks for notification permission, and
        // on a fresh simulator nothing answers the dialog.
        seeded.watchedTopics = [WatchedTopic(
            siteURL: site,
            topicID: "1",
            url: URL(string: "\(site)/t/topic-1/1")!,
            title: "Topic 1",
            knownPostCount: 1
        )]
        try store.save(seeded)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let ai = StateAIStub()
        ai.gated = false
        ai.echoContentInSummary = true
        let app = AppModel(store: store, forumService: forumService, aiService: ai, planner: planner)
        app.usesDirectForumRequests = true
        app.settings.hasCompletedOnboarding = true
        app.acceptTerms()
        app.allowAllAIProviders()
        app.selectModel(ModelSelection(provider: .ollama, model: "llama-local"), for: .both)
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil

        let t1 = ForumTopic(siteURL: site, topicID: "1", url: URL(string: "\(site)/t/topic-1/1")!, title: "Topic 1")
        let page = PageContext(url: t1.url, site: .discourse, siteURL: site, forumName: "Stub", topic: t1, state: .topic)
        app.browser.setPageContext(page)
        handler?(page)

        // Summarize Topic 1 before blocking Post #2 ("Post 2" by bob).
        XCTAssertTrue(app.enqueueSummary(for: t1))
        let deadline1 = Date().addingTimeInterval(5)
        while !app.activities.allSatisfy(\.status.isTerminal), Date() < deadline1 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let initialSummary = try XCTUnwrap(app.sessions[t1.topicKey]?.summary)
        XCTAssertTrue(initialSummary.contains("Post 2"))

        // Block Post #2 on the topic's site:
        app.blockPost(2, topicID: "1", on: site)
        XCTAssertEqual(app.sessions[t1.topicKey]?.summary, initialSummary, "Summary is not deleted on block")

        // 1. Chat does not send the pre-block summary as context.
        app.drafts.chat = "What did people say?"
        app.sendChat()
        let deadline2 = Date().addingTimeInterval(5)
        while !app.activities.allSatisfy(\.status.isTerminal), Date() < deadline2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let chatSummarySent = try XCTUnwrap(ai.calls.last(where: { $0.kind == "chat" })?.summary)

        // 2. Voice brief does not include the pre-block summary.
        let voiceBrief = await app.voiceTopicBrief()?.summary ?? ""

        // 3. Agent saved_summaries does not send the pre-block summary to the planner.
        _ = try await app.performAgentRun(goal: "Check saved summaries", siteURL: site)
        let agentObservation = planner.transcripts.flatMap { $0 }.map(\.content).joined(separator: "\n")

        // 4. Daily Digest does not condense the pre-block summary.
        StateForumStub.postCounts["1"] = 2
        app.makeTodaysDigest()
        let deadline3 = Date().addingTimeInterval(5)
        while app.todaysDigest?.isComplete != true, Date() < deadline3 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let digestSummaryInput = ai.calls.last(where: { $0.kind == "summary" })?.content ?? ""

        // 5. Re-running Summarize (without regenerate) does not short-circuit on the pre-block summary.
        let summaryCallsBefore = ai.calls.filter { $0.kind == "summary" }.count
        XCTAssertTrue(app.enqueueSummary(for: t1))
        let deadline4 = Date().addingTimeInterval(5)
        while !app.activities.allSatisfy(\.status.isTerminal), Date() < deadline4 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let summaryCallsAfter = ai.calls.filter { $0.kind == "summary" }.count

        XCTAssertFalse(chatSummarySent.contains("Post 2"))
        XCTAssertFalse(voiceBrief.contains("Post 2"))
        XCTAssertFalse(agentObservation.contains("Post 2"))
        XCTAssertFalse(digestSummaryInput.contains("Post 2"))
        XCTAssertGreaterThan(summaryCallsAfter, summaryCallsBefore)
    }

    func testBlockedCitationAndFocusBlockedUserAreIgnored() async throws {
        StateForumStub.reset()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StateForumStub.self]
        let forumService = ForumService(session: URLSession(configuration: cfg), pacer: ForumRequestPacer(clock: InstantPacingClock()))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var seeded = AppSnapshot()
        seeded.ensureForum(site)
        try store.save(seeded)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let app = AppModel(store: store, forumService: forumService)
        app.usesDirectForumRequests = true
        let handler = app.browser.onPageContextChanged
        app.browser.onPageContextChanged = nil
        let t1 = ForumTopic(siteURL: site, topicID: "1", url: URL(string: "\(site)/t/topic-1/1")!, title: "Topic 1")
        let page = PageContext(url: t1.url, site: .discourse, siteURL: site, forumName: "Stub", topic: t1, state: .topic)
        app.browser.setPageContext(page)
        handler?(page)

        app.blockPost(2, topicID: "1", on: site)
        app.block("mallory", on: site)

        // 1. DrawerSummarySections does not link blocked post #2 while still linking post #1.
        let linked = DrawerSummarySections.link("See #1 and #2.", maximum: 5, hidden: app.currentHiddenPosts)
        XCTAssertTrue(linked.contains("[#1](forumind-post:1)"))
        XCTAssertFalse(linked.contains("forumind-post:2"))

        // 2. jumpToCitation(2) does not lower the drawer from .large to .medium or set citationJump.
        app.router.splitLayout = false
        app.router.openDrawer(at: .large)
        app.router.presentDrawer()
        app.router.drawerAppeared()
        XCTAssertEqual(app.router.drawerDetent, .large)
        app.jumpToCitation(2)
        XCTAssertEqual(app.router.drawerDetent, .large)
        XCTAssertNil(app.citationJump)

        // 3. focus(.user("mallory")) returns .hidden without loading ?username_filters=mallory in the browser.
        let focusResult = await app.focus(.user("mallory"))
        XCTAssertEqual(focusResult.status, .hidden)
        XCTAssertFalse(app.browser.currentURL?.absoluteString.contains("username_filters=mallory") == true)
    }

    private func makeApp(sessions: [TopicSession] = []) -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moderation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PersistentStore(
            fileURL: directory.appendingPathComponent("state.json"),
            keys: InMemoryProviderKeyStore()
        )
        try? store.save(AppSnapshot(sessions: sessions))
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return app
    }
}

private final class ModerationURLStub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class CommentPageModerationTests: XCTestCase {
    func testHackerNewsCommentsCanBeReportedAndHidden() async throws {
        try await check(adapter: HackerNewsAdapter(), url: "https://news.ycombinator.com/item?id=42", html: """
        <table><tbody>
        <tr class="athing comtr" id="101"><td><a class="hnuser">Alice</a><span class="commtext">Helpful reply</span></td></tr>
        <tr class="athing comtr" id="102"><td><a class="hnuser">Bob</a><span class="commtext">BUY spam</span></td></tr>
        <tr class="athing comtr" id="103"><td><a class="hnuser">Carol</a><span class="commtext">Another reply</span></td></tr>
        </tbody></table>
        """)
    }

    func testWordPressCommentsCanBeReportedAndHiddenWithoutHidingReplies() async throws {
        try await check(adapter: WordPressAdapter(), url: "https://blog.example/post/", html: """
        <body class="single postid-42"><ol><li class="comment" id="comment-101"><article id="div-comment-101">
        <div class="comment-author"><b class="fn">Alice</b></div><div class="comment-content">Helpful reply</div></article>
        <ol class="children"><li class="comment" id="comment-103"><article class="comment" id="div-comment-103">
        <div class="comment-author"><b class="fn">Carol</b></div><div class="comment-content">Another reply</div></article></li></ol></li></ol>
        <article class="comment" id="comment-102"><div class="comment-author"><span class="fn">Bob</span></div><div class="comment-content">BUY spam</div></article>
        """, ids: [101, 103, 102])
    }

    private func check(adapter: any SiteAdapter, url: String, html: String, ids: [Int] = [101, 102, 103]) async throws {
        XCTAssertNotNil(adapter.capabilities.pageBridge)
        let browser = ForumBrowserModel()
        // Recognition is tested separately; these minimal pages exercise only the bridges.
        browser.webView.navigationDelegate = nil
        browser.webView.configuration.userContentController.removeScriptMessageHandler(forName: "dcRouteChanged")
        let pageURL = try XCTUnwrap(URL(string: url))
        let siteURL = "\(pageURL.scheme!)://\(pageURL.host!)"
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        browser.webView.frame = host.view.bounds
        host.view.addSubview(browser.webView)
        defer {
            browser.webView.stopLoading()
            browser.webView.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
        }
        browser.webView.loadHTMLString(html, baseURL: URL(string: url))
        for _ in 0..<100 {
            if (try? await browser.webView.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('[id$=\"101\"]')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        browser.setPageContext(PageContext(url: URL(string: url), site: adapter.kind, siteURL: siteURL,
            topic: ForumTopic(siteURL: url, topicID: "42", url: URL(string: url)!, title: "Fixture"), state: .topic))
        let posts = await browser.visiblePosts()
        XCTAssertEqual(posts.map(\.number), ids)
        XCTAssertEqual(posts.first?.username, "Alice")
        XCTAssertEqual(posts.first?.excerpt, "Helpful reply")
        XCTAssertFalse(browser.canTranslatePostsOnScreen)
        let scroll = await browser.scrollToPost(2, anchor: adapter.kind == .hackerNews ? "101" : "comment-101")
        XCTAssertEqual(scroll, .shown)
        let missing = await browser.scrollToPost(99, anchor: "999999")
        XCTAssertEqual(missing, .missing)
        // Use the same entry point as the report sheet and settings.
        browser.moderationRules = ModerationRules(blockedUsers: [siteURL: ["alice"]], filteredWords: ["spam"])
        browser.applyModerationToPage()
        try await Task.sleep(for: .milliseconds(100))
        let remaining = await browser.visiblePosts()
        XCTAssertEqual(remaining.map(\.number), [103])
        let hidden = try await browser.webView.evaluateJavaScript("[101, 102].filter(id => (document.getElementById(String(id)) || document.getElementById('comment-' + id)).querySelector('.commtext, .comment-content').getBoundingClientRect().height === 0).length") as? Int
        XCTAssertEqual(hidden, 2)
        let hiddenJump = await browser.scrollToPost(2, anchor: adapter.kind == .hackerNews ? "101" : "comment-101")
        XCTAssertEqual(hiddenJump, .hidden)
        // New comments loaded into the page inherit the active filter.
        _ = try await browser.webView.evaluateJavaScript("""
        const original = document.getElementById('102') || document.getElementById('comment-102');
        const copy = original.cloneNode(true);
        copy.id = original.id.replace('102', '104');
        copy.removeAttribute('data-forumind-hidden');
        original.parentNode.appendChild(copy);
        true;
        """)
        let newCommentHidden = "(document.getElementById('104') || document.getElementById('comment-104')).getBoundingClientRect().height === 0"
        for _ in 0..<60 {
            if (try await browser.webView.evaluateJavaScript(newCommentHidden)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let dynamicHidden = try await browser.webView.evaluateJavaScript(newCommentHidden) as? Bool
        XCTAssertEqual(dynamicHidden, true)
        _ = try await browser.webView.evaluateJavaScript("copy.remove(); true;")
        browser.moderationRules = ModerationRules()
        browser.applyModerationToPage()
        try await Task.sleep(for: .milliseconds(100))
        let restored = await browser.visiblePosts()
        XCTAssertEqual(restored.map(\.number), ids)
        // Reporting a single comment uses its native DOM id, not its list position.
        browser.moderationRules = ModerationRules(hiddenPosts: [siteURL + "|42": [103]])
        browser.applyModerationToPage()
        try await Task.sleep(for: .milliseconds(100))
        let individuallyHidden = await browser.visiblePosts()
        XCTAssertEqual(individuallyHidden.map(\.number), ids.filter { $0 != 103 })
        // Page and public-list IDs must also filter the sequential AI text.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let blocks = ids.enumerated().map { index, id in
            PostBlock(number: index + 2, author: "author", date: nil,
                      anchor: adapter.kind == .wordpress ? "comment-\(id)" : String(id), score: nil)
        }
        let opening = PostBlock(number: 1, author: "author", date: nil,
                                anchor: adapter.kind == .wordpress ? "" : "42", score: nil)
        let raw = RawTopicFormat.render([(opening, "Opening text")] + blocks.map { ($0, "Comment \($0.anchor)") })
        var session = TopicSession(siteURL: siteURL, topicID: "42", url: pageURL, title: "Fixture")
        session.source = raw
        session.openedByUserAt = Date()
        session.rawPages = [RawForumPage(page: 1, content: raw, blocks: [opening] + blocks)]
        var snapshot = AppSnapshot(sessions: [session])
        snapshot.ensureForum(siteURL, kind: adapter.kind)
        try store.save(snapshot)
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        XCTAssertEqual(app.postAnchor(2, topicKey: session.topicKey), blocks[0].anchor)
        app.settings.blockedPosts = [BlockedPost(siteURL: siteURL, topicID: "42", postNumber: 103)]
        let filtered = app.moderated(raw, siteURL: siteURL, topicID: "42")
        XCTAssertFalse(filtered.contains("Comment \(blocks[ids.firstIndex(of: 103)!].anchor)"))
        XCTAssertTrue(filtered.contains("Comment \(blocks[0].anchor)"))
        let sources = blocks.map { block in
            AgentSources.Source(number: block.number, title: "Fixture",
                url: adapter.links.postURL(topicURL: pageURL, number: block.number, anchor: block.anchor),
                topicID: "42", postNumber: nil, cited: true)
        }
        XCTAssertEqual(app.sourceItems(sources, siteURL: siteURL).count, 2)
        // Comment-search URLs carry the same IDs even before anchors are cached.
        let listing = ForumTopicListing(siteURL: siteURL, id: 42, title: "Fixture", slug: "", url: pageURL)
        let hits = sources.map { ForumSearchHit(topic: listing, postNumber: nil, username: "author", blurb: "Reply", url: $0.url) }
        let search = app.moderatedSiteQueryResult(SiteQueryResult(hits: hits), siteURL: siteURL)
        XCTAssertEqual(search.hits.map(\.url), sources.filter { $0.url.fragment != blocks[ids.firstIndex(of: 103)!].anchor }.map(\.url))
        // The report sheet records the page's native number without remapping it.
        app.settings.blockedPosts = []
        app.blockPost(103, topicID: "42", on: siteURL)
        XCTAssertEqual(app.settings.blockedPosts.map(\.postNumber), [103])
        XCTAssertEqual(app.moderated(raw, siteURL: siteURL, topicID: "42"), filtered)
        // The public moderation list uses exactly the same native IDs.
        app.settings.blockedPosts = []
        app.remoteModeration = RemoteModerationList(posts: [.init(site: siteURL, topic: 42, post: 103)])
        XCTAssertEqual(app.moderated(raw, siteURL: siteURL, topicID: "42"), filtered)
        app.remoteModeration = nil
        // An unrelated native ID must never hide a comment by list position.
        app.settings.blockedPosts = [BlockedPost(siteURL: siteURL, topicID: "42", postNumber: 2)]
        XCTAssertEqual(app.moderated(raw, siteURL: siteURL, topicID: "42"), raw)
        // The report sheet passes the native ID and hides the same DOM row.
        app.settings.blockedPosts = []
        app.blockPost(101, topicID: "42", on: siteURL)
        XCTAssertEqual(app.settings.blockedPosts.map(\.postNumber), [101])
        browser.moderationRules = app.moderationRules
        browser.applyModerationToPage()
        try await Task.sleep(for: .milliseconds(100))
        let citationHidden = await browser.visiblePosts()
        XCTAssertEqual(citationHidden.map(\.number), ids.filter { $0 != 101 })
        // Facts alone suffice when the raw-page anchors are not cached.
        let facts = TopicFacts(postsCount: blocks.count + 1, posts: [.init(id: 42, number: 1, username: "author")] + blocks.enumerated().map { index, block in
            .init(id: ids[index], number: block.number, username: block.author)
        })
        session.rawPages = []
        app.replaceSyncedData(sessions: [session.topicKey: session], agentRuns: [], watchedTopics: [], forums: app.forums)
        app.topicOverviews[session.topicKey] = ForumTopicOverview(siteURL: siteURL, topicID: "42",
            title: "Fixture", slug: "", url: pageURL, postCount: blocks.count + 1, facts: facts)
        XCTAssertEqual(app.postAnchor(2, topicKey: session.topicKey), blocks[0].anchor)
        XCTAssertEqual(app.postAnchor(1, topicKey: session.topicKey), adapter.kind == .wordpress ? nil : "42")
        let plan = BrowseNavigation.plan(adapter: adapter, siteURL: siteURL, topicID: "42", slug: nil,
            landing: .post(2), facts: facts, anchor: { app.postAnchor($0, topicKey: session.topicKey) })
        XCTAssertEqual(plan?.url.fragment, blocks[0].anchor)
        XCTAssertFalse(app.moderated(raw, siteURL: siteURL, topicID: "42").contains("Comment \(blocks[0].anchor)"))
        app.settings.blockedPosts = []
        app.blockPost(101, topicID: "42", on: siteURL)
        XCTAssertEqual(app.settings.blockedPosts.map(\.postNumber), [101])
        // A fresh fetch can be filtered before a session or overview is stored.
        app.replaceSyncedData(sessions: [:], agentRuns: [], watchedTopics: [], forums: app.forums)
        app.topicOverviews = [:]
        XCTAssertFalse(app.moderated(raw, siteURL: siteURL, topicID: "42", blocks: blocks)
            .contains("Comment \(blocks[0].anchor)"))
        // The opening post has its own stable identity and cannot collide
        // with the native ID of a comment.
        app.settings.blockedPosts = []
        app.blockPost(adapter.kind == .wordpress ? 0 : 42, topicID: "42", on: siteURL)
        let openingHidden = app.moderated(raw, siteURL: siteURL, topicID: "42", blocks: [opening] + blocks)
        XCTAssertFalse(openingHidden.contains("Opening text"))
        XCTAssertTrue(openingHidden.contains("Comment \(blocks[0].anchor)"))
        // Off-screen comments are not offered in the report sheet.
        _ = try await browser.webView.evaluateJavaScript("document.body.style.paddingTop = '2000px'; window.scrollTo(0, 0); true;")
        let offscreen = await browser.visiblePosts()
        XCTAssertTrue(offscreen.isEmpty)
    }
}

/// Independent review of the HN/WordPress page bridges. Markup is trimmed
/// verbatim from real pages (wp-themes.com Twenty Twenty-Four and Twenty Twenty
/// previews of "Hello world!", 2026-11-09); the nested reply follows WordPress
/// core `blocks/comment-template.php` (children as `<ol>` inside the `<li>`).
@MainActor
final class CommentBridgeReviewTests: XCTestCase {
    private static let tt4 = """
    <body class="wp-singular post-template-default single single-post postid-1 single-format-standard wp-embed-responsive wp-theme-twentytwentyfour">
    <ol class="wp-block-comment-template"><li id="comment-37977" class="comment even thread-even depth-1">
    <div class="wp-block-group is-layout-flow wp-block-group-is-layout-flow">
      <div class="wp-block-group is-nowrap is-layout-flex wp-block-group-is-layout-flex">
        <div class="wp-block-group is-layout-flow wp-block-group-is-layout-flow">
          <div class="wp-block-comment-author-name"><a rel="external nofollow ugc" href="https://wordpress.org/" target="_self" >A WordPress Commenter</a></div>
          <div class="wp-block-comment-date"><time datetime="2008-06-04T22:04:01+00:00"><a href="?p=1#comment-37977">June 4, 2008</a></time></div>
        </div>
      </div>
      <div class="wp-block-comment-content"><p>Hi, this is a comment.</p></div>
    </div>
    <ol><li id="comment-40000" class="comment odd alt depth-2">
    <div class="wp-block-group is-layout-flow wp-block-group-is-layout-flow">
      <div class="wp-block-comment-author-name"><a href="https://example.org/">Unrelated Replier</a></div>
      <div class="wp-block-comment-content"><p>An unrelated reply.</p></div>
    </div>
    </li></ol>
    </li><li id="comment-509" class="comment odd alt thread-odd thread-alt depth-1">
    <div class="wp-block-group is-layout-flow wp-block-group-is-layout-flow">
      <div class="wp-block-comment-author-name"><a rel="external nofollow ugc" href="http://josephscott.org/" target="_self" >Joseph Scott</a></div>
      <div class="wp-block-comment-content"><p>Need a comment with a real Gravatar.</p></div>
    </div>
    </li></ol></body>
    """

    private static let twentyTwenty = """
    <body class="post-template-default single single-post postid-1 single-format-standard wp-embed-responsive">
    <div class="comments-inner section-inner thin max-percentage">
    <div id="comment-37977" class="comment even thread-even depth-1">
      <article id="div-comment-37977" class="comment-body">
        <footer class="comment-meta"><div class="comment-author vcard"><a href="https://wordpress.org/" rel="external nofollow" class="url"><span class="fn">A WordPress Commenter</span><span class="screen-reader-text says">says:</span></a></div></footer>
        <div class="comment-content entry-content"><p>Hi, this is a comment.</p></div>
      </article>
    </div>
    <div id="comment-509" class="comment odd alt thread-odd thread-alt depth-1">
      <article id="div-comment-509" class="comment-body">
        <footer class="comment-meta"><div class="comment-author vcard"><a href="http://josephscott.org/" rel="external nofollow" class="url"><span class="fn">Joseph Scott</span><span class="screen-reader-text says">says:</span></a></div></footer>
        <div class="comment-content entry-content"><p>Need a comment with a real Gravatar.</p></div>
      </article>
    </div>
    </div></body>
    """

    // MARK: WordPress block theme (default theme family since WP 5.9)

    func testBlockThemeReportSheetShowsRealAuthorsAndText() async throws {
        let browser = try await load(WordPressAdapter(), url: "https://wp-themes.com/twentytwentyfour/?p=1", topicID: "1", html: Self.tt4)
        defer { teardown(browser) }
        let posts = await browser.visiblePosts()
        XCTAssertEqual(posts.map(\.number), [37977, 40000, 509])
        XCTAssertEqual(posts.map(\.username), ["A WordPress Commenter", "Unrelated Replier", "Joseph Scott"])
        XCTAssertEqual(posts.first?.excerpt.contains("Hi, this is a comment."), true)
    }

    func testBlockThemeBlockedUserIsHidden() async throws {
        let browser = try await load(WordPressAdapter(), url: "https://wp-themes.com/twentytwentyfour/?p=1", topicID: "1", html: Self.tt4)
        defer { teardown(browser) }
        try await apply(ModerationRules(blockedUsers: ["https://wp-themes.com": ["joseph scott"]]), to: browser)
        let visible = await browser.visiblePosts()
        XCTAssertEqual(visible.map(\.number), [37977, 40000])
    }

    func testBlockThemeFilteredWordIsHidden() async throws {
        let browser = try await load(WordPressAdapter(), url: "https://wp-themes.com/twentytwentyfour/?p=1", topicID: "1", html: Self.tt4)
        defer { teardown(browser) }
        try await apply(ModerationRules(filteredWords: ["gravatar"]), to: browser)
        let visible = await browser.visiblePosts()
        XCTAssertEqual(visible.map(\.number), [37977, 40000])
    }

    func testBlockThemeBlockingParentKeepsUnrelatedReply() async throws {
        let browser = try await load(WordPressAdapter(), url: "https://wp-themes.com/twentytwentyfour/?p=1", topicID: "1", html: Self.tt4)
        defer { teardown(browser) }
        try await apply(ModerationRules(hiddenPosts: ["https://wp-themes.com|1": [37977]]), to: browser)
        let visible = await browser.visiblePosts()
        XCTAssertEqual(visible.map(\.number), [40000, 509])
    }

    /// The report sheet offers "Block user" with the name it read: "anonymous".
    func testBlockThemeBlockingOfferedNameHidesOnlyThatAuthor() async throws {
        let browser = try await load(WordPressAdapter(), url: "https://wp-themes.com/twentytwentyfour/?p=1", topicID: "1", html: Self.tt4)
        defer { teardown(browser) }
        let offeredPosts = await browser.visiblePosts()
        let offered = try XCTUnwrap(offeredPosts.last?.username)
        try await apply(ModerationRules(blockedUsers: ["https://wp-themes.com": [offered.lowercased()]]), to: browser)
        let visible = await browser.visiblePosts()
        XCTAssertEqual(visible.map(\.number), [37977, 40000])
    }

    // MARK: Twenty Twenty (`'style' => 'div'`)

    func testTwentyTwentyCommentsAreListedAndHidden() async throws {
        let browser = try await load(WordPressAdapter(), url: "https://wp-themes.com/twentytwenty/?p=1", topicID: "1", html: Self.twentyTwenty)
        defer { teardown(browser) }
        let posts = await browser.visiblePosts()
        XCTAssertEqual(posts.map(\.number), [37977, 509])
        try await apply(ModerationRules(blockedUsers: ["https://wp-themes.com": ["joseph scott"]]), to: browser)
        let visible = await browser.visiblePosts()
        XCTAssertEqual(visible.map(\.number), [37977])
    }

    // MARK: Hacker News permalink pages

    /// HN item ids are global: comment 103 blocked while reading story 42 also
    /// appears on `item?id=101` (its parent's page).
    func testHackerNewsBlockedCommentStaysHiddenOnParentPermalinkPage() async throws {
        let html = """
        <table><tbody>
        <tr class="athing comtr" id="101"><td><a class="hnuser">alice</a><div class="commtext c00">Parent</div></td></tr>
        <tr class="athing comtr" id="103"><td><a class="hnuser">carol</a><div class="commtext c00">Blocked reply</div></td></tr>
        </tbody></table>
        """
        let browser = try await load(HackerNewsAdapter(), url: "https://news.ycombinator.com/item?id=101", topicID: "101", html: html)
        defer { teardown(browser) }
        try await apply(ModerationRules(hiddenPosts: ["https://news.ycombinator.com|42": [103]]), to: browser)
        let visible = await browser.visiblePosts()
        XCTAssertEqual(visible.map(\.number), [101])
    }

    // MARK: Cached blocks versus fresh facts

    /// HN numbers are preorder: a new reply shifts later comments. Callers that
    /// pass fresh facts (digest prefetch, voice brief, postText) still get the
    /// cached session's blocks, which win.
    func testFreshFactsAreNotOverriddenByStaleCachedBlocks() throws {
        let site = "https://news.ycombinator.com"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let url = URL(string: "\(site)/item?id=42")!
        let stale = [PostBlock(number: 1, author: "op", date: nil, anchor: "42", score: nil),
                     PostBlock(number: 2, author: "a", date: nil, anchor: "101", score: nil),
                     PostBlock(number: 3, author: "b", date: nil, anchor: "102", score: nil)]
        var session = TopicSession(siteURL: site, topicID: "42", url: url, title: "Story")
        session.source = "cached"
        session.openedByUserAt = Date()
        session.rawPages = [RawForumPage(page: 1, content: "cached", blocks: stale)]
        var snapshot = AppSnapshot(sessions: [session])
        snapshot.ensureForum(site, kind: .hackerNews)
        try store.save(snapshot)
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        app.settings.blockedPosts = [BlockedPost(siteURL: site, topicID: "42", postNumber: 101)]
        XCTAssertEqual(app.sessions[session.topicKey]?.rawPages.flatMap(\.blocks).map(\.anchor), ["42", "101", "102"])
        // Fresh: a new reply to the story arrived before 101, so 101 is now #3.
        let fresh = TopicFacts(postsCount: 3, posts: [.init(id: 42, number: 1, username: "op"),
                                                      .init(id: 102, number: 2, username: "b"),
                                                      .init(id: 101, number: 3, username: "a")])
        let rules = app.topicModerationRules(siteURL: site, topicID: "42", facts: fresh)
        XCTAssertEqual(rules.hiddenPosts["\(site)|42"], [3])
    }

    func testUnnamedCommentNeverOffersOrMatchesAnonymousFallback() async throws {
        let html = """
        <body class="postid-1"><ol>
        <li class="comment" id="comment-10"><div class="comment-content">No author</div>
          <ol><li class="comment" id="comment-11"><div class="comment-author"><b class="fn">alice</b></div>
          <div class="comment-content">Reply</div></li></ol>
        </li></ol></body>
        """
        let browser = try await load(WordPressAdapter(), url: "https://wp.example/?p=1", topicID: "1", html: html)
        defer { teardown(browser) }
        let posts = await browser.visiblePosts()
        XCTAssertFalse(posts.contains { $0.number == 10 })
        try await apply(ModerationRules(blockedUsers: ["https://wp.example": ["anonymous", "alice"]]), to: browser)
        let parentVisible = try await browser.webView.evaluateJavaScript("document.querySelector('#comment-10 > .comment-content').getBoundingClientRect().height > 0")
        XCTAssertEqual(parentVisible as? Bool, true)
    }

    func testCommentBridgesSkipIdleScansAndRestoreAfterRulesRemoved() async throws {
        for adapter: any SiteAdapter in [HackerNewsAdapter(), WordPressAdapter()] {
            let isHN = adapter.kind == .hackerNews
            let html = isHN
                ? "<table><tr class='athing comtr' id='10'><td><a class='hnuser'>alice</a><div class='commtext'>Body</div></td></tr></table>"
                : "<body class='postid-1'><div class='comment' id='comment-10'><div class='comment-author'><b class='fn'>alice</b></div><div class='comment-content'>Body</div></div></body>"
            let site = isHN ? "https://news.ycombinator.com" : "https://wp.example"
            let browser = try await load(adapter, url: site + (isHN ? "/item?id=1" : "/?p=1"), topicID: "1", html: html)
            defer { teardown(browser) }
            try await apply(ModerationRules(blockedUsers: [site: ["alice"]]), to: browser)
            let hidden = await browser.visiblePosts()
            XCTAssertTrue(hidden.isEmpty)
            try await apply(.none, to: browser)
            let restored = await browser.visiblePosts()
            XCTAssertEqual(restored.map(\.number), [10])
            _ = try await browser.webView.evaluateJavaScript("""
            window.reviewScans = 0;
            const originalQuery = document.querySelectorAll.bind(document);
            document.querySelectorAll = function(selector) { window.reviewScans++; return originalQuery(selector); };
            document.body.appendChild(document.createElement('div'));
            true;
            """)
            try await Task.sleep(for: .milliseconds(150))
            let scans = try await browser.webView.evaluateJavaScript("window.reviewScans")
            XCTAssertEqual(scans as? Int, 0)
            // Text-node edits do not trigger scans; inserted children do.
            try await apply(ModerationRules(filteredWords: ["unmatched"]), to: browser)
            _ = try await browser.webView.evaluateJavaScript("""
            window.reviewScans = 0;
            document.querySelector('.commtext, .comment-content').firstChild.data = 'Edited body';
            true;
            """)
            try await Task.sleep(for: .milliseconds(150))
            let textScans = try await browser.webView.evaluateJavaScript("window.reviewScans")
            XCTAssertEqual(textScans as? Int, 0)
            _ = try await browser.webView.evaluateJavaScript("document.body.appendChild(document.createElement('div')); true;")
            try await Task.sleep(for: .milliseconds(150))
            let childScans = try await browser.webView.evaluateJavaScript("window.reviewScans")
            XCTAssertGreaterThan(childScans as? Int ?? 0, 0)
        }
    }

    func testHackerNewsIdentityMapsSiteWideBlocksWithoutCrossSiteLeakage() {
        let site = "https://news.ycombinator.com"
        let rules = ModerationRules(hiddenPosts: [site + "|42": [103], "https://other.example|42": [101]])
        let mapped = HackerNewsAdapter().capabilities.postIdentity.aiRules(rules, siteURL: site, topicID: "101",
            blocks: [], facts: TopicFacts(postsCount: 2, posts: [.init(id: 101, number: 1, username: "a"), .init(id: 103, number: 2, username: "b")]))
        XCTAssertEqual(mapped.hiddenPosts[site + "|101"], [2])
    }

    // MARK: Round 2

    func testPartialFactsOverrideOnlyTheirListedPostNumbers() {
        let site = "https://wp.example"
        let rules = ModerationRules(hiddenPosts: [site + "|42": [101]])
        let blocks = [PostBlock(number: 2, author: "alice", date: nil, anchor: "comment-101", score: nil),
                      PostBlock(number: 3, author: "alice", date: nil, anchor: "comment-101", score: nil)]
        let facts = TopicFacts(postsCount: 3, posts: [.init(id: 102, number: 2, username: "bob")])
        let mapped = WordPressAdapter().capabilities.postIdentity.aiRules(rules, siteURL: site,
            topicID: "42", blocks: blocks, facts: facts)
        XCTAssertEqual(mapped.hiddenPosts[site + "|42"], [3])
    }

    /// Walker_Comment::start_lvl adds no wrapper for `'style' => 'div'`
    /// (Twenty Twenty): a reply's `<div id="comment-N">` is a direct child of
    /// its parent's row, after the parent's `<article>`.
    func testTwentyTwentyNestedReplyStaysVisibleWhenParentIsHidden() async throws {
        let html = """
        <body class="single postid-1"><div class="comments-inner">
        <div id="comment-37977" class="comment even thread-even depth-1 parent">
          <article id="div-comment-37977" class="comment-body">
            <footer class="comment-meta"><div class="comment-author vcard"><span class="fn">A WordPress Commenter</span></div></footer>
            <div class="comment-content entry-content"><p>Hi, this is a comment.</p></div>
          </article>
          <div id="comment-40000" class="comment odd alt depth-2">
            <article id="div-comment-40000" class="comment-body">
              <footer class="comment-meta"><div class="comment-author vcard"><span class="fn">Unrelated Replier</span></div></footer>
              <div class="comment-content entry-content"><p>An unrelated reply.</p></div>
            </article>
          </div>
        </div>
        </div></body>
        """
        let browser = try await load(WordPressAdapter(), url: "https://wp-themes.com/twentytwenty/?p=1", topicID: "1", html: html)
        defer { teardown(browser) }
        let all = await browser.visiblePosts()
        XCTAssertEqual(all.map(\.username), ["A WordPress Commenter", "Unrelated Replier"])
        try await apply(ModerationRules(hiddenPosts: ["https://wp-themes.com|1": [37977]]), to: browser)
        let byPost = await browser.visiblePosts()
        XCTAssertEqual(byPost.map(\.number), [40000])
        try await apply(ModerationRules(blockedUsers: ["https://wp-themes.com": ["a wordpress commenter"]]), to: browser)
        let byUser = await browser.visiblePosts()
        XCTAssertEqual(byUser.map(\.number), [40000])
    }

    /// Blocks for another site must not reach the HN page bridge.
    func testHackerNewsPageIgnoresOtherSitesBlocks() async throws {
        let html = """
        <table><tbody>
        <tr class="athing comtr" id="101"><td><a class="hnuser">alice</a><div class="commtext c00">Parent</div></td></tr>
        <tr class="athing comtr" id="103"><td><a class="hnuser">carol</a><div class="commtext c00">Reply</div></td></tr>
        </tbody></table>
        """
        let browser = try await load(HackerNewsAdapter(), url: "https://news.ycombinator.com/item?id=42", topicID: "42", html: html)
        defer { teardown(browser) }
        try await apply(ModerationRules(hiddenPosts: ["https://other.example|42": [103], "https://news.ycombinator.com.evil.example|42": [101]]), to: browser)
        let visible = await browser.visiblePosts()
        XCTAssertEqual(visible.map(\.number), [101, 103])
    }

    /// WordPress facts carry counts only (`WordPressAPI` builds `TopicFacts`
    /// without posts). The digest passes both the fetched blocks and those facts.
    func testWordPressFetchedBlocksStillFilterWhenFactsHaveNoPosts() throws {
        let site = "https://wp.example"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var snapshot = AppSnapshot()
        snapshot.ensureForum(site, kind: .wordpress)
        try store.save(snapshot)
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        let blocks = [PostBlock(number: 1, author: "author", date: nil, anchor: "", score: nil),
                      PostBlock(number: 2, author: "alice", date: nil, anchor: "comment-101", score: nil),
                      PostBlock(number: 3, author: "bob", date: nil, anchor: "comment-102", score: nil)]
        let raw = RawTopicFormat.render(zip(blocks, ["Opening text", "Blocked comment", "Kept comment"]).map { ($0, $1) })
        app.settings.blockedPosts = [BlockedPost(siteURL: site, topicID: "42", postNumber: 101)]
        let facts = TopicFacts(postsCount: 3, highestPostNumber: 3, openingPoster: "author")
        XCTAssertFalse(app.moderated(raw, siteURL: site, topicID: "42", blocks: blocks).contains("Blocked comment"))
        let digest = app.moderated(raw, siteURL: site, topicID: "42", blocks: blocks, facts: facts)
        XCTAssertFalse(digest.contains("Blocked comment"))
        XCTAssertTrue(digest.contains("Kept comment"))
    }

    // MARK: Helpers

    private var windows: [ObjectIdentifier: UIWindow] = [:]

    func testReportFallbackUsesCachedNativeIdentitiesExcerptsAndModeration() async throws {
        let site = "https://wp.example"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let topic = ForumTopic(siteURL: site, topicID: "42", url: URL(string: site + "/?p=42")!, title: "Post")
        let blocks = [PostBlock(number: 1, author: "editor", date: nil, anchor: "", score: nil),
                      PostBlock(number: 2, author: "Reader_Name", date: nil, anchor: "comment-101", score: nil)]
        var session = TopicSession(siteURL: site, topicID: "42", url: topic.url, title: topic.title)
        let content = RawTopicFormat.render(zip(blocks, ["Article", "Comment excerpt"]).map { ($0, $1) })
        session.rawPages = [RawForumPage(page: 1, content: content, blocks: blocks)]
        session.source = content
        session.openedByUserAt = Date()
        var snapshot = AppSnapshot(sessions: [session])
        snapshot.ensureForum(site, kind: .wordpress)
        try store.save(snapshot)
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        let posts = await app.reportablePosts(for: topic)
        XCTAssertEqual(posts, [VisiblePost(number: 101, username: "Reader_Name", excerpt: "Comment excerpt")])
        app.block("Reader_Name", on: site)
        let hidden = await app.reportablePosts(for: topic)
        XCTAssertTrue(hidden.isEmpty)
        XCTAssertFalse(app.moderated(content, siteURL: site, topicID: "42").contains("Comment excerpt"))
        app.unblock(try XCTUnwrap(app.settings.blockedUsers.first))
        app.topicOverviews[topic.topicKey] = ForumTopicOverview(siteURL: site, topicID: "42", title: "Post", slug: "", url: topic.url,
            postCount: 3, facts: TopicFacts(postsCount: 3, posts: [.init(id: 101, number: 2, username: "Reader Name"), .init(id: 102, number: 3, username: "Other")]))
        let withFacts = await app.reportablePosts(for: topic)
        XCTAssertEqual(withFacts.map(\.number), [101, 102])
        XCTAssertEqual(withFacts.first?.username, "Reader Name")
        XCTAssertEqual(withFacts.first?.excerpt, "Comment excerpt")
        var blank = AppSnapshot()
        blank.ensureForum(site, kind: .wordpress)
        try store.save(blank)
        let empty = AppModel(store: store)
        empty.topicOverviews[topic.topicKey] = app.topicOverviews[topic.topicKey]
        let factsOnly = await empty.reportablePosts(for: topic)
        XCTAssertEqual(factsOnly.map(\.number), [101, 102])
    }

    func testHackerNewsReportFallbackUsesItemIDsFromFacts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        let site = "https://news.ycombinator.com"
        let topic = ForumTopic(siteURL: site, topicID: "42", url: URL(string: site + "/item?id=42")!, title: "Story")
        app.topicOverviews[topic.topicKey] = ForumTopicOverview(siteURL: site, topicID: "42", title: "Story", slug: "", url: topic.url,
            postCount: 2, facts: TopicFacts(postsCount: 2, posts: [.init(id: 42, number: 1, username: "op"), .init(id: 103, number: 2, username: "reader")]))
        let posts = await app.reportablePosts(for: topic)
        XCTAssertEqual(posts.map(\.number), [42, 103])
        app.blockPost(103, topicID: "42", on: site)
        let hidden = await app.reportablePosts(for: topic)
        XCTAssertEqual(hidden.map(\.number), [42])
    }

    func testColdReportFallbackReadsOnlyOnePageAndOffersRESTCommentIDs() async throws {
        let fixture = WordPressFixtureSite(commentCount: 250)
        let site = WordPressFixtureSite.siteURL
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var snapshot = AppSnapshot()
        snapshot.ensureForum(site, kind: .wordpress)
        try store.save(snapshot)
        let app = AppModel(store: store, forumService: fixture.service())
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        let topic = ForumTopic(siteURL: site, topicID: "1001", url: URL(string: site + "/?p=1001")!, title: "Post")
        let posts = await app.reportablePosts(for: topic)
        XCTAssertEqual(posts.count, RawForumPage.size - 1)
        XCTAssertEqual(posts.first?.number, 5001)
        XCTAssertEqual(posts.first?.username, "user1")
        XCTAssertTrue(posts.first?.excerpt.contains("Comment number 1") == true)
        XCTAssertEqual(fixture.requests.filter { $0.path.hasSuffix("/comments") }.count, 1)
        app.blockPost(5001, topicID: "1001", on: site)
        let after = await app.reportablePosts(for: topic)
        XCTAssertFalse(after.contains { $0.number == 5001 })
        XCTAssertTrue(after.contains { $0.number == 5002 })
    }

    func testCachedAuthorTokenAlsoHidesThePageDisplayName() async throws {
        let browser = try await load(WordPressAdapter(), url: "https://wp.example/?p=1", topicID: "1", html: Self.tt4)
        defer { teardown(browser) }
        try await apply(ModerationRules(blockedUsers: ["https://wp.example": ["joseph_scott"]]), to: browser)
        let posts = await browser.visiblePosts()
        XCTAssertEqual(posts.map(\.number), [37977, 40000])
    }

    func testWPDiscuzInsertedAfterLoadIsModeratedAndRestored() async throws {
        let browser = try await load(WordPressAdapter(), url: "https://wp.example/?p=268566", topicID: "268566", html: "<body class='postid-268566'></body>")
        defer { teardown(browser) }
        try await apply(ModerationRules(blockedUsers: ["https://wp.example": ["rim"]]), to: browser)
        let html = try liveFixture("moderation-doc-live")
        let encoded = String(data: try JSONEncoder().encode(html), encoding: .utf8)!
        _ = try await browser.webView.evaluateJavaScript("document.body.innerHTML = \(encoded); true;")
        try await Task.sleep(for: .milliseconds(200))
        let posts = await browser.visiblePosts()
        XCTAssertEqual(posts.map(\.number), [2452127])
        try await apply(.none, to: browser)
        let restored = await browser.visiblePosts()
        XCTAssertEqual(restored.map(\.number), [2452119, 2452127])
    }

    func testPendingAnchorScrollOnStoryPageFlashesOnce() async throws {
        let url = HackerNewsLinks().postURL(topicURL: URL(string: "https://news.ycombinator.com/item?id=268566")!, number: 3, anchor: "50431178")
        let browser = try await load(HackerNewsAdapter(), url: url.absoluteString, topicID: "268566", html: liveFixture("moderation-hn-live"))
        defer { teardown(browser) }
        _ = try await browser.webView.evaluateJavaScript("""
        document.body.insertAdjacentHTML('afterbegin', '<div style=height:4000px></div>');
        document.body.insertAdjacentHTML('beforeend', '<div style=height:4000px></div>');
        window.scrollTo(0, 0);
        window.citationFlashes = 0;
        const target = document.getElementById('50431178').querySelector('.commtext');
        target.animate = () => { window.citationFlashes++; };
        true;
        """)
        let readyContext = browser.pageContext
        browser.setPageContext(PageContext(url: url, state: .maybe))
        browser.highlightAfterLoad([3], topicID: "268566", anchor: "50431178")
        browser.applyPendingHighlight()
        XCTAssertNotNil(browser.pendingHighlight, "Keep the landing anchor until the loaded page has been recognized")
        browser.setPageContext(readyContext)
        browser.applyPendingHighlight(afterLoad: true)
        browser.applyPendingHighlight(afterLoad: true)
        for _ in 0..<40 {
            if (try await browser.webView.evaluateJavaScript("window.citationFlashes") as? Int) == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let flashes = try await browser.webView.evaluateJavaScript("window.citationFlashes") as? Int
        let offset = try await browser.webView.evaluateJavaScript("window.scrollY") as? Double
        XCTAssertEqual(flashes, 1)
        XCTAssertGreaterThan(offset ?? 0, 0)
        XCTAssertNil(browser.pendingHighlight)
    }

    func testFirstPostScrollsToTopWithoutNavigation() async throws {
        for (adapter, url, html): (any SiteAdapter, String, String) in [
            (HackerNewsAdapter(), "https://news.ycombinator.com/item?id=268566",
             "<table><tr class='athing submission' id='268566'><td>Story</td></tr></table>"),
            (WordPressAdapter(), "https://wp.example/?p=268566", "<article><h1>Article</h1></article>")
        ] {
            let browser = try await load(adapter, url: url, topicID: "268566", html: html + "<div style='height:6000px'></div>")
            defer { teardown(browser) }
            _ = try await browser.webView.evaluateJavaScript("window.scrollTo(0, 2000); true;")
            let before = try await browser.webView.evaluateJavaScript("window.scrollY") as? Double
            XCTAssertGreaterThan(before ?? 0, 0)
            let destination = browser.webView.url
            let outcome = await browser.scrollToPost(1, anchor: adapter.kind == .hackerNews ? "268566" : "")
            XCTAssertEqual(outcome, .shown)
            var after: Double?
            for _ in 0..<40 {
                after = try await browser.webView.evaluateJavaScript("window.scrollY") as? Double
                if after == 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(after, 0)
            XCTAssertEqual(browser.webView.url, destination)
        }
    }

    func testUnrenderedCommentIsMissing() async throws {
        let browser = try await load(HackerNewsAdapter(), url: "https://news.ycombinator.com/item?id=268566", topicID: "268566", html: liveFixture("moderation-hn-live"))
        defer { teardown(browser) }
        _ = try await browser.webView.evaluateJavaScript("document.getElementById('50431178').style.display = 'none'; true;")
        let outcome = await browser.scrollToPost(3, anchor: "50431178")
        XCTAssertEqual(outcome, .missing)
    }

    private func liveFixture(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Fixtures/\(name).html"), encoding: .utf8)
    }

    func testLiveCommentMarkupOffersStableIDsAndAuthorsAndKeepsRepliesWhenBlocking() async throws {
        for (adapter, fixture, ids, names): (any SiteAdapter, String, [Int], [String]) in [
            (HackerNewsAdapter(), "moderation-hn-live", [50430766, 50431178], ["postalcoder", "wolttam"]),
            (WordPressAdapter(), "moderation-doc-live", [2452119, 2452127], ["Rim", "raj"]),
            (WordPressAdapter(), "moderation-fm-live", [2505565, 2505577], ["Grant", "Pierre"]),
            (WordPressAdapter(), "moderation-mtm-live", [1873623], ["Chuck"]),
            (WordPressAdapter(), "moderation-vftw-live", [6020534], ["Alec"]),
            (WordPressAdapter(), "moderation-9to5-live", [341940], ["jimw338"]),
            (WordPressAdapter(), "moderation-omaat-live", [5535629, 5535667, 5535668], ["Maryland", "panthers fan", "Maryland"])
        ] {
            let site = adapter.kind == .hackerNews ? "https://news.ycombinator.com" : "https://wp.example"
            let browser = try await load(adapter, url: site + (adapter.kind == .hackerNews ? "/item?id=268566" : "/?p=268566"), topicID: "268566", html: liveFixture(fixture))
            defer { teardown(browser) }
            let posts = await browser.visiblePosts()
            XCTAssertEqual(posts.map(\.number), ids, fixture)
            XCTAssertEqual(posts.map(\.username), names, fixture)
            XCTAssertTrue(posts.allSatisfy { !$0.excerpt.isEmpty }, fixture)
            let anchor = adapter.kind == .hackerNews ? String(ids[0]) : "comment-\(ids[0])"
            _ = try await browser.webView.evaluateJavaScript("document.body.insertAdjacentHTML('afterbegin', '<div data-spacer style=height:4000px></div>'); document.body.insertAdjacentHTML('beforeend', '<div data-spacer style=height:4000px></div>'); window.scrollTo(0, 0); true;")
            let jumped = await browser.scrollToPost(2, anchor: anchor)
            XCTAssertEqual(jumped, .shown, fixture)
            var offset = 0.0
            for _ in 0..<40 {
                offset = (try await browser.webView.evaluateJavaScript("window.scrollY") as? Double) ?? 0
                if offset > 0 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertGreaterThan(offset, 0, fixture)
            let visible = await browser.visiblePosts()
            XCTAssertTrue(visible.contains { $0.number == ids[0] }, fixture)
            XCTAssertFalse(browser.canTranslatePostsOnScreen)
            _ = try await browser.webView.evaluateJavaScript("document.querySelectorAll('[data-spacer]').forEach(e => e.remove()); window.scrollTo(0, 0); true;")
            if fixture == "moderation-9to5-live" {
                XCTAssertTrue(posts.first?.excerpt.contains("I found this description") == true)
            }
            try await apply(ModerationRules(blockedUsers: [site: [names[0].lowercased()]]), to: browser)
            let remaining = await browser.visiblePosts()
            XCTAssertEqual(remaining.map(\.number), zip(ids, names).filter { $0.1 != names[0] }.map { $0.0 }, fixture)
            try await apply(.none, to: browser)
            let restored = await browser.visiblePosts()
            XCTAssertEqual(restored.map(\.number), ids, fixture)
        }
    }

    private func load(_ adapter: any SiteAdapter, url: String, topicID: String, html: String) async throws -> ForumBrowserModel {
        let browser = ForumBrowserModel()
        browser.webView.navigationDelegate = nil
        browser.webView.configuration.userContentController.removeScriptMessageHandler(forName: "dcRouteChanged")
        let pageURL = try XCTUnwrap(URL(string: url))
        let siteURL = "\(pageURL.scheme!)://\(pageURL.host!)"
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        browser.webView.frame = host.view.bounds
        host.view.addSubview(browser.webView)
        windows[ObjectIdentifier(browser)] = window
        browser.webView.loadHTMLString(html, baseURL: pageURL)
        for _ in 0..<100 {
            if (try? await browser.webView.evaluateJavaScript("document.readyState === 'complete'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        // Let the first layout and the installers' first pass finish.
        try await Task.sleep(for: .milliseconds(500))
        browser.setPageContext(PageContext(url: pageURL, site: adapter.kind, siteURL: siteURL,
            topic: ForumTopic(siteURL: siteURL, topicID: topicID, url: pageURL, title: "Fixture"), state: .topic))
        return browser
    }

    private func apply(_ rules: ModerationRules, to browser: ForumBrowserModel) async throws {
        browser.moderationRules = rules
        browser.applyModerationToPage()
        try await Task.sleep(for: .milliseconds(150))
    }

    private func teardown(_ browser: ForumBrowserModel) {
        browser.webView.stopLoading()
        browser.webView.removeFromSuperview()
        if let window = windows.removeValue(forKey: ObjectIdentifier(browser)) {
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
        }
    }
}

// A comment with no author name must never be offered for blocking by name.
extension CommentBridgeReviewTests {
    func testFallbackOffersNoAnonymousFromCachedPages() async throws {
        let site = "https://wp.example"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let topic = ForumTopic(siteURL: site, topicID: "42", url: URL(string: site + "/?p=42")!, title: "Post")
            // What WordPressParsing.page writes for a comment with an empty author_name.
        let blocks = [PostBlock(number: 1, author: "editor", date: nil, anchor: "", score: nil),
                      PostBlock(number: 2, author: RawTopicFormat.authorToken(""), date: nil, anchor: "comment-101", score: nil),
                      PostBlock(number: 3, author: "named", date: nil, anchor: "comment-102", score: nil)]
        var session = TopicSession(siteURL: site, topicID: "42", url: topic.url, title: topic.title)
        let content = RawTopicFormat.render(zip(blocks, ["Article", "Nameless comment", "Named comment"]).map { ($0, $1) })
        session.rawPages = [RawForumPage(page: 1, content: content, blocks: blocks)]
        session.source = content
        session.openedByUserAt = Date()
        var snapshot = AppSnapshot(sessions: [session])
        snapshot.ensureForum(site, kind: .wordpress)
        try store.save(snapshot)
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        let posts = await app.reportablePosts(for: topic)
        XCTAssertFalse(posts.contains { $0.username.lowercased() == "anonymous" }, "offered: \(posts)")
    }

    func testColdFallbackOffersNoAnonymous() async throws {
        let fixture = WordPressFixtureSite(comments: [WordPressFixtureSite.comment(1, author: ""), WordPressFixtureSite.comment(2)])
        let site = WordPressFixtureSite.siteURL
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        var snapshot = AppSnapshot()
        snapshot.ensureForum(site, kind: .wordpress)
        try store.save(snapshot)
        let app = AppModel(store: store, forumService: fixture.service())
        app.usesDirectForumRequests = true
        app.browser.onPageContextChanged = nil
        let topic = ForumTopic(siteURL: site, topicID: "1001", url: URL(string: site + "/?p=1001")!, title: "Post")
        let posts = await app.reportablePosts(for: topic)
        XCTAssertEqual(posts.map(\.number), [5002], "offered: \(posts)")
    }
}
