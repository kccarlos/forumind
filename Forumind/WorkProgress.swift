import Foundation

// How far along a running job is. Summaries report every step of the
// hierarchical pipeline (batches → fold levels → final pass); the agent
// reports steps against its budget; chat is indeterminate once the model is
// asked. Everything here is pure so the mapping can be tested.

/// One step of a summary, reported as it happens (see
/// `AIService.hierarchicalSummary`).
enum SummaryProgressEvent: Equatable, Sendable {
    /// About to summarize batch `index` (0-based) of `count` at fold `level`
    /// (1 = the discussion's sections, 2+ = summaries of summaries).
    case batchStarted(level: Int, index: Int, count: Int)
    /// Batch `index` of `count` at `level` is done.
    case batchFinished(level: Int, index: Int, count: Int)
    /// Writing the summary the reader sees: a single pass over the whole
    /// discussion, or (`combining`) the final pass over batch summaries.
    case finalStarted(combining: Bool)
    /// Characters received so far from the request in flight.
    case streamed(characters: Int)
}

/// Maps summary events to a fraction of the AI phase (0…1). Never goes
/// backwards, and never reports 1 — the run reports completion itself.
struct SummaryProgressTracker: Equatable {
    /// Section batches fill 0…0.7, fold levels 0.7…0.85, the final pass the rest.
    static let sectionsEnd = 0.7
    static let foldsEnd = 0.85
    static let ceiling = 0.99
    /// Typical output of one batch summary and of the final summary; streamed
    /// characters move the bar within the step against these.
    static let batchCharacters = 1_200.0
    static let finalCharacters = 3_000.0

    private(set) var fraction = 0.0
    private(set) var statusText: String?
    private var stepStart = 0.0
    private var stepEnd = 0.0
    private var expectedCharacters = finalCharacters

    /// The share of the AI phase fold `level` occupies: level 1 takes the
    /// sections range; each later level takes half of what the folds have left.
    static func range(level: Int) -> ClosedRange<Double> {
        guard level > 1 else { return 0...sectionsEnd }
        let span = foldsEnd - sectionsEnd
        let start = sectionsEnd + span * (1 - pow(0.5, Double(level - 2)))
        let end = sectionsEnd + span * (1 - pow(0.5, Double(level - 1)))
        return start...end
    }

    /// How far into a step `characters` of streamed output are: rises quickly,
    /// then ever more slowly, so a long answer keeps moving without finishing
    /// the step.
    static func streamedShare(characters: Int, expected: Double) -> Double {
        guard characters > 0, expected > 0 else { return 0 }
        return 0.9 * (1 - exp(-Double(characters) / expected))
    }

    @discardableResult
    mutating func apply(_ event: SummaryProgressEvent) -> Double {
        let candidate: Double
        switch event {
        case let .batchStarted(level, index, count):
            let range = Self.range(level: level)
            let width = (range.upperBound - range.lowerBound) / Double(max(count, 1))
            stepStart = range.lowerBound + width * Double(index)
            stepEnd = stepStart + width
            expectedCharacters = Self.batchCharacters
            candidate = stepStart
            statusText = level == 1
                ? String(localized: "Summarizing part \(index + 1) of \(count)…", comment: "Progress of a long summary: the discussion is summarized in parts")
                : String(localized: "Condensing part \(index + 1) of \(count)…", comment: "Progress of a long summary: the part summaries are shortened again")
        case let .batchFinished(level, index, count):
            let range = Self.range(level: level)
            let width = (range.upperBound - range.lowerBound) / Double(max(count, 1))
            candidate = range.lowerBound + width * Double(index + 1)
        case let .finalStarted(combining):
            stepStart = combining ? Self.foldsEnd : 0
            stepEnd = Self.ceiling
            expectedCharacters = Self.finalCharacters
            candidate = stepStart
            statusText = combining ? String(localized: "Combining…", comment: "Progress of a long summary: the part summaries are merged into the final summary") : nil
        case let .streamed(characters):
            candidate = stepStart
                + (stepEnd - stepStart) * Self.streamedShare(characters: characters, expected: expectedCharacters)
        }
        fraction = max(fraction, min(candidate, Self.ceiling))
        return fraction
    }
}

/// Maps each work type's phases onto the record's single 0…1 progress.
enum WorkProgress {
    /// The share of the bar the forum fetch fills before the AI phase.
    static func fetchShare(for type: WorkType) -> Double {
        switch type {
        case .pull: 1
        case .summary: 0.4
        // Chat goes indeterminate once the model is asked; the fetch never
        // claims more than a third of the bar.
        case .chat: 0.3
        case .agent: 0
        }
    }

    static func fetch(_ fraction: Double, type: WorkType) -> Double {
        min(max(fraction, 0), 1) * fetchShare(for: type)
    }

    /// The whole summary's progress for an AI-phase fraction.
    static func summary(ai fraction: Double) -> Double {
        let share = fetchShare(for: .summary)
        return min(share + (1 - share) * min(max(fraction, 0), 1), SummaryProgressTracker.ceiling)
    }

    /// The agent's progress: `completedSteps` of a budget of `maxSteps` (plus
    /// the final answer), with `within` (0…1) of the current step done.
    static func agent(completedSteps: Int, maxSteps: Int, within: Double = 0) -> Double {
        let total = Double(max(maxSteps, 0) + 1)
        let done = Double(max(completedSteps, 0)) + min(max(within, 0), 0.95)
        return min(done / total, SummaryProgressTracker.ceiling)
    }

    /// Where a new value lands on the record: determinate progress only moves
    /// forward within a run; nil (indeterminate) is always allowed.
    static func advanced(from current: Double?, to next: Double?) -> Double? {
        guard let next else { return nil }
        return max(current ?? 0, min(max(next, 0), 1))
    }
}

/// Rate limit for progress writes (they redraw every view showing the record):
/// at most one per `interval`; later values wait for the next slot.
struct ProgressThrottle: Equatable {
    var interval: TimeInterval = 0.1
    private(set) var lastEmit: Date?

    init(interval: TimeInterval = 0.1) {
        self.interval = interval
    }

    /// nil: write now (and the write is recorded). Otherwise, how long to
    /// wait before the next write is allowed.
    mutating func delay(at now: Date, force: Bool = false) -> TimeInterval? {
        if force || lastEmit.map({ now.timeIntervalSince($0) >= interval }) ?? true {
            lastEmit = now
            return nil
        }
        return interval - now.timeIntervalSince(lastEmit ?? now)
    }
}

/// Coalesces a job's progress reports into throttled record writes; the
/// latest value is always written once its slot comes. `cancel()` drops a
/// pending write (the job ended).
@MainActor
final class ThrottledProgress {
    typealias Write = @MainActor (_ fraction: Double?, _ statusText: String?) -> Void

    private var throttle: ProgressThrottle
    private let write: Write
    private let now: () -> Date
    private var pendingFraction: Double?
    private var pendingStatus: String?
    private var hasPending = false
    private var flushTask: Task<Void, Never>?
    private var cancelled = false

    init(interval: TimeInterval = 0.1, now: @escaping () -> Date = Date.init, write: @escaping Write) {
        throttle = ProgressThrottle(interval: interval)
        self.now = now
        self.write = write
    }

    /// A new status text is written right away (it changes once per step);
    /// fraction-only updates are rate limited.
    func report(_ fraction: Double?, statusText: String? = nil) {
        guard !cancelled else { return }
        pendingFraction = fraction
        if let statusText { pendingStatus = statusText }
        hasPending = true
        if let wait = throttle.delay(at: now(), force: statusText != nil) {
            guard flushTask == nil else { return }
            flushTask = Task { @MainActor [weak self] in
                // Cancelled: a forced write already went out (or the job ended).
                guard (try? await Task.sleep(for: .seconds(wait))) != nil, !Task.isCancelled else { return }
                self?.flushTask = nil
                self?.flush()
            }
        } else {
            flushTask?.cancel()
            flushTask = nil
            emit()
        }
    }

    /// Writes any pending value now.
    func flush() {
        guard !cancelled, hasPending else { return }
        _ = throttle.delay(at: now(), force: true)
        emit()
    }

    func cancel() {
        cancelled = true
        hasPending = false
        flushTask?.cancel()
        flushTask = nil
    }

    private func emit() {
        let fraction = pendingFraction
        let status = pendingStatus
        hasPending = false
        pendingStatus = nil
        write(fraction, status)
    }
}

/// Feeds a summary's events through a tracker into throttled record writes;
/// `map` places the AI-phase fraction on the record's bar (a summary run, or
/// one slice of an agent step).
@MainActor
final class SummaryProgressFeed {
    private(set) var tracker = SummaryProgressTracker()
    private let output: ThrottledProgress
    private let map: (Double) -> Double

    init(output: ThrottledProgress, map: @escaping (Double) -> Double) {
        self.output = output
        self.map = map
    }

    func handle(_ event: SummaryProgressEvent) {
        let previousStatus = tracker.statusText
        tracker.apply(event)
        let status = tracker.statusText != previousStatus ? tracker.statusText : nil
        output.report(map(tracker.fraction), statusText: status)
    }
}
