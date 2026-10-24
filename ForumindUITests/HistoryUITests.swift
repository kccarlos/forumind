import XCTest

/// History (spec §9.2): reachable from Home and from the drawer's menu, the
/// segments filter, and Ask runs list under Asks.
final class HistoryUITests: DCUITestCase {
    private var isEnglish: Bool { Locale.preferredLanguages.first?.hasPrefix("en") ?? true }

    private func summaryRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'savedSummaryRow-'"))
    }

    func testHistoryOpensFromHomeAndSegmentsFilter() throws {
        let app = launch(["-dc-sample", "-dc-forums-home"], orientation: isPhone ? .portrait : .landscapeLeft)
        openHome(in: app)
        let history = app.buttons["homeHistory"]
        XCTAssertTrue(waitForHittable(history), "Home has no History button.")
        history.tap()

        let all = app.buttons["historySegment-all"]
        XCTAssertTrue(all.waitForExistence(timeout: 10), "History did not open.")
        XCTAssertTrue(app.buttons["historySegment-summaries"].exists)
        XCTAssertTrue(app.buttons["historySegment-asks"].exists)
        XCTAssertTrue(app.buttons["historySegment-watching"].exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Forum:")).firstMatch.exists || !isEnglish)

        // Asks: the sample's Whole forum runs, no saved summaries.
        let asks = app.buttons["historySegment-asks"]
        if !asks.isHittable { all.swipeLeft() }
        asks.tap()
        let run = any(app, "agentRunRow")
        XCTAssertTrue(reveal(run, in: app), "A Whole forum run is not listed under Asks.")
        XCTAssertEqual(summaryRows(app).count, 0)

        // Summaries & chats: the saved summaries, no runs.
        app.buttons["historySegment-summaries"].tap()
        XCTAssertTrue(wait(timeout: 10) { self.summaryRows(app).count > 0 }, "No saved summaries listed.")
        XCTAssertFalse(any(app, "agentRunRow").exists)

        // Watching shows neither.
        let watching = app.buttons["historySegment-watching"]
        if !watching.isHittable { app.buttons["historySegment-summaries"].swipeLeft() }
        watching.tap()
        XCTAssertTrue(wait(timeout: 10) { self.summaryRows(app).count == 0 })
        XCTAssertFalse(any(app, "agentRunRow").exists)
    }

    func testHistoryOpensFromTheDrawerMenu() throws {
        try skipUnlessPhone("The drawer is an iPhone behavior.")
        let app = launch(["-dc-sample"])
        showAssistant(in: app)
        let more = app.buttons["assistantMoreMenu"]
        XCTAssertTrue(waitForHittable(more, timeout: 20))
        more.tap()
        let history = app.buttons.matching(NSPredicate(format: "label == 'History' AND identifier != 'agentHistoryMenu'")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10), "The drawer menu has no History.")
        history.tap()
        XCTAssertTrue(app.buttons["historySegment-all"].waitForExistence(timeout: 10), "History did not open.")
    }
}
