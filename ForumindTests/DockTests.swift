import XCTest
@testable import Forumind

/// Which single layer sits at the bottom for each state (spec §8.1) and the
/// Dock's text.
final class DockTests: XCTestCase {
    private func layer(
        drawer: Bool = false,
        voice: Bool = false,
        answer: Bool = false,
        podcast: Bool = false
    ) -> BottomLayer {
        BottomLayer.resolve(drawerOpen: drawer, voiceShowing: voice, answerReady: answer, podcastPlaying: podcast)
    }

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
