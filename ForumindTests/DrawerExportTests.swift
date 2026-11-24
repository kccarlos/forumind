import SwiftUI
import UIKit
import XCTest
@testable import Forumind

final class DrawerExportTests: XCTestCase {
    @MainActor
    func testAssistantPanelRenderAndUnrelatedMutationsDoNotBuildExportText() throws {
        let source = (1...2_000).map { number in
            "user\(number) | 2026-10-20 10:00:00 UTC | #\(number)\n\nPost body \(number) with discussion details."
        }.joined(separator: RawTopicFormat.blockSeparator)
        let (app, _) = try makeSummaryTestApp(
            summary: "## Overview\n- Key point from #1\n- Follow-up in #2000",
            totalPosts: 2_000,
            source: source
        )
        let expectedText = app.currentExportPayload.text(options: app.exportOptions)

        TopicExportPayload.resetTextBuilds()
        let panel = AssistantPanel(app: app, onExpand: { _ in })
        let (window, _) = hostView(panel, size: CGSize(width: 393, height: 740))
        defer { window.isHidden = true }

        XCTAssertEqual(
            TopicExportPayload.textBuilds,
            0,
            "Initial AssistantPanel render must not build export text."
        )

        for step in 0..<10 {
            if step.isMultiple(of: 2) {
                app.askFocusRequest += 1
            } else {
                app.agentComposesNewQuestion.toggle()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            window.layoutIfNeeded()
        }

        XCTAssertEqual(
            TopicExportPayload.textBuilds,
            0,
            "10 unrelated AppModel mutations must not build export text."
        )

        UIPasteboard.general.string = nil
        panel.copyExport()

        XCTAssertEqual(
            TopicExportPayload.textBuilds,
            1,
            "Triggering Copy must build export text exactly once."
        )
        XCTAssertEqual(
            UIPasteboard.general.string,
            expectedText,
            "Copied pasteboard text must match the topic export payload."
        )
    }

    func testTopicExportPayloadHasContentMatchesTextAcrossAllExportOptions() throws {
        let sampleURL = try XCTUnwrap(URL(string: "https://forum.example.com/t/example/42"))
        let payloads: [(name: String, payload: TopicExportPayload)] = [
            (
                "empty",
                TopicExportPayload(summary: "", source: "", title: "", url: nil, history: [])
            ),
            (
                "whitespace title and summary",
                TopicExportPayload(summary: "   \n\t ", source: "", title: " \n ", url: nil, history: [])
            ),
            (
                "whitespace source only",
                TopicExportPayload(summary: "", source: "   ", title: "", url: nil, history: [])
            ),
            (
                "url only",
                TopicExportPayload(summary: "", source: "", title: "", url: sampleURL, history: [])
            ),
            (
                "title only",
                TopicExportPayload(summary: "", source: "", title: "Discussion title", url: nil, history: [])
            ),
            (
                "summary only",
                TopicExportPayload(summary: "Key takeaways", source: "", title: "", url: nil, history: [])
            ),
            (
                "source only",
                TopicExportPayload(summary: "", source: "alice | 2026-10-20 | #1\nHello", title: "", url: nil, history: [])
            ),
            (
                "chat only with empty content",
                TopicExportPayload(summary: "", source: "", title: "", url: nil, history: [ChatMessage(role: .user, content: "")])
            ),
            (
                "all sections populated",
                TopicExportPayload(
                    summary: "## Summary\nPoints",
                    source: "alice | 2026-10-20 | #1\nHello",
                    title: "Example topic",
                    url: sampleURL,
                    history: [
                        ChatMessage(role: .user, content: "Question?"),
                        ChatMessage(role: .assistant, content: "Answer.")
                    ]
                )
            )
        ]

        let bools = [false, true]
        for (name, payload) in payloads {
            for excludeTitleAndURL in bools {
                for excludeSummary in bools {
                    for excludePostAndResponses in bools {
                        for excludeChatHistory in bools {
                            let options = ExportOptions(
                                excludeTitleAndURL: excludeTitleAndURL,
                                excludeSummary: excludeSummary,
                                excludePostAndResponses: excludePostAndResponses,
                                excludeChatHistory: excludeChatHistory
                            )
                            TopicExportPayload.resetTextBuilds()
                            let hasContent = payload.hasContent(options: options)
                            XCTAssertEqual(
                                TopicExportPayload.textBuilds,
                                0,
                                "hasContent(options:) must not build export text (\(name), \(options))."
                            )
                            let expected = !payload.text(options: options)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                            XCTAssertEqual(
                                hasContent,
                                expected,
                                "hasContent(options:) mismatch for \(name) with \(options)."
                            )
                        }
                    }
                }
            }
        }
    }
}
