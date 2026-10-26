import XCTest
@testable import Forumind

/// Spec §13: the timings behind the motion polish (the views only apply them).
@MainActor
final class MotionTests: XCTestCase {
    func testResultCardsRise12PointsStaggeredBy40MillisecondsOrFadeOnly() {
        XCTAssertEqual(ResultCardMotion.delay(order: 0, reduceMotion: false), 0)
        XCTAssertEqual(ResultCardMotion.delay(order: 3, reduceMotion: false), 0.12, accuracy: 1e-9)
        XCTAssertEqual(ResultCardMotion.delay(order: 50, reduceMotion: false), ResultCardMotion.delay(order: ResultCardMotion.staggeredCards, reduceMotion: false),
                       "late cards come in with the eighth")
        XCTAssertEqual(ResultCardMotion.offset(revealed: false, reduceMotion: false), 12)
        XCTAssertEqual(ResultCardMotion.offset(revealed: true, reduceMotion: false), 0)
        // Reduce Motion: fade only, no stagger.
        XCTAssertEqual(ResultCardMotion.offset(revealed: false, reduceMotion: true), 0)
        XCTAssertEqual(ResultCardMotion.delay(order: 5, reduceMotion: true), 0)
    }

    func testOnboardingChecksStaggerBy60MillisecondsOrAppearAtOnce() {
        let first = ChecklistMotion.delay(order: 0, reduceMotion: false)
        XCTAssertEqual(ChecklistMotion.delay(order: 3, reduceMotion: false) - first, 0.18, accuracy: 1e-9)
        for order in 0..<4 { XCTAssertEqual(ChecklistMotion.delay(order: order, reduceMotion: true), 0) }
    }

    /// The AI button bounces when its trigger (the finished answer's id)
    /// changes: a new answer is a new id; seen, it is none.
    func testTheAIButtonBouncesOnceForEachNewFinishedAnswer() throws {
        func agent(_ status: WorkStatus) -> WorkRecord {
            var record = WorkRecord(type: .agent, siteURL: "https://a.example.org", topicID: "agent:\(UUID())", title: "Q",
                                    url: URL(string: "https://a.example.org")!, provider: .ollama, model: "m")
            record.status = status
            record.completedAt = status == .completed ? Date() : nil
            return record
        }
        func model(_ records: [WorkRecord]) throws -> AppModel {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let store = PersistentStore(fileURL: directory.appendingPathComponent("state.json"), keys: InMemoryProviderKeyStore())
            try store.save(AppSnapshot(activities: records))
            let app = AppModel(store: store)
            app.browser.onPageContextChanged = nil
            app.router.answersSeenAt = Date().addingTimeInterval(-60)
            return app
        }

        let done = agent(.completed)
        let first = try model([done])
        XCTAssertEqual(first.readyAnswer?.id, done.id, "done: the trigger changes")
        first.router.answersSeenAt = Date().addingTimeInterval(1)
        XCTAssertNil(first.readyAnswer?.id, "looked at: the trigger clears")

        let next = agent(.completed)
        let second = try model([next, done])
        XCTAssertEqual(second.readyAnswer?.id, next.id, "the next answer is a new trigger")
        XCTAssertNil(try model([agent(.failed)]).readyAnswer?.id, "no bounce for a failed run")
    }
}
