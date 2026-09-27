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
        // The Forums home sync card would shift the rows these flows use.
        app.launchArguments = (wantsOnboarding ? [] : ["-dc-skip-onboarding"]) + ["-dc-no-sync-prompt"] + arguments
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

    /// A current topic on meta.discourse.org (skips when offline).
    func liveTopic() throws -> (url: URL, title: String, id: Int) {
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
                  let url = URL(string: "https://\(Self.forumHost)/t/\(slug)/\(id)")
            else { continue }
            return (url, title, id)
        }
        throw XCTSkip("No topic found on \(Self.forumHost).")
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

    /// In the single-pane layout, switches to the Assistant workspace.
    func showAssistant(in app: XCUIApplication) {
        let workspace = app.segmentedControls["workspacePicker"]
        if workspace.waitForExistence(timeout: 5) {
            workspace.buttons["Assistant"].tap()
        }
    }

    /// In the single-pane layout, switches to the Browse workspace.
    func showBrowser(in app: XCUIApplication) {
        let workspace = app.segmentedControls["workspacePicker"]
        if workspace.exists {
            workspace.buttons["Browse"].tap()
        }
    }

    /// On compact widths the home, account and sign-in controls live behind
    /// the browser's More menu.
    func openBrowserMenuIfCompact(in app: XCUIApplication) {
        let menu = app.buttons["browserMoreMenu"]
        if isPhone, menu.waitForExistence(timeout: 10) {
            menu.tap()
        }
    }

    func dismissMenu(in app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
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
