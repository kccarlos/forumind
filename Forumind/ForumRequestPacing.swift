import Foundation

// Paced forum requests: every request `ForumService` makes (topic JSON, raw
// pages, search, latest, site info; in-page `fetch()` or URLSession) first
// takes a slot from `ForumRequestPacer`. Pacing is per forum host, so two
// forums never slow each other down, and a `Retry-After` from the forum
// pushes that host's next start back on top of the pace.

/// How quickly Forumind sends requests to one forum (Settings › Summaries &
/// chat › Forum requests). Synced; a running job keeps the pace it started with.
enum ForumRequestPace: String, Codable, CaseIterable, Identifiable, Sendable {
    /// One request per second, one at a time (default).
    case gentle
    /// Two requests per second, up to two at a time.
    case standard
    /// No delay, up to four at a time (the behavior before pacing).
    case fast

    static let `default`: ForumRequestPace = .gentle

    var id: String { rawValue }

    /// Minimum time between the starts of two requests to the same host.
    var minimumInterval: TimeInterval {
        switch self {
        case .gentle: 1
        case .standard: 0.5
        case .fast: 0
        }
    }

    /// Requests to the same host that may be in flight at once.
    var maximumConcurrency: Int {
        switch self {
        case .gentle: 1
        case .standard: 2
        case .fast: 4
        }
    }

    var title: String {
        switch self {
        case .gentle: String(localized: "Gentle", comment: "Forum request pace option: 1 request per second")
        case .standard: String(localized: "Standard", comment: "Forum request pace option: 2 requests per second")
        case .fast: String(localized: "Fast", comment: "Forum request pace option: no delay between requests")
        }
    }

    var detail: String {
        switch self {
        case .gentle: String(localized: "1 request per second, one at a time", comment: "Description of the Gentle forum request pace")
        case .standard: String(localized: "2 requests per second, up to 2 at a time", comment: "Description of the Standard forum request pace")
        case .fast: String(localized: "No delay, up to 4 at a time", comment: "Description of the Fast forum request pace")
        }
    }
}

/// Time source for pacing, injectable so tests never really sleep.
protocol ForumPacingClock: Sendable {
    /// Seconds on a monotonic timeline.
    func now() -> TimeInterval
    /// Returns at `deadline` (at once when it has passed); throws
    /// `CancellationError` when the task is cancelled first.
    func sleep(until deadline: TimeInterval) async throws
}

/// The real clock (`ContinuousClock`, so it keeps counting while the
/// device sleeps and never jumps with the wall clock).
struct SystemForumPacingClock: ForumPacingClock {
    private let origin = ContinuousClock.now

    func now() -> TimeInterval {
        let elapsed = ContinuousClock.now - origin
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    func sleep(until deadline: TimeInterval) async throws {
        let wait = deadline - now()
        if wait > 0 {
            try await Task.sleep(for: .seconds(wait))
        } else {
            try Task.checkCancellation()
        }
    }
}

/// Hands out request slots per host: at most `pace.maximumConcurrency` in
/// flight, starts at least `pace.minimumInterval` apart, first come first
/// served. Shared by every request of one `ForumService`.
actor ForumRequestPacer {
    private struct HostState {
        var inFlight = 0
        /// The earliest the next request may start (pace or Retry-After).
        var nextStart: TimeInterval = -.infinity
        var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    }

    nonisolated let clock: ForumPacingClock
    private var hosts: [String: HostState] = [:]

    init(clock: ForumPacingClock = SystemForumPacingClock()) {
        self.clock = clock
    }

    nonisolated static func hostKey(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        return url.port.map { "\(host):\($0)" } ?? host
    }

    /// Waits for a slot on `url`'s host and for its start time, then returns
    /// the host key to pass to `release(_:)` once the request is done.
    /// Cancellation while waiting gives the slot back and throws.
    func acquire(for url: URL, pace: ForumRequestPace) async throws -> String {
        let host = Self.hostKey(for: url)
        try Task.checkCancellation()
        try await waitForSlot(host: host, limit: max(1, pace.maximumConcurrency))
        // The slot is held from here: give it back on any error.
        do {
            var state = hosts[host, default: HostState()]
            let start = max(clock.now(), state.nextStart)
            state.nextStart = start + pace.minimumInterval
            hosts[host] = state
            try await clock.sleep(until: start)
            return host
        } catch {
            release(host)
            throw error
        }
    }

    /// Frees the slot taken by `acquire`; the next waiter (if any) takes it.
    /// With `backOff` (the forum answered `429`), no request to this host
    /// starts before that many seconds from now. It is set before the slot
    /// is handed on (in one actor step), so the waiter that takes it already
    /// sees the new start time.
    func release(_ host: String, backOff seconds: TimeInterval? = nil) {
        if let seconds { backOff(host, seconds: seconds) }
        guard var state = hosts[host] else { return }
        if !state.waiters.isEmpty {
            // The slot passes straight to the next waiter.
            let next = state.waiters.removeFirst()
            hosts[host] = state
            next.continuation.resume()
        } else {
            state.inFlight = max(0, state.inFlight - 1)
            hosts[host] = state
        }
    }

    /// The forum asked to wait (`429` with `Retry-After`): no request to this
    /// host starts before `seconds` from now.
    func backOff(_ host: String, seconds: TimeInterval) {
        var state = hosts[host, default: HostState()]
        state.nextStart = max(state.nextStart, clock.now() + seconds)
        hosts[host] = state
    }

    /// Requests in flight to `url`'s host (tests).
    func inFlight(for url: URL) -> Int {
        hosts[Self.hostKey(for: url)]?.inFlight ?? 0
    }

    private func waitForSlot(host: String, limit: Int) async throws {
        var state = hosts[host, default: HostState()]
        if state.inFlight < limit, state.waiters.isEmpty {
            state.inFlight += 1
            hosts[host] = state
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                hosts[host, default: HostState()].waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id, host: host) }
        }
    }

    private func cancelWaiter(_ id: UUID, host: String) {
        guard var state = hosts[host],
              let index = state.waiters.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let waiter = state.waiters.remove(at: index)
        hosts[host] = state
        waiter.continuation.resume(throwing: CancellationError())
    }
}
