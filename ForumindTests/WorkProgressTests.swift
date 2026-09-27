import XCTest
@testable import Forumind

/// Progress of running work: the phase → fraction mapping, throttling, and
/// the progress bar's clock-driven motion.
@MainActor
final class WorkProgressTests: XCTestCase {
    // MARK: Summary mapping

    func testHierarchicalSummaryProgressIsMonotonicAndCountsBatches() {
        var tracker = SummaryProgressTracker()
        var fractions: [Double] = []
        func apply(_ event: SummaryProgressEvent) { fractions.append(tracker.apply(event)) }

        for index in 0..<7 {
            apply(.batchStarted(level: 1, index: index, count: 7))
            if index == 2 { XCTAssertEqual(tracker.statusText, "Summarizing part 3 of 7…") }
            for characters in stride(from: 0, through: 4_000, by: 400) { apply(.streamed(characters: characters)) }
            apply(.batchFinished(level: 1, index: index, count: 7))
            XCTAssertEqual(tracker.fraction, SummaryProgressTracker.sectionsEnd * Double(index + 1) / 7, accuracy: 1e-9)
        }
        for index in 0..<2 {
            apply(.batchStarted(level: 2, index: index, count: 2))
            XCTAssertEqual(tracker.statusText, "Condensing part \(index + 1) of 2…")
            apply(.batchFinished(level: 2, index: index, count: 2))
        }
        apply(.finalStarted(combining: true))
        XCTAssertEqual(tracker.statusText, "Combining…")
        XCTAssertEqual(tracker.fraction, SummaryProgressTracker.foldsEnd, accuracy: 1e-9)
        for characters in stride(from: 0, through: 50_000, by: 500) { apply(.streamed(characters: characters)) }

        XCTAssertEqual(fractions, fractions.sorted(), "progress never goes backwards")
        XCTAssertLessThan(fractions.last ?? 1, 1, "only the finished run reports 100%")
        XCTAssertGreaterThan(fractions.last ?? 0, 0.95)
    }

    func testStreamingMovesALongSinglePassWithoutFinishingIt() {
        var tracker = SummaryProgressTracker()
        tracker.apply(.finalStarted(combining: false))
        XCTAssertNil(tracker.statusText, "a single pass keeps the caller's status")
        XCTAssertEqual(tracker.fraction, 0)
        let early = tracker.apply(.streamed(characters: 300))
        let later = tracker.apply(.streamed(characters: 3_000))
        let long = tracker.apply(.streamed(characters: 100_000))
        XCTAssertGreaterThan(early, 0)
        XCTAssertGreaterThan(later, early)
        XCTAssertGreaterThan(long, later)
        XCTAssertLessThanOrEqual(long, SummaryProgressTracker.ceiling)
        // Streamed text moves within its batch only.
        var batches = SummaryProgressTracker()
        batches.apply(.batchStarted(level: 1, index: 0, count: 4))
        batches.apply(.streamed(characters: 1_000_000))
        XCTAssertLessThan(batches.fraction, SummaryProgressTracker.sectionsEnd / 4)
    }

    func testFoldLevelsShareTheirRangeAndARetryNeverGoesBack() {
        var previousEnd = SummaryProgressTracker.sectionsEnd
        for level in 2...6 {
            let range = SummaryProgressTracker.range(level: level)
            XCTAssertEqual(range.lowerBound, previousEnd, accuracy: 1e-9)
            XCTAssertLessThanOrEqual(range.upperBound, SummaryProgressTracker.foldsEnd)
            previousEnd = range.upperBound
        }
        // Apple Intelligence retries in smaller sections: the new pass starts
        // over, the bar holds until it catches up.
        var tracker = SummaryProgressTracker()
        tracker.apply(.batchStarted(level: 1, index: 0, count: 2))
        tracker.apply(.batchFinished(level: 1, index: 0, count: 2))
        let reached = tracker.fraction
        tracker.apply(.batchStarted(level: 1, index: 0, count: 5))
        XCTAssertEqual(tracker.fraction, reached)
        tracker.apply(.batchFinished(level: 1, index: 3, count: 5))
        XCTAssertGreaterThan(tracker.fraction, reached)
    }

    func testWorkTypesMapTheirPhasesOntoOneBar() {
        XCTAssertEqual(WorkProgress.fetch(1, type: .pull), 1)
        XCTAssertEqual(WorkProgress.fetch(1, type: .summary), 0.4, accuracy: 1e-9)
        XCTAssertEqual(WorkProgress.fetch(0.5, type: .chat), 0.15, accuracy: 1e-9)
        // The summary's AI phase starts where its fetch ended.
        XCTAssertEqual(WorkProgress.summary(ai: 0), WorkProgress.fetch(1, type: .summary), accuracy: 1e-9)
        XCTAssertEqual(WorkProgress.summary(ai: 0.5), 0.7, accuracy: 1e-9)
        XCTAssertLessThan(WorkProgress.summary(ai: 1), 1)

        // Agent: steps used of the budget (plus the final answer).
        XCTAssertEqual(WorkProgress.agent(completedSteps: 0, maxSteps: 9), 0)
        XCTAssertEqual(WorkProgress.agent(completedSteps: 3, maxSteps: 9), 0.3, accuracy: 1e-9)
        XCTAssertEqual(WorkProgress.agent(completedSteps: 3, maxSteps: 9, within: 0.5), 0.35, accuracy: 1e-9)
        XCTAssertLessThan(
            WorkProgress.agent(completedSteps: 3, maxSteps: 9, within: 1),
            WorkProgress.agent(completedSteps: 4, maxSteps: 9),
            "a sub-step never reaches the next step"
        )
        XCTAssertLessThan(WorkProgress.agent(completedSteps: 40, maxSteps: 9), 1)

        XCTAssertEqual(WorkProgress.advanced(from: 0.6, to: 0.4), 0.6, "never backwards")
        XCTAssertEqual(WorkProgress.advanced(from: 0.4, to: 0.6), 0.6)
        XCTAssertEqual(WorkProgress.advanced(from: nil, to: 0.2), 0.2)
        XCTAssertNil(WorkProgress.advanced(from: 0.3, to: nil), "indeterminate is always allowed")
    }

    // MARK: Throttling

    func testThrottleAllowsOneWritePerInterval() {
        var throttle = ProgressThrottle(interval: 0.1)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertNil(throttle.delay(at: start))
        XCTAssertEqual(throttle.delay(at: start.addingTimeInterval(0.03)) ?? 0, 0.07, accuracy: 1e-9)
        XCTAssertNotNil(throttle.delay(at: start.addingTimeInterval(0.09)))
        XCTAssertNil(throttle.delay(at: start.addingTimeInterval(0.1)))
        XCTAssertNil(throttle.delay(at: start.addingTimeInterval(0.12), force: true))
    }

    func testThrottledProgressCoalescesAndWritesTheLatestValue() async throws {
        var clock = Date(timeIntervalSinceReferenceDate: 1_000)
        var writes: [(Double?, String?)] = []
        let progress = ThrottledProgress(interval: 0.1, now: { clock }) { writes.append(($0, $1)) }

        // A burst of 100 reports within one interval: one write now...
        for step in 1...100 { progress.report(Double(step) / 100) }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.last?.0, 0.01)
        // ...and the latest value once the slot comes.
        clock.addTimeInterval(0.1)
        try await waitUntil { writes.count == 2 }
        XCTAssertEqual(writes.last?.0, 1)

        // A new status is written at once, with the latest fraction.
        progress.report(0.5)
        progress.report(0.6, statusText: "Combining…")
        XCTAssertEqual(writes.count, 3)
        XCTAssertEqual(writes.last?.0, 0.6)
        XCTAssertEqual(writes.last?.1, "Combining…")

        // A forced status write replaces the pending slot: the cancelled
        // wait must not write again before the interval is up.
        clock.addTimeInterval(1)
        writes = []
        progress.report(0.61)
        progress.report(0.62)
        progress.report(0.63, statusText: "Summarizing part 2 of 7…")
        progress.report(0.64)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.last?.1, "Summarizing part 2 of 7…")
        clock.addTimeInterval(0.1)
        try await waitUntil { writes.count == 3 }
        XCTAssertEqual(writes.last?.0, 0.64)

        // Cancelled (the job ended): pending and later reports are dropped.
        progress.report(0.7)
        progress.cancel()
        progress.report(0.8, statusText: "Late")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(writes.count, 3)
    }

    func testSummaryFeedPlacesTheAIPhaseOnTheBar() {
        var writes: [(Double?, String?)] = []
        let output = ThrottledProgress(interval: 0) { writes.append(($0, $1)) }
        let feed = SummaryProgressFeed(output: output, map: WorkProgress.summary(ai:))
        feed.handle(.batchStarted(level: 1, index: 0, count: 2))
        XCTAssertEqual(writes.last?.0 ?? 0, 0.4, accuracy: 1e-9)
        XCTAssertEqual(writes.last?.1, "Summarizing part 1 of 2…")
        feed.handle(.streamed(characters: 600))
        XCTAssertNil(writes.last?.1, "an unchanged status is not rewritten")
        feed.handle(.batchFinished(level: 1, index: 0, count: 2))
        XCTAssertEqual(writes.last?.0 ?? 0, WorkProgress.summary(ai: 0.35), accuracy: 1e-9)
    }

    // MARK: Progress bar motion

    func testIndeterminateSweepMovesWithTheClock() {
        let period = AssistantProgressBar.sweepPeriod
        // Frames half a second apart (as a user sees it) are never in the same place.
        let offsets = stride(from: 0.0, to: period * 3, by: 0.5).map {
            AssistantProgressBar.sweepOffset(at: 10_000 + $0)
        }
        for (previous, next) in zip(offsets, offsets.dropFirst()) {
            XCTAssertGreaterThan(abs(next - previous), 0.01, "the sweep moves between frames")
        }
        for offset in offsets {
            // Most of the segment stays on the track: the bar is never empty.
            XCTAssertGreaterThanOrEqual(offset, -0.1 - 1e-9)
            XCTAssertLessThanOrEqual(offset, 0.8 + 1e-9)
        }
        XCTAssertGreaterThan(offsets.max() ?? 0, 0.7)
        XCTAssertLessThan(offsets.min() ?? 1, 0)
        let pulses = stride(from: 0.0, to: 2.4, by: 0.3).map {
            AssistantProgressBar.pulse(at: $0, low: 0.25, high: 0.65)
        }
        XCTAssertGreaterThan(Set(pulses.map { ($0 * 1_000).rounded() }).count, 4, "Reduce Motion still pulses")
        XCTAssertTrue(pulses.allSatisfy { (0.25...0.65).contains($0) })
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
