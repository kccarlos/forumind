import XCTest
@testable import Forumind

/// The AI drawer's peek line for every page state, and the `#N` citations.
final class DrawerPeekTests: XCTestCase {
    private func line(_ state: PageContext.State, _ change: (inout DrawerPeek.Input) -> Void = { _ in }) -> String {
        var input = DrawerPeek.Input(pageState: state)
        change(&input)
        return DrawerPeek.line(input)
    }

    func testEachPageStateHasItsLine() {
        XCTAssertEqual(line(.notForum), "Not a forum")
        XCTAssertEqual(line(.maybe), "Might be a forum · Try again")
        XCTAssertEqual(line(.forumHome), "Forum home")
        XCTAssertEqual(line(.loading), "Loading page…")
        XCTAssertEqual(line(.topic), "Summarize this topic")
    }

    func testATopicWithoutAProviderAsksToSetUpAI() {
        XCTAssertEqual(line(.topic) { $0.providerReady = false; $0.summary = "Done. More." }, "Set up AI")
        // Other pages say what they are, provider or not.
        XCTAssertEqual(line(.forumHome) { $0.providerReady = false }, "Forum home")
    }

    func testATopicWithASummaryShowsItsFirstSentence() {
        let summary = """
        ## Original post
        Since **2.4**, prints over six hours shift on the Y axis #1. Short ones are fine #12.

        ## What people are saying
        - Lower the current.
        """
        XCTAssertEqual(line(.topic) { $0.summary = summary }, "Since 2.4, prints over six hours shift on the Y axis.")
    }

    func testFirstSentenceSkipsHeadingsAndCode() {
        XCTAssertEqual(DrawerPeek.firstSentence(of: "## Only\n```\ncode. here\n```\n- First item! Second."), "First item!")
        XCTAssertEqual(DrawerPeek.firstSentence(of: "自 2.4 起长时间打印会错层 #3。缩短时间无效。"), "自 2.4 起长时间打印会错层。")
        XCTAssertNil(DrawerPeek.firstSentence(of: "## Heading only"))
    }

    func testRunningSummaryAndAgentMode() {
        XCTAssertEqual(line(.topic) { $0.summaryRunning = true }, "Writing summary…")
        XCTAssertEqual(line(.topic) { $0.summaryRunning = true; $0.summary = "## A\nStreaming text so far" }, "Streaming text so far")
        XCTAssertEqual(line(.topic) { $0.mode = .agent }, "Ask the forum")
    }

    // MARK: Citations

    func testCitationsAreLinkedOutsideCodeAndHeadings() {
        let text = "## Tips #2\nFixed it #37; see `#5` and #9999 and a#4 and [#6](x).\n```\n#7\n```"
        let linked = PostCitations.linked(text, maximum: 100)
        XCTAssertTrue(linked.contains("[#37](forumind-post:37)"))
        XCTAssertTrue(linked.contains("## Tips [#2](forumind-post:2)"), "The heading's ## is not a citation, #2 is.")
        XCTAssertTrue(linked.contains("`#5`"), "Inline code stays as it is.")
        XCTAssertTrue(linked.contains("#9999 "), "Beyond the topic's last post: plain text.")
        XCTAssertTrue(linked.contains("a#4"))
        XCTAssertTrue(linked.contains("[#6](x)"))
        XCTAssertTrue(linked.hasSuffix("```\n#7\n```"))
        XCTAssertEqual(PostCitations.numbers(in: "确认#37，还有 #2 和 #37"), [37, 2])
    }

    func testCitationURLsRoundTrip() throws {
        let url = try XCTUnwrap(PostCitations.url(post: 37))
        XCTAssertEqual(PostCitations.postNumber(from: url), 37)
        XCTAssertNil(PostCitations.postNumber(from: URL(string: "https://example.org/t/x/1/37")!))
    }

    func testStrippedRemovesCitations() {
        XCTAssertEqual(PostCitations.stripped("It fixes it #37 ; three confirm #52 #88."), "It fixes it; three confirm.")
    }
}

/// The drawer's presentation phases (PresentationRouter.swift): which host
/// presents the root sheets and alerts, and the watchdog for a presentation
/// UIKit dropped.
@MainActor
final class DrawerPhaseTests: XCTestCase {
    func testPhasesMoveOnFromTheSheetsCallbacksAndPickTheHost() {
        let router = PresentationRouter()
        XCTAssertTrue(router.rootHostIsActive)
        router.presentDrawer()
        XCTAssertEqual(router.drawerPhase, .presenting)
        XCTAssertTrue(router.drawerPhase.isPresented)
        XCTAssertFalse(router.rootHostIsActive || router.drawerHostIsActive, "neither while it animates in")
        router.presentDrawer()
        router.drawerAppeared()
        router.drawerAppeared()
        XCTAssertEqual(router.drawerPhase, .shown)
        XCTAssertTrue(router.drawerHostIsActive)
        router.dismissDrawer()
        XCTAssertEqual(router.drawerPhase, .dismissing)
        XCTAssertFalse(router.drawerPhase.isPresented)
        XCTAssertFalse(router.rootHostIsActive || router.drawerHostIsActive)
        router.drawerAppeared()
        XCTAssertEqual(router.drawerPhase, .dismissing, "a late appear does not reopen it")
        router.drawerDismissed()
        XCTAssertEqual(router.drawerPhase, .closed)
        XCTAssertTrue(router.rootHostIsActive)
    }

    /// A presentation that never appears falls back (the root host presents
    /// again) and is tried again shortly; after two in a row the request is
    /// given up.
    func testADroppedPresentationFallsBackAndIsGivenUpAfterTwo() async throws {
        let router = PresentationRouter()
        router.watchdogDelay = .milliseconds(50)
        router.recoveryDelay = .milliseconds(50)
        router.openDrawer()
        router.presentDrawer()
        try await waitUntil { router.drawerPhase == .recovering }
        XCTAssertTrue(router.rootHostIsActive)
        router.presentDrawer()
        XCTAssertEqual(router.drawerPhase, .recovering, "not again at once: a sheet may still be leaving")
        try await waitUntil { router.drawerPhase == .closed }
        XCTAssertTrue(router.wantsDrawer, "tried again")
        router.presentDrawer()
        try await waitUntil { router.drawerPhase == .closed }
        XCTAssertFalse(router.wantsDrawer, "given up")

        // A dismissal that never reports also ends closed.
        router.openDrawer()
        router.presentDrawer()
        router.drawerAppeared()
        router.dismissDrawer()
        try await waitUntil { router.drawerPhase == .closed }
        // One that does appear in time stays up.
        router.presentDrawer()
        router.drawerAppeared()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(router.drawerPhase, .shown)
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
