import XCTest
@testable import Forumind

/// Which single layer sits at the bottom for each state (spec §8.1) and the
/// Dock's text.
final class DockTests: XCTestCase {
    private func layer(
        drawer: Bool = false,
        voice: Bool = false,
        answer: Bool = false,
        podcast: Bool = false,
        hint: DrawerHint.Row? = nil
    ) -> BottomLayer {
        BottomLayer.resolve(drawerOpen: drawer, voiceShowing: voice, answerReady: answer, podcastPlaying: podcast, hint: hint)
    }

    private let newReplies = DrawerHint.Row(action: .checkNew(12), isTip: false)

    func testBrowsingShowsTheBarAlone() {
        XCTAssertEqual(layer(), .bar)
    }

    func testVoiceReplacesTheBar() {
        XCTAssertEqual(layer(voice: true), .dock)
        XCTAssertEqual(layer(voice: true, answer: true, podcast: true), .dock)
    }

    func testAnOpenDrawerHidesEverythingElse() {
        XCTAssertEqual(layer(drawer: true, voice: true, answer: true, podcast: true), .drawer)
    }

    func testPodcastRowOnlyWhilePlayingWithTheDrawerClosed() {
        XCTAssertEqual(layer(podcast: true), .barWithPodcast)
        XCTAssertEqual(layer(drawer: true, podcast: true), .drawer)
    }

    func testAnswerReadyComesBeforeThePodcastRow() {
        XCTAssertEqual(layer(answer: true, podcast: true), .barWithAnswerReady)
    }

    /// voice Dock > Answer ready > podcast > hint > bar; the drawer above all.
    func testTheHintRowComesLast() {
        XCTAssertEqual(layer(hint: newReplies), .barWithHint(newReplies))
        XCTAssertEqual(layer(podcast: true, hint: newReplies), .barWithPodcast)
        XCTAssertEqual(layer(answer: true, hint: newReplies), .barWithAnswerReady)
        XCTAssertEqual(layer(voice: true, hint: newReplies), .dock)
        XCTAssertEqual(layer(drawer: true, hint: newReplies), .drawer)
    }

    /// The AI button's dot: new replies whose hint row another row outranks.
    func testTheNewRepliesDotOnlyWhenTheHintRowIsOutranked() {
        XCTAssertFalse(layer(hint: newReplies).showsNewRepliesDot(hint: newReplies), "The row says it.")
        XCTAssertTrue(layer(podcast: true, hint: newReplies).showsNewRepliesDot(hint: newReplies))
        XCTAssertTrue(layer(answer: true, hint: newReplies).showsNewRepliesDot(hint: newReplies))
        XCTAssertFalse(layer(drawer: true, hint: newReplies).showsNewRepliesDot(hint: newReplies), "No bar under the drawer.")
        XCTAssertFalse(layer(voice: true, hint: newReplies).showsNewRepliesDot(hint: newReplies), "No bar under the Dock.")
        let setUp = DrawerHint.Row(action: .setUpAI, isTip: false)
        XCTAssertFalse(layer(podcast: true, hint: setUp).showsNewRepliesDot(hint: setUp))
        XCTAssertFalse(layer(podcast: true).showsNewRepliesDot(hint: nil))
    }

    /// The cards' chip in the drawer's status row.
    func testTheCardsChipInTheDrawer() {
        var cursor = BrowseCursor()
        XCTAssertFalse(cursor.showsInDrawer)
        let items = (1...4).map { BrowseItem(kind: .source, siteURL: "https://forum.example", topicID: "7", postNumber: $0, title: "T") }
        cursor.replace(with: items, origin: .sources, current: 1)
        XCTAssertTrue(cursor.showsInDrawer)
        XCTAssertEqual(cursor.chipLabel, "4 sources · 2/4")
        cursor.cards = .collapsed
        XCTAssertTrue(cursor.showsInDrawer, "Collapsed over the page, still a chip in the drawer.")
        cursor.cards = .hidden
        XCTAssertFalse(cursor.showsInDrawer, "Dismissed: gone.")
        cursor.replace(with: items, origin: .search("x"))
        XCTAssertEqual(cursor.chipLabel, "4 results", "No card open yet: no position.")
    }

    func testClock() {
        XCTAssertEqual(DockText.clock(252), "4:12")
        XCTAssertEqual(DockText.clock(9.9), "0:09")
        XCTAssertEqual(DockText.clock(-3), "0:00")
    }

    func testMinutesLeftToday() {
        XCTAssertEqual(DockText.minutesLeft(limitMinutes: 30, usedSeconds: 252), 26)
        XCTAssertEqual(DockText.minutesLeft(limitMinutes: 30, usedSeconds: 30 * 60 + 5), 0)
        XCTAssertNil(DockText.minutesLeft(limitMinutes: 0, usedSeconds: 100))
    }

    func testSessionLineWithoutADailyLimitIsJustTheTime() {
        XCTAssertEqual(DockText.sessionLine(connected: 75, minutesLeft: nil), "1:15")
    }

    func testLevelsGoQuietWhenTheVoiceStops() {
        let levels = VoiceLevels()
        levels.setOutput(0.8, at: 100)
        XCTAssertEqual(levels.output(at: 100.1), 0.8, accuracy: 0.001)
        XCTAssertEqual(levels.output(at: 101), 0)
    }
}

/// One layout-aware "show the AI view" for every entry point, and Answer
/// ready on the finished record's run (audit A1, A2).
@MainActor
final class AIViewIntentTests: XCTestCase {
    private let site = "https://a.example.org"

    private func model(runs: [AgentRun] = [], records: [WorkRecord] = []) throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        // A run's forum is in the directory (its adapter picks the home to open).
        let forums = runs.isEmpty ? [] : [Forum(siteURL: site, kind: .discourse, name: "Example")]
        try store.save(AppSnapshot(activities: records, agentRuns: runs, forums: forums))
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        addTeardownBlock { @MainActor in app.browser.webView.stopLoading() }
        return app
    }

    private func onPage(_ app: AppModel) {
        app.browser.load(URL(string: "\(site)/t/topic/1")!)
        XCTAssertFalse(app.browser.showsForumsHome)
    }

    private func finished(_ run: AgentRun) -> WorkRecord {
        var record = WorkRecord(type: .agent, siteURL: run.siteURL, topicID: "agent:" + run.id.uuidString, title: run.goal,
                                url: URL(string: run.siteURL)!, provider: .ollama, model: "m")
        record.status = .completed
        record.completedAt = Date()
        return record
    }

    func testOnHomeNothingIsArmed() throws {
        let app = try model()
        XCTAssertTrue(app.browser.showsForumsHome)
        for split in [false, true] {
            app.router.splitLayout = split
            XCTAssertFalse(app.showAIView())
            XCTAssertFalse(app.router.wantsDrawer, "no drawer request left for later")
            XCTAssertEqual(app.router.splitPanelMode, .auto)
        }
    }

    func testDrawerLayoutOpensTheDrawerSplitLayoutShowsThePanel() throws {
        let app = try model()
        onPage(app)
        app.router.splitLayout = false
        XCTAssertTrue(app.showAIView())
        XCTAssertTrue(app.router.wantsDrawer)
        XCTAssertEqual(app.router.drawerDetent, .medium)
        app.toggleAIView()
        XCTAssertFalse(app.router.wantsDrawer, "the toggle closes it")

        app.router.splitLayout = true
        app.router.splitPanelMode = .hidden
        XCTAssertTrue(app.showAIView())
        XCTAssertEqual(app.router.splitPanelMode, .shown)
        XCTAssertFalse(app.router.wantsDrawer, "no drawer in the split layout")
        app.toggleAIView()
        XCTAssertEqual(app.router.splitPanelMode, .hidden)
    }

    func testAnswerReadySelectsTheFinishedRunAndMarksItSeen() throws {
        var selected = AgentRun(siteURL: site, goal: "Selected", provider: .ollama, model: "m")
        selected.result = .completed
        var voiceRun = AgentRun(siteURL: site, goal: "Asked by voice", provider: .ollama, model: "m", origin: .voice)
        voiceRun.result = .completed
        let record = finished(voiceRun)
        let app = try model(runs: [selected, voiceRun], records: [record])
        app.router.answersSeenAt = Date().addingTimeInterval(-60)
        app.selectedAgentRunID = selected.id
        app.router.splitLayout = true
        app.router.splitPanelMode = .hidden
        onPage(app)
        XCTAssertEqual(app.readyAnswer?.id, record.id)

        app.showAnswer(for: record)
        XCTAssertEqual(app.selectedAgentRunID, voiceRun.id)
        XCTAssertEqual(app.assistantMode, .agent)
        XCTAssertEqual(app.router.splitPanelMode, .shown)
        XCTAssertNil(app.readyAnswer, "seen once shown")
    }

    func testAnswerReadyWithoutAPageToShowItOnChangesNothing() throws {
        // A record whose run is gone, over Home: no forum to open.
        let orphan = finished(AgentRun(siteURL: site, goal: "Gone", provider: .ollama, model: "m"))
        let app = try model(records: [orphan])
        app.router.answersSeenAt = Date().addingTimeInterval(-60)
        app.router.splitLayout = false
        app.showAnswer(for: orphan)
        XCTAssertFalse(app.router.wantsDrawer)
        XCTAssertNotEqual(app.assistantMode, .agent)
        XCTAssertEqual(app.readyAnswer?.id, orphan.id, "not seen: it never showed")
    }

    func testAnswerReadyOverHomeOpensTheRunsForumFirst() throws {
        var run = AgentRun(siteURL: site, goal: "Q", provider: .ollama, model: "m")
        run.result = .completed
        let record = finished(run)
        let app = try model(runs: [run], records: [record])
        app.router.answersSeenAt = Date().addingTimeInterval(-60)
        app.router.splitLayout = false
        XCTAssertTrue(app.browser.showsForumsHome)
        app.showAnswer(for: record)
        XCTAssertFalse(app.browser.showsForumsHome, "the run's forum opened")
        XCTAssertTrue(app.router.wantsDrawer)
        XCTAssertEqual(app.selectedAgentRunID, run.id)
    }
}

/// History and Settings go where the layout puts them, and the AI view
/// reopens on the topic (audit A3).
@MainActor
final class PanelRouteTests: XCTestCase {
    private func model() throws -> AppModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        addTeardownBlock { @MainActor in app.browser.webView.stopLoading() }
        return app
    }

    func testSettingsAndHistoryAreSheetsOnHomeAndInTheDrawerLayout() throws {
        let app = try model()
        app.router.splitLayout = true
        app.openPanelRoute(.settings)
        XCTAssertEqual(app.router.item, .expanded(.settings), "on Home: a sheet")
        XCTAssertEqual(app.panelRoute, .topic)
        app.router.item = nil

        app.browser.load(URL(string: "https://a.example.org/t/x/1")!)
        app.router.splitLayout = false
        app.openPanelRoute(.history)
        XCTAssertEqual(app.router.item, .expanded(.history), "drawer layout: a sheet")
    }

    func testInTheSplitPanelAndBackToTheTopicOnceHidden() throws {
        let app = try model()
        app.browser.load(URL(string: "https://a.example.org/t/x/1")!)
        app.router.splitLayout = true
        app.router.splitPanelMode = .hidden
        app.openPanelRoute(.settings)
        XCTAssertEqual(app.router.item, .expanded(.settings), "Settings: a sheet in every layout")
        app.router.item = nil
        app.openPanelRoute(.history)
        XCTAssertNil(app.router.item)
        XCTAssertEqual(app.panelRoute, .history)
        XCTAssertTrue(app.isAIViewShown)

        app.toggleAIView()
        app.aiViewVisibilityChanged()
        XCTAssertEqual(app.panelRoute, .topic)
    }

    func testADrawerStillWantedKeepsItsRoute() throws {
        let app = try model()
        app.browser.load(URL(string: "https://a.example.org/t/x/1")!)
        app.router.splitLayout = false
        app.router.openDrawer()
        app.panelRoute = .history
        // Closed for a moment while a dropped presentation is tried again.
        app.aiViewVisibilityChanged()
        XCTAssertEqual(app.panelRoute, .history)
        app.router.closeDrawer()
        app.aiViewVisibilityChanged()
        XCTAssertEqual(app.panelRoute, .topic)
    }
}
