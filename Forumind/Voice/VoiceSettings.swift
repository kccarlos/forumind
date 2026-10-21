import Foundation

/// The provider a voice session talks to. Both use the user's own key from
/// Settings › AI models (the Keychain); there is no Forumind server.
enum VoiceProvider: String, Codable, CaseIterable, Identifiable {
    /// Google AI Studio, with the Google Gemini key.
    case aiStudio = "aistudio"
    /// Vertex AI, with the Google Vertex AI key.
    case vertex

    var id: String { rawValue }

    /// The AI provider whose key and address it uses.
    var keyProvider: AIProvider {
        switch self {
        case .aiStudio: .gemini
        case .vertex: .vertexAI
        }
    }

    var displayName: String {
        switch self {
        case .aiStudio: "Google AI Studio"
        case .vertex: "Google Vertex AI"
        }
    }
}

/// How much the voice says. Told only to keep replies short, voice models
/// answered in one line and left the user asking follow-ups, so even
/// `short` asks for a real answer.
enum VoiceAnswerLength: String, Codable, CaseIterable, Identifiable {
    case short
    case normal
    case detailed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .short: String(localized: "Short", comment: "Voice answer length setting: brief spoken answers")
        case .normal: String(localized: "Normal", comment: "Voice answer length setting: the default length of spoken answers")
        case .detailed: String(localized: "Detailed", comment: "Voice answer length setting: thorough spoken answers")
        }
    }
}

/// Whether the voice may read posts out instead of pointing at the screen.
enum VoiceEyesFree: String, Codable, CaseIterable, Identifiable {
    /// On while headphones are connected.
    case auto
    case on
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: String(localized: "Automatic")
        case .on: String(localized: "On")
        case .off: String(localized: "Off")
        }
    }

    func isActive(headphones: Bool) -> Bool {
        switch self {
        case .auto: headphones
        case .on: true
        case .off: false
        }
    }
}

/// Voice preferences (they sync with the other settings). Whether voice is
/// on, and the consent, are per device (`AppSettings.voiceEnabled`,
/// `voiceConsent`).
struct VoiceSettings: Codable, Equatable {
    var provider: VoiceProvider = .aiStudio
    /// A prebuilt Gemini voice (`VoiceCatalog`); empty keeps Google's default.
    var voiceName = VoiceCatalog.defaultVoice
    var answerLength: VoiceAnswerLength = .normal
    var eyesFree: VoiceEyesFree = .auto
    /// Seconds without speech either way before the session closes (it
    /// reopens on the next tap): every connected minute is billed.
    var idleTimeout: Double = VoiceSettings.defaultIdleTimeout
    /// Send the focused post's full text when the user's words point at the
    /// screen ("this post", "他说的"), before the model answers.
    var groundsOnScreenReference = true
    /// Send it also when the reader stops on a post for about 2 s (the
    /// fallback if the transcript arrives too late for the rule above).
    var groundsOnDwell = true
    /// The Google Cloud project for Vertex AI, when the Vertex address in
    /// Settings has none (an express-mode key has no project in it).
    var vertexProject = ""
    /// The cost guard, in connected minutes (0: no limit). At a limit the
    /// session ends after the current answer. Every connected minute is
    /// billed to the user's key.
    var sessionLimitMinutes = VoiceSettings.defaultSessionLimit
    var dailyLimitMinutes = VoiceSettings.defaultDailyLimit

    static let defaultIdleTimeout: Double = 60
    static let defaultSessionLimit = 15
    static let defaultDailyLimit = 30
    /// The choices Settings offers (0 is "No limit").
    static let sessionLimitChoices = [5, 10, 15, 30, 60, 0]
    static let dailyLimitChoices = [15, 30, 60, 120, 0]

    /// A limit in seconds, nil for "no limit".
    static func limit(_ minutes: Int) -> TimeInterval? {
        minutes > 0 ? TimeInterval(minutes) * 60 : nil
    }
    static let idleTimeoutRange: ClosedRange<Double> = 15...600

    init() {}

    private enum CodingKeys: String, CodingKey {
        case provider, voiceName, answerLength, eyesFree, idleTimeout
        case groundsOnScreenReference, groundsOnDwell, vertexProject
        case sessionLimitMinutes, dailyLimitMinutes
    }

    // Each field falls back on its own: a newer build's value, or a missing
    // one, never resets the others.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)).flatMap { $0 } ?? fallback
        }
        provider = value(.provider, .aiStudio)
        // Builds before the voice list saved "" for Google's default.
        let name = value(.voiceName, VoiceCatalog.defaultVoice)
        voiceName = name.isEmpty ? VoiceCatalog.defaultVoice : name
        answerLength = value(.answerLength, .normal)
        eyesFree = value(.eyesFree, .auto)
        idleTimeout = min(Self.idleTimeoutRange.upperBound, max(Self.idleTimeoutRange.lowerBound, value(.idleTimeout, Self.defaultIdleTimeout)))
        groundsOnScreenReference = value(.groundsOnScreenReference, true)
        groundsOnDwell = value(.groundsOnDwell, true)
        vertexProject = value(.vertexProject, "")
        sessionLimitMinutes = max(0, value(.sessionLimitMinutes, Self.defaultSessionLimit))
        dailyLimitMinutes = max(0, value(.dailyLimitMinutes, Self.defaultDailyLimit))
    }
}

// MARK: - Voices

/// The prebuilt voices. The Live API docs say native-audio models such as
/// `gemini-3.8-live` take any of the text-to-speech voices; this is that
/// list (ai.google.dev, speech generation, checked 2026-10-20), with
/// Google's one-word style. Add or remove names here.
enum VoiceCatalog {
    struct Voice: Identifiable, Equatable {
        let name: String
        /// Google's style word, in English.
        let style: String
        var id: String { name }
    }

    /// Warm and unhurried, for reading along with someone.
    static let defaultVoice = "Sulafat"

    static let voices: [Voice] = [
        ("Achernar", "Soft"), ("Achird", "Friendly"), ("Algenib", "Gravelly"), ("Algieba", "Smooth"),
        ("Alnilam", "Firm"), ("Aoede", "Breezy"), ("Autonoe", "Bright"), ("Callirrhoe", "Easy-going"),
        ("Charon", "Informative"), ("Despina", "Smooth"), ("Enceladus", "Breathy"), ("Erinome", "Clear"),
        ("Fenrir", "Excitable"), ("Gacrux", "Mature"), ("Iapetus", "Clear"), ("Kore", "Firm"),
        ("Laomedeia", "Upbeat"), ("Leda", "Youthful"), ("Orus", "Firm"), ("Puck", "Upbeat"),
        ("Pulcherrima", "Forward"), ("Rasalgethi", "Informative"), ("Sadachbia", "Lively"),
        ("Sadaltager", "Knowledgeable"), ("Schedar", "Even"), ("Sulafat", "Warm"), ("Umbriel", "Easy-going"),
        ("Vindemiatrix", "Gentle"), ("Zephyr", "Bright"), ("Zubenelgenubi", "Casual")
    ].map { Voice(name: $0.0, style: $0.1) }
}

// MARK: - Consent (App Review 5.1.2)

/// Explicit consent to send audio and page content to the provider, asked
/// once per provider before its first session and kept on this device.
enum VoiceConsent {
    /// What the user agrees to (shown on the consent sheet).
    static var text: String {
        String(localized: "Audio and the page content you ask about are sent to Google.", comment: "Voice consent: what a live voice session sends, and to whom")
    }

    static func isGranted(_ provider: VoiceProvider, in settings: AppSettings) -> Bool {
        settings.voiceConsent[provider.rawValue] != nil
    }
}

// MARK: - Minutes used

/// Connected minutes per session and per day, for the cost guard. Kept on
/// this device in UserDefaults: each device spends its own minutes.
final class VoiceUsageStore {
    private let defaults: UserDefaults
    private let calendar: Calendar
    private static let daysKey = "voice.usage.secondsByDay"
    private static let lastSessionKey = "voice.usage.lastSessionSeconds"
    /// Days kept (the rest are dropped).
    static let keptDays = 60

    init(defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        self.defaults = defaults
        self.calendar = calendar
    }

    /// Seconds connected on `date`'s day.
    func seconds(on date: Date) -> Double {
        days[Self.dayKey(date, calendar: calendar)] ?? 0
    }

    func minutes(on date: Date) -> Double { seconds(on: date) / 60 }

    /// The last (or current) session's seconds.
    var lastSessionSeconds: Double { defaults.double(forKey: Self.lastSessionKey) }

    /// Adds connected time on `date`'s day; `sessionTotal` is the session's
    /// running total.
    func add(seconds: Double, at date: Date, sessionTotal: Double) {
        guard seconds > 0 else { return }
        var days = days
        let key = Self.dayKey(date, calendar: calendar)
        days[key, default: 0] += seconds
        if days.count > Self.keptDays {
            for old in days.keys.sorted().prefix(days.count - Self.keptDays) { days[old] = nil }
        }
        defaults.set(days, forKey: Self.daysKey)
        defaults.set(sessionTotal, forKey: Self.lastSessionKey)
    }

    private var days: [String: Double] {
        defaults.dictionary(forKey: Self.daysKey) as? [String: Double] ?? [:]
    }

    /// "2026-10-20" in the user's calendar.
    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
