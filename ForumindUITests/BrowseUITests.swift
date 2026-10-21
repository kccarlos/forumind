import XCTest

/// Post-level browsing on a live topic: opening a topic at a post lands
/// there and highlights it, then a search shows numbered result cards and
/// Next opens the first hit. The page position comes from the DEBUG
/// `browseDebugState` element (`-dc-browse-debug`), which shows the posts
/// the bridge reports highlighted on the page itself.
final class BrowseUITests: DCUITestCase {
    func testOpeningAtAPostHighlightsItAndTheCardsMoveAlongTheHits() throws {
        let topic = try liveTopic(minimumPosts: 5)
        // A post that exists: deleted posts leave gaps in the numbers.
        let numbers = try livePostNumbers(topicID: topic.id)
        guard numbers.count >= 3 else { throw XCTSkip("The live topic has too few regular posts.") }
        let post = numbers[2]
        let app = try launchOnForum(
            topic.url.absoluteString,
            extra: ["-dc-browse-post", String(post), "-dc-browse-find", "plugin", "-dc-browse-debug"]
        )
        showBrowser(in: app)

        let state = any(app, "browseDebugState")
        XCTAssertTrue(waitOrDump(state, timeout: 30, in: app), "The browse state hook is missing.")
        let landed = wait(timeout: 90) {
            state.label.contains("post=\(post) ") && state.label.contains("highlighted=\(post) ")
        }
        attachText(state.label, named: "state after landing")
        XCTAssertTrue(landed, "The page didn't land on post \(post) with it highlighted: \(state.label)")

        // Scrolling minimizes the bar, which shrinks the cards to a chip.
        let cards = any(app, "resultCards")
        let chip = app.buttons["resultCardsChip"]
        let shown = wait(timeout: 60) { cards.exists || chip.exists }
        if !shown { attachTree(app) }
        XCTAssertTrue(shown, "No result cards after the search.")
        if !cards.exists { chip.tap() }
        XCTAssertTrue(waitOrDump(any(app, "resultCard-1"), timeout: 10, in: app))
        attachScreenshot(named: "result-cards")

        let next = app.buttons["resultCardsNext"]
        XCTAssertTrue(waitForHittable(next), "Next is missing on the cards.")
        next.tap()
        // The first hit opens (another topic, or this one) and is marked.
        let moved = wait(timeout: 90) {
            state.label.contains("current=1") && state.label.range(of: #"highlighted=\d"#, options: .regularExpression) != nil
        }
        attachText(state.label, named: "state after next")
        attachScreenshot(named: "after-next")
        XCTAssertTrue(moved, "Next didn't open the first hit highlighted: \(state.label)")
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
