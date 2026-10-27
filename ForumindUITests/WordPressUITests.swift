import XCTest

/// P1 W12: a local WordPress site (`FixtureWordPressServer`, loopback, never
/// the network) opened in the in-app browser. The page is recognized, a
/// summary reads the article and every comment and runs against a fixture
/// Ollama endpoint on the same server (`-dc-fixture-model`), and a follow-up
/// chat answers. The comments the summary reads come through the page's own
/// `fetch()` (the in-page loader) with `X-WP-Total` readable, so no extra
/// page is probed.
final class WordPressUITests: DCUITestCase {
    private var server: FixtureWordPressServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = FixtureWordPressServer()
        try server.start()
    }

    override func tearDown() {
        server?.stop()
        super.tearDown()
    }

    private func launchOnPost() -> XCUIApplication {
        launch(["-dc-open", server.postURL, "-dc-fixture-model", server.baseURL])
    }

    func testAWordPressPostIsRecognizedSummarizedAndAnsweredThroughTheInPageLoader() throws {
        let app = launchOnPost()
        showAssistant(in: app)

        // Recognized: the post is a topic, so the assistant offers a summary.
        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitOrDump(summarize, timeout: 30, in: app), "A WordPress post offers no summary.")
        XCTAssertTrue(waitForHittable(summarize))
        summarize.tap()

        let summary = any(app, "summaryContent")
        XCTAssertTrue(waitOrDump(summary, timeout: 60, in: app), "The summary did not appear.")
        XCTAssertTrue(
            wait(timeout: 30) { self.server.modelRequests.contains { $0.contains("Comment number 250") } },
            "The model was not handed the last comment; requests: \(server.modelRequests.map(\.count))"
        )
        let handed = try XCTUnwrap(server.modelRequests.first { $0.contains("Comment number 250") })
        XCTAssertTrue(handed.contains("The opening article of the fixture blog"), "The article is missing from the model input.")
        XCTAssertTrue(handed.contains("Comment number 1 "), "The first comment is missing from the model input.")
        XCTAssertTrue(
            wait(timeout: 20) { app.staticTexts.containing(self.label(contains: FixtureWordPressServer.summaryMarker)).firstMatch.exists },
            "The model's summary is not shown."
        )

        // In-page loader: the comments were read in three pages by the shown
        // page itself (a Referer), and no fourth page was probed because
        // X-WP-Total reached the app.
        let comments = server.commentRequests.filter { $0.query["post"] == "\(FixtureWordPressServer.postID)" && $0.query["per_page"] == "100" }
        attachText(comments.map { "\($0.line) referer=\($0.headers["referer"] ?? "-")" }.joined(separator: "\n"), named: "comment requests")
        XCTAssertEqual(comments.compactMap { $0.query["page"] }.sorted(), ["1", "2", "3"], "Exactly three comment pages: the total came from X-WP-Total.")
        XCTAssertTrue(comments.allSatisfy { $0.headers["referer"]?.hasPrefix(server.baseURL) == true },
                      "Comments were not read by the page's own fetch (the in-page loader).")

        // A follow-up chat answers.
        let input = app.textFields["chatInput"]
        XCTAssertTrue(waitOrDump(input, timeout: 15, in: app), "The assistant has no chat input.")
        input.tap()
        input.typeText(FixtureWordPressServer.chatQuestion)
        let send = app.buttons["Send question"].firstMatch
        XCTAssertTrue(waitForHittable(send), "Send question is missing.")
        send.tap()
        XCTAssertTrue(
            wait(timeout: 60) { app.staticTexts.containing(self.label(contains: FixtureWordPressServer.chatMarker)).firstMatch.exists },
            "The chat answer did not appear."
        )
    }
}
