import XCTest

/// Report or block on a live topic (guideline 1.2): the sheet lists the posts
/// on screen, blocking hides the user's posts, and Settings › Data & privacy
/// lists and unblocks them. Leaves nobody blocked.
final class ModerationUITests: DCUITestCase {
    func testBlockingFromTheReportSheetHidesTheUsersPosts() throws {
        let topic = try liveTopic()
        let app = try launchOnForum(topic.url.absoluteString)
        showBrowser(in: app)

        let menu = app.buttons["browserMoreMenu"]
        XCTAssertTrue(waitForHittable(menu, timeout: 30), "The browser menu is missing.")
        // Menu items lose their identifiers; match the label.
        let reportItem = app.buttons["Report or block…"]
        // The item appears once the page is recognized as a topic.
        let found = wait(timeout: 30) {
            menu.tap()
            if reportItem.waitForExistence(timeout: 3) { return true }
            dismissMenu(in: app)
            return false
        }
        XCTAssertTrue(found, "Report or block is missing from the menu on a topic.")
        reportItem.tap()

        let block = app.descendants(matching: .button)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'blockUser'"))
            .firstMatch
        XCTAssertTrue(block.waitForExistence(timeout: 15), "No posts are listed in the report sheet.")
        XCTAssertTrue(app.buttons["reportTopic"].exists)
        attachScreenshot(named: "report-sheet")
        let number = String(block.identifier.dropFirst("blockUser".count))
        XCTAssertTrue(app.buttons["reportPost\(number)"].exists)

        block.tap()
        let confirm = app.sheets.buttons["Block"].firstMatch.exists
            ? app.sheets.buttons["Block"].firstMatch
            : app.buttons["Block"].firstMatch
        XCTAssertTrue(waitForHittable(confirm), "Blocking asks for confirmation.")
        confirm.tap()
        // The developer hears about the block: the mail composer, or (no
        // mail account, as on the simulator) the report to copy or share.
        if app.buttons["copyReport"].waitForExistence(timeout: 5) {
            attachScreenshot(named: "report-fallback")
            app.navigationBars["Send report"].buttons["Done"].tap()
        } else if app.navigationBars.buttons["Cancel"].waitForExistence(timeout: 3) {
            app.navigationBars.buttons["Cancel"].tap()
            let delete = app.buttons["Delete Draft"]
            if delete.waitForExistence(timeout: 3) { delete.tap() }
        }
        XCTAssertTrue(waitForGone(app.buttons["blockUser\(number)"], timeout: 10), "The blocked user's post is still listed.")
        attachScreenshot(named: "after-block")
        app.buttons["Done"].firstMatch.tap()

        // Settings › Data & privacy lists the user; unblock to clean up.
        let settings = launch(["-dc-show-settings", "data"])
        let unblock = settings.buttons["Unblock"].firstMatch
        XCTAssertTrue(reveal(unblock, in: settings), "The blocked user is not listed in Data & privacy.")
        attachScreenshot(named: "settings-blocked")
        unblock.tap()
        XCTAssertTrue(waitForGone(unblock, timeout: 5))
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
