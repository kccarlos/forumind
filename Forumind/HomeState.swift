import Foundation

// MARK: - Home and the launch rule (spec §7.1, §7.2): the decisions, no views
//
// - `HomeRoute`            pages pushed over Home (Today, an earlier digest,
//                          Settings › Daily digest); `AppModel.homePath`
// - `TodayModuleState`     which of the Today module's 7 states Home shows
// - `HomeSections`         Continue reading, Watching, when to suggest forums
// - `LaunchDestination`    Settings › Browser › When Forumind opens
// - `LaunchRule`           where a launch lands (Home or the last forum)

/// A page pushed over Home.
enum HomeRoute: Hashable {
    case today
    /// An earlier digest, read only.
    case digest(UUID)
    case digestSettings
}

// MARK: - Today module

/// What the Today module at the top of Home shows. Only the podcast states
/// get the big card; the others are a strip or one row, so the forums stay
/// on the first screen.
enum TodayModuleState: Equatable {
    /// Today's episode is made: "Listen to today".
    case podcastReady
    /// The episode is being made; playable once its first chapter is.
    case podcastInProgress
    /// The digest is done (no episode): the card strip and Listen.
    case digestReady
    /// The digest is being made ("3 of 6 ready"); `offline` when the
    /// forums or the provider can't be reached.
    case digestInProgress(offline: Bool)
    /// No digest today: "Make a digest of today's topics".
    case digestOff
    /// No assistant model to make one: "Set up AI to get a daily digest".
    case aiNotSetUp
    /// Today's digest found nothing.
    case nothingNew

    /// Podcast or digest ready or being made (the launch rule's "Today has
    /// something").
    var hasSomething: Bool {
        switch self {
        case .podcastReady, .podcastInProgress, .digestReady, .digestInProgress: true
        case .digestOff, .aiNotSetUp, .nothingNew: false
        }
    }

    var usesBigCard: Bool { self == .podcastReady || self == .podcastInProgress }

    /// The state for today's digest and episode, highest first: the episode,
    /// then the digest, then why there is none.
    static func resolve(
        digest: DailyDigest?,
        digestActivity: DigestActivity,
        providerReady: Bool,
        episode: PodcastEpisode?,
        podcastActivity: PodcastActivity
    ) -> TodayModuleState {
        if let digest, let episode, episode.digestID == digest.id, !episode.entries.isEmpty {
            return episode.isComplete && !podcastActivity.isRunning ? .podcastReady : .podcastInProgress
        }
        if let digest {
            if digest.isComplete {
                return digest.cards.isEmpty ? .nothingNew : .digestReady
            }
            // Cards waiting with nothing to make them (no model): set up.
            if !digestActivity.isRunning, digestActivity != .unreachable, !providerReady { return .aiNotSetUp }
            return .digestInProgress(offline: digestActivity == .unreachable)
        }
        switch digestActivity {
        case .preparing, .summarizing: return .digestInProgress(offline: false)
        case .unreachable: return .digestInProgress(offline: true)
        case .idle: return providerReady ? .digestOff : .aiNotSetUp
        }
    }
}

/// The podcast card's numbers: topics, the real length (every chapter's
/// audio, the intro and outro included) and how much is made.
struct PodcastCardFacts: Equatable {
    var topics: Int
    /// Seconds of audio made so far.
    var seconds: TimeInterval
    var readyChapters: Int
    var chapters: Int

    init(episode: PodcastEpisode) {
        topics = episode.entries.filter { $0.chapter.kind == .topic }.count
        seconds = episode.entries.filter(\.isReady).compactMap(\.duration).reduce(0, +)
        readyChapters = episode.readyCount
        chapters = episode.entries.count
    }

    /// Whole minutes, at least 1 once there is any audio.
    var minutes: Int { seconds > 0 ? max(1, Int((seconds / 60).rounded())) : 0 }
}

// MARK: - Sections

enum HomeSections {
    /// Continue reading: the last topics the user opened, newest first.
    static let continueReadingLimit = 3
    /// Suggested forums show below Recent only while the user has fewer
    /// forums than this (never the main content, App Review 4.2).
    static let suggestionsBelowForumCount = 3

    static func continueReading(_ sessions: [TopicSession], limit: Int = continueReadingLimit) -> [TopicSession] {
        Array(
            sessions
                .filter { $0.openedByUserAt != nil }
                .sorted { $0.lastSeenAt > $1.lastSeenAt }
                .prefix(limit)
        )
    }

    /// "12 newer replies": posts since the summary was made (or since the
    /// topic was first read).
    static func newerReplies(_ session: TopicSession) -> Int {
        guard let total = session.totalPosts, let summarized = session.summaryPostCount else { return 0 }
        return max(0, total - summarized)
    }

    /// Watched topics with new replies, most first.
    static func watching(_ watched: [WatchedTopic]) -> [WatchedTopic] {
        watched.filter { $0.newReplies > 0 }.sorted { $0.newReplies > $1.newReplies }
    }

    static func showsSuggestions(forumCount: Int) -> Bool {
        forumCount < suggestionsBelowForumCount
    }
}

// MARK: - Launch rule

/// Settings › Browser › When Forumind opens. Synced like the other settings.
enum LaunchDestination: String, Codable, CaseIterable, Identifiable {
    /// Home on the day's first launch when Today has something; otherwise
    /// the last forum.
    case automatic
    case home
    case lastForum

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: String(localized: "Automatic", comment: "When Forumind opens: Home on the first launch of the day when Today has something, else the last forum")
        case .home: String(localized: "Home", comment: "When Forumind opens: always on Home")
        case .lastForum: String(localized: "Last forum", comment: "When Forumind opens: always on the forum read last")
        }
    }
}

/// The launch rule's progress in this process: it runs once, on the first
/// activation, unless an outside request came first.
enum LaunchPhase: Equatable {
    case waiting
    /// A link, notification, Siri, Spotlight or the share extension opened
    /// something before the rule ran.
    case openedExternally
    /// The rule ran (or was skipped); later requests just navigate.
    case settled
}

/// Where a launch lands.
enum LaunchDecision: Equatable {
    /// A link, notification, Siri, Spotlight or the share extension opened
    /// the app: that request decides.
    case external
    /// Home; `marksDay` records today as the day Home was shown by itself.
    case home(marksDay: Bool)
    /// The last forum (`AppModel.startForum(in:)`), as before Home existed.
    case lastForum
}

enum LaunchRule {
    /// The day (`DailyDigest.dayKey`) `.automatic` last showed Home; local
    /// to the device (UserDefaults), never synced.
    static let lastHomeAutoShownDayKey = "dc.lastHomeAutoShownDay"

    static func decide(
        setting: LaunchDestination,
        openedExternally: Bool,
        todayHasSomething: Bool,
        lastHomeAutoShownDay: String?,
        now: Date,
        calendar: Calendar = .current
    ) -> LaunchDecision {
        if openedExternally { return .external }
        switch setting {
        case .home:
            return .home(marksDay: false)
        case .lastForum:
            return .lastForum
        case .automatic:
            let today = DailyDigest.dayKey(for: now, calendar: calendar)
            guard lastHomeAutoShownDay != today, todayHasSomething else { return .lastForum }
            return .home(marksDay: true)
        }
    }
}
