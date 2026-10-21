import XCTest

/// The daily digest's Today page on sample data (`-dc-sample
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

        // Done closes the page.
        let done = app.buttons["todayDone"]
        XCTAssertTrue(waitForHittable(done))
        done.tap()
        XCTAssertTrue(waitForGone(watched, timeout: 5))
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

    /// The podcast on the sample digest with the fake engine
    /// (`-dc-podcast-fake`: fixed lines, a few seconds of silence per turn): Make
    /// and Play, then the mini player plays and moves between chapters. No
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

        // The mini player replaces Make / Play, with the chapter list:
        // intro, the two summarized cards (not the waiting one), outro.
        let mini = any(app, "podcastMiniPlayer")
        XCTAssertTrue(mini.waitForExistence(timeout: 10), "The mini player did not appear.")
        XCTAssertTrue(any(app, "podcastChapter-0").waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(any(app, "podcastChapter-3"), in: app))
        XCTAssertFalse(any(app, "podcastChapter-4").exists, "the waiting card has no chapter")
        XCTAssertTrue(any(app, "podcastChapterOpen-1").exists, "a topic chapter opens its topic")
        XCTAssertFalse(any(app, "podcastChapterOpen-0").exists, "the intro has no topic")

        // It plays (the pause button shows), and moves to the next chapter.
        XCTAssertTrue(reveal(mini, in: app))
        let toggle = app.buttons["podcastPlay"]
        XCTAssertTrue(wait(timeout: 15) { toggle.exists && toggle.label != "Play" } || !isEnglish(app), toggle.label)
        let status = any(app, "podcastStatus")
        let next = app.buttons["podcastNextChapter"]
        XCTAssertTrue(wait(timeout: 15) { next.isEnabled })
        let before = status.label
        next.tap()
        XCTAssertTrue(wait(timeout: 10) { status.label != before }, "Next chapter changed nothing: \(before)")
        XCTAssertTrue(app.buttons["todayDone"].exists)
    }

    private func isEnglish(_ app: XCUIApplication) -> Bool {
        Locale.preferredLanguages.first?.hasPrefix("en") ?? true
    }

    /// The forum switcher's All Forums.
    private func showForumsHome(in app: XCUIApplication) {
        let switcher = app.buttons["forumSwitcher"]
        if waitForHittable(switcher) {
            switcher.tap()
            let allForums = app.buttons["switcherAllForums"]
            if allForums.waitForExistence(timeout: 5) { allForums.tap() }
        }
    }

    /// From launch to the Today page, via the Forums home's Today row.
    @discardableResult
    private func openToday(in app: XCUIApplication) -> XCUIElement {
        let home = any(app, "forumsHome")
        // The sample opens on the Assistant; on a slow launch the home under
        // it isn't in the tree yet, so show the browser first then.
        if !home.waitForExistence(timeout: 10) { showBrowser(in: app) }
        if !home.waitForExistence(timeout: 10) { showForumsHome(in: app) }
        XCTAssertTrue(home.waitForExistence(timeout: 10), "The Forums home did not appear.")
        // `-dc-forums-home` re-shows the home 2 s after launch; a restored
        // forum that finishes loading later replaces it, so bring it back
        // from the forum switcher.
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        if !home.waitForExistence(timeout: 3) { showForumsHome(in: app) }
        XCTAssertTrue(home.waitForExistence(timeout: 10))

        // The sample opens on the Assistant in the single-pane layout.
        showBrowser(in: app)

        // The Today row sits at the top of the Forums home.
        let entry = any(app, "todayEntry")
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "The Forums home has no Today row.")
        // The web view under the Forums home stays in the accessibility tree
        // and can make the row read as not hittable; tap its center.
        if !waitForHittable(entry, timeout: 3) { attachTree(app) }
        entry.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        return entry
    }
}
