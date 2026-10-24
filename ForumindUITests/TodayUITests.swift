import XCTest

/// The daily digest's Today page (pushed over Home) on sample data (`-dc-sample
/// -dc-digest-sample`): no network, no AI key, nothing saved.
final class TodayUITests: DCUITestCase {
    func testTodayPageShowsTheDigestCardsAndTheirPostLinks() throws {
        // iPad: the side-by-side layout (landscape), as the other iPad tests.
        let app = launch(
            ["-dc-sample", "-dc-forums-home", "-dc-digest-sample"],
            orientation: isPhone ? .portrait : .landscapeLeft
        )

        let entry = openToday(in: app)

        // One card per topic: finished ones with their post-level links, the
        // waiting one with its progress state.
        let watched = any(app, "digestCard-404728")
        XCTAssertTrue(watched.waitForExistence(timeout: 10), "The Today page did not show the watched topic's card.")
        XCTAssertTrue(any(app, "digestLink-first-404728").exists, "A watched topic links to its first new reply.")
        XCTAssertTrue(any(app, "digestLink-top-404728").exists)
        let solved = any(app, "digestCard-18342")
        XCTAssertTrue(reveal(solved, in: app))
        XCTAssertTrue(any(app, "digestLink-solution-18342").exists, "A solved topic links to its accepted answer.")
        XCTAssertFalse(any(app, "digestLink-first-18342").exists, "A trending topic has no new-reply link.")
        let waiting = any(app, "digestCard-18391")
        XCTAssertTrue(reveal(waiting, in: app))
        XCTAssertTrue(app.staticTexts["Waiting to be summarized"].exists || !isEnglish(app))

        // Back returns to Home.
        let back = app.navigationBars["Today"].buttons.element(boundBy: 0)
        XCTAssertTrue(waitForHittable(back))
        back.tap()
        XCTAssertTrue(waitForGone(watched, timeout: 5))
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

    /// The podcast on the sample digest with the fake engine
    /// (`-dc-podcast-fake`: fixed lines, a few seconds of silence per turn): Make
    /// and Play, then Now Playing plays, pauses and moves between chapters. No
    /// network, no AI key, no TTS.
    func testTodayPageMakesAndPlaysThePodcast() throws {
        let app = launch(
            ["-dc-sample", "-dc-forums-home", "-dc-digest-sample", "-dc-podcast-fake"],
            orientation: isPhone ? .portrait : .landscapeLeft
        )
        openToday(in: app)

        let start = any(app, "podcastStart")
        XCTAssertTrue(start.waitForExistence(timeout: 10), "The Today page has no podcast section.")
        XCTAssertTrue(app.buttons["makePodcast"].exists, "Make Podcast is offered.")
        let play = app.buttons["podcastPlay"]
        XCTAssertTrue(waitForHittable(play))
        play.tap()

        // The Now Playing row replaces Make / Play; it opens the player.
        let row = app.buttons["podcastNowPlayingRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The Now Playing row did not appear.")
        XCTAssertFalse(any(app, "podcastMiniPlayer").exists, "no second player on the Today page")
        row.tap()
        XCTAssertTrue(any(app, "nowPlaying").waitForExistence(timeout: 10), "Now Playing did not open.")

        // The chapter list: intro, the two summarized cards (not the waiting one), outro.
        XCTAssertTrue(any(app, "podcastChapter-0").waitForExistence(timeout: 5) || reveal(any(app, "podcastChapter-0"), in: app))
        XCTAssertTrue(reveal(any(app, "podcastChapter-3"), in: app))
        XCTAssertFalse(any(app, "podcastChapter-4").exists, "the waiting card has no chapter")
        XCTAssertTrue(any(app, "podcastChapterOpen-1").exists, "a topic chapter opens its topic")
        XCTAssertFalse(any(app, "podcastChapterOpen-0").exists, "the intro has no topic")

        // It plays (the pause button shows), pauses and plays again, and moves to the next chapter.
        let toggle = app.buttons["podcastPlay"]
        XCTAssertTrue(wait(timeout: 15) { toggle.exists && toggle.label == "Pause" } || !isEnglish(app), toggle.label)
        if isEnglish(app) {
            toggle.tap()
            XCTAssertTrue(wait(timeout: 5) { toggle.label == "Play" }, "Pause did not pause: \(toggle.label)")
            toggle.tap()
            XCTAssertTrue(wait(timeout: 5) { toggle.label == "Pause" }, "Play did not play: \(toggle.label)")
        }
        let status = any(app, "podcastStatus")
        let next = app.buttons["podcastNextChapter"]
        XCTAssertTrue(wait(timeout: 15) { next.isEnabled })
        let before = status.label
        next.tap()
        XCTAssertTrue(wait(timeout: 10) { status.label != before }, "Next chapter changed nothing: \(before)")

        // Close; leaving the page, the podcast goes on in a row above the
        // bar, which opens Now Playing again.
        app.buttons["nowPlayingClose"].tap()
        XCTAssertTrue(waitForGone(any(app, "nowPlaying"), timeout: 10))
        let back = app.navigationBars["Today"].buttons.element(boundBy: 0)
        XCTAssertTrue(waitForHittable(back))
        back.tap()
        if isPhone {
            let dock = any(app, "dockPodcastRow")
            XCTAssertTrue(dock.waitForExistence(timeout: 10), "No podcast row while it plays.")
            XCTAssertTrue(app.buttons["dockPodcastToggle"].exists)
            app.buttons["dockPodcastOpen"].tap()
            XCTAssertTrue(any(app, "nowPlaying").waitForExistence(timeout: 10), "The mini row did not open Now Playing.")
        }
    }

    private func isEnglish(_ app: XCUIApplication) -> Bool {
        Locale.preferredLanguages.first?.hasPrefix("en") ?? true
    }

    /// From launch to the Today page, via Home's Today module.
    @discardableResult
    private func openToday(in app: XCUIApplication) -> XCUIElement {
        openHome(in: app)
        let entry = app.buttons["homeTodayOpen"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "Home has no Today module.")
        if !waitForHittable(entry, timeout: 3) { attachTree(app) }
        entry.tap()
        XCTAssertTrue(any(app, "todayPage").waitForExistence(timeout: 10), "The Today page was not pushed.")
        return entry
    }
}
