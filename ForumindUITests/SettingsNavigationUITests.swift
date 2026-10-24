import XCTest

/// Settings is a grouped root list; every row pushes its own page.
final class SettingsNavigationUITests: DCUITestCase {
    /// Root row identifier suffix → the pushed page's navigation title.
    private let pages: [(row: String, title: String)] = [
        ("provider", "AI models"),
        ("sync", "iCloud Sync"),
        ("forums", "Forums"),
        ("summaries", "Summaries & chat"),
        ("agent", "Ask the forum"),
        ("watched", "Watched topics"),
        ("browser", "Browser"),
        ("data", "Data & privacy"),
        ("help", "Help")
    ]

    func testEachRootRowOpensItsPageAndBackReturns() throws {
        // `-dc-panel-settings` opens Settings inside the assistant panel.
        let app = launch(["-dc-sample", "-dc-panel-settings"])

        let root = any(app, "settingsRoot")
        XCTAssertTrue(root.waitForExistence(timeout: 20), "Settings did not open in the assistant panel.")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["backToTopic"].exists, "The panel's Settings has no way back to the assistant.")

        for page in pages {
            let row = app.buttons["settingsRow-\(page.row)"]
            XCTAssertTrue(reveal(row, in: app), "Root row \(page.row) is missing.")
            row.tap()
            XCTAssertTrue(
                app.navigationBars[page.title].waitForExistence(timeout: 10),
                "Row \(page.row) did not open “\(page.title)”."
            )
            assertPageContent(page.row, in: app)
            // A back tap during the push animation can be dropped; retry.
            for _ in 0..<3 where app.navigationBars[page.title].exists {
                tapNavigationBack(in: app)
                _ = waitForGone(app.navigationBars[page.title], timeout: 3)
            }
            XCTAssertTrue(
                app.navigationBars["Settings"].waitForExistence(timeout: 10),
                "Back from “\(page.title)” did not return to the Settings root."
            )
            XCTAssertTrue(waitForGone(app.navigationBars[page.title], timeout: 5))
        }

        // Help's own sub-pages push and pop too.
        let help = app.buttons["settingsRow-help"]
        XCTAssertTrue(reveal(help, in: app))
        help.tap()
        XCTAssertTrue(app.navigationBars["Help"].waitForExistence(timeout: 10))
        let sharing = app.buttons["How to share from Safari or Chrome"]
        XCTAssertTrue(reveal(sharing, in: app))
        sharing.tap()
        XCTAssertTrue(app.navigationBars["Share from Safari or Chrome"].waitForExistence(timeout: 10))
        app.navigationBars.buttons["Help"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Help"].waitForExistence(timeout: 10))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))

        // Back to the assistant.
        let back = app.buttons["backToTopic"]
        if !back.isHittable { app.swipeDown() }
        XCTAssertTrue(waitForHittable(back))
        back.tap()
        // iPhone: the drawer's Ask box; iPad: the panel's mode picker.
        XCTAssertTrue(
            any(app, "askScopeButton")
                .waitForExistence(timeout: 10),
            "Back to assistant did not return to the assistant."
        )
        XCTAssertFalse(root.exists)
    }

    func testStandaloneSettingsOpensEveryPage() throws {
        // `-dc-show-settings root` presents Settings full screen (no assistant).
        let app = launch(["-dc-sample", "-dc-show-settings", "root"])

        XCTAssertTrue(any(app, "settingsRoot").waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["backToTopic"].exists)
        for page in pages {
            let row = app.buttons["settingsRow-\(page.row)"]
            XCTAssertTrue(reveal(row, in: app), "Root row \(page.row) is missing.")
            row.tap()
            XCTAssertTrue(app.navigationBars[page.title].waitForExistence(timeout: 10))
            tapNavigationBack(in: app)
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        }
    }

    func testSyncPageShowsStatusTogglesAndDelete() throws {
        // `-dc-sync-status` fakes the displayed status (screenshots/tests only).
        let app = launch(["-dc-sample", "-dc-show-settings", "sync", "-dc-sync-status", "upToDate"])

        XCTAssertTrue(app.navigationBars["iCloud Sync"].waitForExistence(timeout: 20))
        let status = any(app, "syncStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Up to date"), "Got “\(status.label)”.")
        XCTAssertEqual(app.switches["syncEnabled"].value as? String, "1", "Sync with iCloud is on.")
        XCTAssertTrue(app.buttons["syncNow"].exists)
        let toggle = app.switches["syncAPIKeys"]
        XCTAssertTrue(reveal(toggle, in: app))
        XCTAssertEqual(toggle.value as? String, "1", "Sync API keys is on by default.")
        let delete = app.buttons["syncDeleteCloudData"]
        XCTAssertTrue(reveal(delete, in: app, swipes: 4))
        delete.tap()
        // Confirmation first; cancel deletes nothing.
        XCTAssertTrue(
            app.staticTexts["Delete iCloud data?"].waitForExistence(timeout: 5),
            "Delete iCloud data asks for confirmation."
        )
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() } else { app.tap() }
        XCTAssertTrue(waitForGone(app.staticTexts["Delete iCloud data?"], timeout: 5))
    }

    func testSyncPageShowsAccountFix() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "sync", "-dc-sync-status", "noAccount"])

        XCTAssertTrue(app.navigationBars["iCloud Sync"].waitForExistence(timeout: 20))
        let status = any(app, "syncStatus")
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Sign in to iCloud"), "Got “\(status.label)”.")
        XCTAssertFalse(app.buttons["syncStatusAction"].exists, "Nothing to retry without an account.")
    }

    /// Settings › AI models lists both roles with their own models (here set
    /// apart with `-dc-agent-model`) and opens a role's model picker.
    func testAIModelsPageShowsBothRolesAndOpensARolesPicker() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "provider", "-dc-agent-model", "deepseek:deepseek-v4-flash"])

        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 20))
        let assistant = any(app, "modelRole-assistant")
        let agent = any(app, "modelRole-agent")
        XCTAssertTrue(assistant.waitForExistence(timeout: 5))
        XCTAssertTrue(assistant.label.contains("claude-sonnet-4-5"), "Got “\(assistant.label)”.")
        XCTAssertTrue(agent.label.contains("deepseek-v4-flash"), "Got “\(agent.label)”.")
        XCTAssertTrue(any(app, "useSameModel-agent").exists, "Different models offer “Use deepseek-v4-flash for both”.")
        XCTAssertTrue(any(app, "useSameModel-assistant").exists)
        // Favorites with their state; both roles' models are starred.
        XCTAssertTrue(any(app, "favoriteModel-anthropic:claude-sonnet-4-5").exists)
        XCTAssertFalse(any(app, "starCurrentModel-assistant").exists, "The current model is starred already.")

        capture("ai-models")

        agent.tap()
        XCTAssertTrue(app.navigationBars["Ask the forum"].waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "providerPicker").waitForExistence(timeout: 5))
        capture("ai-models-agent-picker")
        XCTAssertTrue(reveal(app.buttons["testAndSaveProvider"], in: app, swipes: 4))
        tapNavigationBack(in: app)
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 10))
    }

    /// The Assistant's model switcher names the current mode's role: Chat
    /// (and Summary) switch the summaries & chat model, Ask the forum its own.
    func testAssistantModelSwitcherFollowsTheMode() throws {
        try skipUnlessPhone("The Assistant header layout checked here is the iPhone one.")
        // The drawer's model pill shows the mode's model and lists the favorites.
        for (mode, model) in [("chat", "claude-sonnet-4-5"), ("agent", "deepseek-v4-flash")] {
            let app = launch(["-dc-sample", "-dc-topic", "makers", "-dc-assistant-mode", mode,
                              "-dc-agent-model", "deepseek:deepseek-v4-flash"] + phonePage)
            let pill = app.buttons["modelPill"]
            XCTAssertTrue(pill.waitForExistence(timeout: 20), "The drawer did not open in \(mode).")
            XCTAssertTrue(pill.label.contains(model), "Got “\(pill.label)” in \(mode).")
            pill.tap()
            // A favorite reads "Provider, model · Ready" (menu toggles drop
            // their identifiers).
            let current = menuOption(model, in: app)
            XCTAssertTrue(current.waitForExistence(timeout: 5), "The \(mode) switcher doesn't list \(model).")
            // The menu names its role (ModelMenu / ModelForum).
            let title = mode == "agent" ? "ASK THE FORUM" : "SUMMARIES & CHAT"
            XCTAssertTrue(app.staticTexts[title].exists, "No “\(title)” header in \(mode).")
            XCTAssertTrue(any(app, "modelUseForBoth").exists, "The roles differ: “Use X for both”.")
            capture("model-switcher-\(mode)")
            app.terminate()
        }
    }

    /// §6: picking a favorite from the drawer's pill switches the scope's
    /// model, and the pill's label follows.
    func testModelPillSwitchesTheModel() throws {
        try skipUnlessPhone("The model pill is in the iPhone drawer's header.")
        let app = launch(["-dc-sample", "-dc-topic", "makers", "-dc-assistant-mode", "chat",
                          "-dc-agent-model", "deepseek:deepseek-v4-flash"] + phonePage)
        let pill = app.buttons["modelPill"]
        XCTAssertTrue(pill.waitForExistence(timeout: 20), "The drawer did not open.")
        XCTAssertTrue(pill.label.contains("claude-sonnet-4-5"), "Got “\(pill.label)”.")
        pill.tap()
        let option = menuOption("deepseek-v4-flash", in: app)
        XCTAssertTrue(waitOrDump(option, timeout: 5, in: app), "The menu doesn't list the other favorite.")
        option.tap()
        let switched = NSPredicate(format: "label CONTAINS %@", "deepseek-v4-flash")
        expectation(for: switched, evaluatedWith: pill)
        waitForExpectations(timeout: 5)
        // Only This topic's model changed: the roles now share it.
        pill.tap()
        XCTAssertTrue(menuOption("claude-sonnet-4-5", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(any(app, "modelUseForBoth").exists, "Both roles use deepseek-v4-flash now.")
        // AI models… opens Settings › AI models over the drawer (router).
        app.buttons["modelMenuSettings"].tap()
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 10), "AI models… did not open Settings › AI models.")
    }

    /// Settings › AI models favorites (ModelSettings): tap = pick the role,
    /// hold = use for both, swipe = remove.
    func testFavoritesTapHoldAndSwipe() throws {
        let app = launch(["-dc-sample", "-dc-show-settings", "provider", "-dc-agent-model", "deepseek:deepseek-v4-flash"])
        XCTAssertTrue(app.navigationBars["AI models"].waitForExistence(timeout: 20))
        let agent = any(app, "modelRole-agent")
        let assistant = any(app, "modelRole-assistant")
        XCTAssertTrue(agent.waitForExistence(timeout: 5))

        // Tap: the role choice; Ask the forum takes claude-sonnet-4-5.
        let claude = any(app, "favoriteModel-anthropic:claude-sonnet-4-5")
        XCTAssertTrue(reveal(claude, in: app))
        claude.tap()
        let useForAgent = app.buttons["Use for Ask the forum"]
        XCTAssertTrue(waitOrDump(useForAgent, timeout: 5, in: app), "Tapping a favorite offers its roles.")
        useForAgent.tap()
        XCTAssertTrue(wait(timeout: 5) { agent.label.contains("claude-sonnet-4-5") }, "Got “\(agent.label)”.")

        // Hold: both roles take deepseek-v4-flash.
        let deepseek = any(app, "favoriteModel-deepseek:deepseek-v4-flash")
        XCTAssertTrue(reveal(deepseek, in: app))
        deepseek.press(forDuration: 1.2)
        XCTAssertTrue(wait(timeout: 5) {
            agent.label.contains("deepseek-v4-flash") && assistant.label.contains("deepseek-v4-flash")
        }, "Holding a favorite uses it for both; got “\(assistant.label)” and “\(agent.label)”.")
        XCTAssertFalse(app.buttons["Use for Ask the forum"].exists, "Holding doesn't open the role choice.")

        // Swipe left: remove. The roles keep their model, so it can be starred again.
        deepseek.swipeLeft()
        let remove = app.buttons["Remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
        XCTAssertTrue(waitForGone(deepseek, timeout: 5))
        XCTAssertTrue(any(app, "starCurrentModel-assistant").waitForExistence(timeout: 5), "Star deepseek-v4-flash is offered.")
    }

    /// A favorite in the model menu: "Provider, model · state".
    private func menuOption(_ model: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ", \(model) · ")).firstMatch
    }

    /// Only the role that can't run shows the setup card: here Ask the
    /// forum's provider has no key while chat works.
    func testSetupCardShowsOnlyForTheRoleThatIsNotReady() throws {
        let args = ["-dc-sample", "-dc-topic", "makers",
                    "-dc-agent-model", "deepseek:deepseek-v4-flash", "-dc-no-agent-key"]
            + phonePage
        var app = launch(args + ["-dc-assistant-mode", "agent"])
        let card = any(app, "providerSetupCard")
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Ask the forum should ask for its model.")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "deepseek-v4-flash isn’t ready")).firstMatch.exists,
            "The card names the model that isn't ready."
        )
        XCTAssertTrue(app.buttons["providerSetupButton"].label.contains("Key"), "Got “\(app.buttons["providerSetupButton"].label)”.")
        // Never a dead end: the ready favorite is offered (ModelSetup).
        XCTAssertTrue(any(app, "readyModel-anthropic:claude-sonnet-4-5").exists)
        capture("setup-card-agent")
        app.terminate()

        app = launch(args + ["-dc-assistant-mode", "chat"])
        XCTAssertTrue(app.buttons["assistantMoreMenu"].waitForExistence(timeout: 20))
        XCTAssertFalse(any(app, "providerSetupCard").exists, "Chat's model is ready.")
    }

    /// iPhone: the AI drawer shows on pages, not over the Forums home (where
    /// the fictional makers forum's failed load lands), so load a real page
    /// under the seeded makers topic.
    private var phonePage: [String] {
        ["-dc-open", DCUITestCase.forumLatest]
    }

    /// Screenshot attached to the result; also written to
    /// `$DC_SCREENSHOT_DIR` (pass `TEST_RUNNER_DC_SCREENSHOT_DIR`) when set.
    private func capture(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["DC_SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    /// A control each page is known for (moved out of the old single form).
    private func assertPageContent(_ row: String, in app: XCUIApplication) {
        let expected: XCUIElement?
        switch row {
        case "provider": expected = any(app, "modelRole-assistant")
        case "sync": expected = any(app, "syncAPIKeys")
        case "summaries": expected = any(app, "summaryBatchLimit")
        case "agent": expected = any(app, "agentMaxSteps")
        case "watched": expected = any(app, "watchAutoRefresh")
        case "browser": expected = app.segmentedControls["browserBarPosition"]
        case "data": expected = any(app, "clearAllData")
        case "help": expected = any(app, "replayOnboarding")
        default: expected = nil
        }
        guard let expected else { return }
        XCTAssertTrue(reveal(expected, in: app, swipes: 4), "The \(row) page is missing its main control.")
    }
}
