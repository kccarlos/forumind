import Foundation

/// The audio boundary of a voice session. The engine behind it (capture
/// with echo cancellation, voice activity gate, playback queue) is plan B6
/// and not built yet; tests use a fake.
///
/// - Microphone frames come in as 16 kHz PCM16 mono, only while the
///   capture gate is open (the user is speaking).
/// - The model's 24 kHz PCM16 mono goes out to `play`.
@MainActor
protocol VoiceAudioIO: AnyObject {
    /// Starts capture and playback. `frame` gets microphone audio, `gate`
    /// the capture gate opening (true) and closing (false).
    func start(frame: @escaping @MainActor (Data) -> Void, gate: @escaping @MainActor (Bool) -> Void) async throws
    func stop()
    func play(_ pcm: Data)
    /// Drops queued playback (the user interrupted).
    func flushPlayback()
    /// Queued model audio is still playing. Gemini generates about four
    /// times faster than real time, so this is most of "speaking".
    var isPlaying: Bool { get }
    /// Headphones are the output: eyes-free mode on `auto`.
    var headphonesConnected: Bool { get }
}

/// Wall time for the session's timers (an injectable clock for tests).
@MainActor
protocol VoiceClock: AnyObject {
    var now: Date { get }
}

final class SystemVoiceClock: VoiceClock {
    nonisolated init() {}
    var now: Date { Date() }
}

/// Low-level noise like a real microphone's floor (±8 LSB). Sent for about
/// a second after the user stops, so the server's activity detection ends
/// the turn and transcribes the last words; streaming zeros instead stalled
/// turns by up to 35 s.
enum ComfortNoise {
    static let frameDuration: TimeInterval = 0.04
    static let duration: TimeInterval = 1.0
    /// 40 ms of 16 kHz PCM16.
    static let samplesPerFrame = 640

    static func frame(seed: inout UInt64) -> Data {
        var data = Data(capacity: samplesPerFrame * 2)
        for _ in 0..<samplesPerFrame {
            // xorshift: cheap and deterministic per session.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            let sample = Int16(Int(seed % 17) - 8)
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
