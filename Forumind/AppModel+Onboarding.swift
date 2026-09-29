import Foundation
import SwiftUI

// MARK: - Onboarding and Settings support (UI engineer B)
//
// - `OnboardingStep`                 the walkthrough pages, in order (pure)
// - `ProviderGuide`                  per-provider help text and key/download links (pure)
// - `SettingsPage`                   Settings sub-pages (navigation values)
// - `testProviderInline()`           tests the selected provider; returns an error message or nil
// - `loadModelsInline()`             model discovery; returns an error message or nil
// - `clearSavedData(forSiteURL:)`    deletes a forum's summaries, chats, runs, and watches (keeps the forum)
// - `clearAllSavedData()`            the same for every forum
// - `savedItemCount(forSiteURL:)`    how many saved items a forum has
// - `applyOnboardingDebugArguments()` DEBUG launch arguments for screenshots

/// One page of the first-launch walkthrough.
enum OnboardingStep: Int, CaseIterable, Identifiable, Hashable {
    case welcome
    case features
    case provider
    case forums
    case sync
    case share
    case privacy
    case done

    var id: Int { rawValue }

    static var first: OnboardingStep { .welcome }
    static var last: OnboardingStep { .done }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }
    var isFirst: Bool { self == .first }
    var isLast: Bool { self == .last }

    /// 0...1 position for the progress indicator.
    var progress: Double {
        Double(rawValue) / Double(Self.allCases.count - 1)
    }

    /// Short title used for accessibility ("Step 3 of 8: Connect an AI provider").
    var title: String {
        switch self {
        case .welcome: String(localized: "Welcome")
        case .features: String(localized: "What it does")
        case .provider: String(localized: "Connect an AI provider")
        case .forums: String(localized: "Choose your forums")
        case .sync: String(localized: "Sync across your devices")
        case .share: String(localized: "Share from Safari or Chrome")
        case .privacy: String(localized: "Your privacy")
        case .done: String(localized: "You’re all set")
        }
    }

    /// "Step 3 of 8": matches the progress dots (which include Welcome and Done).
    var stepLabel: String {
        String(localized: "Step \(rawValue + 1) of \(Self.allCases.count)", comment: "Walkthrough progress, e.g. Step 3 of 8")
    }

    var accessibilityLabel: String {
        String(localized: "Step \(rawValue + 1) of \(Self.allCases.count): \(title)", comment: "Walkthrough progress for VoiceOver: step number, total, step title")
    }

    /// Steps the user may skip past (optional setup).
    var allowsSkip: Bool {
        switch self {
        case .provider, .forums: true
        default: false
        }
    }

    /// Label of the primary button on this step.
    var continueTitle: String {
        switch self {
        case .welcome: String(localized: "Get started")
        case .done: String(localized: "Finish")
        default: String(localized: "Continue")
        }
    }

    /// Steps with text fields, where swiping between pages is disabled so
    /// editing text never flips the page.
    var hasTextInput: Bool {
        self == .provider || self == .forums
    }

    /// Parses a DEBUG `-dc-onboarding-step` value: a 1-based number or a name.
    static func parse(_ value: String) -> OnboardingStep? {
        if let number = Int(value) {
            return OnboardingStep(rawValue: number - 1)
        }
        let lowered = value.lowercased()
        return allCases.first { String(describing: $0) == lowered }
    }
}

/// Help text and links for choosing and connecting an AI provider (matches the
/// provider table in the README).
struct ProviderGuide: Equatable {
    /// One-line "good to know".
    var blurb: String
    /// Where to get a key (hosted) or the app (local).
    var link: URL
    var linkTitle: String
    /// Extra advice shown under the fields.
    var note: String?
    /// A local server (Ollama, LM Studio): the link downloads the app.
    var isLocal = false

    static func guide(for provider: AIProvider) -> ProviderGuide {
        switch provider {
        case .appleIntelligence:
            ProviderGuide(
                blurb: String(localized: "Built in and private. Runs on this device or on Apple’s Private Cloud Compute; nothing goes anywhere else. No key, no bill."),
                link: URL(string: "https://www.apple.com/apple-intelligence/")!,
                linkTitle: String(localized: "About Apple Intelligence"),
                note: String(localized: "Needs iOS 26 or later on a device that supports Apple Intelligence, with Apple Intelligence turned on in Settings.")
            )
        case .openRouter:
            ProviderGuide(
                blurb: String(localized: "One key, hundreds of models. An easy place to start."),
                link: URL(string: "https://openrouter.ai/keys")!,
                linkTitle: String(localized: "Get a key at openrouter.ai")
            )
        case .openAI:
            ProviderGuide(
                blurb: String(localized: "GPT models from OpenAI."),
                link: URL(string: "https://platform.openai.com/api-keys")!,
                linkTitle: String(localized: "Get a key at platform.openai.com")
            )
        case .anthropic:
            ProviderGuide(
                blurb: String(localized: "Claude models from Anthropic."),
                link: URL(string: "https://console.anthropic.com/settings/keys")!,
                linkTitle: String(localized: "Get a key at console.anthropic.com")
            )
        case .groq:
            ProviderGuide(
                blurb: String(localized: "Very fast open models, with a free tier."),
                link: URL(string: "https://console.groq.com/keys")!,
                linkTitle: String(localized: "Get a key at console.groq.com")
            )
        case .gemini:
            ProviderGuide(
                blurb: String(localized: "Gemini models from Google, with a free tier."),
                link: URL(string: "https://aistudio.google.com/app/apikey")!,
                linkTitle: String(localized: "Get a key in Google AI Studio")
            )
        case .vertexAI:
            ProviderGuide(
                blurb: String(localized: "Gemini models through your Google Cloud project, billed to it."),
                link: URL(string: "https://console.cloud.google.com/apis/credentials")!,
                linkTitle: String(localized: "Get a key in the Google Cloud console"),
                note: String(localized: "Use a Vertex AI API key. The model list is built in; you can also type any Gemini model ID that your project can use.")
            )
        case .ollama:
            ProviderGuide(
                blurb: String(localized: "Runs on your own computer. No key and no usage bill."),
                link: URL(string: "https://ollama.com/download")!,
                linkTitle: String(localized: "Download Ollama"),
                note: String(localized: "Use your computer’s network address (for example http://192.168.1.20:11434), not localhost, and start Ollama with OLLAMA_HOST=0.0.0.0 so your iPhone or iPad can reach it."),
                isLocal: true
            )
        case .xAI:
            ProviderGuide(
                blurb: String(localized: "Grok models from xAI."),
                link: URL(string: "https://console.x.ai")!,
                linkTitle: String(localized: "Get a key at console.x.ai")
            )
        case .deepSeek:
            ProviderGuide(
                blurb: String(localized: "DeepSeek’s low-cost chat and reasoning models."),
                link: URL(string: "https://platform.deepseek.com/api_keys")!,
                linkTitle: String(localized: "Get a key at platform.deepseek.com")
            )
        case .lmStudio:
            ProviderGuide(
                blurb: String(localized: "Runs on your own computer. No key and no usage bill."),
                link: URL(string: "https://lmstudio.ai")!,
                linkTitle: String(localized: "Download LM Studio"),
                note: String(localized: "Turn on “Serve on Local Network” in LM Studio and use your computer’s network address (for example http://192.168.1.20:1234/v1).", comment: "“Serve on Local Network” is the name of a setting in LM Studio (English UI)."),
                isLocal: true
            )
        case .nvidia:
            ProviderGuide(
                blurb: String(localized: "Open models hosted by NVIDIA, with free credits to start."),
                link: URL(string: "https://build.nvidia.com/settings/api-keys")!,
                linkTitle: String(localized: "Get a key at build.nvidia.com")
            )
        }
    }
}

/// Settings sub-pages (navigation destinations).
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case provider
    case sync
    case forums
    case summaries
    case agent
    case watched
    case browser
    case data
    case help
    case sharing
    case about
    case acknowledgements

    var id: String { rawValue }

    var title: String {
        switch self {
        case .provider: String(localized: "AI models", comment: "Settings page: the AI models for summaries & chat and for Ask the forum, and the providers' keys")
        case .sync: String(localized: "iCloud Sync")
        case .forums: String(localized: "Forums")
        case .summaries: String(localized: "Summaries & chat")
        case .agent: String(localized: "Ask the forum")
        case .watched: String(localized: "Watched topics")
        case .browser: String(localized: "Browser")
        case .data: String(localized: "Data & privacy")
        case .help: String(localized: "Help")
        case .sharing: String(localized: "Share from Safari or Chrome")
        case .about: String(localized: "About")
        case .acknowledgements: String(localized: "Acknowledgements")
        }
    }

    var systemImage: String {
        switch self {
        case .provider: "cpu"
        case .sync: "icloud.fill"
        case .forums: "bubble.left.and.bubble.right.fill"
        case .summaries: "text.alignleft"
        case .agent: "sparkle.magnifyingglass"
        case .watched: "bell.badge.fill"
        case .browser: "safari.fill"
        case .data: "hand.raised.fill"
        case .help: "questionmark"
        case .sharing: "square.and.arrow.up"
        case .about: "info"
        case .acknowledgements: "text.book.closed.fill"
        }
    }

    var tint: Color {
        switch self {
        case .provider: DCTheme.brandPurple
        case .sync: Color(light: 0x2F7FE6, dark: 0x5AAEFF)
        case .forums: DCTheme.brandBlue
        case .summaries: DCTheme.summaryTint
        case .agent: DCTheme.agentTint
        case .watched: Color(light: 0xD9372B, dark: 0xFF6259)
        case .browser: Color(light: 0x1C7CD6, dark: 0x4AA3FF)
        case .data: Color(light: 0x4B5563, dark: 0x8E96A3)
        case .help: DCTheme.chatTint
        case .sharing: Color(light: 0x1C7CD6, dark: 0x4AA3FF)
        case .about: Color(light: 0x6B7280, dark: 0x8E96A3)
        case .acknowledgements: Color(light: 0x6B7280, dark: 0x8E96A3)
        }
    }

    /// Parses a DEBUG `-dc-show-settings` value; "root" or unknown → nil.
    static func parse(_ value: String) -> SettingsPage? {
        SettingsPage(rawValue: value.lowercased())
    }
}

/// App version text for About ("1.0 (1)").
enum AppVersion {
    static func text(info: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    static let repositoryURL = URL(string: "https://github.com/kccarlos/forumind")!
}

extension AppModel {
    /// Runs the connection test for a role's provider and reports the
    /// result inline instead of through the app-wide alert (which cannot show
    /// over the onboarding cover). Returns nil on success.
    /// A stale result (settings changed meanwhile) returns nil; use
    /// `testConnection(for:)` to tell it apart from success.
    func testProviderInline(for role: ModelRole = .assistant) async -> String? {
        if case .failure(let message) = await testConnection(for: role) { return message }
        return nil
    }

    /// Loads a provider's model list into `discoveredModels`. Returns an
    /// error message, or nil on success (or when its settings changed meanwhile).
    func loadModelsInline(provider: AIProvider) async -> String? {
        if case .failure(let message) = await discoverModels(provider: provider) { return message }
        return nil
    }

    /// Saved summaries, chats, agent runs, and watched topics for a forum.
    func savedItemCount(forSiteURL siteURL: String) -> Int {
        sessions.values.filter { $0.siteURL == siteURL }.count
            + agentRuns.filter { $0.siteURL == siteURL }.count
            + watchedTopics.filter { $0.siteURL == siteURL }.count
    }

    var totalSavedItemCount: Int {
        sessions.count + agentRuns.count + watchedTopics.count
    }

    /// Site URLs that have saved data, including forums no longer in the list.
    var siteURLsWithSavedData: [String] {
        var seen = Set<String>()
        let all = sessions.values.map(\.siteURL) + agentRuns.map(\.siteURL)
            + watchedTopics.map(\.siteURL) + activities.map(\.siteURL)
        return all.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Deletes a forum's saved summaries, chats, activity, agent runs, and
    /// watched topics; active work is cancelled first. The forum stays.
    ///
    /// Drafts are kept on purpose (they are unsent text, not saved data),
    /// except a follow-up draft for an agent run that was deleted.
    func clearSavedData(forSiteURL siteURL: String) {
        for record in activities where record.siteURL == siteURL && !record.status.isTerminal {
            cancel(record: record)
        }
        for record in activities where record.siteURL == siteURL {
            deleteActivity(id: record.id)
        }
        for run in agentRuns where run.siteURL == siteURL {
            deleteAgentRun(id: run.id)
        }
        for watched in watchedTopics where watched.siteURL == siteURL {
            unwatch(topicKey: watched.topicKey)
        }
        for session in sessions.values where session.siteURL == siteURL {
            deleteSession(topicKey: session.topicKey)
        }
    }

    func clearAllSavedData() {
        for siteURL in siteURLsWithSavedData {
            clearSavedData(forSiteURL: siteURL)
        }
    }
}

#if DEBUG
/// DEBUG launch arguments for QA and screenshots (see `applyOnboardingDebugArguments`).
enum OnboardingDebug {
    static var arguments: [String] { ProcessInfo.processInfo.arguments }

    static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    /// `-dc-onboarding-step N|name` opens the walkthrough on that step.
    static var initialStep: OnboardingStep? {
        value(after: "-dc-onboarding-step").flatMap(OnboardingStep.parse)
    }

    /// `-dc-show-settings root|<page>` presents Settings on launch.
    static var settingsPage: String? { value(after: "-dc-show-settings") }
}

extension AppModel {
    /// - `-dc-reset`               shows the walkthrough again (no data is deleted)
    /// - `-dc-onboarding-step N`   walkthrough on step N (1-based) or a step name
    /// - `-dc-skip-onboarding`     marks the walkthrough done (UI tests)
    /// - `-dc-show-settings <page>` Settings on launch (root, provider, forums, …)
    /// - `-dc-panel-settings`      opens Settings inside the assistant panel
    /// - `-dc-keychain-sync-probe` also skips the walkthrough so the probe alert shows
    func applyOnboardingDebugArguments() {
        let arguments = OnboardingDebug.arguments
        if arguments.contains("-dc-panel-settings") {
            settings.hasCompletedOnboarding = true
            panelRoute = .settings
        }
        if arguments.contains("-dc-reset") || OnboardingDebug.initialStep != nil {
            settings.hasCompletedOnboarding = false
        }
        // The keychain probe's alert can't show over the walkthrough cover.
        if arguments.contains("-dc-skip-onboarding") || OnboardingDebug.settingsPage != nil
            || arguments.contains(KeychainSyncProbe.launchArgument) {
            settings.hasCompletedOnboarding = true
        }
    }
}
#endif
