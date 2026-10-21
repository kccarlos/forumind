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

        let home = any(app, "forumsHome")
        XCTAssertTrue(home.waitForExistence(timeout: 20), "The Forums home did not appear.")
        // `-dc-forums-home` re-shows the home 2 s after launch; a restored
        // forum that finishes loading later replaces it, so bring it back
        // from the forum switcher.
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        if !home.waitForExistence(timeout: 3) {
            let switcher = app.buttons["forumSwitcher"]
            if waitForHittable(switcher) {
                switcher.tap()
                let allForums = app.buttons["switcherAllForums"]
                if allForums.waitForExistence(timeout: 5) { allForums.tap() }
            }
        }
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

    private func isEnglish(_ app: XCUIApplication) -> Bool {
        Locale.preferredLanguages.first?.hasPrefix("en") ?? true
    }
}
