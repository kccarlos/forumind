import UIKit
import XCTest

/// Layout, browser, assistant and Manage smoke tests. Offline tests use the
/// `-ui-test-*` / `-dc-sample` seeds; tests that need a live forum open
/// meta.discourse.org and skip when it is unreachable. The two live AI tests
/// run only on a physical device with a configured provider.
final class PhysicalDeviceSmokeTests: DCUITestCase {
    func testLandscapeShowsBrowserAndAdaptivePanelSideBySide() throws {
        try skipUnlessPhone("The iPad workspace switcher, mode picker and Manage screen were replaced in Phase 8; IPadLayoutUITests covers the split and drawer layouts.")
        try skipUnlessPad("The side-by-side layout is an iPad feature.")
        let app = launch(["-dc-sample"], orientation: .landscapeRight)

        let modePicker = app.segmentedControls["assistantModePicker"]
        XCTAssertTrue(
            modePicker.waitForExistence(timeout: 20),
            "The assistant panel did not appear in landscape."
        )
        XCTAssertTrue(
            app.webViews.firstMatch.waitForExistence(timeout: 30),
            "The forum WKWebView did not appear."
        )
        let home = app.buttons["browserHome"]
        XCTAssertTrue(home.waitForExistence(timeout: 10), "The browser toolbar did not appear.")
        XCTAssertTrue(home.label.hasSuffix(" home"), "Home is labeled “\(home.label)”.")
        XCTAssertTrue(app.buttons["forumSwitcher"].exists)
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label == %@ OR label == %@", "Reload", "Stop loading")
            ).firstMatch.waitForExistence(timeout: 10),
            "The forum browser reload control is missing."
        )
        XCTAssertFalse(app.segmentedControls["workspacePicker"].exists)

        let browserFrame = app.webViews.firstMatch.frame
        let panelFrame = modePicker.frame
        XCTAssertLessThan(
            browserFrame.midX,
            panelFrame.midX,
            "The forum must remain to the left of the assistant panel."
        )
        XCTAssertFalse(
            browserFrame.intersects(panelFrame),
            "The adaptive assistant panel must not overlap the forum."
        )

        XCTAssertTrue(modePicker.buttons["Summary"].isSelected)
        XCTAssertTrue(modePicker.buttons["Chat"].exists)
        XCTAssertTrue(modePicker.buttons["Agent"].exists)

        app.buttons["openSettings"].tap()
        XCTAssertTrue(
            any(app, "settingsRoot").waitForExistence(timeout: 10),
            "The Settings panel did not render."
        )
        XCTAssertTrue(app.buttons["settingsRow-provider"].exists)
        app.buttons["backToTopic"].tap()

        app.buttons["openHistory"].tap()
        XCTAssertTrue(
            app.staticTexts["In progress"].waitForExistence(timeout: 10),
            "The Manage panel did not render."
        )
        XCTAssertTrue(reveal(app.staticTexts["Summaries & chats"], in: app))
        XCTAssertTrue(reveal(app.staticTexts["Recent activity"], in: app))
        app.buttons["backToTopic"].tap()
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10))
    }

    func testPortraitUsesBrowseAssistantWorkspaceSwitcher() throws {
        try skipUnlessPhone("The iPad workspace switcher, mode picker and Manage screen were replaced in Phase 8; IPadLayoutUITests covers the split and drawer layouts.")
        // A page is open (the web view shows even when it fails to load offline).
        let app = launch(["-dc-open", Self.forumLatest])
        if isPhone {
            assertPhoneOpensTheAIDrawer(in: app)
            return
        }

        let workspace = app.segmentedControls["workspacePicker"]
        XCTAssertTrue(
            workspace.waitForExistence(timeout: 20),
            "The portrait workspace switcher did not appear."
        )
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(workspace.buttons["Browse"].isSelected)
        XCTAssertTrue(app.buttons["forumSwitcher"].exists)

        workspace.buttons["Assistant"].tap()
        XCTAssertTrue(
            app.segmentedControls["assistantModePicker"].waitForExistence(timeout: 10),
            "The Assistant workspace did not appear."
        )
        XCTAssertTrue(app.buttons["openHistory"].exists)
        XCTAssertTrue(app.buttons["openSettings"].exists)
        // The Assistant pane shows only the workspace switch, not the address bar.
        XCTAssertFalse(app.buttons["Back"].exists)

        workspace.buttons["Browse"].tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
    }

    func testForumLoginLoadsInsideEmbeddedBrowser() throws {
        let app = try launchOnForum()
        try waitForForumDetected(in: app)

        openBrowserMenuIfCompact(in: app)
        // iPhone: the forum menu's header row is the account ("host · Not
        // signed in" / "Logged in as …").
        let accountButton = app.buttons.matching(label(contains: "Signed in")).firstMatch
        let loggedIn = app.buttons.matching(label(contains: "Logged in as")).firstMatch
        if accountButton.waitForExistence(timeout: 5) || loggedIn.exists {
            // Signed in from an earlier run: the account button opens the forum home.
            dismissMenuIfCompact(in: app)
        } else {
            let signInButton = app.buttons.matching(label(contains: "Not signed in")).firstMatch
            XCTAssertTrue(signInButton.waitForExistence(timeout: 10))
            signInButton.tap()

            let loginURL = address(containing: "\(Self.forumHost)/login", in: app)
            if !loginURL.waitForExistence(timeout: 30) {
                attachTree(app, named: "Login accessibility tree")
                XCTFail("Forum login did not load in the persistent embedded browser.")
                return
            }
        }

        // Sign-in help.
        let menu = app.buttons["forumSwitcher"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        tapBarItem(menu)
        let help = app.buttons["Sign-in help"]
        XCTAssertTrue(help.waitForExistence(timeout: 10))
        help.tap()

        XCTAssertTrue(app.navigationBars["Forum Login"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Forum session"].waitForExistence(timeout: 10))
        let openSignIn = app.buttons["Open forum sign in"]
        // List rows below the fold are not realized until scrolled into view.
        for _ in 0..<4 where !openSignIn.exists {
            app.swipeUp()
        }
        XCTAssertTrue(openSignIn.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
    }

    func testExpandedWorkspacesRenderMarkdownAndKeepChatComposerVisible() throws {
        try skipUnlessPhone("The iPad workspace switcher, mode picker and Manage screen were replaced in Phase 8; IPadLayoutUITests covers the split and drawer layouts.")
        // iPhone: a page under the AI drawer (the seeded topic stays selected).
        let app = launch(["-ui-test-sample-session"] + (isPhone ? ["-dc-open", Self.forumLatest] : []))

        if isPhone {
            showAssistant(in: app)
            dragDrawer(in: app, to: 0.05)
        } else {
            let workspace = app.segmentedControls["workspacePicker"]
            if workspace.waitForExistence(timeout: 20) {
                workspace.buttons["Assistant"].tap()
            }
        }

        XCTAssertTrue(
            app.staticTexts["Card Strategy"].waitForExistence(timeout: 10),
            "The Markdown heading did not render."
        )
        XCTAssertTrue(app.staticTexts["Key points"].exists)
        XCTAssertTrue(app.staticTexts["Sample card"].exists)
        XCTAssertTrue(app.staticTexts["4x points"].exists)

        // iPhone: the drawer shows the summary and the conversation together
        // (its Ask box picks This topic or Whole forum); iPad: the picker.
        let modePicker = app.segmentedControls["assistantModePicker"]
        if !isPhone {
            XCTAssertTrue(modePicker.waitForExistence(timeout: 10))
            XCTAssertTrue(modePicker.buttons["Summary"].isSelected)
        }
        XCTAssertTrue(app.descendants(matching: .any)["summaryContent"].exists)
        let exportOptions = isPhone ? "Export Options…" : "Export options"
        let postResponses = isPhone ? "Post & Responses" : "Post & responses"

        // Export lives in the More menu; its options open a sheet of toggles.
        // (Menu items lose their identifiers; match the labels.)
        app.buttons["assistantMoreMenu"].tap()
        XCTAssertTrue(app.buttons["Export .txt"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Share"].exists)
        XCTAssertTrue(app.buttons["Copy"].exists)
        app.buttons[exportOptions].tap()
        XCTAssertTrue(app.switches["excludeTitleURL"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["excludeSummary"].exists)
        XCTAssertTrue(app.switches["excludePostResponses"].exists)
        XCTAssertTrue(app.switches["excludeChatHistory"].exists)
        app.buttons["Done"].tap()

        // The pulled post opens full screen from the same menu.
        app.buttons["assistantMoreMenu"].tap()
        XCTAssertTrue(app.buttons[postResponses].waitForExistence(timeout: 10))
        app.buttons[postResponses].tap()
        XCTAssertTrue(app.navigationBars["Post & responses"].waitForExistence(timeout: 10))
        let postDisclosure = app.descendants(matching: .any)["postResponsesDisclosure"].firstMatch
        XCTAssertTrue(postDisclosure.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["pulledPostContent"].exists)
        postDisclosure.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pulledPostContent"].exists)
        app.buttons["Done"].tap()

        // Chat: collapsed summary card, transcript, and a pinned composer.
        if !isPhone { modePicker.buttons["Chat"].tap() }
        let chatInput = app.textFields["chatInput"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10))
        XCTAssertTrue(chatInput.isHittable, "The chat composer must stay pinned and visible.")
        XCTAssertTrue(app.buttons["Send question"].exists)
        XCTAssertTrue(app.buttons["chatInstructions"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["chatMessage-assistant"].exists)
        if isPhone {
            // Per-topic instructions sheet, from the composer.
            app.buttons["chatInstructions"].tap()
            XCTAssertTrue(app.navigationBars["Instructions"].waitForExistence(timeout: 10))
            app.buttons["Cancel"].tap()
            // Manage is the drawer menu's History for now; Settings is in the
            // forum menu (SettingsNavigationUITests).
            app.buttons["assistantMoreMenu"].tap()
            XCTAssertFalse(app.buttons["Open full screen"].exists)
            let history = app.buttons["History"]
            XCTAssertTrue(history.waitForExistence(timeout: 10))
            history.tap()
            XCTAssertTrue(app.buttons["historySegment-all"].waitForExistence(timeout: 10))
            app.buttons["backToTopic"].tap()
            XCTAssertTrue(any(app, "askScopeButton").waitForExistence(timeout: 10))
            return
        }
        let summaryCard = app.buttons["chatSummaryCard"]
        XCTAssertTrue(summaryCard.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["chatSummaryContent"].exists)
        summaryCard.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["chatSummaryContent"].waitForExistence(timeout: 5)
        )
        // Let the expand animation settle before collapsing again.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        summaryCard.tap()
        XCTAssertTrue(waitForGone(app.descendants(matching: .any)["chatSummaryContent"], timeout: 10))

        // Per-topic instructions sheet.
        app.buttons["chatInstructions"].tap()
        XCTAssertTrue(app.navigationBars["Instructions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["topicInstructions"].exists)
        app.buttons["Cancel"].tap()

        // iPad: the whole assistant can open full screen from a panel that
        // is not already full screen (single-pane and split alike). iPhone:
        // the drawer's large height is that.
        app.buttons["assistantMoreMenu"].tap()
        if isPhone {
            XCTAssertTrue(app.buttons["Post & responses"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["Open full screen"].exists)
            dismissMenu(in: app)
        } else {
            XCTAssertTrue(app.buttons["Open full screen"].waitForExistence(timeout: 10))
            app.buttons["Open full screen"].tap()
            XCTAssertTrue(app.navigationBars["Assistant"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.textFields["chatInput"].firstMatch.waitForExistence(timeout: 10))
            app.buttons["Done"].tap()
        }

        // Manage and Settings show in place with a way back to the topic.
        app.buttons["openHistory"].tap()
        XCTAssertTrue(app.staticTexts["In progress"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.staticTexts["Summaries & chats"], in: app))
        app.buttons["backToTopic"].tap()

        // Settings is a root list; summary batching lives in Summaries & chat.
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.staticTexts["AI models"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["settingsRow-browser"].exists)
        app.buttons["settingsRow-summaries"].tap()
        XCTAssertTrue(app.navigationBars["Summaries & chat"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "summaryBatchLimit").waitForExistence(timeout: 5))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.buttons["backToTopic"].waitForExistence(timeout: 10))
        app.buttons["backToTopic"].tap()
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10))
    }

    func testAgentModeAndWatchedTopics() throws {
        let app = launch(["-ui-test-sample-session"])
        // iPhone: the AI drawer, whose Ask box scope picks This topic or
        // Whole forum; iPad: the panel's mode picker.
        let modePicker = app.segmentedControls["assistantModePicker"]
        if isPhone {
            let aiButton = app.buttons["aiButton"]
            XCTAssertTrue(waitForBarItem(aiButton, timeout: 20), "The bar's AI button is missing.")
            tapBarItem(aiButton)
            XCTAssertTrue(any(app, "askScopeButton").waitForExistence(timeout: 10), "The drawer did not open.")
        } else {
            let workspace = app.segmentedControls["workspacePicker"]
            if workspace.waitForExistence(timeout: 20) {
                workspace.buttons["Assistant"].tap()
            }
            XCTAssertTrue(modePicker.waitForExistence(timeout: 20))
        }
        let watchLabel = isPhone ? "Watch Topic" : "Watch topic for new replies"
        let unwatchLabel = isPhone ? "Unwatch Topic" : "Unwatch topic"

        // Agent mode: goal box, run button, and a run that ends cleanly (the
        // run record, its status and the follow-up field all appear).
        selectMode("Whole forum", picker: "Agent", in: app)
        // iPhone: runs left by earlier launches are selected; ask anew.
        if isPhone, app.buttons["agentNewQuestion"].waitForExistence(timeout: 3) {
            app.buttons["agentNewQuestion"].tap()
        }
        let goal = app.textFields["agentGoalInput"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10))
        let runButton = app.buttons["runAgent"]
        XCTAssertFalse(runButton.isEnabled)
        goal.tap()
        goal.typeText("What are people saying about retention offers?")
        XCTAssertTrue(runButton.isEnabled)
        runButton.tap()

        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 5) {
            alert.buttons["OK"].tap()
        }
        XCTAssertTrue(app.staticTexts["agentRunGoal"].waitForExistence(timeout: 10))
        let status = app.staticTexts["agentRunStatus"]
        // Without a provider the run fails at once. With one set up on this
        // simulator it would really run: stop it right away (at most one
        // request) and accept the cancelled run.
        let stop = app.buttons["cancelAgentRun"]
        if stop.waitForExistence(timeout: 3), stop.isHittable { stop.tap() }
        XCTAssertTrue(
            wait(timeout: 30) { ["Failed", "Cancelled", "Done"].contains { status.label.hasPrefix($0) } },
            "Run status was: \(status.label)"
        )
        if status.label.hasPrefix("Failed") {
            XCTAssertTrue(app.descendants(matching: .any)["agentRunError"].exists)
        }
        XCTAssertTrue(app.textFields["agentFollowUpInput"].waitForExistence(timeout: 10))
        // Starting a run clears the goal box, so a new goal is needed to run
        // again (iPhone: the Ask box follows the run up until New question).
        if isPhone {
            app.buttons["agentNewQuestion"].tap()
            XCTAssertTrue(goal.waitForExistence(timeout: 10))
        }
        XCTAssertFalse(runButton.isEnabled)
        goal.tap()
        goal.typeText("Another goal")
        XCTAssertTrue(runButton.isEnabled)

        // Watch the current topic from the More menu (grant notifications if asked).
        selectMode("This topic", picker: "Summary", in: app)
        if isPhone {
            // The Ask box keeps the typed text across the scope switch.
            let chat = app.textFields["chatInput"]
            XCTAssertTrue(chat.waitForExistence(timeout: 10))
            XCTAssertEqual(chat.value as? String, "Another goal", "Switching the scope lost the typed text.")
        }
        app.buttons["assistantMoreMenu"].tap()
        // Menu items may lose their identifiers; match the labels too.
        let watchButton = app.buttons.matching(NSPredicate(
            format: "identifier == 'toggleWatchTopic' OR label IN %@", [watchLabel, unwatchLabel]
        )).firstMatch
        XCTAssertTrue(watchButton.waitForExistence(timeout: 10))
        if watchButton.label == unwatchLabel {
            // Left watched by an interrupted earlier run: start from unwatched.
            watchButton.tap()
            app.buttons["assistantMoreMenu"].tap()
            XCTAssertTrue(watchButton.waitForExistence(timeout: 10))
        }
        XCTAssertEqual(watchButton.label, watchLabel)
        watchButton.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }

        app.buttons["assistantMoreMenu"].tap()
        XCTAssertTrue(watchButton.waitForExistence(timeout: 10))
        XCTAssertEqual(watchButton.label, unwatchLabel)
        if isPhone {
            // Manage is the drawer menu's History for now.
            app.buttons.matching(NSPredicate(
                format: "identifier == 'openHistoryMenu' OR (label == 'History' AND identifier != 'agentHistoryMenu')"
            )).firstMatch.tap()
        } else {
            dismissMenu(in: app)
        }

        // Manage lists the watched topic and the agent run, grouped by forum.
        if !isPhone { app.buttons["openHistory"].tap() }
        XCTAssertTrue(app.staticTexts["In progress"].waitForExistence(timeout: 10))
        let watchedRow = any(app, "watchedTopicRow-999999")
        XCTAssertTrue(reveal(watchedRow, in: app), "The watched topic is not listed in Manage.")
        XCTAssertTrue(app.buttons["checkWatchedTopics"].exists)
        let runRow = any(app, "agentRunRow")
        if !runRow.exists { reveal(runRow, in: app) }
        XCTAssertTrue(runRow.exists, "The agent run is not listed in Manage.")
        // The Watched filter shows only watched topics; unwatch from the row.
        let watchedChip = app.buttons["historySegment-watching"]
        // The chips scroll sideways; the Watched chip may start off screen.
        for _ in 0..<3 where !watchedChip.isHittable { app.buttons["historySegment-all"].swipeLeft() }
        XCTAssertTrue(waitForHittable(watchedChip))
        watchedChip.tap()
        XCTAssertTrue(watchedRow.waitForExistence(timeout: 5))
        XCTAssertFalse(any(app, "agentRunRow").exists)
        let unwatch = app.buttons["Unwatch"].firstMatch
        XCTAssertTrue(reveal(unwatch, in: app))
        unwatch.tap()
        XCTAssertTrue(waitForGone(watchedRow, timeout: 5))
        for _ in 0..<8 where !app.buttons["backToTopic"].isHittable { app.swipeDown() }
        app.buttons["backToTopic"].tap()

        // Settings: the agent budget is under Ask the forum, watch options under Watched topics.
        openSettings(in: app)
        XCTAssertTrue(app.staticTexts["AI models"].waitForExistence(timeout: 10))
        app.buttons["settingsRow-agent"].tap()
        XCTAssertTrue(app.navigationBars["Ask the forum"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "agentMaxSteps").waitForExistence(timeout: 5))
        XCTAssertTrue(any(app, "agentMaxTopicReads").exists)
        tapNavigationBack(in: app)

        XCTAssertTrue(app.buttons["settingsRow-watched"].waitForExistence(timeout: 10))
        app.buttons["settingsRow-watched"].tap()
        XCTAssertTrue(app.navigationBars["Watched topics"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(any(app, "watchAutoRefresh"), in: app))
        tapNavigationBack(in: app)
        if isPhone {
            closeSettings(in: app)
            return
        }
        XCTAssertTrue(app.buttons["backToTopic"].waitForExistence(timeout: 10))
        app.buttons["backToTopic"].tap()
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10))
    }

    /// iPhone: the Ask box's scope menu (This topic / Whole forum); iPad:
    /// the mode picker segment.
    private func selectMode(_ title: String, picker segment: String, in app: XCUIApplication) {
        guard isPhone else {
            app.segmentedControls["assistantModePicker"].buttons[segment].tap()
            return
        }
        let menu = any(app, "askScopeButton")
        XCTAssertTrue(waitForHittable(menu), "The Ask box's scope button is missing.")
        menu.tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title) is missing from the scope menu.")
        item.tap()
    }

    func testBrowserBarMinimizesOnScrollAndMovesToBottom() throws {
        try skipUnlessPhone("The iPad workspace switcher, mode picker and Manage screen were replaced in Phase 8; IPadLayoutUITests covers the split and drawer layouts.")
        let app = try launchOnForum()
        if isPhone {
            try assertPhoneBarMinimizesEditsAndMoves(in: app)
            return
        }

        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 20))
        _ = webView.links.firstMatch.waitForExistence(timeout: 30)

        // In the single-pane layout the workspace switch sits above the address row.
        let workspaceSwitch = app.segmentedControls["workspacePicker"]
        if workspaceSwitch.exists {
            XCTAssertLessThanOrEqual(workspaceSwitch.frame.maxY, app.buttons["Back"].frame.minY)
        }

        // Scrolling down minimizes the bar to a strip; tapping it restores it.
        // (Let the page finish laying out first: a still-short page can't scroll.)
        _ = wait(timeout: 20) { !app.buttons["Stop loading"].exists }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let strip = app.buttons["browserChromeStrip"]
        for _ in 0..<6 where !strip.waitForExistence(timeout: 1) {
            webView.swipeUp()
        }
        if !strip.waitForExistence(timeout: 5), app.buttons["Stop loading"].exists {
            // The simulator's WebContent process can crash on a full forum
            // load, leaving a blank page that never scrolls.
            throw XCTSkip("\(Self.forumHost) never finished loading, so the page can't scroll.")
        }
        XCTAssertTrue(strip.exists, "The browser bar did not minimize.")
        XCTAssertFalse(app.buttons["Back"].exists)
        strip.tap()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))
        XCTAssertFalse(strip.exists)

        // Scrolling back up also restores it.
        for _ in 0..<4 where !strip.exists {
            webView.swipeUp()
        }
        XCTAssertTrue(strip.waitForExistence(timeout: 5))
        webView.swipeDown()
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 5))


        // Tapping the address opens an editable field; Go loads a forum path.
        let currentAddress = address(containing: "\(Self.forumHost)/latest", in: app)
        XCTAssertTrue(currentAddress.waitForExistence(timeout: 30))
        currentAddress.tap()
        let addressField = app.textFields["addressField"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 5))
        addressField.typeText("/top\n")
        XCTAssertTrue(
            address(containing: "\(Self.forumHost)/top", in: app).waitForExistence(timeout: 30),
            "Typing a forum path into the address bar did not navigate."
        )
        XCTAssertFalse(addressField.exists)

        // Moving the bar to the bottom puts the chrome below the page.
        let workspace = app.segmentedControls["workspacePicker"]
        let usesSinglePane = workspace.exists
        setBrowserBar("Bottom", in: app, singlePane: usesSinglePane)
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10))
        XCTAssertGreaterThan(
            app.buttons["Back"].frame.minY,
            webView.frame.midY,
            "The browser bar must sit below the page when set to Bottom."
        )
        if usesSinglePane {
            XCTAssertGreaterThanOrEqual(
                workspace.frame.minY,
                app.buttons["Back"].frame.maxY,
                "At the bottom the workspace switch sits below the address row, on the screen edge."
            )
        }

        // Restore the default so other tests see the bar on top.
        setBrowserBar("Top", in: app, singlePane: usesSinglePane)
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10))
        XCTAssertLessThan(app.buttons["Back"].frame.maxY, webView.frame.midY)
    }

    func testManageRowsUseMailStyleSwipeActions() throws {
        try skipUnlessPhone("The iPad workspace switcher, mode picker and Manage screen were replaced in Phase 8; IPadLayoutUITests covers the split and drawer layouts.")
        let app = launch(["-ui-test-manage-swipe"])

        if isPhone {
            // No page, so no AI drawer: Manage from the bar's menu.
            openBrowserMenuIfCompact(in: app)
            let item = app.buttons["History"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), "History is missing from the browser menu.")
            item.tap()
        } else {
            let workspace = app.segmentedControls["workspacePicker"]
            if workspace.waitForExistence(timeout: 20) {
                workspace.buttons["Assistant"].tap()
            }
            let openHistory = app.buttons["openHistory"]
            XCTAssertTrue(openHistory.waitForExistence(timeout: 10))
            openHistory.tap()
        }
        XCTAssertTrue(app.staticTexts["In progress"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.staticTexts["Recent activity"], in: app))

        let recentRow = app.staticTexts["Swipe test recent activity"]
        XCTAssertTrue(reveal(recentRow, in: app))
        recentRow.swipeRight()
        let deleteRecent = app.buttons["Delete recent activity"]
        if deleteRecent.waitForExistence(timeout: 2) {
            deleteRecent.tap()
        }
        XCTAssertTrue(waitForGone(recentRow, timeout: 5))

        let deleteSummaryRow = app.staticTexts["Swipe test delete summary"]
        XCTAssertTrue(reveal(deleteSummaryRow, in: app))
        deleteSummaryRow.swipeRight()
        let deleteSummary = app.buttons["Delete saved summary"]
        if deleteSummary.waitForExistence(timeout: 2) {
            deleteSummary.tap()
        }
        XCTAssertTrue(waitForGone(deleteSummaryRow, timeout: 5))

        let keepSummaryRow = app.staticTexts["Swipe test keep summary"]
        XCTAssertTrue(reveal(keepSummaryRow, in: app))
        keepSummaryRow.swipeLeft()
        let keepSummary = app.buttons["Keep saved summary"]
        if keepSummary.waitForExistence(timeout: 2) {
            keepSummary.tap()
        }
        XCTAssertTrue(keepSummaryRow.waitForExistence(timeout: 5))

        keepSummaryRow.swipeRight()
        let unkeepSummary = app.buttons["Unkeep saved summary"]
        XCTAssertTrue(unkeepSummary.waitForExistence(timeout: 2))
        unkeepSummary.tap()
        XCTAssertTrue(keepSummaryRow.waitForExistence(timeout: 5))
    }

    func testAssistantPageStatesOffline() throws {
        try skipUnlessPhone("The iPad workspace switcher, mode picker and Manage screen were replaced in Phase 8; IPadLayoutUITests covers the split and drawer layouts.")
        // A page that isn't a Discourse forum: status chip and not-forum card.
        var app = launch(["-dc-sample", "-dc-no-provider", "-dc-page-state", "notForum"])
        showAssistantIfNeeded(in: app)
        XCTAssertTrue(any(app, "notForumState").waitForExistence(timeout: 20), "The not-a-forum card is missing.")
        XCTAssertTrue(any(app, "providerSetupCard").exists, "The provider card must show without a provider.")
        XCTAssertTrue(app.buttons["stateAllForums"].exists)
        app.terminate()

        // A forum's home page: Ask the forum.
        app = launch(["-dc-sample", "-dc-page-state", "forumHome"])
        showAssistantIfNeeded(in: app)
        XCTAssertTrue(any(app, "forumHomeState").waitForExistence(timeout: 20), "The forum-home card is missing.")
        XCTAssertTrue(any(app, "forumHomeGoalInput").exists)
        XCTAssertFalse(any(app, "providerSetupCard").exists)
        app.terminate()

        // A topic: Summary / Chat / Agent.
        app = launch(["-dc-sample", "-dc-assistant-mode", "chat"])
        showAssistantIfNeeded(in: app)
        if isPhone {
            // The drawer shows the summary and the conversation together.
            XCTAssertTrue(any(app, "chatInput").waitForExistence(timeout: 20), "The drawer has no chat input.")
            XCTAssertTrue(any(app, "summaryContent").exists, "The summary sits above the conversation.")
            selectMode("Whole forum", picker: "Agent", in: app)
            // The sample's finished run: the Ask box follows it up.
            XCTAssertTrue(app.textFields["agentFollowUpInput"].waitForExistence(timeout: 10))
            return
        }
        let modePicker = app.segmentedControls["assistantModePicker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 20))
        XCTAssertTrue(wait(timeout: 5) { modePicker.buttons["Chat"].isSelected })
        XCTAssertTrue(any(app, "assistantTopicTitle").exists)
        modePicker.buttons["Agent"].tap()
        XCTAssertTrue(app.textFields["agentGoalInput"].waitForExistence(timeout: 10))
    }

    func testLivePullPostResponsesSupportsExportAndChat() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Live pull verification runs only on a physical device.")
        #else
        let app = try launchOnForum(extra: ["-ui-test-pull-mode"])

        try selectForumTopic(in: app)

        app.buttons["assistantMoreMenu"].tap()
        let pullButton = app.buttons["pullPost"]
        XCTAssertTrue(pullButton.waitForExistence(timeout: 10))
        XCTAssertTrue(pullButton.isEnabled)
        pullButton.tap()

        // The summary button is disabled while the pull runs and re-enables after.
        let summaryButton = any(app, "createSummary")
        try waitForEnabled(
            summaryButton,
            in: app,
            timeout: 180,
            operation: "post pull"
        )
        XCTAssertFalse(app.descendants(matching: .any)["summaryContent"].exists)

        app.buttons["assistantMoreMenu"].tap()
        XCTAssertTrue(app.buttons["copyExport"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["shareExport"].exists)
        XCTAssertTrue(app.buttons["exportExport"].exists)
        app.buttons["exportOptions"].tap()
        XCTAssertTrue(app.switches["excludeTitleURL"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["excludeTitleURL"].isEnabled)
        XCTAssertFalse(app.switches["excludeSummary"].isEnabled)
        XCTAssertTrue(app.switches["excludePostResponses"].isEnabled)
        XCTAssertFalse(app.switches["excludeChatHistory"].isEnabled)
        app.buttons["Done"].tap()

        app.buttons["assistantMoreMenu"].tap()
        XCTAssertTrue(app.buttons["Post & responses"].waitForExistence(timeout: 10))
        app.buttons["Post & responses"].tap()
        let postDisclosure = app.descendants(matching: .any)["postResponsesDisclosure"].firstMatch
        XCTAssertTrue(postDisclosure.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["pulledPostContent"].exists)
        postDisclosure.tap()
        let pulledPost = app.descendants(matching: .any)["pulledPostContent"].firstMatch
        XCTAssertTrue(pulledPost.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        app.buttons["assistantMoreMenu"].tap()
        let copyButton = app.buttons["copyExport"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 10))
        copyButton.tap()

        app.segmentedControls["assistantModePicker"].buttons["Chat"].tap()
        let chatInput = app.textFields["chatInput"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 20))
        chatInput.tap()
        chatInput.typeText("What is the main point of this pulled discussion?")
        let sendButton = app.buttons["Send question"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.tap()

        let assistantMessage = app.descendants(matching: .any)[
            "chatMessage-assistant"
        ].firstMatch
        try waitForAIResult(
            assistantMessage,
            in: app,
            timeout: 600,
            operation: "pull-only chat"
        )
        #endif
    }

    func testLayoutAdaptsWhenRotatedAfterLaunch() throws {
        try skipUnlessPhone("The iPad workspace switcher, mode picker and Manage screen were replaced in Phase 8; IPadLayoutUITests covers the split and drawer layouts.")
        try skipUnlessPad("The side-by-side layout is an iPad feature.")
        let app = launch(["-dc-open", Self.forumLatest])

        let workspace = app.segmentedControls["workspacePicker"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 20))

        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(
            app.segmentedControls["assistantModePicker"].waitForExistence(timeout: 10),
            "The assistant did not appear after rotating to landscape."
        )
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForGone(workspace, timeout: 5))

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(
            workspace.waitForExistence(timeout: 10),
            "The workspace switcher did not return after rotating to portrait."
        )
    }

    func testSelectingForumPostActivatesTopicPanel() throws {
        try skipUnlessPhone("The iPad workspace switcher, mode picker and Manage screen were replaced in Phase 8; IPadLayoutUITests covers the split and drawer layouts.")
        let app = try launchOnForum()

        try selectForumTopic(in: app)

        let summaryButton = any(app, "createSummary")
        XCTAssertTrue(summaryButton.isEnabled)
        XCTAssertTrue(any(app, "assistantTopicTitle").exists)
        XCTAssertFalse(any(app, "notForumState").exists)
        XCTAssertFalse(any(app, "forumHomeState").exists)
    }

    func testLiveSummaryAndChat() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Live API verification runs only on a physical device.")
        #else
        let app = try launchOnForum()
        try selectForumTopic(in: app)

        let summaryButton = any(app, "createSummary")
        XCTAssertTrue(summaryButton.waitForExistence(timeout: 10))
        XCTAssertTrue(
            summaryButton.isEnabled,
            "The live AI test must not continue until a forum topic is selected."
        )
        summaryButton.tap()

        let summary = app.descendants(matching: .any)["summaryContent"].firstMatch
        try waitForAIResult(
            summary,
            in: app,
            timeout: 600,
            operation: "summary"
        )
        attachText(summary.label, named: "Live summary response")

        let modePicker = app.segmentedControls["assistantModePicker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10))
        modePicker.buttons["Chat"].tap()

        let chatInput = app.textFields["chatInput"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 20))
        chatInput.tap()
        chatInput.typeText(
            "In one short sentence, state the main point of this forum discussion."
        )
        let sendButton = app.buttons["Send question"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.tap()

        let assistantMessage = app.descendants(matching: .any)[
            "chatMessage-assistant"
        ].firstMatch
        try waitForAIResult(
            assistantMessage,
            in: app,
            timeout: 600,
            operation: "chat"
        )
        attachText(assistantMessage.label, named: "Live chat response")
        #endif
    }

    func testPhoneKeepsTheAIDrawerInLandscape() throws {
        try skipUnlessPhone("The AI drawer is an iPhone behavior.")
        let app = launch(["-dc-open", Self.forumLatest], orientation: .landscapeRight)

        XCTAssertFalse(app.segmentedControls["workspacePicker"].exists)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        showAssistant(in: app)
        XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 10), "The AI button did not open the drawer.")
        XCTAssertTrue(app.buttons["assistantMoreMenu"].waitForExistence(timeout: 10))

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["assistantMoreMenu"].waitForExistence(timeout: 10))
        XCTAssertTrue(drawerState(in: app).exists, "Rotating closed the drawer.")
    }

    func testPhoneBrowserToolbarExposesAllActions() throws {
        try skipUnlessPhone("The iPhone bar and forum menu are an iPhone behavior.")
        let app = try launchOnForum()
        try waitForForumDetected(in: app)

        // Three items: avatar, title, AI button. No More menu, no Back button.
        let title = app.buttons["browserTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "The bar has no title capsule.")
        XCTAssertTrue(app.buttons["aiButton"].exists || any(app, "aiButton").exists, "The bar has no AI button.")
        XCTAssertFalse(app.buttons["browserMoreMenu"].exists)
        XCTAssertTrue(any(app, "contentBlockingShield").exists, "The ad shield is not in the title.")

        // The forum menu lists every bar action (menu items keep only labels).
        openForumMenu(in: app)
        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Forward"].exists)
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label == %@ OR label == %@", "Reload", "Stop loading")
            ).firstMatch.exists
        )
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " home")).firstMatch.exists, "Forum home is missing.")
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS %@ OR label CONTAINS %@", "signed in", "Logged in as")
            ).firstMatch.exists
            || app.buttons.matching(label(contains: "Signed in")).firstMatch.exists,
            "The account row is missing."
        )
        let help = app.buttons["Sign-in help"]
        XCTAssertTrue(help.exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(app.buttons["Share Page"].exists)
        XCTAssertTrue(app.buttons["Copy Link"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any).matching(label(contains: "Block Ads on This Site")).firstMatch.exists,
            "Block Ads on This Site is missing."
        )
        XCTAssertTrue(app.buttons["Add Forum…"].exists)
        XCTAssertTrue(app.buttons["Home · Today & all forums"].exists)
        XCTAssertTrue(app.buttons["History"].exists)

        help.tap()
        XCTAssertTrue(app.navigationBars["Forum Login"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        // Long-pressing the title lists the history.
        XCTAssertTrue(waitForBarItem(title))
        pressBarItem(title, duration: 1.2)
        let history = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR label == %@ OR label == %@", "No history yet", "Back", "Forward"))
            .firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 5), "Long-pressing the title shows no history menu.")
        dismissMenu(in: app)

        // Home over the page: the title becomes the search and address
        // field; the forum menu's Back returns to the page.
        openForumsHomeFromSwitcher(in: app)
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "homeSettings").exists)
        XCTAssertTrue(waitForBarItem(title))
        XCTAssertTrue(title.label.hasPrefix("Search or enter"), "The title is “\(title.label)”.")
        XCTAssertFalse(app.buttons["aiButton"].exists, "Home has no AI button.")
        openForumMenu(in: app)
        let back = app.buttons["Back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(waitForGone(any(app, "home"), timeout: 10))
    }

    /// iPhone: the bar sits at the bottom (Automatic), minimizes while the
    /// page scrolls down, edits the address on the keyboard, and moves to
    /// the top when set to Top.
    private func assertPhoneBarMinimizesEditsAndMoves(in app: XCUIApplication) throws {
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30))
        let title = app.buttons["browserTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(title.frame.minY, webView.frame.midY, "Automatic puts the bar at the bottom on iPhone.")
        _ = webView.links.firstMatch.waitForExistence(timeout: 30)
        _ = wait(timeout: 20) { !app.staticTexts["Stop loading"].exists }
        RunLoop.current.run(until: Date().addingTimeInterval(2))

        // Scrolling down minimizes the bar (iOS 27: the system toolbar
        // shrinks; earlier: a strip); scrolling up brings it back.
        let expanded = title.frame
        let strip = app.buttons["browserChromeStrip"]
        func minimized() -> Bool {
            strip.exists || !title.exists || title.frame.height < expanded.height - 4
                || title.frame.minY > expanded.minY + 4
        }
        for _ in 0..<6 where !minimized() {
            webView.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        }
        attachScreenshot(named: "bar-minimized")
        XCTAssertTrue(minimized(), "The bar did not minimize while scrolling down.")
        webView.swipeDown()
        if strip.exists { strip.tap() }
        let back = wait(timeout: 5) { title.exists && abs(title.frame.minY - expanded.minY) < 4 }
        if !back { attachTree(app) }
        XCTAssertTrue(back, "The bar did not come back.")

        // Tapping the title edits the address on the keyboard; Go loads a path.
        tapBarItem(title)
        let addressField = app.textFields["addressField"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 5) {
            XCTAssertLessThanOrEqual(addressField.frame.maxY, keyboard.frame.minY + 1, "The address field is under the keyboard.")
        }
        attachScreenshot(named: "address-editing")
        addressField.typeText("/top\n")
        XCTAssertTrue(
            address(containing: "\(Self.forumHost)/top", in: app).waitForExistence(timeout: 30),
            "Typing a forum path into the address bar did not navigate."
        )
        XCTAssertFalse(addressField.exists)

        // Top puts the bar above the page; Automatic brings it back down.
        setBrowserBar("Top", in: app, singlePane: false)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertLessThan(title.frame.maxY, webView.frame.midY, "Top puts the bar above the page.")
        setBrowserBar("Automatic", in: app, singlePane: false)
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(title.frame.minY, webView.frame.midY)
    }

    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Helpers

    /// iPhone: no Browse/Assistant switch; the bar's AI button opens the
    /// drawer with the assistant, and closing it leaves the page.
    private func assertPhoneOpensTheAIDrawer(in app: XCUIApplication) {
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.segmentedControls["workspacePicker"].exists)
        XCTAssertTrue(app.buttons["forumSwitcher"].exists)
        let button = app.buttons["aiButton"]
        XCTAssertTrue(waitForBarItem(button, timeout: 20), "The bar has no AI button.")
        tapBarItem(button)
        XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 10), "The AI button did not open the drawer.")
        XCTAssertEqual(drawerState(in: app).label, "detent=medium")
        // A forum's home page: the header (no Ask box until a topic or Whole forum).
        XCTAssertTrue(
            any(app, "drawerHeader").waitForExistence(timeout: 10),
            "The drawer does not show the assistant."
        )
        // Manage is the drawer menu's History; Settings is in the forum menu.
        XCTAssertTrue(app.buttons["assistantMoreMenu"].exists)
        XCTAssertTrue(app.buttons["modelPill"].exists)
        closeDrawer(in: app)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForBarItem(button, timeout: 5))
    }

    /// Waits until the page is detected as a Discourse forum (the switcher
    /// then names it).
    private func waitForForumDetected(in app: XCUIApplication) throws {
        let switcher = app.buttons["forumSwitcher"]
        guard switcher.waitForExistence(timeout: 20),
              wait(timeout: 45, until: { switcher.label.hasPrefix("Forum:") })
        else {
            attachTree(app)
            throw XCTSkip("\(Self.forumHost) did not load as a Discourse forum (network?).")
        }
    }

    private func showAssistantIfNeeded(in app: XCUIApplication) {
        // `-dc-sample` switches to the Assistant (iPhone: opens the drawer)
        // on its own after launch.
        if isPhone {
            showAssistant(in: app)
            return
        }
        let workspace = app.segmentedControls["workspacePicker"]
        if workspace.waitForExistence(timeout: 10) {
            _ = wait(timeout: 3) { workspace.buttons["Assistant"].isSelected }
            if !workspace.buttons["Assistant"].isSelected {
                workspace.buttons["Assistant"].tap()
            }
        }
    }

    private func setBrowserBar(_ position: String, in app: XCUIApplication, singlePane: Bool) {
        if isPhone {
            openSettings(in: app)
            let row = app.buttons["settingsRow-browser"]
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            let picker = app.segmentedControls["browserBarPosition"]
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            picker.buttons[position].tap()
            XCTAssertTrue(picker.buttons[position].isSelected)
            tapNavigationBack(in: app)
            closeSettings(in: app)
            return
        }
        let workspace = app.segmentedControls["workspacePicker"]
        if singlePane {
            workspace.buttons["Assistant"].tap()
            XCTAssertTrue(app.buttons["openSettings"].waitForExistence(timeout: 10))
        }
        app.buttons["openSettings"].tap()
        let row = app.buttons["settingsRow-browser"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        let picker = app.segmentedControls["browserBarPosition"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons[position].tap()
        XCTAssertTrue(picker.buttons[position].isSelected)
        tapNavigationBack(in: app)
        XCTAssertTrue(app.buttons["backToTopic"].waitForExistence(timeout: 10))
        app.buttons["backToTopic"].tap()
        if singlePane {
            workspace.buttons["Browse"].tap()
        }
    }

    private func dismissMenuIfCompact(in app: XCUIApplication) {
        dismissMenu(in: app)
    }

    /// Opens a topic from the forum's latest list by tapping its title link
    /// (a Discourse SPA navigation), then shows the Assistant.
    private func selectForumTopic(in app: XCUIApplication) throws {
        let topic = try liveTopic()
        let webView = app.webViews.firstMatch
        XCTAssertTrue(webView.waitForExistence(timeout: 30))
        XCTAssertTrue(address(containing: "\(Self.forumHost)/latest", in: app).waitForExistence(timeout: 30))

        let titleLink = webView.links.matching(label(contains: topic.title)).firstMatch
        guard titleLink.waitForExistence(timeout: 30) else {
            attachTree(app)
            throw XCTSkip("The topic “\(topic.title)” is not in the rendered list.")
        }
        // Let Discourse finish booting so the tap is routed by the app.
        _ = wait(timeout: 20) { !app.buttons["Stop loading"].exists }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        for _ in 0..<4 where !titleLink.isHittable { webView.swipeUp() }
        titleLink.tap()

        // A tap that lands while the list is still settling can be dropped; retry once.
        let topicAddress = address(containing: "\(Self.forumHost)/t/", in: app)
        if !topicAddress.waitForExistence(timeout: 15), titleLink.exists {
            for _ in 0..<4 where !titleLink.isHittable { webView.swipeUp() }
            titleLink.tap()
        }
        XCTAssertTrue(
            waitOrDump(topicAddress, timeout: 30, in: app),
            "The embedded browser did not navigate to the selected topic."
        )

        // Opening a topic never switches workspaces on its own; in the
        // single-pane layout the user opens the Assistant explicitly (iPhone:
        // the AI drawer; past its first-run peek it stays closed).
        if isPhone {
            XCTAssertFalse(drawerState(in: app).exists, "Opening a topic must not open the AI drawer.")
            showAssistant(in: app)
        }
        let workspace = app.segmentedControls["workspacePicker"]
        if workspace.exists {
            XCTAssertTrue(
                workspace.buttons["Browse"].isSelected,
                "Opening a topic must not auto-switch to the Assistant workspace."
            )
            workspace.buttons["Assistant"].tap()
        }

        XCTAssertTrue(
            any(app, "createSummary").waitForExistence(timeout: 30),
            "Selecting a Discourse SPA topic did not activate the summary panel."
        )
    }

    private func waitForAIResult(
        _ result: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        operation: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if result.exists, !result.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            try failOnAlert(in: app, operation: operation)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTFail("Timed out waiting for the live \(operation) response.")
        throw LiveTestFailure.timeout
    }

    private func waitForEnabled(
        _ result: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval,
        operation: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if result.exists, result.isEnabled {
                return
            }
            try failOnAlert(in: app, operation: operation)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        XCTFail("Timed out waiting for the live \(operation) to finish.")
        throw LiveTestFailure.timeout
    }

    private func failOnAlert(in app: XCUIApplication, operation: String) throws {
        let alert = app.alerts.firstMatch
        guard alert.exists else { return }
        let message = alert.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        XCTFail("Live \(operation) failed: \(message)")
        throw LiveTestFailure.apiAlert
    }
}

private enum LiveTestFailure: Error {
    case apiAlert
    case timeout
}
