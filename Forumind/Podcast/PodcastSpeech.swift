import Foundation

// MARK: - Speech engines
//
// Each chapter is synthesized on its own and saved as one audio file in the
// cache, so playback can start after the first chapter.
//
// - `GeminiSpeechEngine`: `gemini-3.8-flash-tts` through `generateContent`
//   (AI Studio or Vertex AI, the user's key in `x-goog-api-key`), two hosts
//   in one request with `multiSpeakerVoiceConfig`, one host with
//   `voiceConfig`. Per the speech-generation docs (checked 2026-10-20): each
//   turn is its own part with `speech_metadata` {speaker, style}; a unary
//   response is WAV (RIFF header) at 24 kHz, mono, 16-bit, in
//   `candidates[0].content.parts[].inlineData`; raw PCM (`audio/L16;…;
//   rate=N`) is handled too. 429 and 5xx are retried with backoff.
// - `SystemSpeechEngine` (PodcastSystemSpeech.swift): `AVSpeechSynthesizer`
//   written to a file, two system voices alternating.
// - `SilentSpeechEngine` (DEBUG): the UI tests' engine.

/// Writes a chapter's speech to a file and returns its duration.
@MainActor
protocol PodcastSpeechEngine: AnyObject {
    /// The audio file's extension ("wav", "caf").
    var fileExtension: String { get }
    func synthesize(_ turns: [PodcastTurn], to url: URL) async throws -> TimeInterval
}

enum PodcastSpeechError: Error, Equatable, LocalizedError {
    case http(Int, String)
    /// Google answered without audio (blocked or empty).
    case noAudio(String)
    case unsupportedAudio(String)
    case synthesis(String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let detail):
            String(localized: "Google’s text-to-speech failed (\(status)): \(detail)", comment: "Podcast error; the placeholders are the HTTP status and Google's message, in English")
        case .noAudio(let reason):
            String(localized: "Google returned no audio (\(reason)).", comment: "Podcast error; the placeholder is Google's reason, in English")
        case .unsupportedAudio(let format):
            String(localized: "Google returned audio in a format Forumind can’t play (\(format)).", comment: "Podcast error; the placeholder is the audio format")
        case .synthesis(let reason):
            String(localized: "The voices couldn’t read this chapter (\(reason)).", comment: "Podcast error; the placeholder is the system's reason, in English")
        }
    }
}

// MARK: - Gemini TTS wire format

enum GeminiTTS {
    static let model = "gemini-3.8-flash-tts"
    /// Unary responses are 24 kHz mono 16-bit unless the format says otherwise.
    static let defaultSampleRate = 24_000

    struct Endpoint: Equatable {
        var provider: VoiceProvider
        /// The user's Gemini or Vertex address from Settings › AI models.
        var baseURL: String
        var apiKey: String
    }

    /// `{base}/models/{model}:generateContent` (AI Studio) or
    /// `{base}/publishers/google/models/{model}:generateContent` (Vertex AI,
    /// express-mode host or a project and location path). The key goes in
    /// the `x-goog-api-key` header on both, never in the URL.
    static func request(turns: [PodcastTurn], voices: PodcastVoices, endpoint: Endpoint, model: String = model) throws -> URLRequest {
        var base = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        let path = endpoint.provider == .vertex ? "publishers/google/models" : "models"
        let escaped = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        guard !base.isEmpty, let url = URL(string: "\(base)/\(path)/\(escaped):generateContent") else {
            throw PodcastSpeechError.synthesis("invalid address")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(endpoint.apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(turns: turns, voices: voices), options: [.sortedKeys])
        return request
    }

    /// Two speakers: every part names its speaker, and both are configured
    /// in `multiSpeakerVoiceConfig` (at most two, prebuilt voices). One
    /// speaker: `voiceConfig.voice`, parts carry only the style.
    static func body(turns: [PodcastTurn], voices: PodcastVoices) -> [String: Any] {
        let speakers = PodcastSpeaker.allCases.filter { speaker in turns.contains { $0.speaker == speaker } }
        let multi = speakers.count > 1
        let parts: [[String: Any]] = turns.map { turn in
            var metadata: [String: Any] = ["style": turn.speaker.speechStyle]
            if multi { metadata["speaker"] = turn.speaker.rawValue }
            return ["text": turn.text, "speech_metadata": metadata]
        }
        let speechConfig: [String: Any]
        if multi {
            speechConfig = [
                "multiSpeakerVoiceConfig": [
                    "speakerVoiceConfigs": speakers.map { speaker in
                        [
                            "speaker": speaker.rawValue,
                            "voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voices.voice(speaker)]]
                        ] as [String: Any]
                    }
                ]
            ]
        } else {
            speechConfig = ["voiceConfig": ["voice": voices.voice(speakers.first ?? .a)]]
        }
        return [
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": speechConfig
            ]
        ]
    }

    /// The audio of a `generateContent` response: every `inlineData` part
    /// decoded and joined, as PCM16 at the response's rate.
    static func decode(_ data: Data) throws -> PCMAudio {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PodcastSpeechError.noAudio("not JSON")
        }
        if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
            throw PodcastSpeechError.noAudio(reason)
        }
        let candidate = (json["candidates"] as? [[String: Any]])?.first
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        var audio: PCMAudio?
        for part in parts {
            guard let inline = (part["inlineData"] ?? part["inline_data"]) as? [String: Any],
                  let base64 = inline["data"] as? String,
                  let bytes = Data(base64Encoded: base64)
            else {
                continue
            }
            let mime = (inline["mimeType"] ?? inline["mime_type"]) as? String ?? ""
            let piece = try PCMAudio.decode(bytes, mimeType: mime)
            if var joined = audio {
                guard joined.sampleRate == piece.sampleRate, joined.channels == piece.channels else {
                    throw PodcastSpeechError.unsupportedAudio("mixed formats")
                }
                joined.samples.append(piece.samples)
                audio = joined
            } else {
                audio = piece
            }
        }
        guard let audio, !audio.samples.isEmpty else {
            throw PodcastSpeechError.noAudio(candidate?["finishReason"] as? String ?? "empty")
        }
        return audio
    }

    /// How long to wait before retrying a refused request: `Retry-After`,
    /// else the error's `RetryInfo.retryDelay` ("12s"), else nil.
    static func retryDelay(headers: [AnyHashable: Any], body: Data) -> TimeInterval? {
        for (key, value) in headers {
            if (key as? String)?.lowercased() == "retry-after", let seconds = TimeInterval("\(value)") {
                return seconds
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let details = (json["error"] as? [String: Any])?["details"] as? [[String: Any]]
        else {
            return nil
        }
        for detail in details {
            if let delay = detail["retryDelay"] as? String, delay.hasSuffix("s"), let seconds = TimeInterval(delay.dropLast()) {
                return seconds
            }
        }
        return nil
    }
}

/// 16-bit little-endian PCM.
struct PCMAudio: Equatable {
    var samples: Data
    var sampleRate: Int
    var channels: Int = 1

    var duration: TimeInterval {
        guard sampleRate > 0, channels > 0 else { return 0 }
        return TimeInterval(samples.count / (2 * channels)) / TimeInterval(sampleRate)
    }

    /// A WAV file's bytes, or headerless L16 with the rate from the mime type
    /// (`audio/L16;codec=pcm;rate=24000`). Sniffed: a RIFF header wins over
    /// the mime type.
    static func decode(_ bytes: Data, mimeType: String) throws -> PCMAudio {
        if bytes.starts(with: Array("RIFF".utf8)) {
            guard let audio = WAVFile.parse(bytes) else { throw PodcastSpeechError.unsupportedAudio(mimeType.isEmpty ? "WAV" : mimeType) }
            return audio
        }
        let lower = mimeType.lowercased()
        guard lower.isEmpty || lower.contains("l16") || lower.contains("pcm") else {
            throw PodcastSpeechError.unsupportedAudio(mimeType)
        }
        var rate = GeminiTTS.defaultSampleRate
        for parameter in lower.split(separator: ";") {
            let pair = parameter.split(separator: "=").map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == "rate", let value = Int(pair[1]), value > 0 { rate = value }
        }
        return PCMAudio(samples: bytes.count % 2 == 0 ? bytes : bytes.dropLast(), sampleRate: rate)
    }
}

/// Minimal RIFF/WAVE reading and writing (PCM 16-bit).
enum WAVFile {
    static func data(_ audio: PCMAudio) -> Data {
        var data = Data()
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let byteRate = UInt32(audio.sampleRate * audio.channels * 2)
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + audio.samples.count))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append32(16)
        append16(1)
        append16(UInt16(audio.channels))
        append32(UInt32(audio.sampleRate))
        append32(byteRate)
        append16(UInt16(audio.channels * 2))
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(audio.samples.count))
        data.append(audio.samples)
        return data
    }

    /// The PCM16 of a WAV file (chunks walked, so extra chunks are skipped).
    static func parse(_ bytes: Data) -> PCMAudio? {
        let data = Data([UInt8](bytes))
        guard data.count >= 12, data.starts(with: Array("RIFF".utf8)),
              data[8..<12].elementsEqual(Array("WAVE".utf8))
        else {
            return nil
        }
        func uint32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
        }
        func uint16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
        }
        var offset = 12
        var rate: Int?
        var channels = 1
        var bits = 16
        while offset + 8 <= data.count {
            let id = String(decoding: data[offset..<offset + 4], as: UTF8.self)
            var size = Int(uint32(offset + 4))
            let start = offset + 8
            if id == "fmt ", start + 16 <= data.count {
                channels = Int(uint16(start + 2))
                rate = Int(uint32(start + 4))
                bits = Int(uint16(start + 14))
            } else if id == "data" {
                // Streams written before their length was known say 0 or more.
                if size == 0 || size == 0xFFFF_FFFF || start + size > data.count { size = data.count - start }
                guard let rate, bits == 16, channels > 0 else { return nil }
                var samples = data.subdata(in: start..<start + size)
                if samples.count % 2 != 0 { samples = samples.dropLast() }
                return PCMAudio(samples: samples, sampleRate: rate, channels: channels)
            }
            offset = start + size + (size % 2)
        }
        return nil
    }
}

// MARK: - Gemini engine

/// Sends one chapter per request and writes the WAV it gets back.
@MainActor
final class GeminiSpeechEngine: PodcastSpeechEngine {
    struct Retry {
        var attempts = 5
        var baseDelay: TimeInterval = 2
        var maxDelay: TimeInterval = 60
    }

    let endpoint: GeminiTTS.Endpoint
    let voices: PodcastVoices
    var retry = Retry()
    private let session: URLSession
    /// Waits between retries (tests pass an instant one).
    private let sleep: (TimeInterval) async throws -> Void

    var fileExtension: String { "wav" }

    init(
        endpoint: GeminiTTS.Endpoint,
        voices: PodcastVoices,
        session: URLSession = .shared,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.endpoint = endpoint
        self.voices = voices
        self.session = session
        self.sleep = sleep
    }

    func synthesize(_ turns: [PodcastTurn], to url: URL) async throws -> TimeInterval {
        let request = try GeminiTTS.request(turns: turns, voices: voices, endpoint: endpoint)
        var attempt = 0
        while true {
            attempt += 1
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) {
                let audio = try GeminiTTS.decode(data)
                try WAVFile.data(audio).write(to: url, options: .atomic)
                return audio.duration
            }
            let retriable = status == 429 || status == 500 || status == 503 || status == 504
            guard retriable, attempt < retry.attempts else {
                throw PodcastSpeechError.http(status, Self.detail(data, status: status))
            }
            let hinted = GeminiTTS.retryDelay(headers: http?.allHeaderFields ?? [:], body: data)
            let backoff = retry.baseDelay * pow(2, Double(attempt - 1)) * Double.random(in: 1...1.25)
            try await sleep(min(retry.maxDelay, hinted ?? backoff))
        }
    }

    /// Google's error message, without anything that could be the key.
    private static func detail(_ data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = (json["error"] as? [String: Any])?["message"] as? String {
            return String(message.prefix(300))
        }
        return HTTPURLResponse.localizedString(forStatusCode: status)
    }
}

#if DEBUG
/// `-dc-podcast-fake`: a few seconds of silence per turn, written at once.
/// No network, no key, nothing spoken.
@MainActor
final class SilentSpeechEngine: PodcastSpeechEngine {
    var secondsPerTurn: Double = 4
    var fileExtension: String { "wav" }

    func synthesize(_ turns: [PodcastTurn], to url: URL) async throws -> TimeInterval {
        let rate = 8_000
        let frames = Int(Double(rate) * secondsPerTurn) * max(1, turns.count)
        let audio = PCMAudio(samples: Data(count: frames * 2), sampleRate: rate)
        try WAVFile.data(audio).write(to: url, options: .atomic)
        return audio.duration
    }
}
#endif
