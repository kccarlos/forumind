import UIKit
import XCTest

/// Layout, browser, assistant and Manage smoke tests. Offline tests use the
/// `-ui-test-*` / `-dc-sample` seeds; tests that need a live forum open
/// meta.discourse.org and skip when it is unreachable. The two live AI tests
/// run only on a physical device with a configured provider.
final class PhysicalDeviceSmokeTests: DCUITestCase {
    func testLandscapeShowsBrowserAndAdaptivePanelSideBySide() throws {
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

        app.buttons["openManage"].tap()
        XCTAssertTrue(
            app.staticTexts["Active tasks"].waitForExistence(timeout: 10),
            "The Manage panel did not render."
        )
        XCTAssertTrue(reveal(app.staticTexts["Saved summaries"], in: app))
        XCTAssertTrue(reveal(app.staticTexts["Recent activity"], in: app))
        app.buttons["backToTopic"].tap()
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10))
    }

    func testPortraitUsesBrowseAssistantWorkspaceSwitcher() {
        // A page is open (the web view shows even when it fails to load offline).
        let app = launch(["-dc-open", Self.forumLatest])

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
        XCTAssertTrue(app.buttons["openManage"].exists)
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
        let accountButton = app.buttons["Forum account"]
        if accountButton.waitForExistence(timeout: 5) {
            // Signed in from an earlier run: the account button opens the forum home.
            dismissMenuIfCompact(in: app)
        } else {
            let signInButton = app.buttons["Forum sign in"]
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
        let menu = app.buttons["browserMoreMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
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
        let app = launch(["-ui-test-sample-session"])

        let workspace = app.segmentedControls["workspacePicker"]
        if workspace.waitForExistence(timeout: 20) {
            workspace.buttons["Assistant"].tap()
        }

        XCTAssertTrue(
            app.staticTexts["Card Strategy"].waitForExistence(timeout: 10),
            "The Markdown heading did not render."
        )
        XCTAssertTrue(app.staticTexts["Key points"].exists)
        XCTAssertTrue(app.staticTexts["Sample card"].exists)
        XCTAssertTrue(app.staticTexts["4x points"].exists)

        let modePicker = app.segmentedControls["assistantModePicker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10))
        XCTAssertTrue(modePicker.buttons["Summary"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["summaryContent"].exists)

        // Export lives in the More menu; its options open a sheet of toggles.
        app.buttons["assistantMoreMenu"].tap()
        XCTAssertTrue(app.buttons["copyExport"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["shareExport"].exists)
        XCTAssertTrue(app.buttons["exportExport"].exists)
        app.buttons["exportOptions"].tap()
        XCTAssertTrue(app.switches["excludeTitleURL"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["excludeSummary"].exists)
        XCTAssertTrue(app.switches["excludePostResponses"].exists)
        XCTAssertTrue(app.switches["excludeChatHistory"].exists)
        app.buttons["Done"].tap()

        // The pulled post opens full screen from the same menu.
        app.buttons["assistantMoreMenu"].tap()
        XCTAssertTrue(app.buttons["viewPost"].waitForExistence(timeout: 10))
        app.buttons["viewPost"].tap()
        XCTAssertTrue(app.navigationBars["Post & responses"].waitForExistence(timeout: 10))
        let postDisclosure = app.descendants(matching: .any)["postResponsesDisclosure"].firstMatch
        XCTAssertTrue(postDisclosure.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["pulledPostContent"].exists)
        postDisclosure.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pulledPostContent"].exists)
        app.buttons["Done"].tap()

        // Chat: collapsed summary card, transcript, and a pinned composer.
        modePicker.buttons["Chat"].tap()
        let chatInput = app.textFields["chatInput"]
        XCTAssertTrue(chatInput.waitForExistence(timeout: 10))
        XCTAssertTrue(chatInput.isHittable, "The chat composer must stay pinned and visible.")
        XCTAssertTrue(app.buttons["Send question"].exists)
        XCTAssertTrue(app.buttons["chatInstructions"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["chatMessage-assistant"].exists)
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

        // The whole assistant can open full screen from a panel that is not
        // already full screen (single-pane and split alike).
        app.buttons["assistantMoreMenu"].tap()
        XCTAssertTrue(app.buttons["openFullScreen"].waitForExistence(timeout: 10))
        app.buttons["openFullScreen"].tap()
        XCTAssertTrue(app.navigationBars["Assistant"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["chatInput"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        // Manage and Settings show in place with a way back to the topic.
        app.buttons["openManage"].tap()
        XCTAssertTrue(app.staticTexts["Active tasks"].waitForExistence(timeout: 10))
        XCTAssertTrue(reveal(app.staticTexts["Saved summaries"], in: app))
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

        let workspace = app.segmentedControls["workspacePicker"]
        if workspace.waitForExistence(timeout: 20) {
            workspace.buttons["Assistant"].tap()
        }
        let modePicker = app.segmentedControls["assistantModePicker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 20))

        // Agent mode: goal box, run button, and a run that fails cleanly without
        // an API key (the run record, error, and follow-up composer all appear).
        modePicker.buttons["Agent"].tap()
        let goal = app.textFields["agentGoalInput"]
        XCTAssertTrue(goal.waitForExistence(timeout: 10))
        let runButton = app.buttons["runAgent"]
        XCTAssertFalse(runButton.isEnabled)
        goal.tap()
        goal.typeText("What are people saying about retention offers?")
        XCTAssertTrue(runButton.isEnabled)
        runButton.tap()

        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 30) {
            alert.buttons["OK"].tap()
        }
        XCTAssertTrue(app.staticTexts["agentRunGoal"].waitForExistence(timeout: 10))
        let status = app.staticTexts["agentRunStatus"]
        XCTAssertTrue(
            wait(timeout: 30) { status.label.hasPrefix("Failed") },
            "Run status was: \(status.label)"
        )
        XCTAssertTrue(app.descendants(matching: .any)["agentRunError"].exists)
        XCTAssertTrue(app.textFields["agentFollowUpInput"].waitForExistence(timeout: 10))
        // Starting a run clears the goal box, so a new goal is needed to run again.
        XCTAssertFalse(runButton.isEnabled)
        goal.tap()
        goal.typeText("Another goal")
        XCTAssertTrue(runButton.isEnabled)

        // Watch the current topic from the More menu (grant notifications if asked).
        modePicker.buttons["Summary"].tap()
        app.buttons["assistantMoreMenu"].tap()
        let watchButton = app.buttons["toggleWatchTopic"]
        XCTAssertTrue(watchButton.waitForExistence(timeout: 10))
        if watchButton.label == "Unwatch topic" {
            // Left watched by an interrupted earlier run: start from unwatched.
            watchButton.tap()
            app.buttons["assistantMoreMenu"].tap()
            XCTAssertTrue(watchButton.waitForExistence(timeout: 10))
        }
        XCTAssertEqual(watchButton.label, "Watch topic for new replies")
        watchButton.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) {
            allow.tap()
        }

        app.buttons["assistantMoreMenu"].tap()
        XCTAssertTrue(watchButton.waitForExistence(timeout: 10))
        XCTAssertEqual(watchButton.label, "Unwatch topic")
        dismissMenu(in: app)

        // Manage lists the watched topic and the agent run, grouped by forum.
        app.buttons["openManage"].tap()
        XCTAssertTrue(app.staticTexts["Active tasks"].waitForExistence(timeout: 10))
        let watchedRow = any(app, "watchedTopicRow-999999")
        XCTAssertTrue(reveal(watchedRow, in: app), "The watched topic is not listed in Manage.")
        XCTAssertTrue(app.buttons["checkWatchedTopics"].exists)
        let runRow = any(app, "agentRunRow")
        if !runRow.exists { reveal(runRow, in: app) }
        XCTAssertTrue(runRow.exists, "The agent run is not listed in Manage.")
        // The Watched filter shows only watched topics; unwatch from the row.
        let watchedChip = app.buttons["manageKind-Watched"]
        // The chips scroll sideways; the Watched chip may start off screen.
        for _ in 0..<3 where !watchedChip.isHittable { app.buttons["manageKind-All"].swipeLeft() }
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
        app.buttons["openSettings"].tap()
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
        XCTAssertTrue(app.buttons["backToTopic"].waitForExistence(timeout: 10))
        app.buttons["backToTopic"].tap()
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10))
    }

    func testBrowserBarMinimizesOnScrollAndMovesToBottom() throws {
        let app = try launchOnForum()

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
        let app = launch(["-ui-test-manage-swipe"])

        let workspace = app.segmentedControls["workspacePicker"]
        if workspace.waitForExistence(timeout: 20) {
            workspace.buttons["Assistant"].tap()
        }

        let openManage = app.buttons["openManage"]
        XCTAssertTrue(openManage.waitForExistence(timeout: 10))
        openManage.tap()
        XCTAssertTrue(app.staticTexts["Active tasks"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.buttons["viewPost"].waitForExistence(timeout: 10))
        app.buttons["viewPost"].tap()
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

    func testPhoneKeepsWorkspaceSwitcherInLandscape() throws {
        try skipUnlessPhone("The single-pane landscape layout is an iPhone behavior.")
        let app = launch(["-dc-open", Self.forumLatest], orientation: .landscapeRight)

        let workspace = app.segmentedControls["workspacePicker"]
        XCTAssertTrue(
            workspace.waitForExistence(timeout: 20),
            "An iPhone in landscape must keep the Browse/Assistant switcher."
        )
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))

        workspace.buttons["Assistant"].tap()
        XCTAssertTrue(app.segmentedControls["assistantModePicker"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["openManage"].exists)

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls["assistantModePicker"].exists)
    }

    func testPhoneBrowserToolbarExposesAllActions() throws {
        try skipUnlessPhone("The compact browser toolbar menu is an iPhone behavior.")
        let app = try launchOnForum()

        XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Forward"].exists)
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label == %@ OR label == %@", "Reload", "Stop loading")
            ).firstMatch.exists
        )
        try waitForForumDetected(in: app)

        let menu = app.buttons["browserMoreMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        let home = app.buttons["browserHome"]
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        XCTAssertTrue(home.label.hasSuffix(" home"), "Home is labeled “\(home.label)”.")
        XCTAssertTrue(app.buttons["All Forums"].exists)
        XCTAssertTrue(app.buttons["Add Forum…"].exists)
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(
                    format: "label == %@ OR label == %@",
                    "Forum account",
                    "Forum sign in"
                )
            ).firstMatch.exists
        )
        let help = app.buttons["Sign-in help"]
        XCTAssertTrue(help.exists)
        XCTAssertTrue(app.buttons["Share Page"].exists)
        XCTAssertTrue(app.buttons["Copy Link"].exists)

        help.tap()
        XCTAssertTrue(app.navigationBars["Forum Login"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()

        // All Forums shows the Forums home over the page; Back returns to it.
        menu.tap()
        app.buttons["All Forums"].tap()
        XCTAssertTrue(any(app, "forumsHome").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["forumsHomeBackToPage"].waitForExistence(timeout: 5))
        app.buttons["forumsHomeBackToPage"].tap()
        XCTAssertTrue(waitForGone(any(app, "forumsHome"), timeout: 10))
    }

    // MARK: Helpers

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
        // `-dc-sample` switches to the Assistant on its own after launch.
        let workspace = app.segmentedControls["workspacePicker"]
        if workspace.waitForExistence(timeout: 10) {
            _ = wait(timeout: 3) { workspace.buttons["Assistant"].isSelected }
            if !workspace.buttons["Assistant"].isSelected {
                workspace.buttons["Assistant"].tap()
            }
        }
    }

    private func setBrowserBar(_ position: String, in app: XCUIApplication, singlePane: Bool) {
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
        if isPhone {
            dismissMenu(in: app)
        }
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
        // single-pane layout the user opens the Assistant explicitly.
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
