import XCTest

/// Forums home: suggested forums, pinning, and the forum switcher.
final class ForumsHomeUITests: DCUITestCase {
    func testPinningASuggestedForumShowsItInTheSwitcher() throws {
        let app = launch(["-dc-forums-home"])

        let home = any(app, "forumsHome")
        XCTAssertTrue(home.waitForExistence(timeout: 20), "The Forums home did not appear.")
        // `-dc-forums-home` re-shows the home 2 s after a restored forum starts loading.
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        XCTAssertTrue(home.waitForExistence(timeout: 10))

        // The first suggestion not added yet (earlier runs may have added some).
        let pinButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pinSuggested-'"))
        let pinButton = pinButtons.firstMatch
        guard reveal(pinButton, in: app) else {
            attachTree(app)
            throw XCTSkip("Every suggested forum is already in the directory; nothing to pin.")
        }
        let host = String(pinButton.identifier.dropFirst("pinSuggested-".count))
        let forumName = String(pinButton.label.dropFirst("Pin ".count))
        pinButton.tap()

        // Pinned: it leaves the suggestions and appears as a pinned tile.
        XCTAssertTrue(waitForGone(app.buttons["pinSuggested-\(host)"], timeout: 5))
        let tile = any(app, "pinnedForum-\(host)")
        for _ in 0..<6 where !tile.exists { app.swipeDown() }
        XCTAssertTrue(tile.waitForExistence(timeout: 10), "\(host) did not appear under Pinned.")

        // The browser bar's switcher lists it.
        let switcher = app.buttons["forumSwitcher"]
        XCTAssertTrue(waitForHittable(switcher))
        switcher.tap()
        let row = app.buttons["switcherForum-\(host)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The forum switcher does not list \(forumName).")
        XCTAssertTrue(app.buttons["switcherAllForums"].exists)
        XCTAssertTrue(app.buttons["switcherAddForum"].exists)

        // "All forums…" closes the switcher and keeps the Forums home.
        app.buttons["switcherAllForums"].tap()
        XCTAssertTrue(waitForGone(row, timeout: 5))
        XCTAssertTrue(home.waitForExistence(timeout: 5))

        // Clean up in Settings › Forums (swipe to remove) so the suggestion
        // comes back next run. Give the background name/icon refresh a
        // moment first so it can't re-add the forum.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        showAssistant(in: app)
        let openSettings = app.buttons["openSettings"]
        XCTAssertTrue(openSettings.waitForExistence(timeout: 10))
        openSettings.tap()
        let forumsRow = app.buttons["settingsRow-forums"]
        XCTAssertTrue(forumsRow.waitForExistence(timeout: 10))
        forumsRow.tap()
        XCTAssertTrue(app.navigationBars["Forums"].waitForExistence(timeout: 10))
        let settingsRow = app.cells.containing(.any, identifier: "settingsForum-\(host)").firstMatch
        if !reveal(settingsRow, in: app) { attachTree(app) }
        XCTAssertTrue(settingsRow.exists, "Settings › Forums does not list \(host).")
        settingsRow.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "No Remove swipe action for \(host).")
        remove.tap()
        let confirm = app.buttons["Remove and delete saved data"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(waitForGone(settingsRow, timeout: 5), "\(host) was not removed.")
        tapNavigationBack(in: app)
        XCTAssertTrue(app.buttons["backToTopic"].waitForExistence(timeout: 10))
        app.buttons["backToTopic"].tap()
        showBrowser(in: app)
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.buttons["pinSuggested-\(host)"], in: app), "\(host) is not suggested again.")
    }

    func testAddForumSheetOpensFromTheForumsHome() throws {
        let app = launch(["-dc-forums-home"])

        XCTAssertTrue(any(app, "forumsHome").waitForExistence(timeout: 20))
        let add = app.buttons["forumsHomeAddByAddress"]
        XCTAssertTrue(reveal(add, in: app))
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Forum"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "addForumAddress").exists)
        // Nothing typed yet: Add is disabled.
        XCTAssertFalse(app.buttons["addForumConfirm"].isEnabled)
        app.navigationBars["Add Forum"].buttons["Cancel"].tap()
        XCTAssertTrue(waitForGone(app.navigationBars["Add Forum"], timeout: 5))
    }
}
