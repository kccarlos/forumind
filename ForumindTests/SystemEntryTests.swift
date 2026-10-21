import XCTest
@testable import Forumind

/// App Intents and Siri suggestions: each intent's perform hands the right
/// action to the app (through a fake router), actions that arrive during
/// launch wait for the UI, the forum entity's query lists pinned forums
/// first, the AppModel carries each action out (summarize, ask, Today,
/// podcast, voice), and topics are donated only while the switch is on.
@MainActor
final class SystemEntryTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let topicURL = URL(string: "https://forum.example.com/t/topic/42")!

    override func setUp() async throws {
        SystemEntry.reset()
        SystemEntry.clipboard = { nil }
        SystemEntry.storedForums = { [] }
        SystemEntry.storedTopics = { [] }
    }

    override func tearDown() async throws {
        SystemEntry.reset()
    }

    // MARK: Intents

    func testSummarizeLinkUsesTheLinkOrTheClipboard() async throws {
        let router = FakeSystemRouter()
        SystemEntry.attach(router)

        _ = try await SummarizeLinkIntent(url: topicURL).perform()
        XCTAssertEqual(router.actions, [.summarize(topicURL)])

        SystemEntry.clipboard = { "Look at this\nhttps://forum.example.com/t/other/7 thanks" }
        _ = try await SummarizeLinkIntent(url: nil).perform()
        XCTAssertEqual(router.actions.last, .summarize(URL(string: "https://forum.example.com/t/other/7")!))

        SystemEntry.clipboard = { "no link here" }
        do {
            _ = try await SummarizeLinkIntent(url: nil).perform()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SystemEntryError, .noLink)
        }
        XCTAssertThrowsError(try SystemEntry.summaryLink(URL(string: "mailto:someone@example.com")))
        XCTAssertEqual(router.actions.count, 2)
    }

    func testAskForumNeedsAQuestionAndNamesTheForum() async throws {
        let router = FakeSystemRouter()
        SystemEntry.attach(router)
        let forum = ForumEntity(id: site, name: "Example", host: "forum.example.com")

        _ = try await AskForumIntent(forum: forum, question: "  Did anyone fix the layer shifts?  ").perform()
        XCTAssertEqual(router.actions, [.ask(siteURL: site, question: "Did anyone fix the layer shifts?")])

        do {
            _ = try await AskForumIntent(forum: forum, question: "   ").perform()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SystemEntryError, .emptyQuestion)
        }
    }

    func testTheOtherIntentsSendTheirActions() async throws {
        let router = FakeSystemRouter()
        SystemEntry.attach(router)
        _ = try await OpenTodayIntent().perform()
        _ = try await PlayPodcastIntent().perform()
        _ = try await StartVoiceChatIntent().perform()
        _ = try await OpenTopicIntent(target: TopicEntity(id: "forum.example.com/t/3", title: "T", forumName: "F")).perform()
        XCTAssertEqual(router.actions, [.openToday, .playToday, .startVoice, .openTopic(topicKey: "forum.example.com/t/3")])
    }

    func testActionsBeforeTheUIIsUpWaitForIt() async throws {
        _ = try await OpenTodayIntent().perform()
        _ = try await StartVoiceChatIntent().perform()
        XCTAssertEqual(SystemEntry.pending, [.openToday, .startVoice])

        let router = FakeSystemRouter()
        SystemEntry.attach(router)
        XCTAssertEqual(router.actions, [.openToday, .startVoice])
        XCTAssertEqual(SystemEntry.pending, [])
    }

    func testIntentsOpenTheApp() {
        XCTAssertTrue(SummarizeLinkIntent.openAppWhenRun)
        XCTAssertTrue(AskForumIntent.openAppWhenRun)
        XCTAssertTrue(OpenTodayIntent.openAppWhenRun)
        XCTAssertTrue(PlayPodcastIntent.openAppWhenRun)
        XCTAssertTrue(StartVoiceChatIntent.openAppWhenRun)
        XCTAssertEqual(ForumindShortcuts.appShortcuts.count, 5)
    }

    // MARK: Forum entity

    func testForumQueryListsPinnedForumsFirstAndMatchesNames() async throws {
        let router = FakeSystemRouter()
        router.forums = [
            Forum(siteURL: "https://recent.example.com", name: "Recent Café", lastVisitedAt: Date(timeIntervalSince1970: 50)),
            Forum(siteURL: "https://second.example.com", name: "Second", isPinned: true, pinOrder: 1),
            Forum(siteURL: "https://first.example.com", name: "First", isPinned: true, pinOrder: 0),
            Forum(siteURL: "https://newer.example.com", name: "Newer", lastVisitedAt: Date(timeIntervalSince1970: 90))
        ]
        SystemEntry.attach(router)
        let query = ForumEntityQuery()

        let suggested = try await query.suggestedEntities()
        XCTAssertEqual(suggested.map(\.name), ["First", "Second", "Newer", "Recent Café"])
        XCTAssertEqual(suggested.first?.host, "first.example.com")

        let matched = try await query.entities(matching: "cafe")
        XCTAssertEqual(matched.map(\.id), ["https://recent.example.com"], "accents and case are ignored")
        let byHost = try await query.entities(matching: "second.example")
        XCTAssertEqual(byHost.map(\.name), ["Second"])

        let found = try await query.entities(for: ["https://second.example.com", "https://gone.example.com"])
        XCTAssertEqual(found.map(\.name), ["Second"])
    }

    func testWithoutTheAppTheQueryReadsTheSavedForums() async throws {
        SystemEntry.storedForums = { [Forum(siteURL: "https://stored.example.com", name: "Stored", isPinned: true)] }
        let suggested = try await ForumEntityQuery().suggestedEntities()
        XCTAssertEqual(suggested.map(\.name), ["Stored"])
    }

    func testTheStoredSnapshotIsReadWithoutTheApp() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("state.json")
        var session = TopicSession(siteURL: site, topicID: "5", url: URL(string: "\(site)/t/five/5")!, title: "Five")
        session.rawPages = [RawForumPage(page: 1, content: "long text")]
        try PersistentStore(fileURL: fileURL).save(AppSnapshot(
            sessions: [session],
            forums: [
                Forum(siteURL: "https://recent.example.com", name: "Recent", lastVisitedAt: Date()),
                Forum(siteURL: site, name: "Pinned", isPinned: true)
            ]
        ))
        StoredSnapshot.fileURLOverride = fileURL
        defer { StoredSnapshot.fileURLOverride = nil }
        SystemEntry.storedForums = { StoredSnapshot.forums() }

        XCTAssertEqual(SystemEntry.forumChoices().map(\.name), ["Pinned", "Recent"])
        XCTAssertEqual(StoredSnapshot.topics().map { "\($0.id)|\($0.title)|\($0.forumName)" }, ["forum.example.com/t/5|Five|Pinned"])
    }

    // MARK: The app carries them out

    func testSummarizeOpensTheTopicAndSummarizesItOnceReady() throws {
        let app = makeApp(ready: true)
        app.perform(.summarize(topicURL))
        deliverTopicPage(to: app)
        XCTAssertTrue(app.presentAssistant)
        XCTAssertEqual(app.assistantMode, .summary)
        XCTAssertTrue(app.activities.contains { $0.type == .summary && $0.topicKey == "forum.example.com/t/42" })
        for record in app.activities where !record.status.isTerminal { app.cancel(record: record) }
    }

    func testBeforeTheTermsAreAcceptedNothingIsSpent() throws {
        let app = makeApp(ready: true)
        app.settings.acceptedTermsVersion = 0
        app.perform(.summarize(topicURL))
        deliverTopicPage(to: app)
        XCTAssertTrue(app.presentAssistant)
        XCTAssertFalse(app.activities.contains { $0.type == .summary })

        app.perform(.ask(siteURL: site, question: "Why?"))
        XCTAssertTrue(app.agentRuns.isEmpty)
        XCTAssertEqual(app.agentGoalDraft, "Why?")
    }

    func testAskStartsAskTheForumOnThatForum() throws {
        let app = makeApp(ready: true)
        app.perform(.ask(siteURL: site, question: "Did anyone fix it?"))
        XCTAssertEqual(app.assistantMode, .agent)
        XCTAssertTrue(app.presentAssistant)
        XCTAssertEqual(app.agentSiteURL, site)
        let run = try XCTUnwrap(app.agentRuns.first)
        XCTAssertEqual(run.goal, "Did anyone fix it?")
        XCTAssertEqual(run.siteURL, site)
        app.cancelAgentRun(id: run.id)
    }

    func testAskWithoutAModelKeepsTheQuestionAndAsksForSetup() {
        let app = makeApp(ready: false)
        app.perform(.ask(siteURL: site, question: "Did anyone fix it?"))
        XCTAssertTrue(app.agentRuns.isEmpty)
        XCTAssertEqual(app.agentGoalDraft, "Did anyone fix it?")
        XCTAssertEqual(app.needsProviderSetup, .agent)
    }

    func testTodayAndThePodcastWithoutAnEpisodeOpenTheTodayPage() {
        let app = makeApp(ready: true)
        app.perform(.openToday)
        XCTAssertTrue(app.showsTodayPage)
        app.showsTodayPage = false
        app.perform(.playToday)
        XCTAssertTrue(app.showsTodayPage, "no episode: Today")
        XCTAssertNil(app.podcast.player.playlist)
    }

    func testVoiceWithoutAKeyOpensVoiceSettings() {
        let app = makeApp(ready: true)
        app.perform(.startVoice)
        XCTAssertEqual(app.requestedSettingsPage, .voice)
        XCTAssertFalse(app.voice.isActive)
    }

    func testVoiceWithAKeyAsksForConsentFirst() {
        let app = makeApp(ready: true)
        var gemini = app.settings.configuration(for: VoiceProvider.aiStudio.keyProvider)
        gemini.apiKey = "test-key"
        app.settings.setConfiguration(gemini, for: VoiceProvider.aiStudio.keyProvider)
        app.settings.voiceConsent = [:]
        app.perform(.startVoice)
        XCTAssertEqual(app.voice.consentProvider, .aiStudio, "the consent gate, before any audio")
        XCTAssertNil(app.requestedSettingsPage)
        XCTAssertFalse(app.voice.isActive)
    }

    // MARK: Siri suggestions

    func testTopicsAreDonatedOncePerVisitAndOnlyWithTheSwitchOn() {
        let donor = FakeTopicActivityDonor()
        let app = makeApp(ready: true, donor: donor)
        let topic = ForumTopic(siteURL: site, topicID: "42", url: topicURL, title: "Topic")

        app.select(topic: topic)
        app.select(topic: topic)
        XCTAssertEqual(donor.donated, ["forum.example.com/t/42"])
        app.select(topic: nil)
        XCTAssertEqual(donor.resignCount, 1)

        app.settings.donatesTopicActivity = false
        XCTAssertEqual(donor.deleteAllCount, 1, "off: every donation is forgotten")
        app.select(topic: topic)
        XCTAssertEqual(donor.donated.count, 1)

        app.settings.donatesTopicActivity = true
        XCTAssertEqual(donor.donated.count, 2, "on again: the open topic is offered")
    }

    // MARK: Helpers

    private func makeApp(ready: Bool, donor: FakeTopicActivityDonor? = nil) -> AppModel {
        let app = AppModel(
            store: PersistentStore(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent("state.json")
            ),
            spotlightIndex: FakeSpotlightIndex(),
            topicActivityDonor: donor ?? FakeTopicActivityDonor()
        )
        app.usesDirectForumRequests = true
        app.settings.hasCompletedOnboarding = true
        app.settings.acceptedTermsVersion = ModerationTerms.currentVersion
        if ready {
            app.selectModel(ModelSelection(provider: .ollama, model: "llama3.2"), for: .both)
        }
        return app
    }

    private func deliverTopicPage(to app: AppModel) {
        let topic = ForumTopic(siteURL: site, topicID: "42", url: topicURL, title: "Topic")
        app.browser.onPageContextChanged?(
            PageContext(url: topicURL, isDiscourse: true, siteURL: site, forumName: "Example", topic: topic, state: .topic)
        )
    }
}

@MainActor
final class FakeSystemRouter: SystemEntryRouting {
    var forums: [Forum] = []
    var topicEntities: [TopicEntity] = []
    private(set) var actions: [SystemEntryAction] = []

    func perform(_ action: SystemEntryAction) { actions.append(action) }
}
