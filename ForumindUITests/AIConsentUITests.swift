import XCTest

/// App Review blockers on sample data (`-dc-sample`, a topic page): the AI
/// data consent page before the first summary (5.1.2(i)) and Report This
/// Summary… in the drawer's ··· menu (1.2). No network: the summary is the
/// DEBUG fake one and the report falls back to copy/share (no Mail account
/// on the simulator), as it would offline.
final class AIConsentUITests: DCUITestCase {
    private let sample = ["-dc-sample", "-dc-page-state", "topic"]

    /// The sample's provider (Anthropic, a placeholder key) has no consent
    /// yet: Create summary shows the page; Allow lets the summary run.
    func testConsentPageShowsBeforeTheFirstSummaryAndAllowProceeds() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample + ["-dc-no-summary", "-dc-fake-summary", "-dc-ask-ai-consent"])
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")

        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitForHittable(summarize, timeout: 15), "Create summary is missing.")
        summarize.tap()

        let page = any(app, "aiConsentPage")
        XCTAssertTrue(waitOrDump(page, timeout: 10, in: app), "The consent page did not show before the summary.")
        let title = any(app, "aiConsentTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Send forum content to Anthropic?")
        XCTAssertTrue(app.links["aiConsentTerms"].exists || any(app, "aiConsentTerms").exists, "The provider's terms link is missing.")
        XCTAssertFalse(app.buttons["retrySummary"].exists, "Nothing may run before the answer.")

        app.buttons["aiConsentAllow"].tap()
        XCTAssertTrue(waitForGone(page, timeout: 10), "Allow did not close the page.")
        XCTAssertTrue(waitOrDump(app.buttons["retrySummary"].firstMatch, timeout: 30, in: app), "The summary did not run after Allow.")
    }

    /// ··· › Report This Summary… › reason › Next: the report (topic URL,
    /// model, text) to copy or share, without Mail or the network.
    func testReportThisSummaryIsReachableFromTheDrawerMenu() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(sample)
        let state = drawerState(in: app)
        XCTAssertTrue(waitOrDump(state, timeout: 20, in: app), "The sample did not open the drawer.")

        let more = app.buttons["assistantMoreMenu"]
        XCTAssertTrue(waitForHittable(more))
        more.tap()
        // Menu items show by label (as History in DrawerUITests).
        let report = app.buttons["Report This Summary…"]
        XCTAssertTrue(waitOrDump(report, timeout: 10, in: app), "Report This Summary… is missing from the menu.")
        XCTAssertTrue(report.isEnabled)
        report.tap()

        let next = app.buttons["reportNext"]
        XCTAssertTrue(waitOrDump(next, timeout: 10, in: app), "The report form did not show.")
        XCTAssertTrue(app.navigationBars["Report summary"].exists)
        next.tap()
        // No Mail account on the simulator: the report to copy or share.
        XCTAssertTrue(waitOrDump(app.navigationBars["Send report"], timeout: 10, in: app), "The report fallback did not show.")
        let body = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'AI output: summary'")).firstMatch
        XCTAssertTrue(body.exists, "The report has no AI output details.")
        XCTAssertTrue(body.label.contains("Topic URL: https://meta.discourse.org/t/"), "The report has no topic URL.")
        XCTAssertTrue(body.label.contains("Model: "), "The report has no model.")
        XCTAssertTrue(body.label.contains("AI text:"), "The report has no AI text.")
    }
}
