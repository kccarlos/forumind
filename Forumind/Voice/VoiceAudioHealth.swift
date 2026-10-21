import Foundation

/// What the voice bar's Health row shows about the audio engine.
struct VoiceAudioHealth: Equatable {
    var echoCancellation = VoiceProcessingStatus()
    /// Audible gaps in the model's speech (the jitter buffer ran dry and
    /// more of the same reply came within 300 ms).
    var underruns = 0
    /// The jitter buffer's current target, in milliseconds.
    var bufferTargetMilliseconds = PlaybackProfile.gemini.floorMilliseconds
    /// The microphone is on but delivers only digital zero.
    var noMicrophoneSignal = false
    /// Hardware input rate (usually 48 kHz).
    var inputSampleRate: Double = 0
    var gate = CaptureGate.Diagnostics()
    /// iOS paused the audio (a call, Siri) and didn't offer to resume it.
    var needsResume = false

    /// "Speaker ← iPhone Microphone".
    var route: String {
        [echoCancellation.outputRoute, echoCancellation.inputRoute].filter { !$0.isEmpty }.joined(separator: " ← ")
    }
}

/// Whether the system echo canceller can work right now. It cancels only
/// what it hears itself play, so it needs all of: the `.voiceChat` mode,
/// voice processing on the input node (which makes the engine's I/O one
/// voice-processing unit, so the output the player feeds is its reference),
/// and not bypassed.
struct VoiceProcessingStatus: Equatable {
    var inputEnabled = false
    var outputEnabled = false
    var bypassed = false
    var voiceChatMode = false
    /// Where playback goes ("Speaker", "AirPods Pro").
    var outputRoute = ""
    /// Where the microphone is ("iPhone Microphone").
    var inputRoute = ""

    var isActive: Bool { inputEnabled && outputEnabled && !bypassed && voiceChatMode }

    /// What is missing when it's off, in English (the Health row is a
    /// diagnostic, like a log line).
    var missing: [String] {
        var missing: [String] = []
        if !inputEnabled {
            missing.append("voice processing is off")
        } else if !outputEnabled {
            missing.append("the output is not voice-processed")
        }
        if bypassed { missing.append("bypassed") }
        if !voiceChatMode { missing.append("session not in voice-chat mode") }
        return missing
    }
}

/// Notices a microphone that is "on" but delivers nothing: every sample
/// digital zero (or no buffers at all) for `threshold` seconds while
/// capture should be running.
///
/// That is not a quiet room (a real room is never exactly zero) but a
/// broken capture path: voice processing starting silent, the wrong input,
/// another app holding the microphone, or a system-level input mute. The
/// Health row says so, and the engine restarts capture once.
///
/// Pure: the caller feeds it buffer peaks and clock ticks.
struct MicSignalWatchdog: Equatable {
    var threshold: TimeInterval

    /// True while the microphone is judged to deliver nothing.
    private(set) var noSignal = false
    /// Set while capture should deliver audio.
    private(set) var armedAt: TimeInterval?
    /// The last time a non-zero sample arrived.
    private(set) var lastSignalAt: TimeInterval?
    /// How many times it fired since it was last armed.
    private(set) var firings = 0

    init(threshold: TimeInterval = 3) {
        self.threshold = threshold
    }

    /// Capture started (or resumed): the clock starts now.
    mutating func arm(at now: TimeInterval) {
        armedAt = now
        lastSignalAt = nil
        noSignal = false
        firings = 0
    }

    /// Stopped or paused: nothing is expected, so nothing is wrong.
    mutating func disarm() {
        armedAt = nil
        lastSignalAt = nil
        noSignal = false
    }

    var isArmed: Bool { armedAt != nil }

    /// One captured buffer's peak (LSB). Returns the new `noSignal` when it
    /// changed.
    @discardableResult
    mutating func observe(peak: Int, at now: TimeInterval) -> Bool? {
        guard armedAt != nil else { return nil }
        if peak > 0 {
            lastSignalAt = now
            if noSignal {
                noSignal = false
                return false
            }
            return nil
        }
        return tick(at: now)
    }

    /// The clock moved (also when no buffers arrive at all). Returns the
    /// new `noSignal` when it changed.
    @discardableResult
    mutating func tick(at now: TimeInterval) -> Bool? {
        guard let armedAt else { return nil }
        let since = lastSignalAt ?? armedAt
        let silent = now - since >= threshold
        guard silent != noSignal else { return nil }
        noSignal = silent
        if silent { firings += 1 }
        return silent
    }
}

enum AudioLifecycle {
    /// The watchdog expects signal only from a running microphone that iOS
    /// hasn't paused (a call, Siri). Mute doesn't stop capture: the session
    /// just sends nothing, so the watchdog keeps watching.
    static func watchdogShouldRun(running: Bool, interrupted: Bool) -> Bool {
        running && !interrupted
    }
}

/// Hysteresis on "speaking": once audio has played, it still counts as
/// speaking for `holdSeconds` across a playback gap, so a brief underrun or
/// the pause between two chunks of one reply doesn't flip the session to
/// listening (and let an INTERRUPT result cut in). A flush is not a gap:
/// `reset` drops the hold at once.
struct SpeakingHold: Equatable {
    static let defaultHold: TimeInterval = 0.8

    let holdSeconds: TimeInterval
    private(set) var playing = false
    /// When playback last stopped, while the hold runs.
    private(set) var stoppedAt: TimeInterval?

    init(holdSeconds: TimeInterval = SpeakingHold.defaultHold) {
        self.holdSeconds = holdSeconds
    }

    /// Folds in whether audio is playing at `now`; returns whether it
    /// counts as speaking.
    @discardableResult
    mutating func update(playing isPlaying: Bool, now: TimeInterval) -> Bool {
        if isPlaying {
            playing = true
            stoppedAt = nil
            return true
        }
        if playing {
            playing = false
            stoppedAt = now
        }
        return speaking(at: now)
    }

    mutating func speaking(at now: TimeInterval) -> Bool {
        if playing { return true }
        guard let stoppedAt else { return false }
        if now - stoppedAt < holdSeconds { return true }
        self.stoppedAt = nil
        return false
    }

    mutating func reset() {
        playing = false
        stoppedAt = nil
    }
}
