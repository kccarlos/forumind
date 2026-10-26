import XCTest
@testable import Forumind

/// The AI drawer's hint row over the bar (only when worth a look) and its
/// button for every page state, and the `#N` citations.
final class DrawerHintTests: XCTestCase {
    private func action(_ state: PageContext.State, _ change: (inout DrawerHint.Input) -> Void = { _ in }) -> DrawerHint.Action? {
        var input = DrawerHint.Input(pageState: state)
        change(&input)
        return DrawerHint.action(input)
    }

    private func row(_ state: PageContext.State, tip: Bool = false, _ change: (inout DrawerHint.Input) -> Void = { _ in }) -> DrawerHint.Row? {
        var input = DrawerHint.Input(pageState: state)
        change(&input)
        return DrawerHint.row(input, tipPending: tip)
    }

    func testTheButtonFollowsTheState() {
        XCTAssertEqual(action(.topic), .summarize)
        XCTAssertEqual(action(.topic) { $0.hasSummary = true; $0.totalPosts = 20; $0.summaryPostCount = 14 }, .checkNew(6))
        XCTAssertNil(action(.topic) { $0.hasSummary = true; $0.totalPosts = 14; $0.summaryPostCount = 14 })
        XCTAssertNil(action(.topic) { $0.hasSummary = true })
        XCTAssertNil(action(.topic) { $0.summaryRunning = true })
        XCTAssertNil(action(.topic) { $0.mode = .agent })
        XCTAssertEqual(action(.topic) { $0.providerReady = false }, .setUpAI)
        XCTAssertEqual(action(.topic) { $0.providerReady = false; $0.consentDeclined = true }, .allowAI)
        for state in [PageContext.State.notForum, .maybe, .forumHome, .loading] {
            XCTAssertNil(action(state), "\(state)")
            XCTAssertNil(action(state) { $0.providerReady = false }, "\(state)")
        }
        XCTAssertEqual(DrawerHint.Action.checkNew(6).title, "Check 6 new replies")
        XCTAssertEqual(DrawerHint.Action.checkNew(6).badge, "6")
        XCTAssertEqual(DrawerHint.Action.checkNew(250).badge, "99+")
        XCTAssertNil(DrawerHint.Action.summarize.badge)
        XCTAssertEqual(DrawerHint.Action.summarize.symbol, "sparkles")
        XCTAssertEqual(DrawerHint.Action.checkNew(6).symbol, "arrow.clockwise")
        XCTAssertEqual(DrawerHint.Action.setUpAI.symbol, "key.fill")
        XCTAssertTrue(DrawerHint.Action.allowAI.needsAttention)
    }

    /// The row shows only when needed: the first-run tip, new replies, or AI
    /// to set up or allow. Otherwise none.
    func testTheRowShowsOnlyWhenNeeded() {
        // A topic without a summary: only as the one-time tip.
        XCTAssertEqual(row(.topic, tip: true), DrawerHint.Row(action: .summarize, isTip: true))
        XCTAssertNil(row(.topic, tip: false))
        XCTAssertEqual(row(.topic, tip: true)?.text, "Summarize this topic")
        // New replies since the summary, tip or not.
        let stale = row(.topic) { $0.hasSummary = true; $0.totalPosts = 26; $0.summaryPostCount = 14 }
        XCTAssertEqual(stale, DrawerHint.Row(action: .checkNew(12), isTip: false))
        XCTAssertEqual(stale?.text, "12 new replies")
        XCTAssertEqual(row(.topic) { $0.hasSummary = true; $0.totalPosts = 15; $0.summaryPostCount = 14 }?.text, "1 new reply")
        // AI not set up or not allowed.
        XCTAssertEqual(row(.topic) { $0.providerReady = false }?.text, "Set up AI")
        XCTAssertEqual(row(.topic) { $0.providerReady = false; $0.consentDeclined = true }?.action, .allowAI)
        // Nothing to say: no row.
        XCTAssertNil(row(.topic, tip: true) { $0.hasSummary = true; $0.totalPosts = 14; $0.summaryPostCount = 14 })
        XCTAssertNil(row(.topic, tip: true) { $0.summaryRunning = true })
        XCTAssertNil(row(.topic, tip: true) { $0.mode = .agent })
        XCTAssertNil(row(.forumHome, tip: true))
        XCTAssertNil(row(.notForum, tip: true) { $0.providerReady = false })
    }

    // MARK: Citations

    /// Split layout (no hint row): the panel toggle's dot says "new
    /// replies" while the panel is hidden (audit A8).
    func testTheSplitToggleShowsTheNewRepliesDotOnlyWithThePanelHidden() {
        var stale = DrawerHint.Input(pageState: .topic)
        stale.hasSummary = true
        stale.totalPosts = 20
        stale.summaryPostCount = 14
        XCTAssertTrue(DrawerHint.showsSplitNewRepliesDot(stale, panelShown: false))
        XCTAssertFalse(DrawerHint.showsSplitNewRepliesDot(stale, panelShown: true))
        XCTAssertFalse(DrawerHint.showsSplitNewRepliesDot(DrawerHint.Input(pageState: .topic), panelShown: false),
                       "no summary yet: nothing new")
        var notSetUp = stale
        notSetUp.providerReady = false
        XCTAssertFalse(DrawerHint.showsSplitNewRepliesDot(notSetUp, panelShown: false))
    }

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
