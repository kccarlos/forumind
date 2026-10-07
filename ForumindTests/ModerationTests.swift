import XCTest
@testable import Forumind

/// Guideline 1.2 moderation: blocking, word filters, the developer's list,
/// reports, and the Terms of Use setting.
@MainActor
final class ModerationTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let other = "https://other.example.org"

    private let raw = """
    alice | 2026-01-01 10:00:00 UTC | #1

    Welcome to the topic.

    -------------------------

    Bob | 2026-01-01 11:00:00 UTC | #2

    This is spam, buy now.

    -------------------------

    carol | 2026-01-01 12:00:00 UTC | #3

    A helpful reply.

    -------------------------
    """

    // MARK: Filter

    func testNoRulesLeavesTheTextAlone() {
        XCTAssertEqual(ModerationFilter.filter(raw, siteURL: site, topicID: "1", rules: .none), raw)
    }

    func testBlockedUsersPostsAreRemovedOnTheirForumOnly() {
        let rules = ModerationRules(blockedUsers: [site: ["bob"]])
        let filtered = ModerationFilter.filter(raw, siteURL: site, topicID: "1", rules: rules)
        XCTAssertFalse(filtered.contains("buy now"))
        XCTAssertFalse(filtered.contains("Bob |"))
        XCTAssertTrue(filtered.contains("Welcome to the topic."))
        XCTAssertTrue(filtered.contains("A helpful reply."))
        // Another forum's Bob is someone else.
        XCTAssertEqual(ModerationFilter.filter(raw, siteURL: other, topicID: "1", rules: rules), raw)
    }

    func testFilteredWordsRemoveMatchingPostsCaseInsensitively() {
        let rules = ModerationRules(filteredWords: ModerationRules.normalizedWords(["  SPAM ", "spam", ""]))
        XCTAssertEqual(rules.filteredWords, ["spam"])
        let filtered = ModerationFilter.filter(raw, siteURL: site, topicID: "1", rules: rules)
        XCTAssertFalse(filtered.contains("buy now"))
        XCTAssertTrue(filtered.contains("A helpful reply."))
    }

    func testDevelopersListHidesPostsAndUsersEverywhere() {
        let list = RemoteModerationList(
            users: [RemoteModerationList.User(site: nil, username: "Carol")],
            posts: [RemoteModerationList.Post(site: site + "/", topic: 7, post: 1)]
        )
        let rules = ModerationRules(settings: AppSettings(), remote: list)
        let filtered = ModerationFilter.filter(raw, siteURL: site, topicID: "7", rules: rules)
        XCTAssertFalse(filtered.contains("Welcome to the topic."), "Post #1 of topic 7 is on the list.")
        XCTAssertFalse(filtered.contains("A helpful reply."), "Carol is hidden on every forum.")
        XCTAssertTrue(filtered.contains("buy now"))
        // Post #1 of another topic stays.
        XCTAssertTrue(ModerationFilter.filter(raw, siteURL: site, topicID: "8", rules: rules).contains("Welcome"))
    }

    func testTextThatIsNotRawIsHiddenOnlyForAFilteredWord() {
        let rules = ModerationRules(filteredWords: ["spam"])
        XCTAssertEqual(ModerationFilter.filter("just text", siteURL: site, topicID: "1", rules: rules), "just text")
        XCTAssertEqual(ModerationFilter.filter("some spam here", siteURL: site, topicID: "1", rules: rules), "")
    }

    func testRemoteListDecodesWithMissingKeys() throws {
        let list = try JSONDecoder().decode(RemoteModerationList.self, from: Data(#"{"users":[{"username":"x"}]}"#.utf8))
        XCTAssertEqual(list.users, [RemoteModerationList.User(site: nil, username: "x")])
        XCTAssertTrue(list.posts.isEmpty)
        XCTAssertTrue(list.words.isEmpty)
    }

    // MARK: Browser script config

    func testScriptConfigCoversTheCurrentForumOnly() {
        let rules = ModerationRules(
            blockedUsers: [site: ["bob"], other: ["dave"]],
            filteredWords: ["spam"],
            globallyHiddenUsers: ["eve"],
            hiddenPosts: ["\(site)|7": [3, 1], "\(other)|7": [2]]
        )
        let config = ModerationScript.config(rules: rules, siteURL: site)
        XCTAssertEqual(config.users, ["bob", "eve"])
        XCTAssertEqual(config.words, ["spam"])
        XCTAssertEqual(config.posts, ["7": [1, 3]])
        XCTAssertEqual(ModerationScript.config(rules: rules, siteURL: nil).users, ["eve"])
    }

    // MARK: Reports

    func testReportEmailNamesThePostAndReason() throws {
        let target = ReportTarget(
            siteURL: site,
            forumName: "Example",
            topicTitle: "A topic",
            topicURL: URL(string: "https://forum.example.com/t/a-topic/42/9?u=me"),
            kind: .post(number: 3, username: "bob")
        )
        let subject = ModerationReport.subject(for: target, blocked: false)
        XCTAssertEqual(subject, "Forumind report: post #3 by @bob on forum.example.com")
        let body = ModerationReport.body(for: target, reason: .harassment, note: " rude ", blocked: false, appVersion: "1.0 (1)")
        XCTAssertTrue(body.contains("Post URL: https://forum.example.com/t/a-topic/42/3"))
        XCTAssertTrue(body.contains("Reason: harassment"))
        XCTAssertTrue(body.contains("Details:\nrude"))
        XCTAssertTrue(ModerationReport.subject(for: target, blocked: true).hasPrefix("Forumind block:"))

        let mailto = try XCTUnwrap(ModerationReport.mailtoURL(subject: subject, body: body))
        XCTAssertEqual(mailto.scheme, "mailto")
        XCTAssertTrue(mailto.absoluteString.hasPrefix("mailto:\(ModerationTerms.reportEmail)?subject="))
    }

    func testPostURLKeepsTheTopicPathOnly() {
        let url = { (string: String) in URL(string: string)! }
        XCTAssertEqual(
            ModerationReport.postURL(topicURL: url("https://f.example/t/slug/42"), number: 5).absoluteString,
            "https://f.example/t/slug/42/5"
        )
        XCTAssertEqual(
            ModerationReport.postURL(topicURL: url("https://f.example/forum/t/slug/42/17/"), number: 5).absoluteString,
            "https://f.example/forum/t/slug/42/5"
        )
    }

    // MARK: Settings and sync

    func testOlderSettingsDecodeWithNoBlocksAndNoAcceptedTerms() throws {
        let data = try JSONEncoder().encode(AppSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["blockedUsers", "filteredWords", "acceptedTermsVersion"] { object.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(decoded.blockedUsers.isEmpty)
        XCTAssertTrue(decoded.filteredWords.isEmpty)
        XCTAssertFalse(decoded.hasAcceptedCurrentTerms)
    }

    func testBlocksSyncButTermsAcceptanceStaysOnTheDevice() throws {
        var settings = AppSettings()
        settings.blockedUsers = [BlockedUser(siteURL: site, username: "bob")]
        settings.filteredWords = ["spam"]
        settings.acceptedTermsVersion = ModerationTerms.currentVersion
        let units = try SyncSchema.settingsUnits(settings)
        XCTAssertNotNil(units["blockedUsers"])
        XCTAssertNotNil(units["filteredWords"])
        XCTAssertNil(units["acceptedTermsVersion"])
        XCTAssertTrue(SyncSettings.deviceLocalKeys.contains("acceptedTermsVersion"))
    }

    func testBlockingFiltersPromptsAndSurvivesAReset() throws {
        let app = makeApp()
        app.block("@Bob ", on: site)
        app.block("bob", on: site)
        XCTAssertEqual(app.settings.blockedUsers.map(\.username), ["Bob"], "Blocking twice keeps one entry.")
        XCTAssertTrue(app.isBlocked("BOB", on: site))
        XCTAssertFalse(app.moderated(raw, siteURL: site, topicID: "1").contains("buy now"))
        XCTAssertTrue(app.browser.moderationRules.hidesUser("bob", siteURL: site), "The browser gets the new rules.")

        XCTAssertTrue(app.addFilteredWord("helpful"))
        XCTAssertFalse(app.addFilteredWord("HELPFUL"))
        XCTAssertFalse(app.moderated(raw, siteURL: site, topicID: "1").contains("A helpful reply."))

        app.acceptTerms()
        app.resetSettings()
        XCTAssertTrue(app.isBlocked("bob", on: site))
        XCTAssertEqual(app.settings.filteredWords, ["helpful"])
        XCTAssertFalse(app.needsTermsAcceptance)

        app.unblock(try XCTUnwrap(app.settings.blockedUsers.first))
        app.removeFilteredWords(atOffsets: [0])
        XCTAssertEqual(app.moderated(raw, siteURL: site, topicID: "1"), raw)
    }

    func testNewInstallsMustAcceptTheTerms() {
        let app = makeApp()
        XCTAssertTrue(app.needsTermsAcceptance)
        app.acceptTerms()
        XCTAssertFalse(app.needsTermsAcceptance)
        XCTAssertEqual(app.settings.acceptedTermsVersion, ModerationTerms.currentVersion)
    }

    private func makeApp() -> AppModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moderation-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = PersistentStore(
            fileURL: directory.appendingPathComponent("state.json"),
            keys: InMemoryProviderKeyStore()
        )
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        return app
    }
}
