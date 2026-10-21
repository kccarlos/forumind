import AVFoundation
import Foundation

// MARK: - On-device speech

/// A system voice, as the selection sees it (tests build these by hand).
struct SystemVoiceCandidate: Equatable {
    enum Gender: Equatable {
        case female
        case male
        case unknown
    }

    var identifier: String
    /// BCP-47, "en-US", "zh-CN".
    var language: String
    /// 1 default, 2 enhanced, 3 premium.
    var quality: Int
    var gender: Gender = .unknown
    var isNovelty = false

    init(identifier: String, language: String, quality: Int, gender: Gender = .unknown, isNovelty: Bool = false) {
        self.identifier = identifier
        self.language = language
        self.quality = quality
        self.gender = gender
        self.isNovelty = isNovelty
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        identifier = voice.identifier
        language = voice.language
        quality = voice.quality.rawValue
        switch voice.gender {
        case .female: gender = .female
        case .male: gender = .male
        default: gender = .unknown
        }
        isNovelty = voice.voiceTraits.contains(.isNoveltyVoice)
    }
}

/// Picks the two system voices of the on-device podcast.
enum PodcastSystemVoices {
    struct Pick: Equatable {
        var a: String
        var b: String
        /// Only one voice fits: host B speaks with a raised pitch.
        var sameVoice: Bool { a == b }
    }

    /// The speech languages for an app language, best first.
    static func languages(for appLanguage: String, region: String? = Locale.current.region?.identifier) -> [String] {
        switch appLanguage {
        case "zh-Hans": return ["zh-CN", "zh-TW", "zh-HK"]
        case "zh-Hant": return ["zh-TW", "zh-HK", "zh-CN"]
        default:
            let base = String(appLanguage.prefix { $0 != "-" })
            var result: [String] = []
            if let region { result.append("\(base)-\(region)") }
            if base == "en" { result += ["en-US", "en-GB", "en-AU"] }
            return result.reduce(into: []) { if !$0.contains($1) { $0.append($1) } } + [base]
        }
    }

    /// Two distinct voices for the language: no novelty voices, the best
    /// quality first, the preferred region first, and host B of another
    /// gender when one is known. Nil when no voice speaks the language.
    static func pick(appLanguage: String, from voices: [SystemVoiceCandidate], region: String? = Locale.current.region?.identifier) -> Pick? {
        let wanted = languages(for: appLanguage, region: region)
        func rank(_ voice: SystemVoiceCandidate) -> Int? {
            if let exact = wanted.firstIndex(of: voice.language) { return exact }
            let base = String(voice.language.prefix { $0 != "-" })
            // Only a bare base ("en") matches any region; Chinese scripts don't mix.
            if wanted.last == base, !appLanguage.hasPrefix("zh") { return wanted.count }
            return nil
        }
        let fitting = voices
            .filter { !$0.isNovelty }
            .compactMap { voice in rank(voice).map { (voice, $0) } }
            .sorted { lhs, rhs in
                if lhs.0.quality != rhs.0.quality { return lhs.0.quality > rhs.0.quality }
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.identifier < rhs.0.identifier
            }
            .map(\.0)
        guard let first = fitting.first else { return nil }
        let others = fitting.dropFirst().filter { $0.identifier != first.identifier }
        let contrast = others.first {
            first.gender != .unknown && $0.gender != .unknown && $0.gender != first.gender && $0.quality == first.quality
        }
        let second = contrast ?? others.first { $0.language == first.language } ?? others.first
        return Pick(a: first.identifier, b: second?.identifier ?? first.identifier)
    }
}

/// `AVSpeechSynthesizer` written to a file (`write(_:toBufferCallback:)`),
/// turn by turn, with the two hosts on two voices and a short pause between
/// turns. Every buffer is converted to one format before it is written:
/// voices can deliver different formats.
@MainActor
final class SystemSpeechEngine: PodcastSpeechEngine {
    let pick: PodcastSystemVoices.Pick?
    let language: String
    /// Seconds of silence between turns.
    var turnGap: Double = 0.35
    /// The longest one turn may take to synthesize.
    var turnTimeout: TimeInterval = 90

    private let synthesizer = AVSpeechSynthesizer()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22_050, channels: 1, interleaved: false)!

    var fileExtension: String { "caf" }

    init(appLanguage: String) {
        language = PodcastSystemVoices.languages(for: appLanguage).first ?? "en-US"
        pick = PodcastSystemVoices.pick(
            appLanguage: appLanguage,
            from: AVSpeechSynthesisVoice.speechVoices().map(SystemVoiceCandidate.init)
        )
    }

    func synthesize(_ turns: [PodcastTurn], to url: URL) async throws -> TimeInterval {
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var frames: AVAudioFramePosition = 0
        for (index, turn) in turns.enumerated() {
            try Task.checkCancellation()
            if index > 0, let gap = silence(seconds: turnGap) {
                try file.write(from: gap)
                frames += AVAudioFramePosition(gap.frameLength)
            }
            for buffer in try await speak(turn) {
                try file.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            }
        }
        return Double(frames) / format.sampleRate
    }

    private func utterance(_ turn: PodcastTurn) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: turn.text)
        let identifier = turn.speaker == .a ? pick?.a : pick?.b
        utterance.voice = identifier.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: language)
        if turn.speaker == .b, pick?.sameVoice ?? true { utterance.pitchMultiplier = 1.2 }
        utterance.prefersAssistiveTechnologySettings = false
        return utterance
    }

    /// The turn's audio, converted to `format`.
    private func speak(_ turn: PodcastTurn) async throws -> [AVAudioPCMBuffer] {
        let collector = BufferCollector(format: format)
        let utterance = utterance(turn)
        let timeout = turnTimeout
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.continuation = continuation
                synthesizer.write(utterance) { buffer in
                    collector.receive(buffer)
                }
                Task { @MainActor [weak collector] in
                    try? await Task.sleep(for: .seconds(timeout))
                    collector?.fail(PodcastSpeechError.synthesis("timed out"))
                }
            }
        } onCancel: { [synthesizer] in
            Task { @MainActor in synthesizer.stopSpeaking(at: .immediate) }
            collector.fail(CancellationError())
        }
    }

    private func silence(seconds: Double) -> AVAudioPCMBuffer? {
        let count = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
        buffer.frameLength = count
        return buffer
    }
}

/// Gathers one utterance's buffers (delivered on the synthesizer's queue)
/// and resumes once: at the empty end buffer, a failure or the timeout.
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let format: AVAudioFormat
    private var buffers: [AVAudioPCMBuffer] = []
    private var converter: AVAudioConverter?
    var continuation: CheckedContinuation<[AVAudioPCMBuffer], Error>?

    init(format: AVAudioFormat) {
        self.format = format
    }

    func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.lock()
        defer { lock.unlock() }
        guard continuation != nil else { return }
        if pcm.frameLength == 0 {
            continuation?.resume(returning: buffers)
            continuation = nil
            return
        }
        if let converted = convert(pcm) { buffers.append(converted) }
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
