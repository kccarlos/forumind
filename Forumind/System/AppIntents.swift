import AppIntents
import CoreSpotlight
import Foundation

// MARK: - App Intents (Siri, Shortcuts, Spotlight, the Action button)
//
// In the app target (no extension): each intent opens the app and hands its
// action to `SystemEntry` (SystemEntry.swift). `ForumindShortcuts` gives
// them Siri phrases, which Spotlight and the Shortcuts app show too; the
// Action button runs them through a shortcut. The phrases are translated
// in AppShortcuts.xcstrings, the titles in Localizable.xcstrings.

struct SummarizeLinkIntent: AppIntent {
    static let title: LocalizedStringResource = "Summarize Link"
    static let description = IntentDescription(
        "Opens a forum topic in Forumind and summarizes it. Without a link, the link on the clipboard is used.",
        categoryName: "Read"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Link", description: "A forum topic’s web address. Leave empty to use the clipboard.")
    var url: URL?

    init() {}

    init(url: URL?) {
        self.url = url
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Summarize \(\.$url)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let link = try SystemEntry.summaryLink(url)
        SystemEntry.send(.summarize(link))
        return .result()
    }
}

struct AskForumIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask a Forum"
    static let description = IntentDescription(
        "Asks one of your forums a question: Forumind searches and reads its topics and answers with sources.",
        categoryName: "Read"
    )
    static let openAppWhenRun = true

    @Parameter(title: "Forum")
    var forum: ForumEntity

    @Parameter(title: "Question", requestValueDialog: IntentDialog("What do you want to ask?"))
    var question: String

    init() {}

    init(forum: ForumEntity, question: String) {
        self.forum = forum
        self.question = question
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Ask \(\.$forum) \(\.$question)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SystemEntryError.emptyQuestion }
        SystemEntry.send(.ask(siteURL: forum.id, question: trimmed))
        return .result()
    }
}

struct OpenTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Today’s Digest"
    static let description = IntentDescription("Opens the Today page with today’s digest.", categoryName: "Read")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SystemEntry.send(.openToday)
        return .result()
    }
}

struct PlayPodcastIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Today’s Podcast"
    static let description = IntentDescription(
        "Plays today’s podcast. If there is no episode yet, opens the Today page.",
        categoryName: "Listen"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SystemEntry.send(.playToday)
        return .result()
    }
}

struct StartVoiceChatIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a Voice Chat"
    static let description = IntentDescription(
        "Starts a voice chat about the page in Forumind. If voice isn’t set up yet, opens its settings.",
        categoryName: "Listen"
    )
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        SystemEntry.send(.startVoice)
        return .result()
    }
}

/// Opens a topic the user has read (Shortcuts, and Spotlight on iOS 18+).
struct OpenTopicIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Topic"
    static let description = IntentDescription("Opens a topic you’ve read in Forumind.", categoryName: "Read")

    @Parameter(title: "Topic")
    var target: TopicEntity

    init() {}

    init(target: TopicEntity) {
        self.target = target
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        SystemEntry.send(.openTopic(topicKey: target.id))
        return .result()
    }
}

// MARK: - Entities

/// One of the user's forums.
struct ForumEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Forum"
    static let defaultQuery = ForumEntityQuery()

    /// The forum's site URL.
    var id: String
    var name: String
    var host: String

    init(id: String, name: String, host: String) {
        self.id = id
        self.name = name
        self.host = host
    }

    init(forum: Forum) {
        self.init(id: forum.siteURL, name: forum.displayName, host: forum.host)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(host)")
    }
}

/// The user's forums, pinned first (in their order), then the recent ones.
struct ForumEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [ForumEntity.ID]) async throws -> [ForumEntity] {
        let forums = SystemEntry.forumChoices()
        return identifiers.compactMap { id in forums.first { $0.siteURL == id }.map(ForumEntity.init(forum:)) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [ForumEntity] {
        Self.matching(string, in: SystemEntry.forumChoices()).map(ForumEntity.init(forum:))
    }

    @MainActor
    func suggestedEntities() async throws -> [ForumEntity] {
        SystemEntry.forumChoices().map(ForumEntity.init(forum:))
    }

    /// Forums whose name or address contains the text (case and accents
    /// ignored), in the suggested order.
    static func matching(_ string: String, in forums: [Forum]) -> [Forum] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return forums }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return forums.filter {
            $0.displayName.range(of: query, options: options) != nil || $0.host.range(of: query, options: options) != nil
        }
    }
}

/// A topic the user has read.
struct TopicEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Topic"
    static let defaultQuery = TopicEntityQuery()

    /// The topic key (`host[/basePath]/t/{id}`).
    var id: String
    var title: String
    var forumName: String

    init(id: String, title: String, forumName: String) {
        self.id = id
        self.title = title
        self.forumName = forumName
    }

    init(entry: SpotlightEntry) {
        self.init(id: entry.topicKey, title: entry.title, forumName: entry.forumName)
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(forumName)")
    }
}

/// Apple Intelligence and Spotlight find topics through the indexed
/// Spotlight items (`SpotlightCatalog.item(for:)` associates each one).
@available(iOS 18, *)
extension TopicEntity: IndexedEntity {}

struct TopicEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [TopicEntity.ID]) async throws -> [TopicEntity] {
        let topics = SystemEntry.topicChoices()
        return identifiers.compactMap { id in topics.first { $0.id == id } }
    }

    @MainActor
    func entities(matching string: String) async throws -> [TopicEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let topics = SystemEntry.topicChoices()
        guard !query.isEmpty else { return Array(topics.prefix(20)) }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return topics.filter {
            $0.title.range(of: query, options: options) != nil || $0.forumName.range(of: query, options: options) != nil
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [TopicEntity] {
        Array(SystemEntry.topicChoices().prefix(20))
    }
}

// MARK: - Siri phrases

struct ForumindShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SummarizeLinkIntent(),
            phrases: [
                "Summarize a link with \(.applicationName)",
                "Summarize the copied link in \(.applicationName)"
            ],
            shortTitle: "Summarize Link",
            systemImageName: "text.append"
        )
        AppShortcut(
            intent: AskForumIntent(),
            phrases: [
                "Ask \(\.$forum) in \(.applicationName)",
                "Ask a forum in \(.applicationName)"
            ],
            shortTitle: "Ask a Forum",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: OpenTodayIntent(),
            phrases: [
                "Open today's digest in \(.applicationName)",
                "Show my \(.applicationName) digest"
            ],
            shortTitle: "Today’s Digest",
            systemImageName: "sun.max"
        )
        AppShortcut(
            intent: PlayPodcastIntent(),
            phrases: [
                "Play today's podcast in \(.applicationName)",
                "Play my \(.applicationName) podcast"
            ],
            shortTitle: "Play Podcast",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: StartVoiceChatIntent(),
            phrases: [
                "Start a voice chat in \(.applicationName)",
                "Talk to \(.applicationName)"
            ],
            shortTitle: "Voice Chat",
            systemImageName: "waveform"
        )
    }
}
