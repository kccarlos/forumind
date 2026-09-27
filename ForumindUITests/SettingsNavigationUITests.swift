import XCTest

/// Settings is a grouped root list; every row pushes its own page.
final class SettingsNavigationUITests: DCUITestCase {
    /// Root row identifier suffix → the pushed page's navigation title.
    private let pages: [(row: String, title: String)] = [
        ("provider", "AI provider"),
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
        XCTAssertTrue(
            app.segmentedControls["assistantModePicker"].waitForExistence(timeout: 10),
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

    /// A control each page is known for (moved out of the old single form).
    private func assertPageContent(_ row: String, in app: XCUIApplication) {
        let expected: XCUIElement?
        switch row {
        case "provider": expected = any(app, "providerPicker")
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
