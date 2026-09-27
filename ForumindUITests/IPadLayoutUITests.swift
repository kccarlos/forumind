import XCTest

/// iPad layout: rotation across the split threshold, the panel resize
/// handle, hardware-keyboard shortcuts, and removing a pinned forum from its
/// context menu. Uses `-dc-sample` (offline data; nothing is saved).
///
/// Set `TEST_RUNNER_DC_SCREENSHOT_DIR=/some/dir` on `xcodebuild` to also
/// write each screenshot there.
final class IPadLayoutUITests: DCUITestCase {
    private let sample = ["-dc-sample", "-dc-page-state", "topic"]

    // MARK: Rotation

    /// Air 11 / mini cross 850 pt when rotating (1180/1133 ↔ 820/744): the
    /// Settings sub-page open in the panel survives both ways, and portrait
    /// shows the Assistant pane (where the user was).
    func testRotatingAcrossTheSplitThresholdKeepsTheSettingsPage() throws {
        try skipUnlessPad("iPad layout")
        let app = launch(sample + ["-dc-panel-settings", "provider"], orientation: .landscapeLeft)
        let providerPage = app.navigationBars["AI provider"]
        XCTAssertTrue(waitOrDump(providerPage, timeout: 20, in: app), "Settings › AI provider did not open in the panel.")
        XCTAssertFalse(app.segmentedControls["workspacePicker"].exists, "Landscape should be side by side.")
        snapshot("rotation-1-landscape")

        XCUIDevice.shared.orientation = .portrait
        let picker = app.segmentedControls["workspacePicker"]
        let portraitIsSingle = picker.waitForExistence(timeout: 5)
        snapshot("rotation-2-portrait")
        XCTAssertTrue(providerPage.waitForExistence(timeout: 5), "The Settings sub-page was lost on rotation.")
        if portraitIsSingle {
            XCTAssertTrue(picker.buttons["Assistant"].isSelected, "Settings was open, so the Assistant pane should show.")
        }

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForGone(picker, timeout: 5), "Landscape should return to side by side.")
        XCTAssertTrue(providerPage.waitForExistence(timeout: 5), "The Settings sub-page was lost rotating back.")
        snapshot("rotation-3-landscape-again")
    }

    /// Browsing when the window narrows keeps the page (Browse pane).
    func testRotatingWhileBrowsingKeepsTheBrowsePane() throws {
        try skipUnlessPad("iPad layout")
        let app = launch(sample, orientation: .landscapeLeft)
        let address = app.buttons.matching(label(contains: "meta.discourse.org")).firstMatch
        XCTAssertTrue(waitOrDump(address, timeout: 20, in: app))
        // The page loaded after the assistant opened, so Browse is current.
        // (The switcher popover also opens from the bar.)
        app.buttons["forumSwitcher"].tap()
        XCTAssertTrue(app.buttons["switcherAllForums"].waitForExistence(timeout: 5))
        dismissMenu(in: app)
        XCTAssertTrue(waitForGone(app.buttons["switcherAllForums"], timeout: 5))

        XCUIDevice.shared.orientation = .portrait
        let picker = app.segmentedControls["workspacePicker"]
        if picker.waitForExistence(timeout: 5) {
            XCTAssertTrue(picker.buttons["Browse"].isSelected)
            XCTAssertTrue(address.exists, "The page should still be shown.")
            // The waiting assistant is parked off the trailing edge.
            let modes = app.segmentedControls["assistantModePicker"]
            XCTAssertTrue(!modes.exists || modes.frame.minX >= app.windows.firstMatch.frame.maxX)
        }
        snapshot("rotation-browse-portrait")
    }

    /// Regression: animating the split change on top of the rotation made
    /// the Forums home List loop in UICollectionView self-sizing and crash.
    func testRotatingOnTheForumsHomeKeepsTheAppRunning() throws {
        try skipUnlessPad("iPad layout")
        let app = launch(["-dc-sample", "-dc-forums-home"], orientation: .landscapeLeft)
        let home = any(app, "forumsHome")
        XCTAssertTrue(waitOrDump(home, timeout: 20, in: app))
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        for _ in 0..<2 {
            XCUIDevice.shared.orientation = .portrait
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            XCUIDevice.shared.orientation = .landscapeLeft
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(home.exists)
    }

    // MARK: Resize handle

    func testDraggingTheHandleResizesAndRemembersThePanel() throws {
        try skipUnlessPad("iPad layout")
        var app = launch(sample, orientation: .landscapeLeft)
        let handle = any(app, "panelResizeHandle")
        XCTAssertTrue(waitOrDump(handle, timeout: 20, in: app))
        let before = handle.frame.midX

        let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: start.withOffset(CGVector(dx: -120, dy: 0)))
        let dragged = handle.frame.midX
        XCTAssertLessThan(dragged, before - 40, "Dragging left should widen the panel.")
        snapshot("resize-dragged")

        // Remembered across launches.
        app.terminate()
        app = launch(sample, orientation: .landscapeLeft)
        let relaunched = any(app, "panelResizeHandle")
        XCTAssertTrue(relaunched.waitForExistence(timeout: 20))
        XCTAssertEqual(relaunched.frame.midX, dragged, accuracy: 4)

        // Double-tap resets to the default width.
        relaunched.doubleTap()
        XCTAssertTrue(wait(timeout: 3) { abs(relaunched.frame.midX - before) < 4 }, "Double-tap should reset the width.")
    }

    // MARK: Keyboard

    func testKeyboardShortcutsDriveTheWorkspace() throws {
        try skipUnlessPad("hardware keyboard shortcuts")
        let app = launch(sample, orientation: .landscapeLeft)
        let modes = app.segmentedControls["assistantModePicker"]
        XCTAssertTrue(waitOrDump(modes, timeout: 20, in: app))
        // Let the sample page finish loading: a topic change resets the mode.
        XCTAssertTrue(app.buttons.matching(label(contains: "meta.discourse.org")).firstMatch.waitForExistence(timeout: 20))
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        // In a fresh simulator session the first key events can be dropped
        // until a touch sequence has gone through UIKit; a double-tap on the
        // resize handle (resets the width) warms it up.
        any(app, "panelResizeHandle").doubleTap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // The simulator attaches its hardware keyboard on the first key
        // event, which can be dropped; ⌘2 is idempotent, so retry once.
        app.typeKey("2", modifierFlags: .command)
        if !wait(timeout: 2, until: { modes.buttons["Chat"].isSelected }) {
            app.typeKey("2", modifierFlags: .command)
        }
        XCTAssertTrue(wait(timeout: 3) { modes.buttons["Chat"].isSelected }, "⌘2 should show Chat.")
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(wait(timeout: 3) { modes.buttons["Agent"].isSelected }, "⌘3 should show Ask the forum.")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(wait(timeout: 3) { modes.buttons["Summary"].isSelected }, "⌘1 should show Summary.")

        app.typeKey("l", modifierFlags: .command)
        let field = app.textFields["addressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘L should edit the address.")
        // (Esc isn't delivered by XCUITest's simulated keyboard; ⌘. is the
        // other cancel shortcut, so the Esc paths are checked with it.)
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(waitForGone(field, timeout: 5), "⌘. should leave the address unchanged.")

        app.buttons["openManage"].tap()
        XCTAssertTrue(waitForGone(modes, timeout: 5))
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(modes.waitForExistence(timeout: 5), "⌘. should close Manage.")

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(any(app, "settingsRoot").waitForExistence(timeout: 5), "⌘, should open Settings.")
        snapshot("keyboard-settings")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(modes.waitForExistence(timeout: 5), "⌘. should return to the assistant.")

        app.typeKey("h", modifierFlags: [.command, .shift])
        XCTAssertTrue(any(app, "forumsHome").waitForExistence(timeout: 5), "⌘⇧H should show the Forums home.")
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitForGone(any(app, "forumsHome"), timeout: 5), "⌘[ should go back to the page.")
    }

    // MARK: Forums home

    /// "Remove…" from a pinned tile's context menu shows the dialog after the
    /// menu closes, and "Remove Forum" removes the tile.
    func testRemovingAPinnedForumFromItsContextMenu() throws {
        try skipUnlessPad("iPad context menu popover")
        let app = launch(["-dc-sample", "-dc-forums-home"], orientation: .landscapeLeft)
        let home = any(app, "forumsHome")
        XCTAssertTrue(waitOrDump(home, timeout: 20, in: app))
        let tiles = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'pinnedForum-'"))
        let tile = tiles.firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        let identifier = tile.identifier

        tile.press(forDuration: 1.2)
        let remove = app.buttons["Remove…"]
        XCTAssertTrue(waitOrDump(remove, timeout: 5, in: app), "The tile's context menu has no Remove….")
        snapshot("remove-context-menu")
        remove.tap()
        let confirm = app.buttons["Remove Forum"]
        XCTAssertTrue(waitOrDump(confirm, timeout: 5, in: app), "The removal dialog did not appear.")
        snapshot("remove-dialog")
        confirm.tap()
        XCTAssertTrue(waitForGone(any(app, identifier), timeout: 5), "\(identifier) was not removed.")
    }

    // MARK: Helpers

    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["DC_SCREENSHOT_DIR"] {
            let device = UIDevice.current.name.replacingOccurrences(of: " ", with: "_")
            let url = URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(name).png")
            try? shot.pngRepresentation.write(to: url)
        }
    }
}
