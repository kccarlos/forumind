import XCTest
@testable import Forumind

/// iPad workspace rules: split threshold with hysteresis, panel width
/// clamping, and web content crash recovery.
@MainActor
final class IPadLayoutTests: XCTestCase {
    /// Window widths from iPad multitasking: Slide Over / 1/3 (320), 1/2 on
    /// 11" (507), 1/2 on 13" (678), mini portrait (744), Air 11 portrait
    /// (820), Pro 11 portrait (834), 13" portrait (1032), 13" landscape (1366).
    func testFreshWindowsUseTheLayoutTheirWidthImplies() {
        for width: CGFloat in [320, 507, 678, 744, 820, 834] {
            XCTAssertFalse(WorkspaceMetrics.nextIsSplit(current: nil, width: width, idiom: .pad), "\(width)")
        }
        for width: CGFloat in [850, 981, 1_032, 1_180, 1_366] {
            XCTAssertTrue(WorkspaceMetrics.nextIsSplit(current: nil, width: width, idiom: .pad), "\(width)")
        }
        XCTAssertFalse(WorkspaceMetrics.nextIsSplit(current: nil, width: 1_366, idiom: .phone))
    }

    func testResizingNearTheThresholdDoesNotFlap() {
        // Split stays split down to the exit width…
        XCTAssertTrue(WorkspaceMetrics.nextIsSplit(current: true, width: 845, idiom: .pad))
        XCTAssertTrue(WorkspaceMetrics.nextIsSplit(current: true, width: 830, idiom: .pad))
        XCTAssertFalse(WorkspaceMetrics.nextIsSplit(current: true, width: 829, idiom: .pad))
        // …and single pane needs the full threshold to split again.
        XCTAssertFalse(WorkspaceMetrics.nextIsSplit(current: false, width: 845, idiom: .pad))
        XCTAssertTrue(WorkspaceMetrics.nextIsSplit(current: false, width: 850, idiom: .pad))
        // Rotating an Air 11 (1180 ↔ 820) always switches.
        XCTAssertFalse(WorkspaceMetrics.nextIsSplit(current: true, width: 820, idiom: .pad))
        XCTAssertTrue(WorkspaceMetrics.nextIsSplit(current: false, width: 1_180, idiom: .pad))
        // The band holds no real iPad window width (Pro 11 portrait is 834).
        XCTAssertGreaterThan(834, WorkspaceMetrics.splitExitWidth)
    }

    func testPanelWidthIsClampedToTheWindowAndRange() {
        // Default: 40% of the window within 360…560.
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: nil, containerWidth: 1_032), 412.8, accuracy: 0.1)
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: nil, containerWidth: 1_366), 546.4, accuracy: 0.1)
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: nil, containerWidth: 850), DCTheme.panelMinimumWidth)
        // A chosen width is kept, but the page keeps its minimum room…
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: 540, containerWidth: 1_366), 540)
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: 540, containerWidth: 900), 439)
        // …and the range holds at both ends.
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: 900, containerWidth: 1_366), DCTheme.panelMaximumWidth)
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: 100, containerWidth: 1_366), DCTheme.panelMinimumWidth)
        XCTAssertEqual(WorkspaceMetrics.panelWidth(preferred: 540, containerWidth: 700), DCTheme.panelMinimumWidth)
    }

    func testWebContentCrashReloadsOnceThenShowsTheBanner() {
        let browser = ForumBrowserModel()
        let start = Date()
        browser.handleWebContentTermination(now: start)
        XCTAssertFalse(browser.showsCrashNotice, "No page loaded: nothing to reload or report.")

        browser.load(URL(string: "https://meta.discourse.org/latest")!)
        let later = start.addingTimeInterval(ForumBrowserModel.crashReloadWindow + 1)
        browser.handleWebContentTermination(now: later)
        XCTAssertFalse(browser.showsCrashNotice, "The first crash reloads quietly.")

        browser.handleWebContentTermination(now: later.addingTimeInterval(5))
        XCTAssertTrue(browser.showsCrashNotice, "A second crash soon after shows the banner instead of looping.")
        XCTAssertFalse(browser.isLoading, "The bar must not keep a spinning Stop button.")

        browser.retryAfterCrash()
        XCTAssertFalse(browser.showsCrashNotice)
        browser.webView.stopLoading()
    }
}
