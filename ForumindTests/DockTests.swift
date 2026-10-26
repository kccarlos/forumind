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
