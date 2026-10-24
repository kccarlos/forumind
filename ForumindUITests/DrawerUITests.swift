import XCTest

/// The iPhone AI drawer on sample data (`-dc-sample`, a topic page): every
/// kind of root presentation shows over it and the drawer comes back at the
/// same height, and the swipe rules (down from medium only goes to the peek;
/// down from the peek closes it). The height comes from the DEBUG
/// `drawerState` element; `-dc-test-present` triggers the presentation.
final class DrawerUITests: DCUITestCase {
    private let sample = ["-dc-sample", "-dc-page-state", "topic"]

    /// A Settings page request (Start a Voice Chat without voice set up).
    func testSettingsRequestShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "settings", at: "large")
        let page = app.navigationBars["Voice"]
        XCTAssertTrue(waitOrDump(page, timeout: 20, in: app), "Settings › Voice did not show over the drawer.")
        tapNavigationBack(in: app)
        let done = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        assertDrawer(at: "large", in: app, after: page)
    }

    /// A full-screen cover (the DEBUG Settings cover stands in for the
    /// walkthrough and the Terms of Use).
    func testFullScreenCoverShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "cover", at: "medium")
        let done = app.buttons["debugSettingsDone"]
        XCTAssertTrue(waitOrDump(done, timeout: 20, in: app), "The cover did not show over the drawer.")
        done.tap()
        assertDrawer(at: "medium", in: app, after: done)
    }

    /// `presentedError`: the root alert.
    func testErrorAlertShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "error", at: "medium")
        let alert = app.alerts["Forumind"]
        XCTAssertTrue(waitOrDump(alert, timeout: 20, in: app), "The error alert did not show over the drawer.")
        XCTAssertTrue(alert.staticTexts["Test error"].exists)
        alert.buttons["OK"].tap()
        assertDrawer(at: "medium", in: app, after: alert)
    }

    /// A root sheet closed while the drawer waits to come back (asked for
    /// under the sheet): the drawer comes back, and a root alert still shows
    /// (the drawer never ends up half presented with neither host active).
    func testClosingARootSheetWhileTheDrawerIsPendingBringsItBack() throws {
        let app = try launchWithDrawer(presenting: "pending-drawer", at: "medium")
        let page = app.navigationBars["Voice"]
        XCTAssertTrue(waitOrDump(page, timeout: 20, in: app), "Settings › Voice did not show.")
        tapNavigationBack(in: app)
        let done = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 15, in: app), "The pending drawer did not come back.")
        let alert = app.alerts["Forumind"]
        XCTAssertTrue(waitOrDump(alert, timeout: 20, in: app), "The root alert did not show after the drawer came back.")
        alert.buttons["OK"].tap()
        XCTAssertTrue(waitForGone(alert, timeout: 10))
    }

    /// A drawer presentation that never reports its content (as when UIKit
    /// drops it) falls back after the watchdog: the root alert still shows
    /// and the drawer comes up.
    func testADroppedDrawerPresentationDoesNotBlockAlerts() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-drawer-drop-first", "-dc-test-present", "error", "-dc-test-present-after", "8"])
        let alert = app.alerts["Forumind"]
        XCTAssertTrue(waitOrDump(alert, timeout: 30, in: app), "The root alert was blocked by a dropped drawer.")
        XCTAssertTrue(alert.staticTexts["Test error"].exists)
        alert.buttons["OK"].tap()
        XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 10), "The drawer did not come up.")
    }

    /// Report or block (a routed sheet), from the peek.
    func testReportSheetShowsOverTheDrawer() throws {
        let app = try launchWithDrawer(presenting: "report", at: "peek")
        let sheet = app.navigationBars["Report or block"]
        XCTAssertTrue(waitOrDump(sheet, timeout: 20, in: app), "The report sheet did not show over the drawer.")
        sheet.buttons["Done"].tap()
        assertDrawer(at: "peek", in: app, after: sheet)
    }

    /// Down from medium stops at the peek; down from the peek closes the
    /// drawer, and the bar's AI button opens it again at medium.
    func testSwipingDownGoesToThePeekThenCloses() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample)
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "Got \(state.label).")

        dragDrawer(in: app, to: 0.99)
        XCTAssertTrue(wait(timeout: 5) { state.exists && state.label == "detent=peek" },
                      "A swipe down from medium must stop at the peek.")
        XCTAssertTrue(any(app, "drawerPeekLine").exists, "The peek shows its one line.")
        XCTAssertFalse(app.segmentedControls["assistantModePicker"].exists, "The peek shows only the header and one line.")

        dragDrawer(in: app, to: 0.99)
        XCTAssertTrue(waitForGone(state, timeout: 5), "A swipe down from the peek must close the drawer.")

        let button = app.buttons["aiButton"]
        XCTAssertTrue(waitForBarItem(button, timeout: 10), "The bar's AI button is missing.")
        tapBarItem(button)
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "The AI button opens the drawer at medium.")
    }

    /// §4.6: a topic opens with the drawer at the peek → summarize (the
    /// DEBUG fake summary) → at large, tap `#12` → the page scrolls to post
    /// 12 and marks it, and the drawer steps down to medium. The sample page
    /// is the live meta topic 404728 (its posts 1–13 exist).
    func testCitationJumpScrollsThePageAndLowersTheDrawer() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        try requireNetwork()
        let app = launch(sample + [
            "-dc-no-summary", "-dc-fake-summary", "-dc-browse-debug", "-dc-drawer-detent", "peek"
        ])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 8) { state.label == "detent=peek" }, "Got \(state.label).")
        let peek = any(app, "drawerPeekLine")
        XCTAssertTrue(peek.waitForExistence(timeout: 5))
        XCTAssertEqual(peek.label, "Summarize this topic")

        peek.tap()
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "The peek line opens the drawer.")
        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitForHittable(summarize), "Create summary is missing.")
        summarize.tap()

        let citation = app.buttons["citation-12"].firstMatch
        XCTAssertTrue(waitOrDump(citation, timeout: 30, in: app), "The summary has no #12 citation.")
        XCTAssertTrue(wait(timeout: 10) { peek.exists == false && app.buttons["retrySummary"].exists },
                      "The summary did not finish.")

        dragDrawer(in: app, to: 0.08)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Got \(state.label), wanted large.")
        if !citation.isHittable { app.swipeUp() }
        XCTAssertTrue(waitForHittable(citation))
        citation.tap()

        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" },
                      "A citation tap at large must lower the drawer to medium; got \(state.label).")
        let browse = any(app, "browseDebugState")
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "The browse state hook is missing.")
        let landed = wait(timeout: 40) {
            // Post 12 at the top (post 11's last pixels may still show under the header).
            (browse.label.hasSuffix("top=12") || browse.label.hasSuffix("top=11"))
                && browse.label.contains("highlighted=12 ")
        }
        attachText(browse.label, named: "browse state")
        XCTAssertTrue(landed, "The page did not scroll to post 12 and mark it: \(browse.label)")
    }

    /// §5 and the citation chips (no network: `-dc-no-provider` fails a run
    /// at once). Text typed under This topic moves along to Whole forum and
    /// to a new question; the run it starts shows in History. The sample
    /// summary's `#3 #7` chips are 44 pt wide and at least 4 pt apart.
    func testAskBoxScopeKeepsTheTextAndAWholeForumRunShowsInHistory() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-no-provider"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=medium" }, "Got \(state.label).")

        let first = app.buttons["citation-3"].firstMatch
        let second = app.buttons["citation-7"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10), "The sample summary has no #3 citation.")
        XCTAssertGreaterThanOrEqual(first.frame.width, 44, "A citation chip must be 44 pt wide to tap.")
        if second.exists, abs(second.frame.midY - first.frame.midY) < 4 {
            XCTAssertGreaterThanOrEqual(second.frame.minX - first.frame.maxX, 4, "Citation chips need 4 pt between them.")
        }

        let question = "Retention offers this year"
        let chat = app.textFields["chatInput"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10), "The Ask box has no field.")
        chat.tap()
        chat.typeText(question)
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=large" }, "Focusing the field must raise the drawer.")

        let scope = any(app, "askScopeButton")
        XCTAssertTrue(waitForHittable(scope), "The Ask box has no scope button.")
        scope.tap()
        let wholeForum = app.buttons["Whole forum"].firstMatch
        XCTAssertTrue(wholeForum.waitForExistence(timeout: 5), "The scope menu has no Whole forum.")
        wholeForum.tap()

        // The sample's run on this forum is finished: the box follows it up.
        let followUp = app.textFields["agentFollowUpInput"]
        XCTAssertTrue(followUp.waitForExistence(timeout: 10), "Whole forum did not follow up the selected run.")
        XCTAssertEqual(followUp.value as? String, question, "Switching the scope lost the typed text.")
        XCTAssertFalse(app.textFields["chatInput"].exists)

        let newQuestion = app.buttons["agentNewQuestion"]
        if !newQuestion.isHittable { app.swipeDown() }
        XCTAssertTrue(waitForHittable(newQuestion), "New question is missing.")
        newQuestion.tap()
        let goal = app.textFields["agentGoalInput"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10))
        XCTAssertEqual(goal.value as? String, question, "New question lost the typed text.")
        XCTAssertTrue(any(app, "agentExample").exists, "A new question shows the example questions.")

        let run = app.buttons["runAgent"]
        XCTAssertTrue(run.isEnabled)
        run.tap()
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) { alert.buttons["OK"].tap() }
        let runGoal = app.staticTexts["agentRunGoal"]
        XCTAssertTrue(runGoal.waitForExistence(timeout: 10), "The run did not show.")
        XCTAssertEqual(runGoal.label, question)

        // History lists the run under Asks.
        let more = app.buttons["assistantMoreMenu"]
        XCTAssertTrue(waitForHittable(more))
        more.tap()
        // Not Ask the forum's own History menu (agentHistoryMenu).
        let history = app.buttons
            .matching(NSPredicate(format: "label == 'History' AND identifier != 'agentHistoryMenu'"))
            .firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let asks = app.buttons["historySegment-asks"]
        XCTAssertTrue(asks.waitForExistence(timeout: 10), "History did not open.")
        asks.tap()
        // Running it shows in progress, finished under Asks; either way the goal is listed.
        XCTAssertTrue(reveal(app.staticTexts[question], in: app), "The new run is not listed under Asks.")
    }

    // MARK: Helpers

    private func launchWithDrawer(presenting kind: String, at detent: String) throws -> XCUIApplication {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + [
            "-dc-drawer-detent", detent,
            "-dc-test-present", kind, "-dc-test-present-after", "8"
        ])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")
        XCTAssertTrue(wait(timeout: 8) { state.label == "detent=\(detent)" }, "Got \(state.label), wanted \(detent).")
        return app
    }

    private func assertDrawer(at detent: String, in app: XCUIApplication, after presented: XCUIElement) {
        XCTAssertTrue(waitForGone(presented, timeout: 10), "The presentation did not close.")
        let state = drawerState(in: app)
        XCTAssertTrue(state.waitForExistence(timeout: 10), "The drawer did not come back.")
        XCTAssertTrue(wait(timeout: 5) { state.label == "detent=\(detent)" },
                      "The drawer came back at \(state.label), not \(detent).")
        // Still the drawer's content, not a copy at the root.
        XCTAssertTrue(any(app, "drawerHeader").exists)
    }
}
