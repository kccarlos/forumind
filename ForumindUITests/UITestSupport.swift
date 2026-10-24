import UIKit
import XCTest

/// Shared launch helpers and waits for the Forumind UI tests.
///
/// The app keeps its state (`Application Support/Forumind/state.json`) between
/// launches, so tests never assume a clean slate: they pass DEBUG launch
/// arguments (see `AppModel+Onboarding.swift`, `AppModel+Browse.swift`,
/// `AppModel+Assistant.swift`) and undo what they change.
class DCUITestCase: XCTestCase {
    /// A Discourse forum that is reachable without an account.
    static let forumLatest = "https://meta.discourse.org/latest"
    static let forumHost = "meta.discourse.org"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: Launch

    /// Launches the app past the walkthrough unless the
    /// arguments ask for the walkthrough.
    @discardableResult
    func launch(
        _ arguments: [String] = [],
        orientation: UIDeviceOrientation = .portrait
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        let wantsOnboarding = arguments.contains("-dc-reset")
            || arguments.contains("-dc-onboarding-step")
        app.launchArguments = (wantsOnboarding ? [] : ["-dc-skip-onboarding"]) + arguments
        app.launch()
        return app
    }

    /// Launches on a live Discourse page (skips when the forum is offline).
    @discardableResult
    func launchOnForum(
        _ url: String = DCUITestCase.forumLatest,
        extra: [String] = [],
        orientation: UIDeviceOrientation = .portrait
    ) throws -> XCUIApplication {
        try requireNetwork()
        return launch(["-dc-open", url] + extra, orientation: orientation)
    }

    // MARK: Device

    var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// The bottom bar and the AI drawer: iPhone, and iPad windows narrower
    /// than 850 pt. (The iPad split layout has the top bar and the panel.)
    func usesDrawerLayout(_ app: XCUIApplication) -> Bool {
        isPhone || app.windows.firstMatch.frame.width < 850
    }

    func skipUnlessPad(_ reason: String) throws {
        if isPhone { throw XCTSkip(reason) }
    }

    func skipUnlessPhone(_ reason: String) throws {
        if !isPhone { throw XCTSkip(reason) }
    }

    // MARK: Network

    /// Skips the test when meta.discourse.org can't be reached from the host.
    func requireNetwork() throws {
        guard let url = URL(string: "https://\(Self.forumHost)/site/basic-info.json") else { return }
        if fetch(url) == nil {
            throw XCTSkip("\(Self.forumHost) is unreachable; this test needs the network.")
        }
    }

    /// A current topic on meta.discourse.org with at least `minimumPosts`
    /// posts (skips when offline).
    func liveTopic(minimumPosts: Int = 1) throws -> (url: URL, title: String, id: Int) {
        guard let listURL = URL(string: "https://\(Self.forumHost)/latest.json"),
              let data = fetch(listURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["topic_list"] as? [String: Any],
              let topics = list["topics"] as? [[String: Any]]
        else {
            throw XCTSkip("\(Self.forumHost) is unreachable; this test needs the network.")
        }
        for topic in topics {
            guard let id = topic["id"] as? Int,
                  let slug = topic["slug"] as? String,
                  let title = topic["title"] as? String,
                  topic["pinned"] as? Bool != true,
                  topic["posts_count"] as? Int ?? 1 >= minimumPosts,
                  let url = URL(string: "https://\(Self.forumHost)/t/\(slug)/\(id)")
            else { continue }
            return (url, title, id)
        }
        throw XCTSkip("No topic found on \(Self.forumHost).")
    }

    /// The post numbers of a live topic's first regular posts (deleted
    /// posts leave gaps in the numbering; small actions are skipped).
    func livePostNumbers(topicID: Int) throws -> [Int] {
        guard let url = URL(string: "https://\(Self.forumHost)/t/\(topicID).json"),
              let data = fetch(url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stream = json["post_stream"] as? [String: Any],
              let posts = stream["posts"] as? [[String: Any]]
        else {
            throw XCTSkip("\(Self.forumHost) is unreachable; this test needs the network.")
        }
        return posts.compactMap { post in
            post["post_type"] as? Int == 1 ? post["post_number"] as? Int : nil
        }
    }

    private func fetch(_ url: URL, timeout: TimeInterval = 10) -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let done = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                result = data
            }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return result
    }

    // MARK: Navigation

    /// Shows the assistant: the AI drawer (from the bar's AI button, at
    /// medium) or, in the split layout, the AI panel.
    func showAssistant(in app: XCUIApplication) {
        if !usesDrawerLayout(app) {
            let toggle = app.buttons["aiPanelToggle"]
            if !any(app, "aiPanel").exists, toggle.waitForExistence(timeout: 5) { toggle.tap() }
            return
        }
        let state = drawerState(in: app)
        if state.waitForExistence(timeout: 3) {
            if state.label == "detent=peek" { dragDrawer(in: app, to: 0.45) }
            return
        }
        let button = app.buttons["aiButton"]
        if waitForBarItem(button, timeout: 10) { tapBarItem(button) }
        _ = state.waitForExistence(timeout: 10)
    }

    /// Shows the page: on iPhone closes the AI drawer (a sample launch opens
    /// it on its own shortly after launch); in the iPad single-pane layout
    /// the Browse workspace.
    func showBrowser(in app: XCUIApplication) {
        if usesDrawerLayout(app) { closeDrawer(in: app) }
    }

    // MARK: AI drawer (iPhone)

    /// DEBUG readout inside the drawer: `detent=peek|medium|large`. Gone
    /// while the drawer is closed.
    func drawerState(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["drawerState"].firstMatch
    }

    /// Drags the drawer by its header to a point of the screen's height
    /// (0 top … 1 bottom).
    func dragDrawer(in app: XCUIApplication, to y: CGFloat) {
        let header = app.descendants(matching: .any)["drawerHeader"].firstMatch
        guard header.waitForExistence(timeout: 5) else { return }
        // On the title, clear of the model pill (a press on it opens its menu).
        let start = header.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: y))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    /// Swipes the drawer down until it closes (large and medium only go
    /// down a height; from the peek it closes).
    func closeDrawer(in app: XCUIApplication) {
        let state = drawerState(in: app)
        guard state.waitForExistence(timeout: 3) else { return }
        for _ in 0..<4 where state.exists {
            dragDrawer(in: app, to: 0.99)
        }
        XCTAssertTrue(waitForGone(state, timeout: 5), "The AI drawer did not close.")
    }

    /// Settings: on iPhone from the forum menu (a sheet); in the iPad
    /// layouts inside the assistant panel.
    func openSettings(in app: XCUIApplication) {
        if usesDrawerLayout(app) { closeDrawer(in: app) }
        openForumMenu(in: app)
        let item = app.buttons["Settings"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Settings is missing from the forum menu.")
        item.tap()
    }

    /// Leaves Settings opened with `openSettings(in:)` (from its root list).
    func closeSettings(in app: XCUIApplication) {
        if usesDrawerLayout(app) {
            let done = app.navigationBars.buttons["Done"].firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 10))
            done.tap()
            return
        }
        let back = app.buttons["backToTopic"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        showBrowser(in: app)
    }

    /// On iPhone the home, account, sign-in and page controls live in the
    /// forum menu (the bar's avatar).
    func openBrowserMenuIfCompact(in app: XCUIApplication) {
        openForumMenu(in: app)
    }

    /// iPhone: taps the bar's forum avatar to open the forum menu.
    func openForumMenu(in app: XCUIApplication) {
        let avatar = app.buttons["forumSwitcher"]
        if !waitForBarItem(avatar, timeout: 15) { attachTree(app) }
        XCTAssertTrue(avatar.exists, "The bar has no forum avatar.")
        tapBarItem(avatar)
        _ = app.buttons["switcherAllForums"].waitForExistence(timeout: 5)
    }

    /// The Forums home: on iPhone the forum menu's Home item; on iPad the
    /// switcher's All forums.
    func openForumsHomeFromSwitcher(in app: XCUIApplication) {
        openForumMenu(in: app)
        let item = app.buttons["Home · Today & all forums"]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Home is missing from the forum menu.")
        item.tap()
    }

    /// From a launch with `-dc-forums-home` to Home with the browser pane
    /// in front (iPad samples open on the Assistant in one pane).
    @discardableResult
    func openHome(in app: XCUIApplication) -> XCUIElement {
        let home = any(app, "home")
        if !home.waitForExistence(timeout: 15) { showBrowser(in: app) }
        if !home.waitForExistence(timeout: 10) { openForumsHomeFromSwitcher(in: app) }
        XCTAssertTrue(home.waitForExistence(timeout: 10), "Home did not appear.")
        showBrowser(in: app)
        return home
    }

    /// iPhone menus open up from the bottom bar, so tap above them.
    func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: usesDrawerLayout(app) ? 0.12 : 0.95)).tap()
    }

    /// Taps a Settings sub-page's back button (titled after the root).
    func tapNavigationBack(in app: XCUIApplication) {
        let back = app.navigationBars.buttons["Settings"].firstMatch
        if back.waitForExistence(timeout: 5) {
            back.tap()
        } else {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    // MARK: iPhone bar

    /// Items in the iPhone's system toolbar report `isHittable == false` (the
    /// toolbar element spans the window), so wait until one is on screen
    /// and tap it by coordinate.
    func waitForBarItem(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        wait(timeout: timeout) {
            guard element.exists else { return false }
            let frame = element.frame
            return frame.width > 0 && frame.height > 0 && frame.minY >= 0
                && frame.maxY <= XCUIApplication().windows.firstMatch.frame.maxY + 1
        }
    }

    func tapBarItem(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func pressBarItem(_ element: XCUIElement, duration: TimeInterval) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: duration)
    }

    // MARK: Waits

    /// Lists realize rows lazily; scroll until the element exists and is
    /// hittable (up to a few screens).
    @discardableResult
    func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 2), element.isHittable { return true }
        for _ in 0..<swipes where !(element.exists && element.isHittable) {
            app.swipeUp()
        }
        return element.waitForExistence(timeout: 5) && element.isHittable
    }

    func waitForGone(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { !element.exists }
    }

    func waitForHittable(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        wait(timeout: timeout) { element.exists && element.isHittable }
    }

    func wait(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// The browser bar's address (shown without the scheme; tap to edit).
    func address(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(label(contains: text)).firstMatch
    }

    func any(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func label(contains text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@", text)
    }

    func attachText(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func attachTree(_ app: XCUIApplication, named name: String = "Accessibility tree") {
        let tree = app.debugDescription
        attachText(tree, named: name)
        print("ACCESSIBILITY-TREE-BEGIN \(name)\n\(tree)\nACCESSIBILITY-TREE-END")
    }

    /// `waitForExistence` that records the accessibility tree when it fails.
    func waitOrDump(
        _ element: XCUIElement,
        timeout: TimeInterval,
        in app: XCUIApplication
    ) -> Bool {
        if element.waitForExistence(timeout: timeout) { return true }
        attachTree(app)
        return false
    }
}
