import Foundation

enum AIProvider: String, Codable, CaseIterable, Identifiable {
    /// Apple Foundation Models: Private Cloud Compute when available, else
    /// on-device. Listed first so pickers show it first. No key, no base URL.
    case appleIntelligence = "appleintelligence"
    case openRouter = "openrouter"
    case openAI = "openai"
    case anthropic
    case groq
    case gemini
    /// Gemini on Google Cloud Vertex AI with an API key (express mode, or a
    /// project and location in the base URL). Same wire format as `gemini`.
    case vertexAI = "vertexai"
    case ollama
    case xAI = "xai"
    case deepSeek = "deepseek"
    case lmStudio = "lmstudio"
    case nvidia

    var id: String { rawValue }

    var displayName: String {
        switch self {
        // Apple's own name per language ("Apple 智能" in Simplified Chinese).
        case .appleIntelligence: String(localized: "Apple Intelligence", comment: "AI provider name. Use Apple's official name for Apple Intelligence in this language.")
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        case .groq: "Groq"
        case .gemini: "Google Gemini"
        case .vertexAI: "Google Vertex AI"
        case .ollama: String(localized: "Ollama (Local)", comment: "AI provider name: Ollama running on the user's own computer. Keep \"Ollama\".")
        case .xAI: "xAI Grok"
        case .deepSeek: "DeepSeek"
        case .lmStudio: String(localized: "LM Studio (Local)", comment: "AI provider name: LM Studio running on the user's own computer. Keep \"LM Studio\".")
        case .nvidia: "NVIDIA NIM"
        }
    }

    var defaultModel: String {
        switch self {
        // The backend is chosen at run time; records store "On-device" or
        // "Private Cloud Compute" (`RunSettings.resolvingAppleIntelligence`).
        case .appleIntelligence: "Automatic"
        case .openRouter: "moonshotai/kimi-k2"
        case .openAI: "gpt-4o-mini"
        case .anthropic: "claude-3-haiku-20240307"
        case .groq: "llama-3.1-8b-instant"
        case .gemini: "gemini-1.5-flash"
        case .vertexAI: "gemini-2.5-flash"
        case .ollama: "llama3.2"
        case .xAI: "grok-3"
        case .deepSeek: "deepseek-chat"
        case .lmStudio: "local-model"
        case .nvidia: "deepseek-ai/deepseek-v4-flash-0731"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .appleIntelligence: ""
        case .openRouter: "https://openrouter.ai/api/v1"
        case .openAI: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        // Express mode's global host. A project key can use
        // https://aiplatform.googleapis.com/v1/projects/<id>/locations/global.
        case .vertexAI: "https://aiplatform.googleapis.com/v1"
        case .ollama: "http://localhost:11434"
        case .xAI: "https://api.x.ai/v1"
        case .deepSeek: "https://api.deepseek.com/v1"
        case .lmStudio: "http://localhost:1234/v1"
        // OpenAI-compatible: /models, /chat/completions, SSE streaming.
        case .nvidia: "https://integrate.api.nvidia.com/v1"
        }
    }

    var requiresAPIKey: Bool {
        self != .ollama && self != .lmStudio && self != .appleIntelligence
    }

    /// Built into the OS (no key, no server address, no model list).
    var isAppleIntelligence: Bool { self == .appleIntelligence }

    /// A model server on the user's own computer (needs a server address).
    var isLocalServer: Bool { self == .ollama || self == .lmStudio }

    /// Vertex AI has no model list an API key can read, so the picker offers
    /// these Gemini models; any other model ID can still be typed.
    static let vertexAIModels = [
        "gemini-3.8-flash",
        "gemini-3.7-flash",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.1-pro-preview",
        "gemini-3.1-flash-lite",
        "gemini-3-flash-preview",
        "gemini-2.5-pro",
        "gemini-2.5-flash",
        "gemini-2.5-flash-lite"
    ]
}

/// A provider's connection (address and key). `model` is not stored: each
/// role's `ModelSelection` is the only model setting, and
/// `AppSettings.configuration(for: ModelRole)` fills it in for a request;
/// a provider's own configuration carries its default model.
struct ProviderConfiguration: Codable, Equatable {
    var model: String
    var baseURL: String
    var apiKey: String

    private enum CodingKeys: String, CodingKey { case baseURL, apiKey }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = ""
        baseURL = try container.decode(String.self, forKey: .baseURL)
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
    }

    init(model: String, baseURL: String, apiKey: String) {
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    init(provider: AIProvider) {
        model = provider.defaultModel
        baseURL = provider.defaultBaseURL
        apiKey = ""
    }
}

/// Which job a model is chosen for. Summaries, chat and watched-topic
/// refreshes use the assistant model; Ask the forum (planning, answers and
/// follow-ups) uses the agent model. See `AppModel+Models.swift`.
enum ModelRole: String, Codable, CaseIterable, Identifiable {
    case assistant
    case agent

    var id: String { rawValue }
}

/// A provider and one of its models: what a role runs with.
struct ModelSelection: Codable, Hashable {
    var provider: AIProvider
    var model: String
}

struct FavoriteModel: Codable, Hashable, Identifiable {
    var provider: AIProvider
    var model: String

    var id: String { "\(provider.rawValue):\(model)" }
}

enum BrowserBarPosition: String, Codable, CaseIterable, Identifiable {
    /// Bottom on iPhone and in narrow windows, top in the iPad split layout.
    /// The default for new users; existing users keep their stored choice.
    case automatic
    case top
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: String(localized: "Automatic", comment: "Browser address bar position: bottom on iPhone and in narrow windows, top in the iPad split layout")
        case .top: String(localized: "Top", comment: "Browser address bar position: at the top of the screen")
        case .bottom: String(localized: "Bottom", comment: "Browser address bar position: at the bottom of the screen")
        }
    }

    /// Where the bar goes in this layout: never `.automatic`.
    func resolved(isSplit: Bool) -> BrowserBarPosition {
        switch self {
        case .automatic: isSplit ? .top : .bottom
        case .top, .bottom: self
        }
    }
}

/// Character budget for one hierarchical-summary batch. Longer discussions are
/// split into batches of this size, each batch is summarized on its own, and the
/// batch summaries are combined into the final summary.
enum SummaryBatchLimit {
    static let `default` = 55_000
    static let minimum = 20_000
    static let maximum = 1_000_000
    static let step = 5_000
    static let presets = [20_000, 55_000, 100_000, 200_000, 500_000, 1_000_000]

    static func normalized(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }

    static func label(_ value: Int) -> String {
        value >= 1_000_000
            ? String(localized: "1M characters", comment: "Summary batch size: one million characters of text")
            : String(localized: "\(value / 1_000)k characters", comment: "Summary batch size in thousands of characters, e.g. 55k characters")
    }
}

struct AppSettings: Codable, Equatable {
    /// Summaries, chat and watched-topic refreshes.
    var assistantModel = ModelSelection(provider: .openRouter, model: AIProvider.openRouter.defaultModel)
    /// Ask the forum: planning, answers and follow-ups.
    var agentModel = ModelSelection(provider: .openRouter, model: AIProvider.openRouter.defaultModel)
    var configurations: [String: ProviderConfiguration] = Dictionary(
        uniqueKeysWithValues: AIProvider.allCases.map {
            ($0.rawValue, ProviderConfiguration(provider: $0))
        }
    )
    var favoriteModels: [FavoriteModel] = []
    var systemPrompt = ""
    var forumContextLimit = 30_000
    var summaryBatchLimit = SummaryBatchLimit.default
    var browserBarPosition: BrowserBarPosition = .automatic
    /// Where the app opens (HomeState.swift). Synced.
    var launchDestination: LaunchDestination = .automatic
    var agentMaxSteps = AgentLimits.defaultMaxSteps
    var agentMaxTopicReads = AgentLimits.defaultMaxTopicReads
    var agentReadLimit = AgentLimits.defaultReadLimit
    var watchAutoRefreshSummaries = true
    /// False on a fresh install until the walkthrough finishes.
    var hasCompletedOnboarding = false
    /// Built-in browser: block ads (EasyList). Off by default, out of respect
    /// for forum owners who rely on ads.
    var contentBlockingEnabled = false
    /// Built-in browser: block trackers (EasyPrivacy). Off by default.
    var blockTrackers = false
    /// Hosts (lowercased, no "www.") where blocking is off; subdomains match.
    var adBlockAllowedSites: [String] = []
    /// API keys are stored as iCloud Keychain (synchronizable) items. On by
    /// default. Turning it off keeps a local copy and leaves the synced item
    /// in place for the user's other devices.
    var syncAPIKeys = true
    /// How quickly requests go to one forum (see ForumRequestPacing.swift).
    var forumRequestPace: ForumRequestPace = .default
    /// Users whose posts are hidden, per forum (see Moderation.swift).
    var blockedUsers: [BlockedUser] = []
    /// Words and phrases whose posts are hidden on every forum.
    var filteredWords: [String] = []
    /// The Terms of Use version accepted on this device (0: none yet).
    var acceptedTermsVersion = 0
    /// Daily digest (see DailyDigest.swift). Off by default: making it
    /// spends the user's AI credits. On/off and the notification are per
    /// device (each device spends and schedules on its own); what goes in
    /// and how many cards sync.
    var dailyDigestEnabled = false
    var dailyDigestNotifies = false
    var dailyDigestIncludesWatched = true
    var dailyDigestIncludesTrending = true
    var dailyDigestMaxCards = DigestLimits.defaultCards
    /// Live voice (Forumind/Voice). Off until the user turns it on on this
    /// device; the consent per provider is this device's too (App Review
    /// 5.1.2: asked before the first session sends audio).
    var voiceEnabled = false
    var voiceConsent: [String: Date] = [:]
    var voice = VoiceSettings()
    /// The daily podcast (Forumind/Podcast): made right after the digest
    /// finishes on open. Off by default (it spends AI and TTS credits); the
    /// switch and the consent to send the script to Google are per device.
    var podcastDailyEnabled = false
    var podcastConsent: [String: Date] = [:]
    var podcast = PodcastSettings()
    /// The language summaries, digest cards and posts are translated into
    /// (Translation/ReadingLanguage.swift), and the podcast's script
    /// language. Empty: the app's language.
    var readingLanguage = ""
    /// Read topics and saved summaries in Spotlight (System/Spotlight.swift).
    /// On by default; each device keeps its own index.
    var spotlightEnabled = true
    /// Topics the user reads are offered to Siri suggestions
    /// (`NSUserActivity`). On by default; per device.
    var donatesTopicActivity = true
    /// AI data consent per provider (`AIDataConsent.swift`), keyed by the
    /// provider's raw value. Syncs, one unit per provider.
    var aiConsent: [String: AIConsentDecision] = [:]

    init() {}

    var hasAcceptedCurrentTerms: Bool { acceptedTermsVersion >= ModerationTerms.currentVersion }

    private enum CodingKeys: String, CodingKey {
        case assistantModel
        case agentModel
        case configurations
        case favoriteModels
        case systemPrompt
        case forumContextLimit
        case summaryBatchLimit
        case browserBarPosition
        case launchDestination
        case agentMaxSteps
        case agentMaxTopicReads
        case agentReadLimit
        case watchAutoRefreshSummaries
        case hasCompletedOnboarding
        case contentBlockingEnabled
        case blockTrackers
        case adBlockAllowedSites
        case syncAPIKeys
        case forumRequestPace
        case blockedUsers
        case filteredWords
        case acceptedTermsVersion
        case dailyDigestEnabled
        case dailyDigestNotifies
        case dailyDigestIncludesWatched
        case dailyDigestIncludesTrending
        case dailyDigestMaxCards
        case voiceEnabled
        case voiceConsent
        case voice
        case podcastDailyEnabled
        case podcastConsent
        case podcast
        case readingLanguage
        case spotlightEnabled
        case donatesTopicActivity
        case aiConsent
    }

    // A missing key takes its default; an unreadable value fails the decode
    // (the store then starts fresh).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decodeIfPresent([String: ProviderConfiguration].self, forKey: .configurations)
        configurations = stored.map { stored in
            Dictionary(uniqueKeysWithValues: stored.map { key, value in
                var configuration = value
                configuration.model = AIProvider(rawValue: key)?.defaultModel ?? ""
                return (key, configuration)
            })
        } ?? Dictionary(
            uniqueKeysWithValues: AIProvider.allCases.map {
                ($0.rawValue, ProviderConfiguration(provider: $0))
            }
        )
        favoriteModels = try container.decodeIfPresent([FavoriteModel].self, forKey: .favoriteModels)
            ?? []
        let stock = AppSettings()
        assistantModel = try container.decodeIfPresent(ModelSelection.self, forKey: .assistantModel) ?? stock.assistantModel
        agentModel = try container.decodeIfPresent(ModelSelection.self, forKey: .agentModel) ?? stock.agentModel
        systemPrompt = try container.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        forumContextLimit = try container.decodeIfPresent(Int.self, forKey: .forumContextLimit)
            ?? 30_000
        summaryBatchLimit = SummaryBatchLimit.normalized(
            try container.decodeIfPresent(Int.self, forKey: .summaryBatchLimit)
                ?? SummaryBatchLimit.default
        )
        browserBarPosition = try container.decodeIfPresent(BrowserBarPosition.self, forKey: .browserBarPosition) ?? stock.browserBarPosition
        launchDestination = try container.decodeIfPresent(LaunchDestination.self, forKey: .launchDestination) ?? stock.launchDestination
        agentMaxSteps = AgentLimits.clampSteps(
            try container.decodeIfPresent(Int.self, forKey: .agentMaxSteps)
                ?? AgentLimits.defaultMaxSteps
        )
        agentMaxTopicReads = AgentLimits.clampTopicReads(
            try container.decodeIfPresent(Int.self, forKey: .agentMaxTopicReads)
                ?? AgentLimits.defaultMaxTopicReads
        )
        agentReadLimit = AgentLimits.clampReadLimit(
            try container.decodeIfPresent(Int.self, forKey: .agentReadLimit)
                ?? AgentLimits.defaultReadLimit
        )
        watchAutoRefreshSummaries = try container.decodeIfPresent(
            Bool.self,
            forKey: .watchAutoRefreshSummaries
        ) ?? true
        hasCompletedOnboarding = try container.decodeIfPresent(
            Bool.self,
            forKey: .hasCompletedOnboarding
        ) ?? false
        contentBlockingEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .contentBlockingEnabled
        ) ?? false
        blockTrackers = try container.decodeIfPresent(Bool.self, forKey: .blockTrackers) ?? false
        adBlockAllowedSites = (try container.decodeIfPresent([String].self, forKey: .adBlockAllowedSites) ?? [])
            .compactMap(ContentBlockingRules.normalizedHost)
        syncAPIKeys = try container.decodeIfPresent(Bool.self, forKey: .syncAPIKeys) ?? true
        forumRequestPace = try container.decodeIfPresent(ForumRequestPace.self, forKey: .forumRequestPace) ?? .default
        blockedUsers = try container.decodeIfPresent([BlockedUser].self, forKey: .blockedUsers) ?? []
        filteredWords = try container.decodeIfPresent([String].self, forKey: .filteredWords) ?? []
        acceptedTermsVersion = try container.decodeIfPresent(Int.self, forKey: .acceptedTermsVersion) ?? 0
        dailyDigestEnabled = try container.decodeIfPresent(Bool.self, forKey: .dailyDigestEnabled) ?? false
        dailyDigestNotifies = try container.decodeIfPresent(Bool.self, forKey: .dailyDigestNotifies) ?? false
        dailyDigestIncludesWatched = try container.decodeIfPresent(Bool.self, forKey: .dailyDigestIncludesWatched) ?? true
        dailyDigestIncludesTrending = try container.decodeIfPresent(Bool.self, forKey: .dailyDigestIncludesTrending) ?? true
        dailyDigestMaxCards = DigestLimits.clampCards(
            try container.decodeIfPresent(Int.self, forKey: .dailyDigestMaxCards) ?? DigestLimits.defaultCards
        )
        voiceEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? false
        voiceConsent = try container.decodeIfPresent([String: Date].self, forKey: .voiceConsent) ?? [:]
        voice = try container.decodeIfPresent(VoiceSettings.self, forKey: .voice) ?? VoiceSettings()
        podcastDailyEnabled = try container.decodeIfPresent(Bool.self, forKey: .podcastDailyEnabled) ?? false
        podcastConsent = try container.decodeIfPresent([String: Date].self, forKey: .podcastConsent) ?? [:]
        podcast = try container.decodeIfPresent(PodcastSettings.self, forKey: .podcast) ?? PodcastSettings()
        readingLanguage = try container.decodeIfPresent(String.self, forKey: .readingLanguage) ?? ""
        spotlightEnabled = try container.decodeIfPresent(Bool.self, forKey: .spotlightEnabled) ?? true
        donatesTopicActivity = try container.decodeIfPresent(Bool.self, forKey: .donatesTopicActivity) ?? true
        aiConsent = try container.decodeIfPresent([String: AIConsentDecision].self, forKey: .aiConsent) ?? [:]
    }

    func configuration(for provider: AIProvider) -> ProviderConfiguration {
        var configuration = configurations[provider.rawValue] ?? ProviderConfiguration(provider: provider)
        configuration.model = provider.defaultModel
        return configuration
    }

    mutating func setConfiguration(_ configuration: ProviderConfiguration, for provider: AIProvider) {
        var stored = configuration
        stored.model = provider.defaultModel
        configurations[provider.rawValue] = stored
    }

    var persistable: AppSettings {
        var copy = self
        for provider in AIProvider.allCases {
            var configuration = copy.configuration(for: provider)
            configuration.apiKey = ""
            copy.setConfiguration(configuration, for: provider)
        }
        return copy
    }
}

struct RawForumPage: Codable, Equatable {
    var page: Int
    var content: String
    /// The topic's post count when the page was fetched: a page that was full
    /// then never changes (`CachePlan`).
    var topicPostCount: Int?

    /// Posts per raw page.
    static let size = 100
}

enum ChatRole: String, Codable {
    case user
    case assistant
}

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: ChatRole
    var content: String
    var createdAt = Date()
}

struct TopicSession: Codable, Identifiable, Equatable {
    /// The forum's site URL (origin + base path).
    var siteURL: String
    var topicID: String
    var url: URL
    var title: String
    var source = ""
    var rawPages: [RawForumPage] = []
    var summary = ""
    var history: [ChatMessage] = []
    var kept = false
    /// Per-topic instructions; when non-empty they replace the global custom
    /// instructions for this topic's summary and chat.
    var instructions = ""
    var totalPosts: Int?
    var summaryPostCount: Int?
    var provider: AIProvider?
    var model = ""
    var createdAt = Date()
    var updatedAt = Date()
    var summaryUpdatedAt: Date?
    var chatUpdatedAt: Date?
    var lastCheckedAt: Date?
    /// When the user last opened the topic in the browser; nil when only
    /// the agent (or a digest) read it. Continue reading, Spotlight and the
    /// Siri topic entities list only topics the user opened (or summaries).
    var openedByUserAt: Date?

    init(
        siteURL: String,
        topicID: String,
        url: URL,
        title: String
    ) {
        self.siteURL = siteURL
        self.topicID = topicID
        self.url = url
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case siteURL, topicID, url, title, source, rawPages, summary, history, kept, instructions
        case totalPosts, summaryPostCount, provider, model, createdAt, updatedAt
        case summaryUpdatedAt, chatUpdatedAt, lastCheckedAt, openedByUserAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        topicID = try container.decode(String.self, forKey: .topicID)
        url = try container.decode(URL.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        rawPages = try container.decodeIfPresent([RawForumPage].self, forKey: .rawPages) ?? []
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        history = try container.decodeIfPresent([ChatMessage].self, forKey: .history) ?? []
        kept = try container.decodeIfPresent(Bool.self, forKey: .kept) ?? false
        instructions = try container.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        totalPosts = try container.decodeIfPresent(Int.self, forKey: .totalPosts)
        summaryPostCount = try container.decodeIfPresent(Int.self, forKey: .summaryPostCount)
        provider = try container.decodeIfPresent(AIProvider.self, forKey: .provider)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        summaryUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .summaryUpdatedAt)
        chatUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .chatUpdatedAt)
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        openedByUserAt = try container.decodeIfPresent(Date.self, forKey: .openedByUserAt)
    }

    /// `host[/basePath]/t/{id}`; the key of `AppModel.sessions`.
    var topicKey: String { TopicIdentity.key(siteURL: siteURL, topicID: topicID) }
    var id: String { topicKey }
    var hasSummary: Bool { !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    /// When the user last opened it, else when it last changed (lists and
    /// "· 2 hours ago" lines).
    var lastSeenAt: Date { openedByUserAt ?? updatedAt }
    var hasInstructions: Bool {
        !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasStaleSummary: Bool {
        guard hasSummary,
              let summaryPostCount,
              let totalPosts
        else {
            return false
        }
        return totalPosts > summaryPostCount
    }
}

struct ExportOptions: Equatable {
    var excludeTitleAndURL = false
    var excludeSummary = false
    var excludePostAndResponses = false
    var excludeChatHistory = false
}

struct TopicExportPayload: Equatable {
    let summary: String
    let source: String
    let title: String
    let url: URL?
    let history: [ChatMessage]

    var hasTitleAndURL: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(url?.absoluteString.isEmpty ?? true)
    }

    var hasSummary: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSource: Bool {
        !source.isEmpty
    }

    var hasChatHistory: Bool {
        !history.isEmpty
    }

    func text(options: ExportOptions) -> String {
        var sections: [String] = []
        if !options.excludeTitleAndURL {
            if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(title)
            }
            if let url, !url.absoluteString.isEmpty {
                sections.append(String(localized: "Post URL: \(url.absoluteString)", comment: "Exported text: line with the forum post's address"))
            }
        }
        if !options.excludeSummary,
           !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(String(localized: "Summary:\n\(summary)", comment: "Exported text: heading followed by the AI summary"))
        }
        if !options.excludePostAndResponses, !source.isEmpty {
            sections.append(String(localized: "Full post:\n\(source)", comment: "Exported text: heading followed by the forum post and its replies"))
        }
        if !options.excludeChatHistory, !history.isEmpty {
            let transcript = history.map { message in
                let role = message.role == .user
                    ? String(localized: "User", comment: "Exported chat transcript: label for the user's messages")
                    : String(localized: "Assistant", comment: "Exported chat transcript: label for the AI's messages")
                return "\(role):\n\(message.content)"
            }
            let joined = transcript.joined(separator: "\n\n")
            sections.append(String(localized: "Chat history:\n\(joined)", comment: "Exported text: heading followed by the chat transcript"))
        }
        return sections.joined(separator: "\n\n")
    }

    func hasContent(options: ExportOptions) -> Bool {
        !text(options: options).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum ForumPreview {
    static func compact(
        _ source: String,
        headLines: Int = 50,
        tailLines: Int = 50
    ) -> String {
        let lines = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let visibleLines = headLines + tailLines
        guard lines.count > visibleLines else { return source }
        let omitted = lines.count - visibleLines
        return lines.prefix(headLines).joined(separator: "\n")
            + "\n\n" + String(localized: "[… \(omitted) middle lines omitted from the preview …]", comment: "Shown in the middle of a long forum post preview") + "\n\n"
            + lines.suffix(tailLines).joined(separator: "\n")
    }
}

struct ForumTopic: Equatable, Identifiable {
    let siteURL: String
    let topicID: String
    let url: URL
    let title: String

    var topicKey: String { TopicIdentity.key(siteURL: siteURL, topicID: topicID) }
    var id: String { topicKey }

    /// Parses `/t/{slug}/{id}` (or `/t/{id}`) under `basePath` on any host.
    /// URL-only: callers must know the page is on a Discourse forum (probe or
    /// forum directory). The default title uses the forum name.
    static func parse(
        url: URL?,
        title: String?,
        basePath: String = "",
        forumName: String? = nil
    ) -> ForumTopic? {
        guard let url,
              let siteURL = ForumSite.siteURL(fromPage: url, basePath: basePath),
              let topicID = ForumSite.extractTopicID(from: url, basePath: basePath)
        else {
            return nil
        }

        var canonical = URLComponents(url: url, resolvingAgainstBaseURL: false)
        canonical?.query = nil
        canonical?.fragment = nil
        guard let canonicalURL = canonical?.url else { return nil }
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ForumSite.displayName(siteURL: siteURL, name: forumName)
        return ForumTopic(
            siteURL: siteURL,
            topicID: topicID,
            url: canonicalURL,
            title: normalizedTitle?.isEmpty == false
                ? normalizedTitle!
                : String(localized: "\(name) topic \(topicID)", comment: "Fallback title of a forum topic: forum name, then the topic's number")
        )
    }
}

/// Topic keys for records. A record whose id is not a forum topic id (agent
/// work records use `agent:{runID}`) keys on its id unchanged.
enum TopicIdentity {
    static func key(siteURL: String, topicID: String) -> String {
        ForumSite.topicKey(siteURL: siteURL, topicID: topicID) ?? topicID
    }
}

enum WorkType: String, Codable {
    case summary
    case pull
    case chat
    case agent
}

/// Budget for one agent run. Steps count every tool call; topic reads count
/// each distinct topic whose posts are pulled or summarized.
enum AgentLimits {
    static let defaultMaxSteps = 15
    static let stepRange = 3...60
    static let defaultMaxTopicReads = 8
    static let topicReadRange = 1...30
    static let defaultReadLimit = 30_000
    static let readLimitRange = 10_000...200_000

    static func clampSteps(_ value: Int) -> Int {
        min(stepRange.upperBound, max(stepRange.lowerBound, value))
    }

    static func clampTopicReads(_ value: Int) -> Int {
        min(topicReadRange.upperBound, max(topicReadRange.lowerBound, value))
    }

    static func clampReadLimit(_ value: Int) -> Int {
        min(readLimitRange.upperBound, max(readLimitRange.lowerBound, value))
    }
}

/// One tool call (or the final answer) inside an agent run.
struct AgentStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var tool: String
    var arguments: [String: String] = [:]
    var thought = ""
    /// Short human-readable outcome shown in the step log.
    var outcome = ""
    var isError = false
    var topicID: String?
    /// Key of the topic the step read (`sessions` key), when it read one.
    var topicKey: String?
    var startedAt = Date()
    var finishedAt: Date?
}

/// How an Ask the forum run was started; History tags voice runs.
enum AgentRunOrigin: String, Codable, CaseIterable {
    case typed, voice, shortcut
}

/// A goal-driven run of the forum agent, kept so it can be reopened and
/// continued with follow-up questions.
/// The terminal outcome of an agent run.
enum AgentRunResult: String, Codable, Equatable {
    case completed
    case failed
    case cancelled

    var workStatus: WorkStatus {
        switch self {
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}

struct AgentRun: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The forum every tool call of this run (and its follow-ups) targets.
    var siteURL: String
    var goal: String
    /// How the run ended; nil while it is live. Whether a live run is queued
    /// or running is its work record's (`AppModel.status(of:)`).
    var result: AgentRunResult?
    var steps: [AgentStep] = []
    /// Model/observation exchange; follow-ups append to it so the agent keeps
    /// the topics it already read as context.
    var transcript: [ChatMessage] = []
    /// The latest answer (updated by follow-ups).
    var answer = ""
    /// The answer to the original goal, kept when follow-ups replace `answer`.
    var initialAnswer = ""
    /// Follow-up questions and their answers, in order.
    var followUps: [ChatMessage] = []
    var topicIDs: [String] = []
    var error = ""
    var provider: AIProvider
    var model: String
    var origin: AgentRunOrigin = .typed
    var createdAt = Date()
    var updatedAt = Date()
    var completedAt: Date?

    var readTopicCount: Int { topicIDs.count }

    var isFinished: Bool { result != nil }

    init(id: UUID = UUID(), siteURL: String, goal: String, provider: AIProvider, model: String, origin: AgentRunOrigin = .typed) {
        self.id = id
        self.origin = origin
        self.siteURL = siteURL
        self.goal = goal
        self.provider = provider
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case id, siteURL, goal, result, steps, transcript, answer, initialAnswer, followUps
        case topicIDs, error, provider, model, origin, createdAt, updatedAt, completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        goal = try container.decode(String.self, forKey: .goal)
        result = try container.decodeIfPresent(AgentRunResult.self, forKey: .result)
        steps = try container.decode([AgentStep].self, forKey: .steps)
        transcript = try container.decode([ChatMessage].self, forKey: .transcript)
        answer = try container.decode(String.self, forKey: .answer)
        initialAnswer = try container.decode(String.self, forKey: .initialAnswer)
        followUps = try container.decode([ChatMessage].self, forKey: .followUps)
        topicIDs = try container.decode([String].self, forKey: .topicIDs)
        error = try container.decode(String.self, forKey: .error)
        provider = try container.decode(AIProvider.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        origin = try container.decode(AgentRunOrigin.self, forKey: .origin)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

/// A topic the app checks for new replies on the user's behalf.
struct WatchedTopic: Codable, Identifiable, Equatable {
    var siteURL: String
    var topicID: String
    var url: URL
    var title: String
    var knownPostCount: Int
    var newReplies = 0
    var addedAt = Date()
    var lastCheckedAt: Date?

    var topicKey: String { TopicIdentity.key(siteURL: siteURL, topicID: topicID) }
    var id: String { topicKey }

    init(siteURL: String, topicID: String, url: URL, title: String, knownPostCount: Int) {
        self.siteURL = siteURL
        self.topicID = topicID
        self.url = url
        self.title = title
        self.knownPostCount = knownPostCount
    }

    private enum CodingKeys: String, CodingKey {
        case siteURL, topicID, url, title, knownPostCount, newReplies, addedAt, lastCheckedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        topicID = try container.decode(String.self, forKey: .topicID)
        url = try container.decode(URL.self, forKey: .url)
        title = try container.decode(String.self, forKey: .title)
        knownPostCount = try container.decode(Int.self, forKey: .knownPostCount)
        newReplies = try container.decodeIfPresent(Int.self, forKey: .newReplies) ?? 0
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
    }

    /// Applies a fresh post count. Returns the number of replies that arrived
    /// since the last check (0 when nothing changed).
    mutating func record(postCount: Int, at date: Date = Date()) -> Int {
        lastCheckedAt = date
        let delta = max(0, postCount - knownPostCount)
        if delta > 0 {
            newReplies += delta
            knownPostCount = postCount
        }
        return delta
    }

    mutating func markSeen() {
        newReplies = 0
    }
}

/// A topic as listed by the forum's search/latest endpoints.
struct ForumTopicListing: Codable, Equatable, Identifiable {
    var siteURL: String
    var id: Int
    var title: String
    var slug: String
    var postsCount: Int
    var lastPostedAt: String?
    var excerpt: String?
    /// From topic lists (`/latest.json`, `/top.json`); nil from search.
    var isPinned: Bool?
    var likeCount: Int?
    var hasAcceptedAnswer: Bool?

    var topicID: String { String(id) }

    var url: URL {
        ForumSite.topicURL(siteURL: siteURL, topicID: topicID, slug: slug)
            ?? URL(string: siteURL) ?? URL(string: "about:blank")!
    }
}

/// Title and post count of a topic from `/t/{id}.json`.
struct ForumTopicOverview: Equatable {
    var siteURL: String
    var topicID: String
    var title: String
    var slug: String
    var postCount: Int
    /// Read from the same JSON.
    var facts: ForumTopicFacts?

    var url: URL {
        ForumSite.topicURL(siteURL: siteURL, topicID: topicID, slug: slug)
            ?? URL(string: siteURL) ?? URL(string: "about:blank")!
    }
}

/// One Discourse search hit: a post in a topic. `/search.json` can return
/// several posts of one topic; hits keep the forum's order.
struct ForumSearchHit: Equatable, Identifiable {
    var topic: ForumTopicListing
    var postNumber: Int
    var username: String?
    var blurb: String?

    var id: String { "\(topic.id)/\(postNumber)" }

    /// The topic opened at this post.
    var url: URL {
        ForumSite.topicURL(siteURL: topic.siteURL, topicID: topic.topicID, slug: topic.slug, postNumber: postNumber)
            ?? topic.url
    }
}

/// What `/t/{id}.json` says about a topic beyond its title, without another
/// request: size, the post-id stream, the opening poster, the accepted answer
/// (Solved plugin) and the posts the JSON included (about the first 20).
struct ForumTopicFacts: Equatable {
    struct Post: Equatable {
        var id: Int
        var number: Int
        var username: String
        var likeCount: Int?
    }

    struct AcceptedAnswer: Equatable {
        var postNumber: Int
        var username: String?
    }

    var postsCount: Int?
    var highestPostNumber: Int?
    /// Every post id in topic order. Its positions are not post numbers:
    /// deleted posts leave gaps in the numbering.
    var stream: [Int] = []
    var openingPoster: String?
    var acceptedAnswer: AcceptedAnswer?
    var posts: [Post] = []

    /// The id of post `number`, when the JSON included that post.
    func postID(forNumber number: Int) -> Int? {
        posts.first { $0.number == number }?.id
    }

    /// The id of post `number` if known, else a guess: counted along the
    /// stream from the nearest included post before it. Deleted posts after
    /// that one make the guess land later, so callers check the number of
    /// the post that comes back.
    func likelyPostID(forNumber number: Int) -> Int? {
        if let id = postID(forNumber: number) { return id }
        guard number >= 1, !stream.isEmpty else { return nil }
        let anchor = posts
            .filter { $0.number < number }
            .max { $0.number < $1.number }
            .flatMap { post in stream.firstIndex(of: post.id).map { (index: $0, number: post.number) } }
        let index = anchor.map { $0.index + number - $0.number } ?? number - 1
        return stream[min(index, stream.count - 1)]
    }
}

/// A post fetched by id (`/t/{id}/posts.json`), its cooked HTML as plain text.
struct ForumPost: Equatable, Identifiable {
    var id: Int
    var number: Int
    var username: String
    var text: String
    var likeCount: Int?
}

/// Who asked for a job. Work the app starts by itself (a watched topic's
/// summary refresh) never interrupts with an alert: a failure stays on its
/// record in Activity.
enum WorkOrigin: String, Codable {
    case user
    case automatic
}

enum WorkStatus: String, Codable {
    case queued
    case running
    case completed
    case failed
    case cancelled

    var isTerminal: Bool {
        self == .completed || self == .failed || self == .cancelled
    }
}

struct WorkRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var type: WorkType
    /// The forum the work runs against.
    var siteURL: String
    /// Forum topic id, or `agent:{runID}` for agent work.
    var topicID: String
    var title: String
    var url: URL
    var question = ""
    var provider: AIProvider
    var model: String
    var status: WorkStatus = .queued
    var origin: WorkOrigin = .user
    var statusText = WorkRecord.waitingStatusText
    var progress: Double?
    var error = ""
    /// Per-run override of the hierarchical-summary batch size; nil uses the
    /// setting current when the task runs (survives task restoration).
    var batchLimit: Int?
    /// Summary Retry: written again even when no reply is new. Not saved (a
    /// restored task summarizes normally).
    var regenerate: Bool?
    var createdAt = Date()
    var updatedAt = Date()
    var startedAt: Date?
    var completedAt: Date?

    static var waitingStatusText: String {
        String(localized: "Waiting for an available worker…", comment: "Status of queued AI work (summary, chat or research) before it starts")
    }

    /// `host[/basePath]/t/{id}`, or `agent:{runID}` for agent work.
    var topicKey: String { TopicIdentity.key(siteURL: siteURL, topicID: topicID) }

    init(
        id: UUID = UUID(),
        type: WorkType,
        siteURL: String,
        topicID: String,
        title: String,
        url: URL,
        question: String = "",
        provider: AIProvider,
        model: String
    ) {
        self.id = id
        self.type = type
        self.siteURL = siteURL
        self.topicID = topicID
        self.title = title
        self.url = url
        self.question = question
        self.provider = provider
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, siteURL, topicID, title, url, question, provider, model, status, origin
        case statusText, progress, error, batchLimit, createdAt, updatedAt, startedAt, completedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        type = try container.decode(WorkType.self, forKey: .type)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        topicID = try container.decode(String.self, forKey: .topicID)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decode(URL.self, forKey: .url)
        question = try container.decodeIfPresent(String.self, forKey: .question) ?? ""
        provider = try container.decode(AIProvider.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        status = try container.decode(WorkStatus.self, forKey: .status)
        origin = try container.decodeIfPresent(WorkOrigin.self, forKey: .origin) ?? .user
        statusText = try container.decodeIfPresent(String.self, forKey: .statusText) ?? ""
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        error = try container.decodeIfPresent(String.self, forKey: .error) ?? ""
        batchLimit = try container.decodeIfPresent(Int.self, forKey: .batchLimit)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

struct ForumFetchProgress: Equatable {
    var completedPages: Int
    var totalPages: Int
    var totalPosts: Int
    var message: String

    var fraction: Double {
        guard totalPages > 0 else { return 0 }
        return min(1, max(0, Double(completedPages) / Double(totalPages)))
    }
}

struct ForumFetchResult: Equatable {
    var content: String
    var rawPages: [RawForumPage]
    var totalPosts: Int
    var unchanged: Bool
    var newPosts: Int
    /// From the topic JSON fetched for the post count.
    var facts: ForumTopicFacts?
}

struct ForumResourceResponse {
    var statusCode: Int
    var statusText: String
    var retryAfter: String?
    var data: Data
}

/// Which pages of a topic to fetch. A page that was full when it was
/// fetched never changes (replies are appended), so it is reused; the last,
/// growing page and every missing one (a read cut short, pages dropped to
/// save space) are fetched. Fewer posts than before (deleted replies): all
/// pages again.
enum CachePlan: Equatable {
    case unchanged
    case fetch(reusablePages: [RawForumPage], pageNumbers: [Int])

    /// `knownTotalPosts`: the session's post count, for pages saved without
    /// their own.
    static func make(
        cachedPages: [RawForumPage],
        knownTotalPosts: Int?,
        currentTotalPosts: Int,
        totalPages: Int
    ) -> CachePlan {
        let allPages = Array(1...max(1, totalPages))
        let normalized = Dictionary(
            cachedPages.map { ($0.page, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let fetchedAt = { (page: RawForumPage) in page.topicPostCount ?? knownTotalPosts }
        // Replies were deleted since a page was fetched: nothing lines up.
        if normalized.values.contains(where: { (fetchedAt($0) ?? 0) > currentTotalPosts }) {
            return .fetch(reusablePages: [], pageNumbers: allPages)
        }
        // Full when fetched (it never changes), or fetched at today's count.
        let reusable = normalized.values
            .filter { page in
                guard page.page <= totalPages, let count = fetchedAt(page) else { return false }
                return page.page * RawForumPage.size <= count || count == currentTotalPosts
            }
            .sorted { $0.page < $1.page }
        let reused = Set(reusable.map(\.page))
        let missing = allPages.filter { !reused.contains($0) }
        return missing.isEmpty ? .unchanged : .fetch(reusablePages: reusable, pageNumbers: missing)
    }
}

enum AssistantError: LocalizedError {
    case noTopic
    case noForum
    case missingConfiguration(String)
    case invalidResponse
    case http(Int, String)
    case emptyResponse
    case cancelled
    /// Forum content can't go to this provider before the person agrees
    /// (`AIDataConsent.swift`); work the app starts by itself waits.
    case aiConsentRequired(AIProvider)
    /// The person chose Don't Allow (or withdrew consent) for this provider.
    case aiConsentDeclined(AIProvider)

    var errorDescription: String? {
        switch self {
        case .noTopic:
            String(localized: "Open a Discourse topic first.")
        case .noForum:
            String(localized: "Open a Discourse forum first.")
        case .missingConfiguration(let message):
            message
        case .invalidResponse:
            String(localized: "The server returned an invalid response.")
        case .http(let status, let message):
            String(localized: "HTTP \(status): \(message)", comment: "Error: HTTP status code, then the server's message")
        case .emptyResponse:
            String(localized: "The AI provider returned an empty response.")
        case .cancelled:
            String(localized: "The operation was cancelled.")
        case .aiConsentRequired(let provider):
            String(localized: "Waiting for your OK to send forum content to \(provider.displayName). Start a summary or a question to answer, or allow it in Settings › Data & privacy.", comment: "Error; the placeholder is an AI provider's name. Settings › Data & privacy names the app's own Settings page.")
        case .aiConsentDeclined(let provider):
            String(localized: "You chose not to send forum content to \(provider.displayName). To use it, allow it in Settings › Data & privacy.", comment: "Error; the placeholder is an AI provider's name. Settings › Data & privacy names the app's own Settings page.")
        }
    }
}
