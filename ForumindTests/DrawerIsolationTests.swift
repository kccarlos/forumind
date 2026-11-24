import Combine
import SwiftUI
import UIKit
import XCTest
@testable import Forumind

final class DrawerIsolationTests: XCTestCase {
    @MainActor
    func testUnrelatedAppModelMutationsIsolateChatBubblesAndDrawerHeader() throws {
        let (app, topic) = try makeSummaryTestApp(
            summary: "## Overview\n- Key point from #1\n- Follow-up in #2",
            totalPosts: 20
        )

        var session = try XCTUnwrap(app.sessions[topic.topicKey])
        session.history = (1...20).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? .assistant : .user,
                content: index.isMultiple(of: 2)
                    ? "Assistant reply \(index) referencing #1."
                    : "User question \(index) about this topic?"
            )
        }
        app.upsertSessionForTesting(session)

        DrawerRenderProbe.reset()
        let panel = AssistantPanel(app: app, onExpand: { _ in })
        let (window, _) = hostView(panel, size: CGSize(width: 393, height: 740))
        defer { window.isHidden = true }

        XCTAssertGreaterThan(
            DrawerRenderProbe.chatBubbleBodies,
            0,
            "Initial render must evaluate visible and recent chat bubbles."
        )
        XCTAssertGreaterThanOrEqual(
            DrawerRenderProbe.headerBodies,
            1,
            "Initial render must evaluate the drawer header."
        )
        DrawerRenderProbe.reset()

        let otherSite = "https://other.example.com"
        for step in 0..<10 {
            switch step % 3 {
            case 0:
                // Unrelated settings change (not drawn by header or chat bubbles).
                app.settings.forumContextLimit += 5_000
            case 1:
                // New unrelated session for another topic.
                let otherID = "\(100 + step)"
                let otherURL = try XCTUnwrap(URL(string: "\(otherSite)/t/other-topic/\(otherID)"))
                let otherSession = TopicSession(
                    siteURL: otherSite,
                    topicID: otherID,
                    url: otherURL,
                    title: "Other topic \(step)"
                )
                app.upsertSessionForTesting(otherSession)
            default:
                // Activities change for another topic.
                let otherID = "\(200 + step)"
                let otherURL = try XCTUnwrap(URL(string: "\(otherSite)/t/other-activity/\(otherID)"))
                var record = WorkRecord(
                    type: .summary,
                    siteURL: otherSite,
                    topicID: otherID,
                    title: "Other activity \(step)",
                    url: otherURL,
                    provider: .ollama,
                    model: "test-model"
                )
                record.status = .running
                record.statusText = "Summarizing \(step)"
                app.setActivitiesForTesting([record])
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            window.layoutIfNeeded()
        }

        XCTAssertGreaterThan(
            DrawerRenderProbe.assistantPanelBodies,
            0,
            "Unrelated AppModel mutations must actually trigger AssistantPanel.body so isolation is exercised."
        )
        XCTAssertEqual(
            DrawerRenderProbe.chatBubbleBodies,
            0,
            "10 unrelated AppModel mutations must trigger 0 ChatBubble.body evaluations."
        )
        XCTAssertEqual(
            DrawerRenderProbe.headerBodies,
            0,
            "10 unrelated AppModel mutations must trigger 0 drawer header body evaluations."
        )
    }

    @MainActor
    func testForumBrowserModelUnchangedNavigationStateEmitsNoObjectWillChange() {
        let browser = ForumBrowserModel()
        // Settle initial navigation state once before counting.
        browser.refreshPageContext()

        var emissions = 0
        let cancellable = browser.objectWillChange.sink { _ in
            emissions += 1
        }
        defer { cancellable.cancel() }

        for _ in 0..<10 {
            browser.refreshPageContext()
        }

        XCTAssertEqual(
            emissions,
            0,
            "Calling ForumBrowserModel.refreshPageContext() 10 times with identical values must emit 0 objectWillChange events."
        )
    }
}
