import Foundation

/// Scheduling for the gapless player, with no hardware attached.
///
/// The model's audio arrives in chunks of whatever length it produced
/// (40–730 ms observed). They must be appended, never scheduled at "now":
/// this queue holds a small jitter buffer, then hands chunks out **in
/// order**, one `AVAudioPlayerNode.scheduleBuffer` each, so the node
/// concatenates them sample-accurately.
///
/// The jitter buffer's target is **adaptive**. It starts at the profile's
/// floor (150 ms for Gemini). The queue tracks its own playhead (when the
/// audio handed to the player should run out) rather than the player's
/// completion callbacks, which land late and jittery on iOS. A drain
/// followed by more audio within 300 ms is an **underrun**, a gap the user
/// heard: it raises the target by 100 ms (up to the ceiling, 500 ms), and
/// every clean utterance lowers it by 20 ms back towards the floor. After an
/// underrun the queue refills to the new target before playing again, with
/// an 8 ms fade-in so the restart doesn't click.
///
/// **Time-stretch.** `steer` (every 20 ms, from the engine) picks a
/// playback rate (0.85–1.05) from the buffered audio against the target,
/// which the engine applies to an `AVAudioUnitTimePitch` with pitch 0. The
/// playhead is kept in wall-clock time and rescaled on every rate change.
///
/// `flush` (the user interrupted, or the session ended) drops everything at
/// once. It is not a drain and doesn't move the target.
struct PlaybackQueue {
    /// One chunk ready to be scheduled, in arrival order.
    struct Chunk: Equatable, Identifiable {
        let id: Int
        let samples: [Int16]
        var frameCount: Int { samples.count }
        init(id: Int, samples: [Int16]) {
            self.id = id
            self.samples = samples
        }
    }

    enum Phase: Equatable {
        /// Nothing queued and nothing playing.
        case idle
        /// Filling the jitter buffer; nothing has been handed out yet.
        case buffering
        /// Chunks are with the player node.
        case playing
    }

    /// A drain counts as an underrun only if more audio of the same
    /// utterance shows up within this long.
    private static let underrunWindow: TimeInterval = 0.3
    private static let targetStepMilliseconds = 100
    private static let targetDecayMilliseconds = 20
    private static let fadeMilliseconds = 8.0
    /// Headroom over the target before a short utterance starts anyway.
    private static let waitPaddingMilliseconds = 250

    let sampleRate: Double
    /// A lone short utterance still starts after this long rather than never.
    /// Also the ceiling on how long a post-underrun refill will wait before
    /// giving up and playing what it has. The current target plus 250 ms.
    var maximumWait: TimeInterval {
        Double(targetMilliseconds + Self.waitPaddingMilliseconds) / 1000
    }
    /// The initial adaptive target, and the floor it decays back down to.
    private(set) var targetFloorMilliseconds: Int
    /// The most the target may grow to.
    private(set) var targetCeilingMilliseconds: Int

    /// The playback rate the playhead is running at right now.
    private(set) var rate = 1.0
    /// Wall-clock seconds played at a rate other than 1.0, in total.
    private(set) var stretchedSeconds: TimeInterval = 0
    private(set) var ratePolicy = PlaybackRatePolicy()
    private var lastSteerAt: TimeInterval?

    private(set) var phase: Phase = .idle
    /// Samples held back, not yet handed to the player.
    private(set) var bufferedSamples = 0
    /// Samples handed to the player and not yet reported complete.
    private(set) var scheduledSamples = 0
    private(set) var flushes = 0
    private(set) var chunksDropped = 0

    /// The jitter-buffer target right now, in milliseconds: floor to
    /// ceiling (150–500 ms for Gemini), growing on underruns and decaying
    /// by a clean utterance at a time.
    private(set) var targetMilliseconds: Int
    /// Drains that turned out to be audible gaps (more of the same
    /// utterance arrived within `underrunWindow`).
    private(set) var underruns = 0
    /// Every time the player ran out of scheduled audio, underrun or not
    /// (the ordinary silence between utterances is a drain too).
    private(set) var drains = 0
    /// The longest gap seen between chunk arrivals while a gap was worth
    /// caring about (mid-utterance, or still inside the underrun window of
    /// a drain) — a long pause between utterances does not count.
    private(set) var largestArrivalGapMilliseconds = 0

    private var pending: [Chunk] = []
    private var nextID = 1
    private var bufferingSince: TimeInterval = 0
    private var live: Set<Int> = []
    private var scheduledLengths: [Int: Int] = [:]

    /// When the audio already handed to the player is predicted to run
    /// out, in wall-clock time at the current `rate`. This is the
    /// authoritative "is the node dry" clock — computed from chunk
    /// durations, not from completion callbacks, which are late enough on
    /// iOS to make a poor detector.
    private var playheadEndsAt: TimeInterval?
    private var lastPushAt: TimeInterval?
    /// Set when a drain is observed; cleared once the following gap (or
    /// lack of one) has been folded into the underrun/decay bookkeeping.
    private var drainedAt: TimeInterval?
    private var utteranceHadUnderrun = false
    /// True while the next chunk released from buffering should carry a
    /// fade-in because it is resuming after an underrun.
    private var fadeInNextRelease = false

    init(
        sampleRate: Double = VoiceAudioFormat.playbackRate,
        prebufferMilliseconds: Int = 150,
        ceilingMilliseconds: Int = 500
    ) {
        self.sampleRate = sampleRate
        self.targetFloorMilliseconds = prebufferMilliseconds
        self.targetCeilingMilliseconds = max(prebufferMilliseconds, ceilingMilliseconds)
        self.targetMilliseconds = prebufferMilliseconds
    }

    init(profile: PlaybackProfile, sampleRate: Double = VoiceAudioFormat.playbackRate) {
        self.init(
            sampleRate: sampleRate,
            prebufferMilliseconds: profile.floorMilliseconds,
            ceilingMilliseconds: profile.ceilingMilliseconds
        )
    }

    var profile: PlaybackProfile {
        PlaybackProfile(floorMilliseconds: targetFloorMilliseconds, ceilingMilliseconds: targetCeilingMilliseconds)
    }

    /// Switches the target range (the voice provider changed). The target
    /// restarts at the new floor; counters are kept.
    mutating func setProfile(_ profile: PlaybackProfile) {
        guard profile != self.profile else { return }
        targetFloorMilliseconds = profile.floorMilliseconds
        targetCeilingMilliseconds = profile.ceilingMilliseconds
        targetMilliseconds = profile.floorMilliseconds
    }

    /// True while the player has audio to play — most of "speaking".
    var isSpeaking: Bool { scheduledSamples > 0 }

    /// Samples to collect before the next chunk is released, from the
    /// current adaptive target.
    var prebufferSamples: Int {
        Int(sampleRate * Double(targetMilliseconds) / 1000.0)
    }

    /// How much audio has been queued or scheduled and not yet reported
    /// played by the node, in milliseconds. Follows the (late) completion
    /// callbacks; `bufferedMilliseconds(at:)` is the predicted figure.
    var queueDepthMilliseconds: Int {
        Int(Double(bufferedSamples + scheduledSamples) / sampleRate * 1000.0)
    }

    /// How much audio is waiting to be heard at `now`, in milliseconds of
    /// audio: what is held back plus what the predicted playhead has not
    /// reached yet (wall-clock time left × rate). The rate policy's `b`.
    func bufferedMilliseconds(at now: TimeInterval) -> Double {
        var seconds = Double(bufferedSamples) / sampleRate
        if phase == .playing, let endsAt = playheadEndsAt {
            seconds += max(0, endsAt - now) * rate
        }
        return seconds * 1000
    }

    // MARK: - Time-stretch

    /// The 20 ms control loop: notices a drain, then moves the rate one
    /// slew step towards what the buffered audio calls for and rescales
    /// the playhead to it. Returns the rate to apply to the node.
    @discardableResult
    mutating func steer(now: TimeInterval) -> Double {
        observeDrain(now: now)
        let dt = lastSteerAt.map { max(0, now - $0) } ?? 0
        lastSteerAt = now
        switch phase {
        case .idle:
            // Keep the rate through a possible underrun (the drain's
            // bookkeeping is still open); reset once the utterance is over.
            if drainedAt == nil {
                ratePolicy.reset()
                applyRate(1.0, now: now)
            }
        case .buffering:
            break
        case .playing:
            if rate != 1.0 { stretchedSeconds += min(dt, PlaybackRatePolicy.maximumStep) }
            let next = ratePolicy.step(
                bufferedMilliseconds: bufferedMilliseconds(at: now),
                targetMilliseconds: Double(targetMilliseconds),
                dt: dt
            )
            applyRate(next, now: now)
        }
        return rate
    }

    /// Sets the rate directly, bypassing the policy (tests).
    mutating func setRate(_ next: Double, now: TimeInterval) {
        observeDrain(now: now)
        applyRate(next, now: now)
    }

    /// Rescales the remaining playhead: the audio left is (endsAt − now)·r
    /// seconds, and at the new rate it lasts that divided by r'.
    private mutating func applyRate(_ next: Double, now: TimeInterval) {
        guard next != rate else { return }
        if phase == .playing, let endsAt = playheadEndsAt, endsAt > now {
            let remainingAudio = (endsAt - now) * rate
            playheadEndsAt = now + remainingAudio / next
        }
        rate = next
    }

    /// Appends a chunk. Returns the chunks to schedule now, in order: empty
    /// while the jitter buffer fills, then everything held plus this one.
    mutating func push(_ samples: [Int16], now: TimeInterval) -> [Chunk] {
        guard !samples.isEmpty else { return [] }
        trackArrivalGap(now: now)
        observeDrain(now: now)

        if phase == .playing {
            return appendLive(samples, now: now)
        }

        if phase == .idle {
            resolveDrainBookkeeping(now: now)
            phase = .buffering
            bufferingSince = now
        }

        return bufferAndMaybeRelease(samples, now: now)
    }

    /// Releases a short utterance that never reached the jitter buffer, and
    /// notices a drain even when nothing has been pushed since. Call it
    /// from the same timer that refreshes the UI.
    mutating func tick(now: TimeInterval) -> [Chunk] {
        observeDrain(now: now)
        if phase == .idle, let drainedAt, now - drainedAt > Self.underrunWindow {
            finalizeCleanUtterance()
            self.drainedAt = nil
        }
        guard phase == .buffering, now - bufferingSince >= maximumWait else { return [] }
        return release(now: now)
    }

    /// The player finished a chunk. This is bookkeeping for
    /// the queue depth and `isSpeaking` only: drain *detection* for the
    /// adaptive target happens in `push`/`tick` against the playhead, which
    /// usually notices first. A completion for a chunk the playhead already
    /// wrote off (dropped by a predicted drain, or by `flush`) is a no-op.
    mutating func completed(_ id: Int) {
        guard live.remove(id) != nil else { return }
        if let index = scheduledLengths.index(forKey: id) {
            scheduledSamples -= scheduledLengths[index].value
            scheduledLengths.remove(at: index)
        }
        if scheduledSamples < 0 { scheduledSamples = 0 }
        if live.isEmpty && pending.isEmpty {
            scheduledSamples = 0
            if phase == .playing {
                // The node reported dry before the predicted playhead got
                // there: that is still a drain, dated at the prediction.
                drains += 1
                drainedAt = playheadEndsAt
            }
            phase = .idle
            playheadEndsAt = nil
        }
    }

    /// Drop everything now: the queued chunks and the ones already with the
    /// player (the caller stops the node). Returns true when there was
    /// anything to drop, i.e. the node needs stopping. A flush is a reset,
    /// not a drain: it does not count toward underruns or move the
    /// adaptive target, and the next utterance buffers at whatever target
    /// the queue already had.
    @discardableResult
    mutating func flush() -> Bool {
        let hadAudio = !pending.isEmpty || !live.isEmpty
        chunksDropped += pending.count + live.count
        pending.removeAll()
        live.removeAll()
        scheduledLengths.removeAll()
        bufferedSamples = 0
        scheduledSamples = 0
        phase = .idle
        flushes += 1
        playheadEndsAt = nil
        drainedAt = nil
        utteranceHadUnderrun = false
        fadeInNextRelease = false
        ratePolicy.reset()
        rate = 1.0
        return hadAudio
    }

    // MARK: - Drain / underrun detection

    /// If the node's predicted playhead has passed `now` while chunks are
    /// still marked live, the player has run dry. Move to `.idle`
    /// preemptively (a late `completed` for one of those chunks then finds
    /// it already gone from `live` and no-ops) and remember when, so the
    /// next arrival can be judged against the underrun window.
    private mutating func observeDrain(now: TimeInterval) {
        guard phase == .playing, let endsAt = playheadEndsAt, now >= endsAt else { return }
        drains += 1
        phase = .idle
        live.removeAll()
        scheduledLengths.removeAll()
        scheduledSamples = 0
        playheadEndsAt = nil
        drainedAt = endsAt
    }

    /// Called once, right before re-entering `.buffering` from `.idle`:
    /// decides whether the gap since the last drain (if any) was short
    /// enough to be the underrun that caused it, or long enough that the
    /// utterance which just finished was clean.
    private mutating func resolveDrainBookkeeping(now: TimeInterval) {
        guard let drainedAt else { return }
        if now - drainedAt <= Self.underrunWindow {
            registerUnderrun()
        } else {
            finalizeCleanUtterance()
        }
        self.drainedAt = nil
    }

    private mutating func registerUnderrun() {
        underruns += 1
        utteranceHadUnderrun = true
        targetMilliseconds = min(targetMilliseconds + Self.targetStepMilliseconds, targetCeilingMilliseconds)
        fadeInNextRelease = true
    }

    private mutating func finalizeCleanUtterance() {
        if !utteranceHadUnderrun {
            targetMilliseconds = max(targetMilliseconds - Self.targetDecayMilliseconds, targetFloorMilliseconds)
        }
        utteranceHadUnderrun = false
    }

    private mutating func trackArrivalGap(now: TimeInterval) {
        defer { lastPushAt = now }
        guard let last = lastPushAt else { return }
        let midUtterance = phase != .idle || (drainedAt.map { now - $0 <= Self.underrunWindow } ?? false)
        guard midUtterance else { return }
        largestArrivalGapMilliseconds = max(largestArrivalGapMilliseconds, Int((now - last) * 1000))
    }

    // MARK: - Scheduling

    /// Phase is `.playing` and the playhead has not run dry: the chunk goes
    /// straight to the player and extends the predicted playhead.
    private mutating func appendLive(_ samples: [Int16], now: TimeInterval) -> [Chunk] {
        let chunk = Chunk(id: nextID, samples: samples)
        nextID += 1
        live.insert(chunk.id)
        scheduledLengths[chunk.id] = chunk.frameCount
        scheduledSamples += chunk.frameCount
        let start = max(playheadEndsAt ?? now, now)
        playheadEndsAt = start + duration(of: chunk.frameCount) / rate
        return [chunk]
    }

    private mutating func bufferAndMaybeRelease(_ samples: [Int16], now: TimeInterval) -> [Chunk] {
        var chunk = Chunk(id: nextID, samples: samples)
        nextID += 1
        if fadeInNextRelease, pending.isEmpty {
            chunk = fadedIn(chunk)
            fadeInNextRelease = false
        }
        pending.append(chunk)
        bufferedSamples += chunk.frameCount
        if bufferedSamples >= prebufferSamples { return release(now: now) }
        return []
    }

    private mutating func release(now: TimeInterval) -> [Chunk] {
        let out = pending
        pending.removeAll()
        bufferedSamples = 0
        phase = .playing
        var playhead = now
        for chunk in out {
            live.insert(chunk.id)
            scheduledLengths[chunk.id] = chunk.frameCount
            scheduledSamples += chunk.frameCount
            playhead += duration(of: chunk.frameCount) / rate
        }
        playheadEndsAt = playhead
        return out
    }

    private func duration(of frameCount: Int) -> TimeInterval {
        Double(frameCount) / sampleRate
    }

    /// An 8 ms linear ramp from zero, applied to the PCM before it is ever
    /// handed out — the queue owns the samples up to that point, so the
    /// fade is real, not a flag for the caller to interpret.
    private func fadedIn(_ chunk: Chunk) -> Chunk {
        let fadeSamples = min(chunk.samples.count, Int(sampleRate * Self.fadeMilliseconds / 1000.0))
        guard fadeSamples > 1 else { return chunk }
        var samples = chunk.samples
        for index in 0..<fadeSamples {
            let gain = Double(index) / Double(fadeSamples)
            samples[index] = Int16((Double(samples[index]) * gain).rounded())
        }
        return Chunk(id: chunk.id, samples: samples)
    }
}

/// The jitter-buffer target range. Gemini Live delivers about four times
/// faster than real time, so a small buffer is enough.
struct PlaybackProfile: Equatable {
    /// Where the adaptive target starts, and the floor it decays back to.
    let floorMilliseconds: Int
    /// The most the target may grow to after underruns.
    let ceilingMilliseconds: Int

    init(floorMilliseconds: Int, ceilingMilliseconds: Int) {
        self.floorMilliseconds = floorMilliseconds
        self.ceilingMilliseconds = max(floorMilliseconds, ceilingMilliseconds)
    }

    static let gemini = PlaybackProfile(floorMilliseconds: 150, ceilingMilliseconds: 500)
}

/// Pitch-preserving adaptive time-stretch: how fast to play, from how much
/// audio is buffered. Pure arithmetic; `PlaybackQueue` owns one and
/// `VoiceAudioEngine` copies its rate onto an `AVAudioUnitTimePitch`.
///
/// With `b` the buffered audio and `T` the jitter-buffer target:
///
/// | buffered            | rate                              |
/// |---------------------|-----------------------------------|
/// | b > 2T (with debt)  | 1.05 — catch up                   |
/// | T ≤ b               | 1.00                              |
/// | T/2 ≤ b < T         | linear 0.90 → 1.00                |
/// | T/4 < b < T/2       | linear 0.85 → 0.90                |
/// | b ≤ T/4             | 0.85 (the floor)                  |
///
/// The rate moves by at most 0.02 per 20 ms (1.0 per second), so a change
/// is a glide, never a jump.
///
/// **Catch-up needs latency debt.** Speeding up to 1.05 only makes sense
/// to win back time the stretch itself added (playing at r < 1 adds
/// `(1 − r)·dt` of latency). A provider that is simply ahead of real time
/// — Gemini delivers a 10 s reply in ~2.5 s, so b is far above 2T for
/// most of every reply — owes nothing, and plays at exactly 1.0. The debt
/// resets when the queue goes idle: the silence between replies absorbs
/// whatever is left.
struct PlaybackRatePolicy: Equatable {
    static let floorRate = 0.85
    static let kneeRate = 0.90
    static let catchUpRate = 1.05
    /// 0.02 per 20 ms.
    static let slewPerSecond = 1.0
    /// A late control-loop tick cannot turn into a jump.
    static let maximumStep: TimeInterval = 0.1

    /// The rate right now.
    private(set) var rate = 1.0
    /// Wall-clock seconds the stretch has added and not yet won back.
    private(set) var debtSeconds = 0.0

    init() {}

    /// The rate the policy steers towards for `buffered` ms against target
    /// `target` ms, before slewing. `catchUp` is whether there is latency
    /// debt to win back.
    static func desiredRate(bufferedMilliseconds b: Double, targetMilliseconds t: Double, catchUp: Bool = true) -> Double {
        guard t > 0 else { return 1.0 }
        if b > 2 * t { return catchUp ? catchUpRate : 1.0 }
        if b >= t { return 1.0 }
        let half = t / 2
        let quarter = t / 4
        if b >= half {
            return kneeRate + (1.0 - kneeRate) * (b - half) / half
        }
        if b > quarter {
            return floorRate + (kneeRate - floorRate) * (b - quarter) / quarter
        }
        return floorRate
    }

    /// Advances the policy by `dt` seconds of playback at the current rate
    /// (accruing or paying off debt), then slews towards the desired rate.
    /// Returns the new rate.
    @discardableResult
    mutating func step(bufferedMilliseconds b: Double, targetMilliseconds t: Double, dt: TimeInterval) -> Double {
        let dt = min(max(dt, 0), Self.maximumStep)
        debtSeconds = max(0, debtSeconds + (1 - rate) * dt)
        let desired = Self.desiredRate(bufferedMilliseconds: b, targetMilliseconds: t, catchUp: debtSeconds > 0)
        let limit = Self.slewPerSecond * dt
        rate += min(max(desired - rate, -limit), limit)
        // Snap away float dust so "exactly 1.0" is observable.
        if abs(rate - 1.0) < 1e-9 { rate = 1.0 }
        return rate
    }

    /// Back to 1.0 with no debt: the queue went idle or was flushed.
    mutating func reset() {
        rate = 1.0
        debtSeconds = 0
    }
}
