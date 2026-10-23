import XCTest
@testable import Forumind

/// What stays in the snapshot (SessionRetention.swift) and how it is
/// written (PersistentStore's background writer).
@MainActor
final class SessionRetentionTests: XCTestCase {
    private let site = "https://forum.example.com"
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: The plan

    func testOnlyUnprotectedSessionsOverTheirLimitsOrUncitedAgentReadsGo() {
        var sessions: [TopicSession] = []
        // 42 summaries: the two oldest go.
        for index in 0..<42 {
            var value = session("s\(index)", minutesAgo: Double(index))
            value.summary = "Summary"
            sessions.append(value)
        }
        // 62 visits without a summary: the two least recently opened go.
        for index in 0..<62 {
            var value = session("v\(index)", minutesAgo: 1)
            value.openedByUserAt = now.addingTimeInterval(-Double(index) * 60)
            sessions.append(value)
        }
        // Agent reads: uncited goes; cited and old loses its pages; cited and fresh stays whole.
        var uncited = session("a-uncited", minutesAgo: 5)
        uncited.rawPages = [RawForumPage(page: 1, content: "raw")]
        var citedOld = session("a-old", minutesAgo: 60 * 25)
        citedOld.rawPages = [RawForumPage(page: 1, content: "raw")]
        citedOld.source = "text"
        var citedFresh = session("a-fresh", minutesAgo: 60)
        citedFresh.rawPages = [RawForumPage(page: 1, content: "raw")]
        // Never: kept, chat, instructions, protected (open, watched, working).
        var kept = session("kept", minutesAgo: 9_999)
        kept.kept = true
        var chat = session("chat", minutesAgo: 9_999)
        chat.history = [ChatMessage(role: .user, content: "Q")]
        var instructions = session("instructions", minutesAgo: 9_999)
        instructions.instructions = "Be brief"
        let open = session("open", minutesAgo: 9_999)
        sessions += [uncited, citedOld, citedFresh, kept, chat, instructions, open]

        let plan = SessionRetention.plan(
            sessions: Dictionary(uniqueKeysWithValues: sessions.map { ($0.topicKey, $0) }),
            protected: [key("open")],
            citedByRuns: [key("a-old"), key("a-fresh")],
            now: now
        )
        XCTAssertEqual(plan.remove, [key("a-uncited"), key("s40"), key("s41"), key("v60"), key("v61")].sorted())
        XCTAssertEqual(plan.dropPages, [key("a-old")])
    }

    func testAgentRunsCiteTheTopicsTheyReadAndTheirSteps() {
        var run = AgentRun(siteURL: site, goal: "Q", provider: .ollama, model: "m")
        run.topicIDs = ["1"]
        var step = AgentStep(tool: "read_topic")
        step.topicKey = key("2")
        run.steps = [step]
        XCTAssertEqual(SessionRetention.topicKeys(citedBy: [run]), [key("1"), key("2")])
    }

    /// Launch prunes what an earlier version left (agent reads that no run
    /// cites), and nothing else.
    func testLaunchPrunesLeftoverAgentReads() throws {
        var visited = session("1", minutesAgo: 10)
        visited.openedByUserAt = now
        let agentRead = session("2", minutesAgo: 10)
        let watched = session("3", minutesAgo: 10)
        let store = makeStore()
        try store.save(AppSnapshot(
            sessions: [visited, agentRead, watched],
            watchedTopics: [WatchedTopic(siteURL: site, topicID: "3", url: watched.url, title: "3", knownPostCount: 1)]
        ))
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        XCTAssertEqual(Set(app.sessions.keys), [key("1"), key("3")])
    }

    // MARK: The writer

    /// Saves made faster than the disk keeps up land in order, the newest
    /// last; a relaunch (a new store on the same file) reads it.
    func testBackgroundWritesCoalesceAndTheNewestLands() throws {
        let store = makeStore()
        for index in 0..<200 {
            store.scheduleSave(AppSnapshot(sessions: [session("\(index)", minutesAgo: 0)])) { error in
                XCTFail("\(error)")
            }
        }
        XCTAssertEqual(store.saveCount, 200)
        store.flush()
        let relaunched = PersistentStore(fileURL: store.directoryURL.appendingPathComponent("state.json"))
        XCTAssertEqual(relaunched.load().sessions.map(\.topicID), ["199"])
    }

    /// The app's saves are on disk once it leaves the foreground.
    func testLeavingTheForegroundFlushesTheSnapshot() throws {
        let store = makeStore()
        let app = AppModel(store: store)
        app.browser.onPageContextChanged = nil
        app.select(topic: ForumTopic(siteURL: site, topicID: "5", url: URL(string: "\(site)/t/five/5")!, title: "Five"))
        app.handleScenePhase(.background)
        let relaunched = PersistentStore(fileURL: store.directoryURL.appendingPathComponent("state.json"))
        XCTAssertEqual(relaunched.load().sessions.map(\.topicID), ["5"])
    }

    // MARK: Helpers

    private func key(_ id: String) -> String { TopicIdentity.key(siteURL: site, topicID: id) }

    private func session(_ id: String, minutesAgo: Double) -> TopicSession {
        var value = TopicSession(siteURL: site, topicID: id, url: URL(string: "\(site)/t/\(id)")!, title: id)
        value.updatedAt = now.addingTimeInterval(-minutesAgo * 60)
        return value
    }

    private func makeStore() -> PersistentStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
    }
}
