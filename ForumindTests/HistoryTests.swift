import XCTest
@testable import Forumind

/// History (spec §9.2): what each segment and forum filter shows, the grouping
/// by forum, and how an Ask run remembers where it started.
@MainActor
final class HistoryTests: XCTestCase {
    private let alpha = "https://alpha.example.org"
    private let beta = "https://beta.example.org"

    private func record(_ type: WorkType, site: String, id: String, status: WorkStatus = .running) -> WorkRecord {
        var record = WorkRecord(
            type: type,
            siteURL: site,
            topicID: id,
            title: "Work \(id)",
            url: URL(string: "\(site)/t/\(id)")!,
            provider: .ollama,
            model: "m"
        )
        record.status = status
        return record
    }

    private func session(site: String, id: String, kept: Bool = false, summary: String = "S", at: TimeInterval = 0) -> TopicSession {
        var session = TopicSession(siteURL: site, topicID: id, url: URL(string: "\(site)/t/\(id)")!, title: "Topic \(id)")
        session.summary = summary
        session.kept = kept
        session.updatedAt = Date(timeIntervalSince1970: at)
        return session
    }

    private func run(site: String, goal: String, origin: AgentRunOrigin = .typed) -> AgentRun {
        AgentRun(siteURL: site, goal: goal, provider: .ollama, model: "m", origin: origin)
    }

    private func feed(
        forum: String? = nil,
        activities: [WorkRecord] = [],
        sessions: [TopicSession] = [],
        runs: [AgentRun] = [],
        watched: [WatchedTopic] = []
    ) -> HistoryFeed {
        HistoryFeed(forum: forum, activities: activities, sessions: sessions, runs: runs, watched: watched)
    }

    // MARK: Filtering

    func testTheForumFilterNarrowsEverySection() {
        let all = feed(
            activities: [record(.summary, site: alpha, id: "1"), record(.chat, site: beta, id: "2")],
            sessions: [session(site: alpha, id: "1"), session(site: beta, id: "2")],
            runs: [run(site: alpha, goal: "A"), run(site: beta, goal: "B")],
            watched: [WatchedTopic(siteURL: beta, topicID: "9", url: URL(string: "\(beta)/t/9")!, title: "W", knownPostCount: 3)]
        )
        XCTAssertEqual(all.count(.all), 7)
        let onlyBeta = feed(
            forum: beta,
            activities: [record(.summary, site: alpha, id: "1"), record(.chat, site: beta, id: "2")],
            sessions: [session(site: alpha, id: "1"), session(site: beta, id: "2")],
            runs: [run(site: alpha, goal: "A"), run(site: beta, goal: "B")],
            watched: [WatchedTopic(siteURL: beta, topicID: "9", url: URL(string: "\(beta)/t/9")!, title: "W", knownPostCount: 3)]
        )
        XCTAssertEqual(onlyBeta.inProgress.map(\.siteURL), [beta])
        XCTAssertEqual(onlyBeta.saved.map(\.siteURL), [beta])
        XCTAssertEqual(onlyBeta.asks.map(\.goal), ["B"])
        XCTAssertEqual(onlyBeta.watching.count, 1)
    }

    func testSegmentsPickTheirSections() {
        let summary = record(.summary, site: alpha, id: "1")
        let research = record(.agent, site: alpha, id: "agent:\(UUID().uuidString)")
        let done = record(.chat, site: alpha, id: "3", status: .completed)
        let feed = feed(activities: [summary, research, done], sessions: [session(site: alpha, id: "3")])
        XCTAssertEqual(feed.inProgress(in: .all).count, 2)
        XCTAssertEqual(feed.inProgress(in: .summaries).map(\.id), [summary.id])
        XCTAssertEqual(feed.inProgress(in: .asks).map(\.id), [research.id])
        XCTAssertTrue(feed.inProgress(in: .watching).isEmpty)
        XCTAssertEqual(feed.count(.summaries), 1)
        XCTAssertEqual(feed.recent.map(\.id), [done.id])
    }

    func testARunInProgressShowsOnceAndNotAmongTheFinishedAsks() {
        let running = run(site: alpha, goal: "Working")
        let finished = run(site: alpha, goal: "Done")
        let record = record(.agent, site: alpha, id: AppModel.agentTopicPrefix + running.id.uuidString)
        let feed = feed(activities: [record], runs: [running, finished])
        XCTAssertEqual(feed.asks.map(\.goal), ["Done"])
        XCTAssertEqual(feed.inProgress(in: .asks).count, 1)
        XCTAssertEqual(feed.count(.asks), 2)
    }

    func testFinishedAskRecordsAreNotDuplicatedInRecentActivity() {
        let ended = record(.agent, site: alpha, id: "agent:x", status: .completed)
        XCTAssertTrue(feed(activities: [ended]).recent.isEmpty)
    }

    func testRecentActivityIsCapped() {
        let many = (0..<50).map { record(.summary, site: alpha, id: "\($0)", status: .completed) }
        XCTAssertEqual(feed(activities: many).recent.count, HistoryFeed.recentLimit)
    }

    func testSavedKeptFirstThenNewest() {
        let feed = feed(sessions: [
            session(site: alpha, id: "old", at: 1),
            session(site: alpha, id: "new", at: 5),
            session(site: alpha, id: "kept", kept: true, at: 0),
            session(site: alpha, id: "empty", summary: "", at: 9)
        ])
        XCTAssertEqual(feed.saved.map(\.topicID), ["kept", "new", "old"])
    }

    // MARK: Grouping

    func testGroupsFollowTheForumOrderAndDropEmptyForums() {
        let forums = [Forum(siteURL: beta, kind: .discourse, name: "Beta"), Forum(siteURL: alpha, kind: .discourse, name: "Alpha"), Forum(siteURL: "https://c.example.org", kind: .discourse, name: "C")]
        let runs = [run(site: alpha, goal: "a1"), run(site: beta, goal: "b1"), run(site: alpha, goal: "a2")]
        let groups = HistoryFeed.grouped(runs, forums: forums, siteURL: \.siteURL)
        XCTAssertEqual(groups.map(\.0.siteURL), [beta, alpha])
        XCTAssertEqual(groups.last?.1.map(\.goal), ["a1", "a2"])
    }

    // MARK: Origin

    func testAnAskRunDefaultsToTypedAndKeepsItsOriginThroughSync() throws {
        XCTAssertEqual(run(site: alpha, goal: "x").origin, .typed)
        for origin in AgentRunOrigin.allCases {
            let data = try JSONEncoder().encode(run(site: alpha, goal: "x", origin: origin))
            XCTAssertEqual(try JSONDecoder().decode(AgentRun.self, from: data).origin, origin)
        }
    }

    func testStartPointsSetTheOrigin() throws {
        let app = AppModel(store: PersistentStore(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent("state.json")
        ))
        app.selectModel(ModelSelection(provider: .ollama, model: "test-model"), for: .both)
        app.startAgentRun(goal: "Typed", siteURL: alpha)
        _ = try app.startAgentRun(goal: "Spoken", siteURL: alpha, origin: .voice) { _ in }
        app.startAgentRun(goal: "Shortcut", siteURL: alpha, origin: .shortcut)
        let origins = Dictionary(uniqueKeysWithValues: app.agentRuns.map { ($0.goal, $0.origin) })
        XCTAssertEqual(origins, ["Typed": .typed, "Spoken": .voice, "Shortcut": .shortcut])
    }
}
