import XCTest

/// iPad layout: rotation across the split threshold, the panel resize
/// handle, hardware-keyboard shortcuts, and removing a pinned forum from its
/// context menu. Uses `-dc-sample` (offline data; nothing is saved).
///
/// Set `TEST_RUNNER_DC_SCREENSHOT_DIR=/some/dir` on `xcodebuild` to also
/// write each screenshot there.
final class IPadLayoutUITests: DCUITestCase {
    private let sample = ["-dc-sample", "-dc-page-state", "topic"]

    // MARK: Width decides the layout

    /// Landscape (≥ 850 pt) is page + AI panel under the split bar; portrait
    /// (< 850 pt) is the iPhone layout, bottom bar and drawer, on iPad too.
    func testWidthDecidesTheLayoutAcrossRotation() throws {
        try skipUnlessPad("iPad layout")
        let app = launch(sample, orientation: .landscapeLeft)
        let panel = any(app, "aiPanel")
        XCTAssertTrue(waitOrDump(panel, timeout: 20, in: app), "Landscape should show the AI panel beside the page.")
        XCTAssertTrue(app.buttons["aiPanelToggle"].exists, "The split bar has the panel toggle.")
        XCTAssertTrue(any(app, "panelResizeHandle").exists)
        XCTAssertFalse(app.buttons["aiButton"].exists, "The AI button belongs to the bottom bar.")
        snapshot("layout-1-landscape")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForGone(panel, timeout: 8), "Portrait (below 850 pt) should use the drawer layout.")
        XCTAssertFalse(app.buttons["aiPanelToggle"].exists)
        let ai = app.buttons["aiButton"]
        XCTAssertTrue(waitForBarItem(ai, timeout: 10), "Portrait should have the bottom bar's AI button.")
        snapshot("layout-2-portrait")
        tapBarItem(ai)
        XCTAssertTrue(drawerState(in: app).waitForExistence(timeout: 10), "The AI button should open the drawer on iPad portrait.")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "Rotating back should show the panel.")
        XCTAssertTrue(waitForGone(drawerState(in: app), timeout: 8), "The drawer gives way to the panel.")
        XCTAssertEqual(app.state, .runningForeground)
        snapshot("layout-3-landscape-again")
    }

    /// Rotating repeatedly with the drawer or the panel up never crashes.
    func testRotatingRepeatedlyKeepsTheAppRunning() throws {
        try skipUnlessPad("iPad layout")
        let app = launch(sample, orientation: .landscapeLeft)
        XCTAssertTrue(waitOrDump(any(app, "aiPanel"), timeout: 20, in: app))
        for _ in 0..<3 {
            XCUIDevice.shared.orientation = .portrait
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            XCUIDevice.shared.orientation = .landscapeRight
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        }
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(any(app, "aiPanel").waitForExistence(timeout: 10))
    }

    // MARK: Panel

    /// Home is full width with the panel collapsed; the toggle (and ⌥⌘0) hides
    /// and shows the panel on a page.
    func testPanelIsCollapsedOnHomeAndTogglesOnAPage() throws {
        try skipUnlessPad("iPad layout")
        var app = launch(["-dc-sample", "-dc-forums-home"], orientation: .landscapeLeft)
        XCTAssertTrue(waitOrDump(any(app, "home"), timeout: 20, in: app))
        XCTAssertFalse(any(app, "aiPanel").exists, "Home should be full width.")
        app.terminate()

        app = launch(sample, orientation: .landscapeLeft)
        let panel = any(app, "aiPanel")
        XCTAssertTrue(waitOrDump(panel, timeout: 20, in: app))
        let toggle = app.buttons["aiPanelToggle"]
        toggle.tap()
        XCTAssertTrue(waitForGone(panel, timeout: 5), "The toggle should hide the panel.")
        toggle.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "The toggle should show the panel again.")
    }

    /// §4.5 in the panel: summarize (the DEBUG fake summary), tap `#12` → the
    /// page scrolls to post 12 and marks it. Needs the live meta topic.
    func testCitationInThePanelJumpsThePage() throws {
        try skipUnlessPad("iPad layout")
        try requireNetwork()
        let app = launch(sample + ["-dc-no-summary", "-dc-fake-summary", "-dc-browse-debug"], orientation: .landscapeLeft)
        XCTAssertTrue(waitOrDump(any(app, "aiPanel"), timeout: 20, in: app))
        let summarize = app.buttons["createSummary"].firstMatch
        XCTAssertTrue(waitForHittable(summarize, timeout: 20), "Create summary is missing from the panel.")
        summarize.tap()
        let citation = app.buttons["citation-12"].firstMatch
        XCTAssertTrue(waitOrDump(citation, timeout: 30, in: app), "The summary has no #12 citation.")
        XCTAssertTrue(waitForHittable(citation))
        citation.tap()
        let browse = any(app, "browseDebugState")
        XCTAssertTrue(browse.waitForExistence(timeout: 10), "The browse state hook is missing.")
        XCTAssertTrue(wait(timeout: 40) {
            (browse.label.hasSuffix("top=12") || browse.label.hasSuffix("top=11")) && browse.label.contains("highlighted=12 ")
        }, "The page did not land on post 12: \(browse.label)")
    }

    /// Regression: animating the split change on top of the rotation made
    /// the Forums home List loop in UICollectionView self-sizing and crash.
    func testRotatingOnTheForumsHomeKeepsTheAppRunning() throws {
        try skipUnlessPad("iPad layout")
        let app = launch(["-dc-sample", "-dc-forums-home"], orientation: .landscapeLeft)
        let home = any(app, "home")
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
        let title = any(app, "drawerTitle")
        XCTAssertTrue(waitOrDump(title, timeout: 20, in: app))
        // Let the sample page finish loading: a topic change resets the mode.
        XCTAssertTrue(app.buttons.matching(label(contains: "meta.discourse.org")).firstMatch.waitForExistence(timeout: 20))
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        // In a fresh simulator session the first key events can be dropped
        // until a touch sequence has gone through UIKit; a double-tap on the
        // resize handle (resets the width) warms it up.
        any(app, "panelResizeHandle").doubleTap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        // ⌥⌘0 hides and shows the panel (the first key event can be dropped).
        let panel = any(app, "aiPanel")
        app.typeKey("0", modifierFlags: [.command, .option])
        if !waitForGone(panel, timeout: 2) { app.typeKey("0", modifierFlags: [.command, .option]) }
        XCTAssertTrue(waitForGone(panel, timeout: 3), "⌥⌘0 should hide the panel.")
        app.typeKey("0", modifierFlags: [.command, .option])
        XCTAssertTrue(panel.waitForExistence(timeout: 3), "⌥⌘0 should show the panel.")

        app.typeKey("l", modifierFlags: .command)
        let field = app.textFields["addressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘L should edit the address.")
        // (Esc isn't delivered by XCUITest's simulated keyboard; ⌘. is the
        // other cancel shortcut, so the Esc paths are checked with it.)
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(waitForGone(field, timeout: 5), "⌘. should leave the address unchanged.")

        app.typeKey("y", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.buttons["backToTopic"].waitForExistence(timeout: 5), "⇧⌘Y should show History in the panel.")
        app.buttons["backToTopic"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(any(app, "settingsRoot").waitForExistence(timeout: 5), "⌘, should open Settings.")
        snapshot("keyboard-settings")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Back should return to the assistant.")

        app.typeKey("h", modifierFlags: [.command, .shift])
        XCTAssertTrue(any(app, "home").waitForExistence(timeout: 5), "⌘⇧H should show the Forums home.")
        app.typeKey("[", modifierFlags: .command)
        XCTAssertTrue(waitForGone(any(app, "home"), timeout: 5), "⌘[ should go back to the page.")
    }

    // MARK: Forums home

    /// "Remove…" from a pinned tile's context menu shows the dialog after the
    /// menu closes, and "Remove Forum" removes the tile.
    func testRemovingAPinnedForumFromItsContextMenu() throws {
        try skipUnlessPad("iPad context menu popover")
        let app = launch(["-dc-sample", "-dc-forums-home"], orientation: .landscapeLeft)
        let home = any(app, "home")
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
