import Foundation

// MARK: - Podcast settings
//
// The podcast's preferences sync with the other settings (hosts, voices,
// engine, length). Whether it is made every day, and the consent to send
// the script to Google, are per device (`AppSettings.podcastDailyEnabled`,
// `podcastConsent`; see `SyncSettings.deviceLocalKeys`).

/// The two hosts. Their ids in the script and in the TTS request are the
/// fixed ASCII "A" and "B"; the names the user sees and hears are separate,
/// so a renamed (or Chinese) name never reaches `speech_metadata.speaker`.
enum PodcastSpeaker: String, Codable, CaseIterable, Identifiable {
    /// The guide: walks through each topic.
    case a = "A"
    /// The co-host: asks what a reader would ask, reacts briefly.
    case b = "B"

    var id: String { rawValue }

    /// The default name, in the interface language. Short names that read
    /// and sound the same in English and Chinese speech.
    var defaultName: String {
        switch self {
        case .a: String(localized: "Ava", comment: "Podcast: the default name of the first host (the guide). A short name that is easy to say in this language.")
        case .b: String(localized: "Leo", comment: "Podcast: the default name of the second host (the curious co-host). A short name that is easy to say in this language.")
        }
    }

    /// What the host does, for the script prompt (English, like every prompt).
    var promptRole: String {
        switch self {
        case .a: "the guide, who explains each topic clearly and briefly"
        case .b: "the curious co-host, who asks what a reader would ask and reacts in a few words"
        }
    }

    /// The delivery style sent with each turn (`speech_metadata.style`).
    var speechStyle: String {
        switch self {
        case .a: "warm, clear and unhurried, like a morning radio host"
        case .b: "curious and relaxed, conversational"
        }
    }
}

/// The resolved host names of one episode (kept with it).
struct PodcastHosts: Codable, Equatable {
    var a: String
    var b: String

    func name(_ speaker: PodcastSpeaker) -> String {
        speaker == .a ? a : b
    }
}

/// Which speech engine reads the podcast.
enum PodcastEngineChoice: String, Codable, CaseIterable, Identifiable {
    /// Google's voices when a Gemini or Vertex key is there (and agreed to),
    /// otherwise the device's.
    case automatic
    /// Gemini TTS; asks for consent the first time.
    case google
    /// `AVSpeechSynthesizer`: free and offline.
    case onDevice = "ondevice"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .google: String(localized: "Google voices", comment: "Podcast speech engine setting: Gemini text-to-speech")
        case .onDevice: String(localized: "On-device voices", comment: "Podcast speech engine setting: the iPhone's built-in voices")
        }
    }
}

struct PodcastSettings: Codable, Equatable {
    /// Empty: the default name in the interface language (`PodcastSpeaker`),
    /// resolved when an episode is made, so it never freezes in the language
    /// that first saved it.
    var hostA = ""
    var hostB = ""
    /// Gemini prebuilt voices (`VoiceCatalog`).
    var voiceA = PodcastSettings.defaultVoiceA
    var voiceB = PodcastSettings.defaultVoiceB
    var engine: PodcastEngineChoice = .automatic
    /// Spoken minutes per topic chapter.
    var minutesPerChapter = PodcastSettings.defaultMinutes

    /// Google's own multi-speaker example pair: a firm and an upbeat voice,
    /// easy to tell apart.
    static let defaultVoiceA = "Kore"
    static let defaultVoiceB = "Puck"
    static let defaultMinutes = 1.0
    static let minuteChoices: [Double] = [0.5, 1, 2, 3]
    static let minuteRange: ClosedRange<Double> = 0.5...3

    init() {}

    var hosts: PodcastHosts {
        PodcastHosts(a: Self.resolved(hostA, .a), b: Self.resolved(hostB, .b))
    }

    var voices: PodcastVoices {
        PodcastVoices(a: voiceA, b: voiceB)
    }

    private static func resolved(_ name: String, _ speaker: PodcastSpeaker) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? speaker.defaultName : String(trimmed.prefix(24))
    }

    private enum CodingKeys: String, CodingKey {
        case hostA, hostB, voiceA, voiceB, engine, minutesPerChapter
    }

    // Each field falls back on its own, like `VoiceSettings`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        hostA = value(.hostA, "")
        hostB = value(.hostB, "")
        let known = Set(VoiceCatalog.voices.map(\.name))
        let a = value(.voiceA, Self.defaultVoiceA)
        let b = value(.voiceB, Self.defaultVoiceB)
        voiceA = known.contains(a) ? a : Self.defaultVoiceA
        voiceB = known.contains(b) ? b : Self.defaultVoiceB
        engine = value(.engine, .automatic)
        minutesPerChapter = min(Self.minuteRange.upperBound, max(Self.minuteRange.lowerBound, value(.minutesPerChapter, Self.defaultMinutes)))
    }
}

/// The Gemini voice of each host.
struct PodcastVoices: Codable, Equatable {
    var a: String
    var b: String

    func voice(_ speaker: PodcastSpeaker) -> String {
        speaker == .a ? a : b
    }
}

// MARK: - Consent (App Review 5.1.2)

/// Consent to send the podcast script (text, not audio) to Google for
/// text-to-speech, asked once per provider before the first Google-voiced
/// episode and kept on this device. Separate from the voice consent: voice
/// sends the microphone audio, and either can be agreed to or withdrawn
/// without the other.
enum PodcastConsent {
    static func isGranted(_ provider: VoiceProvider, in settings: AppSettings) -> Bool {
        settings.podcastConsent[provider.rawValue] != nil
    }
}

// MARK: - Engine selection

/// The engine an episode (or a read-aloud) uses.
enum PodcastEngineKind: String, Codable, Equatable {
    /// Gemini TTS through Google AI Studio (the Gemini key).
    case aiStudio
    /// Gemini TTS through Vertex AI (the Vertex key).
    case vertex
    case onDevice = "ondevice"
    /// The UI tests' engine (`-dc-podcast-fake`): silent audio, no network.
    case fake

    var provider: VoiceProvider? {
        switch self {
        case .aiStudio: .aiStudio
        case .vertex: .vertex
        case .onDevice, .fake: nil
        }
    }

    init(_ provider: VoiceProvider) {
        self = provider == .vertex ? .vertex : .aiStudio
    }

    /// "Google voices" or "On-device voices": what Now Playing and the Today
    /// card say about the episode (derived from the engine the episode keeps).
    var label: String {
        switch self {
        case .aiStudio, .vertex: PodcastEngineChoice.google.label
        case .onDevice, .fake: PodcastEngineChoice.onDevice.label
        }
    }
}

enum PodcastEngineSelection: Equatable {
    case engine(PodcastEngineKind)
    /// Google voices were asked for, and this provider's consent is missing.
    case needsConsent(VoiceProvider)
}

enum PodcastEngineSelector {
    /// - `providers`: the Google providers with a key, preferred first.
    /// - `interactive`: the user tapped Make or Play. The daily podcast made
    ///   on open never asks: without consent it uses the device's voices.
    static func select(
        choice: PodcastEngineChoice,
        providers: [VoiceProvider],
        settings: AppSettings,
        interactive: Bool
    ) -> PodcastEngineSelection {
        guard choice != .onDevice, let provider = providers.first else { return .engine(.onDevice) }
        if PodcastConsent.isGranted(provider, in: settings) { return .engine(PodcastEngineKind(provider)) }
        if let agreed = providers.first(where: { PodcastConsent.isGranted($0, in: settings) }) {
            return .engine(PodcastEngineKind(agreed))
        }
        guard interactive else { return .engine(.onDevice) }
        return .needsConsent(provider)
    }
}
