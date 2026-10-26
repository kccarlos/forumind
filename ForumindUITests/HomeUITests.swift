import XCTest

/// Home (spec §7.1): the sections in order, the Today page pushed over it,
/// forum tiles, pinning a suggestion, Add forum, and Home with no forums.
final class HomeUITests: DCUITestCase {
    /// On the sample with no forums (nothing is saved): pin a suggestion,
    /// find it under Forums and in the switcher, then unpin it from the
    /// tile's menu.
    func testPinningASuggestedForumShowsItInTheSwitcherAndUnpinning() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-no-forums"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        let home = openHome(in: app)

        let pinButton = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinSuggested-'")).firstMatch
        XCTAssertTrue(reveal(pinButton, in: app), "No suggested forum to pin.")
        let host = String(pinButton.identifier.dropFirst("pinSuggested-".count))
        pinButton.tap()

        // Pinned: it leaves the suggestions and appears as a pinned tile.
        XCTAssertTrue(waitForGone(app.buttons["pinSuggested-\(host)"], timeout: 5))
        let tile = app.buttons["pinnedForum-\(host)"]
        for _ in 0..<6 where !tile.exists { app.swipeDown() }
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "\(host) did not appear under Forums.")

        // The forum menu's first item goes back to Home.
        openForumMenu(in: app)
        let homeItem = app.buttons["Home"]
        XCTAssertTrue(homeItem.exists)
        // Home closes the menu and keeps Home.
        homeItem.tap()
        XCTAssertTrue(waitForGone(homeItem, timeout: 5))
        XCTAssertTrue(home.waitForExistence(timeout: 5))

        // Unpin from the tile's menu: the tile goes, the suggestion is back.
        XCTAssertTrue(waitForHittable(tile))
        tile.press(forDuration: 1.0)
        let unpin = app.buttons["Unpin"]
        XCTAssertTrue(unpin.waitForExistence(timeout: 5), "The tile has no Unpin.")
        unpin.tap()
        XCTAssertTrue(waitForGone(tile, timeout: 5), "\(host) is still pinned.")
    }

    func testAddForumSheetOpensFromHome() throws {
        let app = launch(["-dc-forums-home"])

        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 20))
        // (iPad: in front of the assistant pane.)
        openHome(in: app)
        // Under the pinned tiles, in the Forums section; with no forums
        // (a fresh simulator) the Start with a forum card's button.
        let first = app.buttons["homeAddFirstForum"]
        let add = first.waitForExistence(timeout: 3) ? first : app.buttons["homeAddForum"]
        if !reveal(add, in: app) { attachTree(app) }
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Forum"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "addForumAddress").exists)
        // Nothing typed yet: Add is disabled.
        XCTAssertFalse(app.buttons["addForumConfirm"].isEnabled)
        app.navigationBars["Add Forum"].buttons["Cancel"].tap()
        XCTAssertTrue(waitForGone(app.navigationBars["Add Forum"], timeout: 5))
    }

    /// Today module, Continue reading, the pinned forums, Recent: top to
    /// bottom (the sample: a digest being made, saved topics, three pinned
    /// forums and recents).
    func testHomeSectionsComeInTheFixedOrder() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-digest-sample"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        openHome(in: app)

        let today = any(app, "homeToday")
        let continueRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continueReading-'")).firstMatch
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinnedForum-'")).firstMatch
        XCTAssertTrue(waitOrDump(today, timeout: 10, in: app), "No Today module.")
        XCTAssertTrue(continueRow.waitForExistence(timeout: 5), "No Continue reading.")
        XCTAssertTrue(tile.waitForExistence(timeout: 5), "No pinned forum tiles.")
        XCTAssertLessThan(today.frame.minY, continueRow.frame.minY)
        XCTAssertLessThan(continueRow.frame.minY, tile.frame.minY)
        XCTAssertLessThanOrEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continueReading-'")).count, 3)
        XCTAssertTrue(app.buttons["homeHistory"].exists)
        XCTAssertTrue(app.buttons["homeSettings"].exists)

        let recent = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'recentForum-'")).firstMatch
        XCTAssertTrue(reveal(recent, in: app), "No Recent forums.")
        XCTAssertLessThan(tile.frame.minY, recent.frame.minY)
        // Three forums or more: no suggestions.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinSuggested-'")).firstMatch.exists)
    }

    /// The Today page is pushed over Home and Back returns to it.
    func testTodayPageIsPushedAndGoesBack() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-digest-sample"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        let home = openHome(in: app)
        let open = app.buttons["homeTodayOpen"]
        XCTAssertTrue(waitForHittable(open))
        open.tap()

        let page = any(app, "todayPage")
        XCTAssertTrue(page.waitForExistence(timeout: 10), "The Today page was not pushed.")
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["todayMenu"].exists)
        app.navigationBars["Today"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitForGone(page, timeout: 5))
        XCTAssertTrue(home.waitForExistence(timeout: 5))
    }

    /// A pinned forum's tile opens the forum (Home goes).
    func testForumTileOpensTheForum() throws {
        let app = launch(["-dc-sample", "-dc-forums-home"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        let home = openHome(in: app)
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinnedForum-'")).firstMatch
        XCTAssertTrue(reveal(tile, in: app))
        tile.tap()
        XCTAssertTrue(waitForGone(home, timeout: 10), "The tile did not open its forum.")
    }

    /// No forums yet: Start with a forum, suggestions, the share card.
    func testHomeWithNoForumsShowsSuggestions() throws {
        let app = launch(["-dc-sample", "-dc-forums-home", "-dc-no-forums"],
                         orientation: isPhone ? .portrait : .landscapeLeft)
        openHome(in: app)
        XCTAssertTrue(app.buttons["homeAddFirstForum"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinSuggested-'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(reveal(any(app, "homeShareHowTo"), in: app))
        XCTAssertFalse(any(app, "homeToday").exists, "no Today module without forums")
    }
}
