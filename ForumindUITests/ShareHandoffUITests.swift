import XCTest

/// The share extension hands pages to the app as
/// `forumind://open?url=…&action=open|summary|chat|agent`
/// (IncomingLink.swift). These tests open that link in the running app.
final class ShareHandoffUITests: DCUITestCase {
    func testSummaryLinkOpensTopicAndAsksForAProvider() throws {
        let topic = try liveTopic()
        let app = launchForHandoff()
        try skipIfProviderConfigured(in: app)

        app.open(deepLink(topic.url, action: "summary"))

        // Once the shared topic is detected the Assistant asks for a
        // provider instead of starting a summary.
        let setupSheet = app.navigationBars["Connect an AI provider"]
        guard setupSheet.waitForExistence(timeout: 45) else {
            attachTree(app)
            XCTFail("The provider setup prompt did not appear for a shared summary.")
            return
        }
        XCTAssertTrue(setupSheet.buttons["Later"].exists)
        XCTAssertFalse(setupSheet.buttons["Done"].isEnabled, "Done needs a configured provider.")
        setupSheet.buttons["Later"].tap()
        XCTAssertTrue(waitForGone(setupSheet, timeout: 10))

        // The AI view (the drawer, or the panel in the split layout) shows.
        XCTAssertTrue(
            any(app, usesDrawerLayout(app) ? "drawerHeader" : "aiPanel").waitForExistence(timeout: 10),
            "The Assistant did not appear."
        )
        XCTAssertTrue(any(app, "providerSetupCard").waitForExistence(timeout: 10))
        XCTAssertTrue(any(app, "assistantTopicTitle").waitForExistence(timeout: 10), "No topic is selected.")
        XCTAssertFalse(any(app, "summaryContent").exists, "No summary may start without a provider.")

        // The browser shows the shared topic.
        showBrowser(in: app)
        XCTAssertTrue(
            waitOrDump(address(containing: "/\(topic.id)", in: app), timeout: 10, in: app),
            "The browser did not open the shared topic \(topic.url)."
        )
    }

    func testChatLinkOpensTheChatMode() throws {
        let topic = try liveTopic()
        let app = launchForHandoff()
        try skipIfProviderConfigured(in: app)

        app.open(deepLink(topic.url, action: "chat"))

        let setupSheet = app.navigationBars["Connect an AI provider"]
        guard setupSheet.waitForExistence(timeout: 60) else {
            attachTree(app)
            XCTFail("The provider setup prompt did not appear for a shared chat.")
            return
        }
        setupSheet.buttons["Later"].tap()
        // The drawer and the panel show the summary and the conversation
        // together; the chat input is pinned at the bottom.
        XCTAssertTrue(any(app, "chatInput").waitForExistence(timeout: 10), "The AI view has no chat input.")
    }

    func testOpenLinkOnlyLoadsThePage() throws {
        try requireNetwork()
        let app = launchForHandoff()

        guard let url = URL(string: "https://\(Self.forumHost)/top") else { return }
        app.open(deepLink(url, action: "open"))

        XCTAssertTrue(
            waitOrDump(address(containing: "\(Self.forumHost)/top", in: app), timeout: 30, in: app),
            "The shared page did not load."
        )
        XCTAssertFalse(any(app, "home").exists)
        // "open" never switches to the Assistant or asks for a provider.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertFalse(app.navigationBars["Connect an AI provider"].exists)
        if usesDrawerLayout(app) {
            XCTAssertFalse(drawerState(in: app).exists, "An open link must not open the AI drawer.")
        }
    }

    // MARK: Helpers

    /// `XCUIApplication.open(_:)` may relaunch the app with the same launch
    /// arguments, so these tests pass none that load a page (`-dc-open`) or
    /// show the Forums home later (`-dc-forums-home`): either would replace
    /// the shared page.
    private func launchForHandoff() -> XCUIApplication {
        let app = launch()
        XCTAssertTrue(app.buttons["forumSwitcher"].waitForExistence(timeout: 20))
        return app
    }

    private func deepLink(_ page: URL, action: String) -> URL {
        var components = URLComponents()
        components.scheme = "forumind"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "url", value: page.absoluteString),
            URLQueryItem(name: "action", value: action)
        ]
        return components.url!
    }

    /// These tests must never start real AI work: skip when a key is saved.
    private func skipIfProviderConfigured(in app: XCUIApplication) throws {
        openSettings(in: app)
        let providerRow = app.buttons["settingsRow-provider"]
        XCTAssertTrue(providerRow.waitForExistence(timeout: 10))
        let ready = app.descendants(matching: .any)
            .matching(label(contains: "Provider ready")).firstMatch
        let configured = ready.exists || providerRow.label.contains("Provider ready")
        closeSettings(in: app)
        if configured {
            throw XCTSkip("An AI provider is configured on this simulator; skipping to avoid real AI calls.")
        }
    }
}
