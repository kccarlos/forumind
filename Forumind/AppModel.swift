import BackgroundTasks
import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications

// MARK: - AppModel API for the UI (multi-forum)
//
// Forums (see ForumDirectory.swift for `Forum` / `SuggestedForum`):
// - `forums`                        every added/visited forum (published)
// - `pinnedForums`                  pinned, in the user's order
// - `recentForums`                  unpinned, most recently visited first
// - `AppModel.suggestedForums`      well-known forums offered before adding
// - `currentForum`                  forum of the current page, else the last one shown (computed from `currentSiteURL`)
// - `forum(for:)`                   directory entry for a site URL
// - `addForum(fromAddress:pin:)`    validates a URL/host via basic-info.json, adds it
// - `pin(_:)` / `unpin(_:)` / `togglePin(_:)` / `movePinned(fromOffsets:toOffset:)`
// - `removeForum(_:deleteData:)`    optionally deletes its summaries/chats/runs/watches
// - `openForum(_:)`                 loads its /latest in the browser
// - `recordVisit(siteURL:kind:name:iconURL:)` called automatically for detected forum pages
//
// Page and assistant:
// - `pageContext`                   browser page state (.loading/.notForum/.maybe/.forumHome/.topic)
// - `currentTopic`, `currentSession` topic of the page and its saved session
// - `isProviderReady(for:)`         a role's model can run (key present when required);
//                                   roles and model selection: AppModel+Models.swift
// - `agentSiteURL`                  forum the next agent run targets (nil → current forum)
// - `startAgentRun(goal:siteURL:)`  runs are scoped to one forum (`AgentRun.siteURL`)
// - `startAgentRun(goal:siteURL:completion:)` / `performAgentRun(goal:siteURL:)`
//                                   a run started from code (no panel, selection or draft
//                                   change) that hands back `AgentRunOutcome`
// - `cancelAgentRun(id:)`           stops a queued or running run
// - `askScope`, `setAskScope(_:)`, `sendAsk()` the unified Ask box (AskBox.swift)
// - `sessions` is keyed by topic key (`host[/basePath]/t/{id}`); per-topic calls take
//   `topicKey:` (`setKept`, `deleteSession`, `setInstructions`, `isWatched`, `unwatch`,
//   `markWatchedSeen`)
//
// Onboarding / hand-off:
// - `settings.hasCompletedOnboarding`, `completeOnboarding()`
// - `handle(_ request: IncomingLinkRequest)` share-extension / deep-link hand-off (deduped by id)
// - `drainSharedInbox()`            deliver the App Group inbox (also runs on scene .active)
// - `openShared(url:action:)`       open a shared link; "summary" | "chat" | "agent" | "open"
// - `requestAssistant()`            a hand-off wants the Assistant pane (`assistantRequest`)
// - `needsProviderSetup`            the role a hand-off needs a provider for (UI resets it)
// - `handleDeepLink(_:)`            forumind://open?url=…&action=…
//
// Ad and tracker blocking: see AppModel+ContentBlocking.swift.
//
// Post-level browsing (AppModel+Navigation.swift): `openTopic(_:at:)`,
// `focus(_:)`, `find(_:scope:)`, `next()` / `previous()`, `read(post:)`,
// `research(_:)` / `cancelResearch()`, `openLink(_:)`; the current list is
// `browseCursor`, page changes for the voice layer arrive on `pageChanges`.

/// What the AI view shows: the topic, or (split layout) History in place.
/// Settings is always a sheet: inside the split panel its navigation stack
/// would be nested in the page's and lose its bar.
enum PanelRoute: String, CaseIterable {
    case topic = "Topic"
    case history = "History"
}

enum AssistantMode: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case chat = "Chat"
    case agent = "Agent"

    var id: String { rawValue }
}

/// What an agent run started from code hands back once it ends: the answer
/// and its sources (topics, or single posts with `postNumber`), or why there
/// is none (`status` cancelled or failed, `error`).
struct AgentRunOutcome: Equatable {
    var runID: UUID
    var status: WorkStatus
    var answer: String
    var sources: [AgentSources.Source]
    var error: String
}

enum AgentError: LocalizedError {
    case missingArgument(String)
    /// The argument's name and why it is wrong (model-visible, recoverable).
    case invalidArgument(String, reason: String)
    /// The site has closed its comment search; the run goes on without it.
    case commentsUnavailable
    case topicBudgetExhausted(Int)
    /// The tool asked for and the names this run offers.
    case unknownTool(String, available: [String])
    case runNotFound
    case queueFull

    /// Shown in the step list (localized).
    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            String(localized: "Missing argument \"\(name)\".", comment: "Ask the forum step error; the placeholder is a technical argument name such as query or topic_id")
        case .invalidArgument(let name, let reason):
            String(localized: "Invalid argument \"\(name)\": \(reason)", comment: "Ask the forum step error; the first placeholder is a technical argument name, the second the reason (English)")
        case .commentsUnavailable:
            String(localized: "This site does not allow searching comments. Use search_forum and read_topic instead.", comment: "Ask the forum step error: the WordPress site closed its comment search")
        case .topicBudgetExhausted(let limit):
            String(localized: "The topic-read budget (\(limit)) is used up; answer with what you have.", comment: "Ask the forum step error; the number is the maximum topic reads per run")
        case .unknownTool(let name, let available):
            String(localized: "Unknown tool \"\(name)\". Available: \(available.joined(separator: ", "))", comment: "Ask the forum step error; placeholders are technical tool names")
        case .runNotFound:
            String(localized: "The agent run no longer exists.")
        case .queueFull:
            String(localized: "The task queue is full. Cancel or wait for an existing task.")
        }
    }

    /// Handed back to the model as the tool's observation: always English,
    /// like the rest of the prompt.
    var modelDescription: String {
        switch self {
        case .missingArgument(let name): "Missing argument \"\(name)\"."
        case .invalidArgument(let name, let reason): "Invalid argument \"\(name)\": \(reason)"
        case .commentsUnavailable:
            "COMMENTS_UNAVAILABLE: This site does not allow searching comments. Use search_forum and read_topic instead."
        case .topicBudgetExhausted(let limit):
            "The topic-read budget (\(limit)) is used up; answer with what you have."
        case .unknownTool(let name, let available):
            "Unknown tool \"\(name)\". Available: \(available.joined(separator: ", "))"
        case .runNotFound: "The agent run no longer exists."
        case .queueFull: "The task queue is full."
        }
    }
}

/// Outcome of a provider test or model load.
enum ProviderCheckResult: Equatable {
    case success
    case failure(String)
    /// The provider settings changed (or a newer check started) before it
    /// finished; the result was dropped.
    case stale
}

enum WatchCheckReason {
    case foreground
    case manual
    case background
}

/// Pending edit of a previously sent user turn in a topic's chat. Nothing is
/// deleted from `session.history` until the edited question is submitted.
enum ChatEditState: Equatable {
    case none
    case editing(topicKey: String, messageID: UUID, previousDraft: String)
}

@MainActor
final class AppModel: ObservableObject {
    /// Edits apply at once: work that has not started yet uses them, work
    /// already running keeps the values it started with (`RunSettings`). Every
    /// change is persisted, coalesced (see `saveSettings()`).
    @Published var settings: AppSettings {
        didSet {
            settingsDidChange(from: oldValue)
        }
    }
    @Published private(set) var sessions: [String: TopicSession] {
        didSet {
            sessionsGeneration &+= 1
            moderatedSourceCache.removeAll()
            spotlightDataDidChange()
        }
    }
    var sessionsGeneration = 0
    var moderatedSourceCache: [String: ModeratedSourceCacheEntry] = [:]
    @Published private(set) var activities: [WorkRecord]
    @Published private(set) var currentTopic: ForumTopic?
    @Published var panelRoute: PanelRoute = .topic
    /// Shared between the inline panel and its full-screen copy so opening the
    /// assistant full screen keeps the same mode.
    @Published var assistantMode: AssistantMode = .summary
    /// Streaming summary and chat text; observed by the views that show it
    /// only, not by this model (`StreamStore`).
    let streams = StreamStore()
    /// Live 0…1 progress of running work; observed only by the views that
    /// draw a progress bar, ring or percentage (`ProgressStore`).
    let progress = ProgressStore()
    /// Unsent composer text. Not published here: it changes on every
    /// keystroke, so only the Ask box and the composers observe it.
    let drafts = ComposerDrafts()
    /// Errors waiting for the root alert, oldest first: one shows at a time
    /// and a newer one never replaces it (`presentError`).
    @Published private(set) var errorQueue: [PresentedError] = []
    /// The developer's moderation list (last good copy; see Moderation.swift).
    @Published var remoteModeration: RemoteModerationList? = RemoteModerationCache.load() {
        didSet { remoteModerationDidChange() }
    }
    @Published var settingsStatus = ""
    /// Models each provider offers, from the last successful load.
    @Published var discoveredModels: [AIProvider: [String]] = [:]
    @Published private(set) var agentRuns: [AgentRun] {
        didSet { deliverAgentRunOutcomes() }
    }
    @Published private(set) var watchedTopics: [WatchedTopic]
    @Published var selectedAgentRunID: UUID? {
        // Picking or starting a run shows it (AskBox.swift).
        didSet { agentComposesNewQuestion = false }
    }
    /// The Ask box's Whole forum scope starts a new run instead of following
    /// up the selected one (its examples and recent runs show).
    @Published var agentComposesNewQuestion = false
    /// Bumped to focus the Ask box (⌘2, ⌘3).
    @Published var askFocusRequest = 0
    /// In-progress edit of an existing user turn in chat (`editChat`).
    @Published private(set) var chatEdit: ChatEditState = .none
    @Published private(set) var notificationsAuthorized = false
    /// The user's forums (pinned and recent); see the API list above.
    @Published private(set) var forums: [Forum] {
        didSet {
            spotlightDataDidChange()
            if forums.map(\.siteURL) != oldValue.map(\.siteURL) || forums.map(\.name) != oldValue.map(\.name) {
                forumsDidChangeForShortcuts()
            }
        }
    }
    /// The forum of the current page, or the last forum shown.
    @Published private(set) var currentSiteURL: String?
    /// Last site URL delivered by `handlePageContext` so forum-home switches
    /// can exit a previous forum's `.agent` mode.
    private var lastPageSiteURL: String?
    /// Where Add forum is: detecting the platform of an address, then the
    /// outcome. One detection per address at a time.
    @Published private(set) var addForumPhase = AddForumPhase.idle
    private var addForumTask: (key: AddForumRequest, task: Task<Forum, Error>)?
    /// Forum the next agent run targets; nil means `currentForum`.
    @Published var agentSiteURL: String?
    /// Bumped when a hand-off (shared link, Siri, Spotlight) wants the
    /// Assistant shown (`requestAssistant()`); the root view shows it once
    /// per new value.
    @Published private(set) var assistantRequest = 0
    /// A hand-off needed this role's model, which is not ready yet.
    @Published var needsProviderSetup: ModelRole?
    /// Recent daily digests, newest first (AppModel+Digest.swift; device-local).
    @Published var digests: [DailyDigest] = []
    /// What making today's digest is doing (preparing, a card, an error).
    @Published var digestActivity: DigestActivity = .idle
    /// Pages pushed over Home (the Today page, an earlier digest, digest
    /// settings); emptied when Home hides (AppModel+Browse.swift).
    @Published var homePath: [HomeRoute] = []
    /// Where this launch is in the launch rule (HomeState.swift); not
    /// published, nothing draws it.
    var launchPhase: LaunchPhase = .waiting
    /// The current list (search hits, research sources, focused posts) and
    /// the result cards' state (AppModel+Navigation.swift).
    @Published var browseCursor = BrowseCursor()
    /// The last post citation (or solved hint) jumped to: drives the
    /// selection haptic and the filled chip (AppModel+Navigation.swift).
    @Published var citationJump: CitationJump?
    /// A Settings page an outside request wants shown (Start a Voice Chat
    /// without voice set up); RootView presents it and resets it.
    @Published var requestedSettingsPage: SettingsPage?
    /// Export toggles shared between AssistantPanel and RouterHost's ExportOptionsSheet.
    @Published var exportOptions = ExportOptions()

    /// Cheap check for whether the open topic has pulled post text, without
    /// running moderation filtering during SwiftUI render.
    var hasCurrentSource: Bool {
        !(currentSession?.source.isEmpty ?? true)
    }

    /// Cheap check for whether any enabled export section has content, without
    /// running moderation filtering or building the export string during render.
    func hasCurrentExportContent(options: ExportOptions) -> Bool {
        let session = currentSession
        return TopicExportPayload.hasContent(
            title: session?.title ?? currentTopic?.title ?? "",
            url: session?.url ?? currentTopic?.url,
            summary: session?.summary ?? "",
            hasSource: hasCurrentSource,
            hasChatHistory: !(session?.history.isEmpty ?? true),
            options: options
        )
    }

    var currentExportPayload: TopicExportPayload {
        let session = currentSession
        return TopicExportPayload(
            summary: session?.summary ?? "",
            source: currentModeratedSource,
            title: session?.title ?? currentTopic?.title ?? "",
            url: session?.url ?? currentTopic?.url,
            history: session?.history ?? [],
            summaryUpdatedAt: session?.summaryUpdatedAt,
            summaryPostCount: session?.summaryPostCount,
            totalPosts: session?.totalPosts
        )
    }

    private static var loadsOnlySamplePage: Bool {
        #if DEBUG
        return AssistantDebug.isActive
        #else
        return false
        #endif
    }

    nonisolated static var suggestedForums: [SuggestedForum] {
        return SiteRegistry.standard.adapters.flatMap(\.suggestedForums.general)
    }

    let browser: ForumBrowserModel
    /// Root sheets, covers and alerts, and the iPhone AI drawer
    /// (PresentationRouter.swift).
    let router = PresentationRouter()
    /// Requests waiting for an answer on the AI data consent page
    /// (AIDataConsent.swift).
    let aiConsent = AIConsentGate()
    /// iCloud (CloudKit) sync (see CloudSyncController.swift).
    let cloudSync: CloudSyncController

    private let store: PersistentStore
    // Also used by the feature slices in other files (AppModel+Digest.swift).
    let forumService: ForumService
    /// Every platform this build reads; tests inject their own.
    let sites: SiteRegistry
    let aiService: AIService
    private let planner: AgentPlanner
    let notifier: WatchNotifier
    /// The daily digest's files and background task (AppModel+Digest.swift).
    let digestStore: DigestStore
    let backgroundScheduler: BackgroundTaskScheduling
    var digestPrefetch: DigestPrefetch?
    var digestNotifiedDay: String?
    var digestTask: Task<Void, Never>?
    /// The run `digestTask` belongs to; a paused (cancelled) run that is
    /// still unwinding never writes over a newer one.
    var digestRunID: UUID?
    private var openTodayObserver: NSObjectProtocol?
    private let limiter = TaskLimiter(limit: 2)
    /// The task of each job launched (waiting for a worker or running). The
    /// token tells a job that was paused and launched again from the old
    /// task still unwinding.
    private var runningTasks: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var summaryFeeds: [UUID: SummaryProgressFeed] = [:]
    /// Extra time to finish work after the app leaves the foreground.
    private let backgroundGrace: BackgroundGracing
    /// The grace period, while the app is in the background with work
    /// running; at its end the work pauses (`pauseActiveWork`).
    private var backgroundWork: UIBackgroundTaskIdentifier?
    private var didRestoreTasks = false
    private var lastWatchCheck: Date?
    private var watchTimer: Task<Void, Never>?
    private var openURLObserver: NSObjectProtocol?
    private var pendingShare: PendingShare?
    private var handledShareIDs: Set<UUID> = []
    private let keyStore: ProviderKeyStore
    /// API keys as last written to the key store; only changed ones are rewritten.
    private var persistedAPIKeys: [AIProvider: String] = [:]
    /// Trailing save for rapid settings edits (slider drags, typing).
    private var settingsSaveTask: Task<Void, Never>?
    /// Per provider: bumped when its key or address changes, or a newer
    /// test or model load starts, so an older result is dropped.
    private var connectionTestGeneration: [AIProvider: Int] = [:]
    private var activeConnectionTestGeneration: [AIProvider: Int] = [:]
    private var activeRoleConnectionTests: [ModelRole: (provider: AIProvider, generation: Int, selection: ModelSelection)] = [:]
    private var modelDiscoveryGeneration: [AIProvider: Int] = [:]
    @Published private(set) var isCheckingWatches = false
    /// A forum the user removed while its page is still open: the page must
    /// not add it straight back as a recent forum.
    private var suppressedAutoAddSiteURL: String?
    /// Delay before coalesced settings edits are written.
    var settingsSaveDelay: Duration = .milliseconds(400)
    private static let watchInterval: TimeInterval = 30 * 60
    static let agentTopicPrefix = "agent:"
    /// Runs started from code that wait for their outcome (in memory only).
    private var agentRunCompletions: [UUID: (AgentRunOutcome) -> Void] = [:]
    /// When true, agent tools and watch checks call the forum through
    /// ForumService's URLSession instead of the embedded web view (tests).
    var usesDirectForumRequests = false
    /// Topic overviews (title, slug, facts) by topic key, fetched once per
    /// topic for navigation (AppModel+Navigation.swift).
    var topicOverviews: [String: ForumTopicOverview] = [:]
    /// The running `research(_:)` and its generation; a newer one wins.
    var researchTask: Task<AgentRunOutcome, Error>?
    var researchGeneration = 0
    /// Feeds the voice session's silent context (AppModel+Voice.swift).
    var voicePageSubscription: AnyCancellable?
    /// Starts voice sessions for the UI (Voice/VoiceController.swift).
    private(set) lazy var voice = VoiceController(app: self)
    /// The podcast: episodes, the player, read-aloud (Podcast/PodcastController.swift).
    private(set) lazy var podcast: PodcastController = {
        let controller = PodcastController(app: self, store: PodcastStore(directory: podcastDirectory))
        controller.voice = voice
        return controller
    }()
    /// Whether Space plays or pauses the podcast (WorkspaceLayout.swift).
    private(set) lazy var playPauseShortcut = PlayPauseShortcut(podcast: podcast)
    /// Where podcast audio is cached (`Caches/Podcasts`; tests pass their own).
    let podcastDirectory: URL
    /// Read topics and summaries in Spotlight (AppModel+System.swift).
    let spotlight: SpotlightIndexer
    /// Siri suggestions for the topics the user reads.
    let topicActivityDonor: TopicActivityDonating
    /// The topic last offered to Siri suggestions (one donation per visit).
    var donatedTopicKey: String?
    /// Every page context change (both kinds); `pageChanges` debounces it.
    let pageUpdates = PassthroughSubject<PageContext, Never>()
    /// How long the page must settle before `pageChanges` reports it.
    var pageChangeDelay: DispatchQueue.SchedulerTimeType.Stride = .milliseconds(400)
    /// Fetch every opened topic's facts (post count, accepted answer) into
    /// the page context. Off by default (one more request per topic); the
    /// voice layer turns it on. Navigation actions fetch them either way.
    var prefetchesTopicFacts = false
    /// The iPhone bar shows "Solved · answer at #N" from the facts, so the
    /// browser UI fetches them for every opened topic (unit tests don't).
    var barShowsTopicFacts = false

    /// Loader that runs forum requests in the authenticated web view context.
    var webViewResourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? {
        guard !usesDirectForumRequests else { return nil }
        return { [browser] url in try await browser.fetchForumResource(url) }
    }

    init(
        store: PersistentStore = PersistentStore(),
        forumService: ForumService = ForumService(),
        sites: SiteRegistry = .standard,
        aiService: AIService = AIService(),
        browser: ForumBrowserModel? = nil,
        planner: AgentPlanner? = nil,
        notifier: WatchNotifier = .shared,
        cloudSync: CloudSyncController? = nil,
        backgroundScheduler: BackgroundTaskScheduling = BGTaskScheduler.shared,
        podcastDirectory: URL? = nil,
        spotlightIndex: SpotlightIndexing? = nil,
        topicActivityDonor: TopicActivityDonating? = nil,
        backgroundGrace: BackgroundGracing? = nil
    ) {
        self.store = store
        self.backgroundGrace = backgroundGrace ?? ApplicationBackgroundGrace()
        spotlight = Self.makeSpotlightIndexer(index: spotlightIndex, store: store)
        self.topicActivityDonor = topicActivityDonor ?? Self.makeTopicActivityDonor(store: store)
        self.podcastDirectory = podcastDirectory ?? PodcastStore.defaultDirectory
        self.backgroundScheduler = backgroundScheduler
        digestStore = DigestStore(directory: store.directoryURL)
        self.keyStore = store.keys
        self.cloudSync = cloudSync ?? CloudSyncController.makeDefault(for: store)
        self.forumService = forumService
        self.sites = sites
        self.aiService = aiService
        self.browser = browser ?? ForumBrowserModel(sites: sites)
        self.planner = planner ?? PromptAgentPlanner(aiService: aiService)
        self.notifier = notifier

        let snapshot = store.load()
        forums = snapshot.forums
        let loadedRuns = snapshot.agentRuns.sorted { $0.createdAt > $1.createdAt }
        agentRuns = loadedRuns
        watchedTopics = snapshot.watchedTopics
        selectedAgentRunID = loadedRuns.first?.id
        var loadedSettings = snapshot.settings
        var loadedKeys: [AIProvider: String] = [:]
        for provider in AIProvider.allCases {
            var configuration = loadedSettings.configuration(for: provider)
            configuration.apiKey = store.keys.value(for: provider)
            loadedKeys[provider] = configuration.apiKey
            loadedSettings.setConfiguration(configuration, for: provider)
        }
        settings = loadedSettings
        persistedAPIKeys = loadedKeys

        let now = Date()
        sessions = Dictionary(
            snapshot.sessions.map { session in
                var normalized = session
                if !session.kept,
                   let updated = session.chatUpdatedAt,
                   now.timeIntervalSince(updated) >= 24 * 60 * 60 {
                    normalized.history = []
                    normalized.chatUpdatedAt = nil
                }
                return (normalized.topicKey, normalized)
            },
            uniquingKeysWith: { first, second in first.updatedAt >= second.updatedAt ? first : second }
        )
        let voiceRunIDs = Set(loadedRuns.filter { $0.origin == .voice }.map(\.id))
        activities = snapshot.activities
            .filter {
                !$0.status.isTerminal
                    || now.timeIntervalSince($0.completedAt ?? $0.updatedAt) < 24 * 60 * 60
            }
            .map {
                guard !$0.status.isTerminal else { return $0 }
                var interrupted = $0
                if interrupted.type == .agent,
                   let runID = UUID(uuidString: String(interrupted.topicID.dropFirst(Self.agentTopicPrefix.count))),
                   voiceRunIDs.contains(runID) {
                    interrupted.status = .cancelled
                    interrupted.statusText = String(localized: "Cancelled", comment: "Status of AI work the user cancelled")
                    interrupted.completedAt = now
                } else {
                    interrupted.status = .queued
                    interrupted.statusText = String(localized: "Restoring interrupted work…", comment: "Status of AI work that was interrupted when the app quit and is starting again")
                }
                return interrupted
            }
            .sorted { $0.createdAt > $1.createdAt }

        // Interrupted agent runs resume with their re-queued record (their
        // status is the record's); a run whose record is gone cannot resume
        // and is closed out instead of spinning.
        let restorableRunIDs = Set(
            activities
                .filter { $0.type == .agent && !$0.status.isTerminal }
                .compactMap { UUID(uuidString: String($0.topicID.dropFirst(Self.agentTopicPrefix.count))) }
        )
        agentRuns = agentRuns.map { run in
            guard !run.isFinished else { return run }
            var updated = run
            if !restorableRunIDs.contains(run.id) {
                if !updated.initialAnswer.isEmpty {
                    updated.result = .completed
                    updated.completedAt = updated.completedAt ?? now
                } else {
                    updated.result = .cancelled
                    updated.error = String(localized: "Interrupted before the run could finish.", comment: "Ask the forum: a research run stopped when the app quit")
                    updated.completedAt = now
                }
            }
            return updated
        }

        self.browser.knownForumLookup = { [weak self] url in
            guard let forum = self?.directory.forum(containing: url) else { return nil }
            return KnownForumSite(siteURL: forum.siteURL, name: forum.name, iconURL: forum.iconURL, kind: forum.kind)
        }
        self.browser.onPageContextChanged = { [weak self] context in
            self?.handlePageContext(context)
        }
        self.browser.onNavigationFailed = { [weak self] error in
            guard let self, self.browser.onPageContextChanged != nil else { return }
            self.presentError(error.localizedDescription)
        }
        self.browser.onPagePositionChanged = { [weak self] context in
            self?.handlePagePosition(context)
        }
        self.browser.topicFactsLookup = { [weak self] topic in
            self?.topicOverviews[topic.topicKey]?.facts
        }
        // Start on the most recently visited forum (or the first pinned one);
        // with none, the browser stays empty and the UI shows the Forums home.
        currentSiteURL = Self.startForum(in: forums)?.siteURL
        self.browser.homeSiteURL = currentSiteURL
        // Ad/tracker blocking starts before the first page load.
        configureContentBlocking()
        applyModerationRules()
        // (DEBUG samples load only their own page: a restored forum's load
        // failing late would replace it with the Forums home.)
        if self.browser.webView.url == nil, !Self.loadsOnlySamplePage {
            self.loadHome(silentOnFailure: true)
        }
        openURLObserver = NotificationCenter.default.addObserver(
            forName: WatchNotifier.openURLNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            Task { @MainActor [weak self] in
                self?.noteExternalEntry()
                self?.browser.load(url)
                self?.panelRoute = .topic
            }
        }
        WatchBackgroundRefresh.perform = { [weak self] in
            await self?.checkWatchedTopics(reason: .background)
            // On disk before the system suspends the app again.
            await self?.flushPendingSaves()
        }
        loadDigests()
        // Podcast audio of deleted or week-old digests goes.
        podcast.reconcile()
        openTodayObserver = NotificationCenter.default.addObserver(
            forName: WatchNotifier.openTodayNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.openTodayFromNotification() }
        }
        DigestBackgroundPrefetch.perform = { [weak self] in
            await self?.performBackgroundDigestPrefetch()
            await self?.flushPendingSaves()
        }
        if settings.dailyDigestEnabled { scheduleDigestPrefetch() }
        Task { [weak self] in
            await self?.refreshNotificationAuthorization()
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("-ui-test-") }) {
            // UI-test seeds start past the walkthrough.
            settings.hasCompletedOnboarding = true
        }
        if AssistantDebug.isActive {
            seedAssistantSample()
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-manage-swipe") {
            seedUITestManageSession()
        } else if ProcessInfo.processInfo.arguments.contains("-ui-test-sample-session") {
            seedUITestSession()
        }
        // Sample only: never over the real digests or with a real key.
        if AssistantDebug.isActive, AssistantDebug.has("-dc-digest-sample") { seedDigestSample() }
        // `-dc-no-forums`: the sample as a new user sees Home (never saved).
        if AssistantDebug.isActive, AssistantDebug.has("-dc-no-forums") {
            directory = ForumDirectory(forums: [])
            currentSiteURL = nil
            self.browser.homeSiteURL = nil
        }
        applyStateDebugScript()
        // A scripted voice run starts from the consent sheet.
        if VoiceDebug.isFake { settings.voiceConsent = [:] }
        #endif
        // Launch: what grew while the app ran last (and data from before
        // sessions were pruned at all) goes before anything reads it.
        pruneSessions()
        self.cloudSync.attach(self)
        // The consent backstop before every third-party AI request.
        aiService.consentCheck = { [weak self] provider, configuration in
            guard let self else { throw AssistantError.aiConsentRequired(provider) }
            try self.settings.requireAIConsent(for: provider, baseURL: configuration.baseURL)
        }
        // Launch: bring Spotlight up to date (only the difference, or
        // everything once after a new index version).
        spotlightDataDidChange()
    }

    var currentSession: TopicSession? {
        guard let topicKey = currentTopic?.topicKey else { return nil }
        return sessions[topicKey]
    }

    /// Live availability of the Apple Intelligence provider (through
    /// `aiService`, so tests can fake it).
    var appleIntelligenceStatus: AppleIntelligenceStatus {
        aiService.appleIntelligence.currentStatus()
    }

    /// The assistant role's provider settings and model.
    var selectedConfiguration: ProviderConfiguration {
        settings.configuration(for: .assistant)
    }

    func restorePendingTasksIfNeeded() {
        guard !didRestoreTasks else { return }
        didRestoreTasks = true
        for record in activities where record.status == .queued {
            launch(recordID: record.id)
        }
    }

    /// `forumind://open?url=…&action=open|summary|chat|agent`.
    ///
    /// Any app or web page can open such a link, so a link only starts AI
    /// work (which spends the user's credits) when the share extension queued
    /// the same request in the App Group inbox. Otherwise it opens the page
    /// and the Assistant in the requested mode, and the user starts it.
    func handleDeepLink(_ deepLink: URL) {
        guard let request = IncomingLink.parse(deepLink) else { return }
        guard !handledShareIDs.contains(request.id) else { return }
        // The share extension also queued this request in the inbox.
        let fromShareExtension = SharedInbox.remove(id: request.id)
        handle(request, autoRun: fromShareExtension)
    }

    /// Hand-off from the share extension or a deep link. A request is handled
    /// once even when it arrives both ways (inbox and URL). `autoRun: false`
    /// opens the page and Assistant without starting a summary or pull; before
    /// onboarding and the Terms of Use are done (`acceptsSystemWork`), AI work
    /// never starts automatically either.
    func handle(_ request: IncomingLinkRequest, autoRun: Bool = true) {
        guard handledShareIDs.insert(request.id).inserted else { return }
        noteExternalEntry()
        openShared(url: request.url, action: request.action.rawValue, autoRun: autoRun && acceptsSystemWork)
    }

    /// Delivers the newest request the share extension queued in the App Group
    /// inbox (older ones are superseded) — call on launch/foreground.
    func drainSharedInbox() {
        let requests = SharedInbox.drainAll().filter { !handledShareIDs.contains($0.id) }
        if let latest = requests.last { handle(latest) }
    }

    /// The error the root alert shows.
    var presentedError: String? { errorQueue.first?.message }
    var presentedErrorAction: ErrorAction? { errorQueue.first?.action }

    /// Queues an error for the root alert; a message already waiting is not
    /// queued twice. For what the user just did: work the app started by
    /// itself reports in Activity instead.
    func presentError(_ message: String, action: ErrorAction? = nil) {
        if let index = errorQueue.firstIndex(where: { $0.message == message }) {
            if errorQueue[index].action == nil, let action {
                errorQueue[index].action = action
            }
            return
        }
        errorQueue.append(PresentedError(message: message, action: action))
    }

    /// Runs the root error alert's follow-up action after dismissing the alert.
    func performErrorAction(_ action: ErrorAction, after delay: Duration? = nil) {
        let wait = delay ?? PresentationRouter.settleDelay
        dismissPresentedError()
        if router.item != nil { router.item = nil }
        Task { @MainActor [weak self] in
            if wait > .zero {
                try? await Task.sleep(for: wait)
            }
            guard let self else { return }
            switch action {
            case .openAIModels:
                self.requestedSettingsPage = .provider
            }
        }
    }

    /// The root alert's OK: the next error (if any) shows.
    func dismissPresentedError() {
        guard !errorQueue.isEmpty else { return }
        errorQueue.removeFirst()
    }

    /// Asks the root view to show the Assistant (once per call).
    func requestAssistant() {
        assistantRequest &+= 1
    }

    /// Opens a shared link. Once the page is detected as that topic (or, for
    /// "agent", any page of a Discourse forum), switches to the Assistant and
    /// starts the summary / focuses chat / prepares the agent for that forum.
    /// Without a configured provider it sets `needsProviderSetup` instead of
    /// starting AI work.
    func openShared(url: URL, action: String, autoRun: Bool = true) {
        guard ForumBrowserModel.isBrowsableURL(url) else { return }
        let kind = PendingShare.Action(rawValue: action.lowercased()) ?? .open
        pendingShare = kind == .open
            ? nil
            : PendingShare(
                url: url,
                action: kind,
                topicID: sites.looseTopicID(in: url),
                autoRun: autoRun
            )
        panelRoute = .topic
        browser.load(url)
    }

    /// The browser's current page as the assistant sees it, with the reading
    /// position (posts on screen, highlights). The browser is the only
    /// store: scrolling republishes `ForumBrowserModel`, not this model, which
    /// announces only new pages and routes (`handlePageContext`).
    var pageContext: PageContext {
        #if DEBUG
        if let seededPageContext { return seededPageContext }
        #endif
        return browser.pageContext
    }

    #if DEBUG
    /// Screenshot and UI-test seeds: the page context they show until the
    /// browser reports a scroll position.
    private(set) var seededPageContext: PageContext?
    #endif

    private func handlePageContext(_ context: PageContext) {
        objectWillChange.send()
        let previousSiteURL = lastPageSiteURL
        if let siteURL = context.siteURL {
            lastPageSiteURL = siteURL
        }
        if context.topic == nil,
           context.state == .forumHome,
           assistantMode == .agent,
           let previousSiteURL,
           let newSiteURL = context.siteURL,
           previousSiteURL != newSiteURL {
            assistantMode = .summary
            agentSiteURL = nil
        }
        if let suppressed = suppressedAutoAddSiteURL {
            // A forum removed while its page is open stays removed until the
            // browser settles on another forum or a non-forum page.
            if let siteURL = context.siteURL, siteURL != suppressed {
                suppressedAutoAddSiteURL = nil
            } else if context.state == .notForum {
                suppressedAutoAddSiteURL = nil
            }
        }
        if let kind = context.site, let siteURL = context.siteURL, siteURL != suppressedAutoAddSiteURL {
            recordVisit(siteURL: siteURL, kind: kind, name: context.forumName, iconURL: context.iconURL)
        }
        select(topic: context.topic)
        completePendingShare(with: context)
        pageUpdates.send(context)
        if prefetchesTopicFacts || barShowsTopicFacts, let topic = context.topic, context.state == .topic,
           topicOverviews[topic.topicKey] == nil {
            Task { [weak self] in _ = await self?.topicOverview(siteURL: topic.siteURL, topicID: topic.topicID) }
        }
    }

    /// Only the page's position changed (posts on screen, highlights, the
    /// topic's facts): no topic selection or save.
    func handlePagePosition(_ context: PageContext) {
        #if DEBUG
        seededPageContext = nil
        #endif
        pageUpdates.send(context)
    }

    /// How a link on `siteURL` is read: the site's adapter, with the forum's base
    /// path. Nothing parses when the site has no adapter.
    func linkParser(siteURL: String) -> AgentSources.Parse {
        linkParser(siteURL: siteURL, known: [:])
    }

    /// The parser of one run's links: the adapter's, then the permalinks the
    /// run's tools showed (`AgentRun.knownLinks`), for a platform whose links
    /// carry no topic id.
    func linkParser(for run: AgentRun) -> AgentSources.Parse {
        linkParser(siteURL: run.siteURL, known: run.knownLinks)
    }

    private func linkParser(siteURL: String, known: [String: String]) -> AgentSources.Parse {
        let links = adapter(for: siteURL)?.links
        let basePath = ForumSite.parse(siteURL: siteURL)?.basePath ?? ""
        return AgentSources.Parse(basePath: basePath) { url in
            guard let links else { return nil }
            if let link = links.parse(url, basePath: basePath) { return link }
            return known[AgentSources.knownKey(url, links: links)].map { SiteLink(topicID: $0, slug: nil, postNumber: nil) }
        }
    }

    /// The forum a URL is on: a directory forum, else the page's forum.
    func siteURL(containing url: URL) -> String? {
        if let forum = directory.forum(containing: url) { return forum.siteURL }
        if let siteURL = pageContext.siteURL, ForumSite.isSameForum(url: url, siteURL: siteURL) { return siteURL }
        return nil
    }

    nonisolated private static func sameSharedPage(_ lhs: URL, _ rhs: URL) -> Bool {
        if PageContext.samePage(lhs, rhs) { return true }
        func normalized(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            if let path = components?.path, path.count > 1, path.hasSuffix("/") {
                components?.path = String(path.dropLast())
            }
            return components?.string ?? url.absoluteString
        }
        return normalized(lhs) == normalized(rhs)
    }

    private func completePendingShare(with context: PageContext) {
        guard var pending = pendingShare, let url = context.url else { return }
        if !pending.sawSharedPage, Self.sameSharedPage(url, pending.url) {
            pending.sawSharedPage = true
            pendingShare = pending
        }
        switch context.state {
        case .loading, .maybe:
            return
        case .notForum:
            // Only give up once the shared page itself (or its redirect) settled.
            if !browser.isLoading { pendingShare = nil }
            return
        case .forumHome, .topic:
            break
        }
        let topicMatches: Bool
        if let expectedID = pending.topicID {
            topicMatches = context.topic?.topicID == expectedID
        } else {
            topicMatches = context.state == .topic
                && context.topic != nil
                && (Self.sameSharedPage(url, pending.url) || pending.sawSharedPage)
        }
        switch pending.action {
        case .open:
            pendingShare = nil
        case .agent:
            pendingShare = nil
            agentSiteURL = context.siteURL
            assistantMode = .agent
            panelRoute = .topic
            requestAssistant()
            if !isProviderReady(for: .agent) { needsProviderSetup = .agent }
        case .summary, .chat:
            guard topicMatches else {
                // A Discourse page that is not the shared topic: stop waiting
                // once loading finished somewhere else. For a topic page that
                // needs the shared page to have been reached first (a late
                // report from the page before it must not cancel the share);
                // after that, the user went elsewhere, and visiting the
                // shared topic later must not start work by surprise.
                if !browser.isLoading, !Self.sameSharedPage(url, pending.url),
                   context.state == .forumHome || pending.sawSharedPage {
                    pendingShare = nil
                }
                return
            }
            pendingShare = nil
            assistantMode = pending.action == .summary ? .summary : .chat
            panelRoute = .topic
            requestAssistant()
            guard isProviderReady(for: .assistant) else {
                needsProviderSetup = .assistant
                return
            }
            // A deep link that did not come from the share extension — or a
            // hand-off before onboarding and the Terms of Use are done — only
            // opens the Assistant; the user starts the work.
            guard pending.autoRun, acceptsSystemWork else { return }
            if pending.action == .summary {
                // The same topic shared again while its summary runs: show it.
                if let topicKey = currentTopic?.topicKey,
                   hasActiveWork(topicKey: topicKey, type: .summary) {
                    return
                }
                startSummary()
            } else if currentSession?.source.isEmpty ?? true,
                      let topicKey = currentTopic?.topicKey,
                      !hasActiveWork(topicKey: topicKey, type: .pull) {
                pullTopic()
            }
        }
    }

    func select(topic: ForumTopic?) {
        #if DEBUG
        if topic == nil,
           ProcessInfo.processInfo.arguments.contains("-ui-test-sample-session") {
            return
        }
        #endif
        if case .editing(let editTopicKey, _, _) = chatEdit, editTopicKey != topic?.topicKey {
            cancelEditChat()
        }
        currentTopic = topic
        topicActivityDidChange(topic)
        guard let topic else { return }
        #if DEBUG
        let resetForPullUITest = ProcessInfo.processInfo.arguments.contains(
            "-ui-test-pull-mode"
        )
        #else
        let resetForPullUITest = false
        #endif
        var session = resetForPullUITest ? nil : sessions[topic.topicKey]
        if session == nil {
            session = TopicSession(siteURL: topic.siteURL, topicID: topic.topicID, url: topic.url, title: topic.title)
        }
        session?.url = topic.url
        session?.title = topic.title
        // The page is in front of the user: the one place a visit is recorded.
        session?.openedByUserAt = Date()
        sessions[topic.topicKey] = session
        save()
    }

    /// Starts a summary; `batchLimit` overrides the hierarchical-summary batch
    /// size for this run only.
    /// `regenerate`: write it again even when no reply is new (Retry).
    func startSummary(batchLimit: Int? = nil, regenerate: Bool = false) {
        guard let topic = currentTopic else {
            presentError(AssistantError.noTopic.localizedDescription)
            return
        }
        if activities.contains(where: {
            $0.topicKey == topic.topicKey && $0.type == .summary && !$0.status.isTerminal
        }) {
            return
        }
        router.summarizeTipSeen()
        let shouldRegenerate = regenerate || (batchLimit != nil && currentSession?.hasSummary == true)
        enqueueSummary(for: topic, batchLimit: batchLimit, regenerate: shouldRegenerate)
    }

    /// Queues a summary task for any topic (used by watched-topic refreshes,
    /// `origin: .automatic`).
    @discardableResult
    func enqueueSummary(
        for topic: ForumTopic,
        batchLimit: Int? = nil,
        regenerate: Bool = false,
        origin: WorkOrigin = .user
    ) -> Bool {
        guard !activities.contains(where: {
            $0.topicKey == topic.topicKey && $0.type == .summary && !$0.status.isTerminal
        }) else {
            return false
        }
        guard activeTaskCount < 50 else {
            if origin == .user {
                presentError(String(localized: "The task queue is full. Cancel or wait for an existing task."))
            }
            return false
        }

        let selection = settings.assistantModel
        var record = WorkRecord(
            type: .summary,
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            title: topic.title,
            url: topic.url,
            provider: selection.provider,
            model: selection.model
        )
        record.batchLimit = batchLimit.map(SummaryBatchLimit.normalized)
        record.origin = origin
        if regenerate { record.regenerate = true }
        activities.insert(record, at: 0)
        save()
        launch(recordID: record.id)
        return true
    }

    // MARK: Forums

    private var directory: ForumDirectory {
        get { ForumDirectory(forums: forums) }
        set { forums = newValue.forums }
    }

    var pinnedForums: [Forum] { directory.pinned }
    var recentForums: [Forum] { directory.recent }

    func forum(for siteURL: String) -> Forum? {
        directory.forum(siteURL: siteURL)
    }

    /// The adapter that reads `siteURL`. Lookup order: (1) a host the registry
    /// claims (one site whatever the path); (2) the directory forum's kind;
    /// (3) the open page's detected site when its site URL matches (a forum
    /// removed while its page is still open, `suppressedAutoAddSiteURL`).
    /// Nil means unsupported, and the registry is not asked for a guess: callers
    /// fail with `AssistantError.noForum`, never crash or delete anything.
    func adapter(for siteURL: String) -> (any SiteAdapter)? {
        if let host = URL(string: siteURL)?.host, let claimed = sites.claimedSite(forHost: host) { return claimed.adapter }
        if let forum = forum(for: siteURL) { return sites.adapter(for: forum.kind) }
        let normalized = ForumSite.normalizeSiteURL(siteURL) ?? siteURL
        if pageContext.siteURL == normalized, let kind = pageContext.site { return sites.adapter(for: kind) }
        return nil
    }

    /// The transport for one job on `siteURL`: the forum's cookies, the pace the
    /// job started with and (unless `inPage` is false) the in-page loader.
    func network(for siteURL: String, pace: ForumRequestPace, inPage: Bool = true) async -> SiteNetwork {
        let cookieHeader = await browser.cookieHeader(forSite: siteURL)
        var context = SiteRequestContext(cookieHeader: cookieHeader, pace: pace)
        if inPage, let loader = webViewResourceLoader {
            context.resourceLoader = { url in try await loader(url) }
        }
        return SiteNetwork(service: forumService, siteURL: siteURL, context: context)
    }

    /// The current forum: the last Discourse forum shown (or opened by the
    /// app), resolved from `currentSiteURL` so its name, icon and pin state
    /// always come from the directory.
    var currentForum: Forum? {
        currentSiteURL.map { forumInfo(siteURL: $0) }
    }

    /// After runs were deleted: select a remaining run, and drop a follow-up
    /// draft that belonged to a deleted one.
    func reconcileAgentSelection() {
        guard let selectedAgentRunID, !agentRuns.contains(where: { $0.id == selectedAgentRunID }) else {
            return
        }
        self.selectedAgentRunID = agentRuns.first?.id
        drafts.followUp = ""
    }

    func hasActiveWork(topicKey: String, type: WorkType) -> Bool {
        activities.contains { $0.topicKey == topicKey && $0.type == type && !$0.status.isTerminal }
    }

    /// Most recently visited forum, else the first pinned one.
    static func startForum(in forums: [Forum]) -> Forum? {
        let directory = ForumDirectory(forums: forums)
        return forums
            .filter { $0.lastVisitedAt != nil }
            .max { ($0.lastVisitedAt ?? .distantPast) < ($1.lastVisitedAt ?? .distantPast) }
            ?? directory.pinned.first
    }

    /// Adds (or refreshes) a forum and marks it visited; called for every
    /// detected Discourse page, so visited forums show up as recent.
    func recordVisit(siteURL: String, kind: SiteKind, name: String?, iconURL: URL?) {
        var directory = self.directory
        let previous = directory.forum(siteURL: siteURL)
        let now = Date()
        // Visits within a minute on the same forum do not rewrite the snapshot.
        let isFreshVisit = previous?.lastVisitedAt.map { now.timeIntervalSince($0) > 60 } ?? true
        guard let forum = directory.upsert(
            siteURL: siteURL,
            kind: kind,
            name: name,
            iconURL: iconURL,
            visitedAt: isFreshVisit ? now : nil
        ) else {
            return
        }
        let changed = forum != previous
        if changed { self.directory = directory }
        if currentSiteURL != forum.siteURL { currentSiteURL = forum.siteURL }
        if changed { save() }
    }

    /// Validates an address (URL or host, optionally a page on the forum) by
    /// asking each registered adapter, in order, for the site's info (Discourse:
    /// `/site/basic-info.json`, fallback `/about.json`), then adds the forum with
    /// its kind, name and icon. Existing forums are refreshed. A repeated call
    /// for the address being detected joins that detection (`addForumPhase`).
    @discardableResult
    func addForum(fromAddress address: String, pin: Bool = false) async throws -> Forum {
        let key = AddForumRequest(address: address, pin: pin)
        if case .detecting = addForumPhase, let running = addForumTask, running.key == key {
            return try await running.task.value
        }
        let task = Task { [weak self] () throws -> Forum in
            guard let self else { throw CancellationError() }
            return try await self.detectForum(key)
        }
        addForumTask = (key, task)
        addForumPhase = .detecting(address: address)
        defer {
            if addForumTask?.key == key {
                addForumTask = nil
                // Cancelled before it found an answer: not detecting any more.
                if case .detecting = addForumPhase { addForumPhase = .idle }
            }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Ends the detection `key` started with `phase`, unless a newer one replaced it.
    private func finishAddForum(_ key: AddForumRequest, _ phase: AddForumPhase) {
        if addForumTask?.key == key { addForumPhase = phase }
    }

    private func detectForum(_ key: AddForumRequest) async throws -> Forum {
        let address = key.address
        var firstCandidate: String?
        var lastFailure: NetworkFailure?
        for adapter in sites.adapters {
            for siteURL in adapter.siteURLCandidates(fromAddress: address) {
                firstCandidate = firstCandidate ?? siteURL
                guard ForumSite.parse(siteURL: siteURL).flatMap({ URLComponents(string: $0.origin)?.host }) != nil else {
                    continue
                }
                let net = await network(for: siteURL, pace: settings.forumRequestPace, inPage: false)
                let info: ForumSiteInfo
                do {
                    info = try await adapter.siteInfo(siteURL: siteURL, net: net)
                } catch {
                    lastFailure = NetworkFailure.classify(error)
                    continue
                }
                var directory = self.directory
                guard var forum = directory.upsert(
                    siteURL: siteURL,
                    kind: adapter.kind,
                    name: info.name,
                    iconURL: info.iconURL,
                    overwritingKind: true
                ) else {
                    continue
                }
                if key.pin {
                    directory.setPinned(true, siteURL: forum.siteURL)
                    forum = directory.forum(siteURL: forum.siteURL) ?? forum
                }
                if suppressedAutoAddSiteURL == forum.siteURL { suppressedAutoAddSiteURL = nil }
                self.directory = directory
                save()
                browser.refreshPageContext()
                finishAddForum(key, .recognized(kind: adapter.kind, siteURL: forum.siteURL))
                return forum
            }
        }
        guard let firstCandidate else {
            finishAddForum(key, .idle)
            throw ForumDirectoryError.invalidAddress
        }
        finishAddForum(key, lastFailure.map { .failed($0) } ?? .unsupported)
        throw ForumDirectoryError.notSupported(ForumSite.host(of: firstCandidate))
    }

    /// Fetches a forum's name and icon in the background. Only the name and
    /// icon change: a forum removed meanwhile is not added back, and its pin
    /// state is whatever the user set while the request ran.
    func refreshForumInfo(siteURL: String) {
        guard let normalized = ForumSite.normalizeSiteURL(siteURL),
              let forum = forum(for: normalized),
              let adapter = adapter(for: normalized)
        else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let net = await self.network(for: normalized, pace: self.settings.forumRequestPace, inPage: false)
            guard let info = try? await adapter.siteInfo(siteURL: normalized, net: net),
                  self.forum(for: normalized) != nil
            else {
                return
            }
            var directory = self.directory
            directory.upsert(siteURL: normalized, kind: forum.kind, name: info.name, iconURL: info.iconURL)
            guard directory.forums != self.forums else { return }
            self.directory = directory
            self.save()
        }
    }

    func pin(_ forum: Forum) {
        // A placeholder (`forumInfo`, kind .unknown) is not a forum the app can keep.
        guard forum.kind != .unknown || directory.forum(siteURL: forum.siteURL) != nil else { return }
        if suppressedAutoAddSiteURL == forum.siteURL { suppressedAutoAddSiteURL = nil }
        var directory = self.directory
        if directory.forum(siteURL: forum.siteURL) == nil {
            directory.upsert(siteURL: forum.siteURL, kind: forum.kind, name: forum.name, iconURL: forum.iconURL)
        }
        directory.setPinned(true, siteURL: forum.siteURL)
        self.directory = directory
        save()
    }

    func unpin(_ forum: Forum) {
        var directory = self.directory
        directory.setPinned(false, siteURL: forum.siteURL)
        self.directory = directory
        save()
    }

    func togglePin(_ forum: Forum) {
        if directory.forum(siteURL: forum.siteURL)?.isPinned == true {
            unpin(forum)
        } else {
            pin(forum)
        }
    }

    /// Reorders `pinnedForums` (offsets are into `pinnedForums`).
    func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        var directory = self.directory
        directory.movePinned(fromOffsets: source, toOffset: destination)
        self.directory = directory
        save()
    }

    /// Removes a forum from the directory. With `deleteData`, also cancels its
    /// active work and deletes its saved summaries, chats, agent runs, and
    /// watched topics.
    ///
    /// Work already running for the forum keeps running unless its data is
    /// deleted: a job resolved its adapter when it started and finishes with
    /// it (its pages and results are kept). Work still queued fails with
    /// `noForum` when the data is kept. The agent's forum falls back to the page's forum, and a page
    /// of the removed forum that is still open does not add it back.
    func removeForum(_ forum: Forum, deleteData: Bool) {
        let siteURL = forum.siteURL
        if deleteData {
            for record in activities where record.siteURL == siteURL && !record.status.isTerminal {
                cancel(record: record)
            }
            sessions = sessions.filter { $0.value.siteURL != siteURL }
            activities.removeAll { $0.siteURL == siteURL }
            agentRuns.removeAll { $0.siteURL == siteURL }
            watchedTopics.removeAll { $0.siteURL == siteURL }
            reconcileAgentSelection()
            removeDigestCards(siteURL: siteURL)
        }
        if pageContext.siteURL == siteURL { suppressedAutoAddSiteURL = siteURL }
        var directory = self.directory
        directory.remove(siteURL: siteURL)
        self.directory = directory
        if !deleteData { failQueuedWork(siteURL: siteURL, error: AssistantError.noForum) }
        if currentSiteURL == siteURL {
            currentSiteURL = (pageContext.siteURL.flatMap { self.directory.forum(siteURL: $0) }
                ?? Self.startForum(in: forums))?.siteURL
        }
        if agentSiteURL == siteURL { agentSiteURL = nil }
        if browser.homeSiteURL == siteURL, (pageContext.siteURL != siteURL || browser.showsForumsHome) {
            browser.homeSiteURL = currentSiteURL
        }
        save()
        browser.refreshPageContext()
    }

    /// Work still waiting for its turn on a forum that was just removed never
    /// starts: it ends in the explicit failed state (no spinner) and the person
    /// is asked to add the forum again. A chat answers from the stored source,
    /// so it stays queued.
    private func failQueuedWork(siteURL: String, error: Error) {
        for record in activities where record.siteURL == siteURL && record.status == .queued && record.type != .chat {
            progress.remove(record.id)
            mutateRecord(record.id) {
                $0.status = .failed
                $0.statusText = String(localized: "Failed", comment: "Status of AI work that failed")
                $0.error = error.localizedDescription
                $0.completedAt = Date()
            }
            if record.type == .agent {
                mutateAgentRun(for: record) {
                    $0.result = .failed
                    $0.error = error.localizedDescription
                    $0.completedAt = Date()
                }
            }
            if record.origin == .user { presentError(error.localizedDescription) }
        }
    }

    /// Makes the forum current and loads its /latest.
    func openForum(_ forum: Forum) {
        // No adapter (a placeholder, or a platform this build lacks): leave the state alone.
        guard let adapter = sites.adapter(for: forum.kind) else { return }
        if suppressedAutoAddSiteURL == forum.siteURL { suppressedAutoAddSiteURL = nil }
        currentSiteURL = forum.siteURL
        browser.homeSiteURL = forum.siteURL
        browser.loadHome(adapter: adapter)
        panelRoute = .topic
    }

    /// Opens a suggested forum (added to the directory as recent on arrival).
    func openForum(_ suggested: SuggestedForum) {
        openForum(Forum(siteURL: suggested.siteURL, kind: suggested.kind, name: suggested.name))
    }

    // MARK: Agent runs

    /// Starts an agent run on `siteURL` (default: `agentSiteURL`, else the
    /// current forum). Every tool call and follow-up stays on that forum.
    func startAgentRun(goal rawGoal: String, siteURL: String? = nil, origin: AgentRunOrigin = .typed) {
        guard !rawGoal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            selectedAgentRunID = try enqueueAgentRun(goal: rawGoal, siteURL: siteURL, origin: origin)
            drafts.goal = ""
        } catch {
            presentError(error.localizedDescription)
        }
    }

    /// Starts an agent run from code (the voice `research` tool): it goes
    /// through the same work queue and loop, shows up in Ask the forum and
    /// Manage, but leaves the panel, the selected run and the drafts alone.
    /// `completion` gets the outcome once, on the main actor, when the run
    /// completes, fails, is cancelled or is deleted. Throws instead of
    /// showing an alert when it cannot start.
    @discardableResult
    func startAgentRun(
        goal: String,
        siteURL: String? = nil,
        origin: AgentRunOrigin = .typed,
        completion: @escaping (AgentRunOutcome) -> Void
    ) throws -> UUID {
        let id = try enqueueAgentRun(goal: goal, siteURL: siteURL, origin: origin)
        agentRunCompletions[id] = completion
        return id
    }

    /// `startAgentRun(goal:siteURL:completion:)` as an async call. Cancelling
    /// the calling task cancels the run.
    func performAgentRun(goal: String, siteURL: String? = nil, origin: AgentRunOrigin = .typed) async throws -> AgentRunOutcome {
        let started = StartedRun()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let id = try startAgentRun(goal: goal, siteURL: siteURL, origin: origin) { continuation.resume(returning: $0) }
                    started.id = id
                    // Cancelled before the run existed: the handler saw no id.
                    if Task.isCancelled { cancelAgentRun(id: id) }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let id = started.id { self?.cancelAgentRun(id: id) }
            }
        }
    }

    /// The run id `performAgentRun` shares with its cancellation handler.
    private final class StartedRun: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UUID?
        var id: UUID? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// Cancels a queued or running agent run (its work record).
    func cancelAgentRun(id: UUID) {
        guard let record = activeRecord(forAgentRun: id) else { return }
        cancel(record: record)
    }

    private func enqueueAgentRun(goal rawGoal: String, siteURL: String?, origin: AgentRunOrigin) throws -> UUID {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { throw AgentError.missingArgument("goal") }
        guard let forumSiteURL = (siteURL ?? agentSiteURL ?? currentForum?.siteURL)
            .flatMap(ForumSite.normalizeSiteURL)
        else {
            throw AssistantError.noForum
        }
        guard activeTaskCount < 50 else { throw AgentError.queueFull }
        let selection = settings.agentModel
        var run = AgentRun(
            siteURL: forumSiteURL,
            goal: goal,
            provider: selection.provider,
            model: selection.model,
            origin: origin
        )
        run.transcript = [AgentPrompt.goalMessage(goal)]
        agentRuns.insert(run, at: 0)
        cloudSync.notePruned(kind: .run, ids: agentRuns.dropFirst(50).map(\.id.uuidString))
        agentRuns = Array(agentRuns.prefix(50))
        launchAgentRecord(for: run, title: goal)
        return run.id
    }

    /// Hands each waiting run that has ended (or is gone) its outcome, once.
    /// Called on every change to `agentRuns`; delivered on the next main-actor
    /// turn so a completion never runs inside that change.
    private func deliverAgentRunOutcomes() {
        guard !agentRunCompletions.isEmpty else { return }
        for (id, completion) in agentRunCompletions {
            let outcome: AgentRunOutcome
            if let run = agentRuns.first(where: { $0.id == id }) {
                guard let result = run.result else { continue }
                outcome = AgentRunOutcome(
                    runID: id,
                    status: result.workStatus,
                    answer: result == .completed ? run.answer : "",
                    sources: result == .completed
                        ? AgentSources.extract(
                            from: run.answer, run: run, sessions: sessions, parse: linkParser(for: run)
                        )
                        : [],
                    error: run.error
                )
            } else {
                outcome = AgentRunOutcome(
                    runID: id, status: .cancelled, answer: "", sources: [],
                    error: AgentError.runNotFound.localizedDescription
                )
            }
            agentRunCompletions.removeValue(forKey: id)
            Task { @MainActor in completion(outcome) }
        }
    }

    /// Continues a finished run with a follow-up question; the agent keeps the
    /// topics it already read and may call tools again.
    func continueAgentRun(id: UUID, question rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty,
              let index = agentRuns.firstIndex(where: { $0.id == id }),
              agentRuns[index].isFinished
        else {
            return
        }
        guard activeTaskCount < 50 else {
            presentError(String(localized: "The task queue is full. Cancel or wait for an existing task."))
            return
        }
        agentRuns[index].followUps.append(ChatMessage(role: .user, content: question))
        agentRuns[index].transcript.append(AgentPrompt.followUpMessage(question))
        agentRuns[index].result = nil
        agentRuns[index].error = ""
        agentRuns[index].updatedAt = Date()
        drafts.followUp = ""
        selectedAgentRunID = id
        launchAgentRecord(for: agentRuns[index], title: question)
    }

    func deleteAgentRun(id: UUID) {
        guard let run = agentRuns.first(where: { $0.id == id }), run.isFinished else {
            return
        }
        agentRuns.removeAll { $0.id == id }
        reconcileAgentSelection()
        save()
    }

    func openAgentRun(id: UUID) {
        dismissHistoryIfNeeded()
        if let run = agentRuns.first(where: { $0.id == id }) {
            agentSiteURL = run.siteURL
            if browser.showsForumsHome {
                lastPageSiteURL = run.siteURL
                let forum = forumInfo(siteURL: run.siteURL)
                if isCurrent(forum), browser.currentURL != nil {
                    browser.hideForumsHome()
                } else if sites.adapter(for: forum.kind) != nil {
                    openForum(forum)
                } else if let url = adapter(for: run.siteURL)?.links.homeURL(siteURL: run.siteURL) ?? URL(string: run.siteURL) {
                    browser.load(url)
                }
            }
        }
        selectedAgentRunID = id
        showSelectedAgentRun()
        panelRoute = .topic
        showAIView()
    }

    func showForumOverview() {
        guard currentTopic == nil, assistantPageState == .forumHome else { return }
        assistantMode = .summary
        agentSiteURL = nil
    }

    var selectedAgentRun: AgentRun? {
        guard let selectedAgentRunID else { return agentRuns.first }
        return agentRuns.first { $0.id == selectedAgentRunID } ?? agentRuns.first
    }

    /// The run's status: its outcome once it ended, else its work record's
    /// (queued, running, or paused; the record is the only live state).
    func status(of run: AgentRun) -> WorkStatus {
        if let result = run.result { return result.workStatus }
        return activeRecord(forAgentRun: run.id)?.status ?? .queued
    }

    func activeRecord(forAgentRun id: UUID) -> WorkRecord? {
        activities.first {
            $0.type == .agent && $0.topicID == Self.agentTopicPrefix + id.uuidString
                && !$0.status.isTerminal
        }
    }

    private func launchAgentRecord(for run: AgentRun, title: String) {
        let record = WorkRecord(
            type: .agent,
            siteURL: run.siteURL,
            topicID: Self.agentTopicPrefix + run.id.uuidString,
            title: title,
            url: adapter(for: run.siteURL)?.links.homeURL(siteURL: run.siteURL) ?? URL(string: run.siteURL)
                ?? URL(string: "about:blank")!,
            provider: run.provider,
            model: run.model
        )
        activities.insert(record, at: 0)
        save()
        launch(recordID: record.id)
    }

    // MARK: Watched topics

    func isWatched(topicKey: String) -> Bool {
        watchedTopics.contains { $0.topicKey == topicKey }
    }

    /// Watches or unwatches the current topic, fetching its post count when
    /// the app has not pulled it yet.
    func toggleWatchCurrentTopic() {
        guard let topic = currentTopic else { return }
        if isWatched(topicKey: topic.topicKey) {
            unwatch(topicKey: topic.topicKey)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var count = self.sessions[topic.topicKey]?.totalPosts
            if count == nil, let adapter = self.adapter(for: topic.siteURL) {
                count = try? await adapter.overview(
                    TopicRef(siteURL: topic.siteURL, topicID: topic.topicID),
                    net: await self.network(for: topic.siteURL, pace: self.settings.forumRequestPace)
                ).postCount
            }
            await self.watch(
                siteURL: topic.siteURL,
                topicID: topic.topicID,
                url: topic.url,
                title: topic.title,
                knownPostCount: count ?? 0
            )
        }
    }

    func watch(siteURL: String, topicID: String, url: URL, title: String, knownPostCount: Int) async {
        let watched = WatchedTopic(
            siteURL: siteURL,
            topicID: topicID,
            url: url,
            title: title,
            knownPostCount: knownPostCount
        )
        guard !isWatched(topicKey: watched.topicKey) else { return }
        watchedTopics.append(watched)
        save()
        if !notificationsAuthorized {
            notificationsAuthorized = await notifier.requestAuthorization()
        }
        WatchBackgroundRefresh.schedule()
    }

    func unwatch(topicKey: String) {
        watchedTopics.removeAll { $0.topicKey == topicKey }
        save()
    }

    func markWatchedSeen(topicKey: String) {
        guard let index = watchedTopics.firstIndex(where: { $0.topicKey == topicKey }) else { return }
        watchedTopics[index].markSeen()
        save()
    }

    func openWatched(_ watched: WatchedTopic) {
        dismissHistoryIfNeeded()
        dismissSettingsIfNeeded()
        markWatchedSeen(topicKey: watched.topicKey)
        browser.load(watched.url)
        panelRoute = .topic
        stepDownDrawerIfShown()
    }

    /// Checks every watched topic (on every forum) for new replies. In the
    /// foreground new replies can queue a summary refresh; in the background
    /// they post a notification.
    ///
    /// One check runs at a time (a timer, foreground, and background refresh
    /// can overlap; the later ones return at once). Topics unwatched while the
    /// check is fetching are skipped, and the auto-refresh setting is read
    /// when the replies arrive, so toggling it mid-check takes effect.
    ///
    /// Each topic is one paced request (`settings.forumRequestPace`). Topics
    /// checked longest ago go first, and a background check stops after
    /// `backgroundWatchCheckBudget`: the rest go first next time.
    func checkWatchedTopics(reason: WatchCheckReason) async {
        guard !watchedTopics.isEmpty, !isCheckingWatches else { return }
        isCheckingWatches = true
        defer { isCheckingWatches = false }
        lastWatchCheck = Date()
        var networks: [String: SiteNetwork] = [:]
        var arrivals: [(WatchedTopic, Int)] = []
        let pace = settings.forumRequestPace
        let clock = forumService.pacer.clock
        let started = clock.now()

        for watched in Self.watchCheckOrder(watchedTopics) {
            if Task.isCancelled { break }
            if reason == .background,
               clock.now() - started + pace.minimumInterval > Self.backgroundWatchCheckBudget {
                break
            }
            // A site without an adapter (its forum was removed) is skipped quietly.
            guard let adapter = adapter(for: watched.siteURL) else { continue }
            // The web view cannot run scripts while the app is in the background,
            // so background checks go straight to URLSession with each forum's cookies.
            let net: SiteNetwork
            if let known = networks[watched.siteURL] {
                net = known
            } else {
                net = await network(for: watched.siteURL, pace: pace, inPage: reason != .background)
                networks[watched.siteURL] = net
            }
            let result: Result<ForumTopicOverview, Error>
            do {
                result = .success(try await adapter.overview(
                    TopicRef(siteURL: watched.siteURL, topicID: watched.topicID),
                    net: net
                ))
            } catch {
                // Background time ran out: this topic stays due for next time.
                // (A URLSession request cancelled with the task throws
                // `URLError(.cancelled)`, not `CancellationError`.)
                if error is CancellationError || Task.isCancelled { break }
                result = .failure(error)
            }
            // The list may have changed during the fetch: find the topic again.
            guard let index = watchedTopics.firstIndex(where: { $0.topicKey == watched.topicKey })
            else { continue }
            switch result {
            case .success(let overview):
                let delta = watchedTopics[index].record(postCount: overview.postCount)
                if !overview.title.isEmpty { watchedTopics[index].title = overview.title }
                if var session = sessions[watched.topicKey] {
                    session.totalPosts = overview.postCount
                    session.lastCheckedAt = Date()
                    sessions[watched.topicKey] = session
                }
                if delta > 0 { arrivals.append((watchedTopics[index], delta)) }
            case .failure:
                watchedTopics[index].lastCheckedAt = Date()
            }
        }
        save()

        guard !arrivals.isEmpty else { return }
        let appIsActive = UIApplication.shared.applicationState == .active
        if reason == .background || !appIsActive {
            for (watched, delta) in arrivals where isWatched(topicKey: watched.topicKey) {
                await notifier.notifyNewReplies(topic: watched, count: delta)
            }
        }
        // Without a connected provider the refresh would only fail (and alert).
        if reason != .background, settings.watchAutoRefreshSummaries, canRunUnattended(.assistant) {
            for (watched, _) in arrivals
            where isWatched(topicKey: watched.topicKey) && sessions[watched.topicKey]?.hasSummary == true {
                enqueueSummary(
                    for: ForumTopic(
                        siteURL: watched.siteURL,
                        topicID: watched.topicID,
                        url: watched.url,
                        title: watched.title
                    ),
                    origin: .automatic
                )
            }
        }
    }

    /// Background App Refresh gives about 30 seconds; paced checks stop well
    /// before that.
    static var backgroundWatchCheckBudget: TimeInterval = 20

    /// Topics never checked first, then the ones checked longest ago, so a
    /// check cut short never starves the same topics.
    nonisolated static func watchCheckOrder(_ topics: [WatchedTopic]) -> [WatchedTopic] {
        topics.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.lastCheckedAt ?? .distantPast
                let right = rhs.element.lastCheckedAt ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            drainSharedInbox()
            startWatchTimer()
            // API keys edited on another device arrive through iCloud
            // Keychain, which has no change notification on iOS (sync passes
            // re-read them too, but iCloud sync may be off).
            reloadProviderKeysFromKeychain()
            let stale = lastWatchCheck.map {
                Date().timeIntervalSince($0) >= Self.watchInterval
            } ?? true
            if stale {
                Task { [weak self] in await self?.checkWatchedTopics(reason: .foreground) }
            }
            Task { [weak self] in await self?.refreshNotificationAuthorization() }
            openTodayFromNotification()
            resumeDigestIfNeeded()
            podcast.resumeIfNeeded()
            workEnteredForeground()
            // After the inbox and the digest have started: where the launch lands.
            applyLaunchRuleIfNeeded()
        case .inactive:
            // Coalesced edits must not be lost if the app is closed next.
            flushPendingSaves()
        case .background:
            flushPendingSaves()
            watchTimer?.cancel()
            watchTimer = nil
            if !watchedTopics.isEmpty { WatchBackgroundRefresh.schedule() }
            // Summaries are made in the foreground only; the run continues
            // from the same card next time.
            pauseDigest()
            // Likewise the podcast's chapters; playback goes on.
            podcast.pauseGeneration()
            // Summaries, chats and Ask the forum finish if they can in the
            // time the system gives, else pause until the app is back.
            workEnteredBackground()
            if settings.dailyDigestEnabled { scheduleDigestPrefetch() }
        @unknown default:
            break
        }
        cloudSync.handleScenePhase(phase)
    }

    func requestNotificationAuthorization() {
        Task { [weak self] in
            guard let self else { return }
            self.notificationsAuthorized = await self.notifier.requestAuthorization()
        }
    }

    private func refreshNotificationAuthorization() async {
        let authorized = await notifier.isAuthorized()
        if notificationsAuthorized != authorized {
            notificationsAuthorized = authorized
        }
    }

    private func startWatchTimer() {
        watchTimer?.cancel()
        watchTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchInterval))
                guard !Task.isCancelled else { return }
                await self?.checkWatchedTopics(reason: .foreground)
            }
        }
    }

    func setInstructions(_ instructions: String, topicKey: String) {
        guard var session = sessions[topicKey] else { return }
        session.instructions = instructions
        session.updatedAt = Date()
        sessions[topicKey] = session
        save()
    }

    /// Instructions for a topic: its own when set, otherwise the global ones.
    func effectiveInstructions(for topicKey: String) -> String {
        PromptBuilder.effectiveInstructions(
            topic: sessions[topicKey]?.instructions ?? "",
            global: settings.systemPrompt
        )
    }

    func pullTopic() {
        guard let topic = currentTopic else {
            presentError(AssistantError.noTopic.localizedDescription)
            return
        }
        if activities.contains(where: {
            $0.topicKey == topic.topicKey && $0.type == .pull && !$0.status.isTerminal
        }) {
            panelRoute = .history
            return
        }
        guard activeTaskCount < 50 else {
            presentError(String(localized: "The task queue is full. Cancel or wait for an existing task."))
            return
        }

        let selection = settings.assistantModel
        let record = WorkRecord(
            type: .pull,
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            title: topic.title,
            url: topic.url,
            provider: selection.provider,
            model: selection.model
        )
        activities.insert(record, at: 0)
        save()
        launch(recordID: record.id)
    }

    /// The user turn currently being edited on the open topic, if it still exists.
    var activeChatEdit: (topicKey: String, messageID: UUID, index: Int)? {
        guard case .editing(let topicKey, let messageID, _) = chatEdit,
              currentTopic?.topicKey == topicKey,
              let history = sessions[topicKey]?.history,
              let index = history.firstIndex(where: { $0.id == messageID && $0.role == .user })
        else {
            return nil
        }
        return (topicKey, messageID, index)
    }

    func sendChat() {
        let question = drafts.chat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        guard let topic = currentTopic else {
            presentError(AssistantError.noTopic.localizedDescription)
            return
        }
        let edit = activeChatEdit
        let hasRunningChat = activities.contains {
            $0.topicKey == topic.topicKey && $0.type == .chat && !$0.status.isTerminal
        }
        if edit == nil, hasRunningChat {
            presentError(String(localized: "Wait for the current answer or cancel it in Manage."))
            return
        }
        guard (edit != nil && hasRunningChat) || activeTaskCount < 50 else {
            presentError(String(localized: "The task queue is full. Cancel or wait for an existing task."))
            return
        }
        if edit != nil {
            cancelActiveChat(topicKey: topic.topicKey)
            chatEdit = .none
        } else if case .editing(let editTopicKey, _, _) = chatEdit, editTopicKey == topic.topicKey {
            chatEdit = .none
        }

        var session = sessions[topic.topicKey] ?? TopicSession(
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            url: topic.url,
            title: topic.title
        )
        if let edit,
           let index = session.history.firstIndex(where: { $0.id == edit.messageID && $0.role == .user }) {
            session.history.removeSubrange(index...)
        }
        let userMessage = ChatMessage(role: .user, content: question)
        session.history.append(userMessage)
        session.history = Array(session.history.suffix(100))
        session.chatUpdatedAt = Date()
        session.updatedAt = Date()
        sessions[topic.topicKey] = session
        drafts.chat = ""

        let selection = settings.assistantModel
        let record = WorkRecord(
            type: .chat,
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            title: topic.title,
            url: topic.url,
            question: question,
            provider: selection.provider,
            model: selection.model
        )
        activities.insert(record, at: 0)
        save()
        launch(recordID: record.id)
    }

    func cancel(record: WorkRecord) {
        runningTasks[record.id]?.task.cancel()
        runningTasks.removeValue(forKey: record.id)
        summaryFeeds.removeValue(forKey: record.id)?.cancel()
        streams.remove(record.id)
        progress.remove(record.id)
        Task {
            await limiter.cancel(workID: record.id)
        }
        mutateRecord(record.id) {
            $0.status = .cancelled
            $0.statusText = String(localized: "Cancelled", comment: "Status of AI work the user cancelled")
            $0.completedAt = Date()
        }
        if record.type == .agent {
            mutateAgentRun(for: record) {
                $0.result = .cancelled
                $0.completedAt = Date()
            }
        }
        save()
    }

    /// Delete from History: a record in progress is cancelled first.
    func removeActivity(id: UUID) {
        if let record = activities.first(where: { $0.id == id }), !record.status.isTerminal {
            cancel(record: record)
        }
        deleteActivity(id: id)
    }

    func deleteActivity(id: UUID) {
        guard let record = activities.first(where: { $0.id == id }),
              record.status.isTerminal
        else {
            return
        }
        activities.removeAll { $0.id == id }
        save()
    }

    func open(record: WorkRecord) {
        if record.type == .agent, let runID = agentRunID(for: record) {
            openAgentRun(id: runID)
            return
        }
        dismissHistoryIfNeeded()
        assistantMode = .summary
        browser.load(record.url)
        panelRoute = .topic
        stepDownDrawerIfShown()
    }

    func open(session: TopicSession) {
        dismissHistoryIfNeeded()
        assistantMode = .summary
        browser.load(session.url)
        panelRoute = .topic
        stepDownDrawerIfShown()
    }

    private func dismissHistoryIfNeeded() {
        if router.item == .expanded(.history) {
            router.item = nil
        }
    }

    private func dismissSettingsIfNeeded() {
        if requestedSettingsPage != nil { requestedSettingsPage = nil }
        if router.item == .expanded(.settings) { router.item = nil }
        #if DEBUG
        if case .debugSettings = router.item { router.item = nil }
        #endif
    }

    private func stepDownDrawerIfShown() {
        if router.usesDrawer, router.drawerPhase.isPresented, router.drawerDetent == .large {
            router.drawerDetent = .medium
        }
    }

    func setKept(_ kept: Bool, topicKey: String) {
        guard var session = sessions[topicKey] else { return }
        session.kept = kept
        session.updatedAt = Date()
        sessions[topicKey] = session
        save()
    }

    func deleteSession(topicKey: String) {
        guard !activities.contains(where: {
            $0.topicKey == topicKey && !$0.status.isTerminal
        }) else {
            presentError(String(localized: "Cancel this topic’s active tasks before deleting it."))
            return
        }
        if case .editing(let editTopicKey, _, _) = chatEdit, editTopicKey == topicKey {
            cancelEditChat()
        }
        sessions.removeValue(forKey: topicKey)
        save()
    }

    private func cancelActiveChat(topicKey: String) {
        for record in activities where record.topicKey == topicKey && record.type == .chat && !record.status.isTerminal {
            cancel(record: record)
        }
    }

    func clearChat() {
        guard let topicKey = currentTopic?.topicKey else {
            return
        }
        if case .editing(let editTopicKey, _, _) = chatEdit, editTopicKey == topicKey {
            cancelEditChat()
        }
        cancelActiveChat(topicKey: topicKey)
        guard var session = sessions[topicKey] else {
            return
        }
        session.history = []
        session.chatUpdatedAt = nil
        session.updatedAt = Date()
        sessions[topicKey] = session
        save()
    }

    func editChat(messageID: UUID) {
        guard let topicKey = currentTopic?.topicKey,
              let session = sessions[topicKey],
              let index = session.history.firstIndex(where: { $0.id == messageID }),
              session.history[index].role == .user
        else {
            return
        }
        if assistantMode == .agent {
            assistantMode = .chat
        }
        let content = session.history[index].content
        if case .editing(let editTopicKey, let existingID, let previousDraft) = chatEdit,
           editTopicKey == topicKey {
            if existingID == messageID, drafts.chat == content {
                askFocusRequest += 1
                return
            }
            chatEdit = .editing(topicKey: topicKey, messageID: messageID, previousDraft: previousDraft)
        } else {
            chatEdit = .editing(topicKey: topicKey, messageID: messageID, previousDraft: drafts.chat)
        }
        drafts.chat = content
        askFocusRequest += 1
    }

    func cancelEditChat() {
        guard case .editing(_, _, let previousDraft) = chatEdit else { return }
        chatEdit = .none
        drafts.chat = previousDraft
    }

    /// Exits chat edit mode without overwriting drafts (used when `carryingAskText`
    /// transfers the composer text out of `This topic`).
    func abandonEditChatWithoutRestoringDraft() {
        guard chatEdit != .none else { return }
        chatEdit = .none
    }

    /// Persists settings (API keys to the key store, the rest to the
    /// snapshot). Coalesced: views call this on every slider step, and every
    /// settings change schedules it anyway, so the write happens once the
    /// edits pause (`settingsSaveDelay`), when the app leaves the foreground,
    /// or with the next data save — whichever comes first.
    func saveSettings() {
        settingsSaveTask?.cancel()
        let delay = settingsSaveDelay
        settingsSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    /// Writes coalesced settings edits and waits until the snapshot is on
    /// disk (scene inactive/background, background tasks, tests).
    func flushPendingSaves() {
        if settingsSaveTask != nil { save() }
        store.flush()
    }

    /// Writes API keys that changed since the last write; returns false (and
    /// reports) when the key store refuses one.
    @discardableResult
    private func persistChangedAPIKeys() -> Bool {
        for provider in AIProvider.allCases {
            let key = settings.configuration(for: provider).apiKey
            guard persistedAPIKeys[provider] != key else { continue }
            do {
                try keyStore.set(key, for: provider)
                persistedAPIKeys[provider] = key
            } catch {
                presentError(error.localizedDescription)
                return false
            }
        }
        return true
    }

    /// Reacts to any settings edit (Settings, favorites, onboarding, reset).
    private func settingsDidChange(from old: AppSettings) {
        guard old != settings else { return }
        for provider in AIProvider.allCases {
            let oldConfiguration = old.configuration(for: provider)
            let newConfiguration = settings.configuration(for: provider)
            let endpointChanged = oldConfiguration.baseURL != newConfiguration.baseURL
            guard endpointChanged || oldConfiguration.apiKey != newConfiguration.apiKey else { continue }
            // Results of a test or model load for the old configuration are stale.
            connectionTestGeneration[provider, default: 0] &+= 1
            modelDiscoveryGeneration[provider, default: 0] &+= 1
            settingsStatus = ""
            if endpointChanged, discoveredModels[provider] != nil { discoveredModels[provider] = nil }
        }
        if let role = needsProviderSetup, isProviderReady(for: role) { needsProviderSetup = nil }
        contentBlockingSettingsDidChange(from: old)
        digestSettingsDidChange(from: old)
        systemSettingsDidChange(from: old)
        if old.blockedUsers != settings.blockedUsers
            || old.blockedPosts != settings.blockedPosts
            || old.filteredWords != settings.filteredWords {
            applyModerationRules()
        }
        if old.voiceEnabled, !settings.voiceEnabled {
            voice.end()
        }
        saveSettings()
    }

    /// Resets preferences; onboarding progress is not a preference and stays.
    /// Work already running keeps the provider it started with; queued work
    /// starts with the defaults (and fails clearly without a key).
    ///
    /// "Sync API keys" stays as it is: it says where this device's keys live,
    /// and the reset deletes them there. (Switching it back on would adopt the
    /// iCloud Keychain keys again, so a reset with it off would bring keys
    /// back on the next pass or launch; switching it on first would delete
    /// the synced keys on every device.)
    func resetSettings() {
        var fresh = AppSettings()
        fresh.hasCompletedOnboarding = settings.hasCompletedOnboarding
        fresh.syncAPIKeys = settings.syncAPIKeys
        // Moderation is the user's safety choice, not a preference to reset.
        fresh.acceptedTermsVersion = settings.acceptedTermsVersion
        fresh.blockedUsers = settings.blockedUsers
        fresh.blockedPosts = settings.blockedPosts
        fresh.filteredWords = settings.filteredWords
        // So is what the person agreed to send where.
        fresh.aiConsent = settings.aiConsent
        fresh.voiceConsent = settings.voiceConsent
        fresh.podcastConsent = settings.podcastConsent
        settings = fresh
        discoveredModels = [:]
        settingsStatus = ""
        save()
        // A clean start for Spotlight too: rebuilt from the saved topics.
        resetSpotlightIndex()
    }

    /// Ends the walkthrough (first run or replay). Browsing, the Assistant,
    /// and running work are left as they are.
    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        save()
    }

    /// Loads `provider`'s models into `discoveredModels[provider]`. A result
    /// that arrives after that provider's base URL or key changed (or after a
    /// newer load started) is dropped and reported as `.stale`.
    @discardableResult
    func discoverModels(provider: AIProvider) async -> ProviderCheckResult {
        modelDiscoveryGeneration[provider, default: 0] &+= 1
        let generation = modelDiscoveryGeneration[provider]
        let configuration = settings.configuration(for: provider)
        settingsStatus = String(localized: "Loading models…")
        do {
            let models = try await aiService.discoverModels(configuration: configuration, provider: provider)
            guard generation == modelDiscoveryGeneration[provider] else { return .stale }
            discoveredModels[provider] = models
            settingsStatus = String(localized: "Loaded \(models.count) models", comment: "AI provider settings: number of models found")
            return .success
        } catch {
            guard generation == modelDiscoveryGeneration[provider] else { return .stale }
            settingsStatus = String(localized: "Model loading failed")
            return .failure(error.localizedDescription)
        }
    }

    /// Tests `provider` with its key and address. A result for a
    /// configuration the user has since changed (or superseded by a newer
    /// test of it) is `.stale` and leaves the status alone.
    @discardableResult
    func testConnection(provider: AIProvider) async -> ProviderCheckResult {
        var configuration = settings.configuration(for: provider)
        if provider != .vertexAI { configuration.model = "" }
        return await runConnectionTest(configuration: configuration, provider: provider)
    }

    /// Tests the provider and model a role uses. Stale also when the role's
    /// selection changed meanwhile.
    @discardableResult
    func testConnection(for role: ModelRole = .assistant) async -> ProviderCheckResult {
        let selection = settings.model(for: role)
        let configuration = settings.configuration(for: role)
        return await runConnectionTest(
            configuration: configuration,
            provider: selection.provider,
            role: (role, selection),
            isStillCurrent: { settings.model(for: role) == selection }
        )
    }

    func isTestingConnection(for provider: AIProvider) -> Bool {
        guard let active = activeConnectionTestGeneration[provider] else { return false }
        return active == connectionTestGeneration[provider]
    }

    func isTestingConnection(for role: ModelRole) -> Bool {
        guard let active = activeRoleConnectionTests[role] else { return false }
        return active.selection == settings.model(for: role) && isTestingConnection(for: active.provider)
    }

    private func runConnectionTest(
        configuration: ProviderConfiguration,
        provider: AIProvider,
        role: (ModelRole, ModelSelection)? = nil,
        isStillCurrent: () -> Bool = { true }
    ) async -> ProviderCheckResult {
        connectionTestGeneration[provider, default: 0] &+= 1
        let generation = connectionTestGeneration[provider, default: 0]
        if case .declined = aiConsentState(for: provider) {
            if !settings.hasCompletedOnboarding {
                settings.aiConsent.removeValue(forKey: provider.rawValue)
            } else {
                settingsStatus = String(localized: "Connection failed")
                return .failure(AssistantError.aiConsentDeclined(provider).localizedDescription)
            }
        }
        activeConnectionTestGeneration[provider] = generation
        if let (targetRole, selection) = role {
            activeRoleConnectionTests[targetRole] = (provider, generation, selection)
        }
        defer {
            if activeConnectionTestGeneration[provider] == generation {
                activeConnectionTestGeneration[provider] = nil
            }
            if let (targetRole, _) = role, activeRoleConnectionTests[targetRole]?.generation == generation {
                activeRoleConnectionTests[targetRole] = nil
            }
        }
        settingsStatus = String(localized: "Testing connection…")
        do {
            try await aiService.testConnection(configuration: configuration, provider: provider)
            guard generation == connectionTestGeneration[provider], isStillCurrent() else { return .stale }
            settingsStatus = String(localized: "Connection successful")
            return .success
        } catch {
            guard generation == connectionTestGeneration[provider], isStillCurrent() else { return .stale }
            settingsStatus = String(localized: "Connection failed")
            return .failure(error.localizedDescription)
        }
    }

    func configurationBinding(for provider: AIProvider) -> ProviderConfiguration {
        settings.configuration(for: provider)
    }

    func setConfiguration(_ configuration: ProviderConfiguration, for provider: AIProvider) {
        settings.setConfiguration(configuration, for: provider)
    }

    #if DEBUG
    /// The forum the UI-test seeds belong to.
    private static let uiTestSiteURL = "https://meta.discourse.org"
    private static let uiTestForumName = "Discourse Meta"

    private func seedUITestSession() {
        guard let url = URL(
            string: "https://meta.discourse.org/t/ui-test-topic/999999"
        ) else {
            return
        }
        let topic = ForumTopic(
            siteURL: Self.uiTestSiteURL,
            topicID: "999999",
            url: url,
            title: "Responsive UI test topic"
        )
        var session = TopicSession(
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            url: topic.url,
            title: topic.title
        )
        session.seedSource("Sample forum source for UI verification.")
        session.summary = """
        # Card Strategy

        The discussion recommends **comparing annual fees** before applying.

        ## Key points

        - Review the welcome offer.
        - Confirm the spending requirement.

        > Keep screenshots of the offer terms.

        | Option | Reward |
        | --- | --- |
        | Sample card | 4x points |

        ```text
        Verify before applying
        ```
        """
        session.history = [
            ChatMessage(role: .user, content: "What is the main recommendation?"),
            ChatMessage(
                role: .assistant,
                content: "Compare the **full offer terms** before applying."
            )
        ]
        session.totalPosts = 12
        session.summaryPostCount = 12
        session.summaryUpdatedAt = Date()
        session.chatUpdatedAt = Date()
        currentTopic = topic
        seededPageContext = PageContext(
            url: topic.url,
            site: .discourse,
            siteURL: topic.siteURL,
            forumName: Self.uiTestForumName,
            topic: topic,
            state: .topic
        )
        sessions[topic.topicKey] = session
    }

    /// Replaces the in-memory data with a DEBUG seed (screenshots; see
    /// AppModel+Assistant.swift). Nothing is saved unless the user acts.
    func applyDebugSeed(_ seed: AssistantDebugSeed) {
        forums = seed.forums
        sessions = Dictionary(
            seed.sessions.map { ($0.topicKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        activities = seed.activities
        agentRuns = seed.agentRuns
        watchedTopics = seed.watchedTopics
        currentTopic = seed.currentTopic
        currentSiteURL = seed.currentForum?.siteURL
        seededPageContext = seed.pageContext
        selectedAgentRunID = seed.agentRuns.first?.id
        // No automatic watch check (network, summary refresh) for the seed.
        lastWatchCheck = Date()
    }

    /// Advances a seeded running record (DEBUG sample only), the way a real
    /// job would: progress moves forward only.
    func debugAdvanceSample(recordID: UUID, progress: Double, statusText: String? = nil) {
        guard let current = activities.first(where: { $0.id == recordID }),
              current.status == .running
        else { return }
        self.progress.advance(recordID, to: progress)
        if let statusText, statusText != current.statusText {
            mutateRecord(recordID) { $0.statusText = statusText }
        }
    }

    private func seedUITestManageSession() {
        guard let deleteURL = URL(
            string: "https://meta.discourse.org/t/ui-test-delete/999997"
        ),
        let keepURL = URL(
            string: "https://meta.discourse.org/t/ui-test-keep/999998"
        ) else {
            return
        }

        let now = Date()
        var deleteSession = TopicSession(
            siteURL: Self.uiTestSiteURL,
            topicID: "999997",
            url: deleteURL,
            title: "Swipe test delete summary"
        )
        deleteSession.summary = "# Summary\n\nDelete this saved summary."
        deleteSession.totalPosts = 1
        deleteSession.summaryPostCount = 1
        deleteSession.summaryUpdatedAt = now

        var keepSession = TopicSession(
            siteURL: Self.uiTestSiteURL,
            topicID: "999998",
            url: keepURL,
            title: "Swipe test keep summary"
        )
        keepSession.summary = "# Summary\n\nKeep this saved summary."
        keepSession.totalPosts = 1
        keepSession.summaryPostCount = 1
        keepSession.summaryUpdatedAt = now

        var recent = WorkRecord(
            type: .summary,
            siteURL: Self.uiTestSiteURL,
            topicID: "999997",
            title: "Swipe test recent activity",
            url: deleteURL,
            provider: .openAI,
            model: "test-model"
        )
        recent.status = .completed
        recent.statusText = "Completed"
        recent.completedAt = now

        sessions = [
            deleteSession.topicKey: deleteSession,
            keepSession.topicKey: keepSession
        ]
        activities = [recent]
        currentTopic = nil
    }
    #endif

    private func launch(recordID: UUID) {
        guard runningTasks[recordID] == nil else { return }
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.jobEnded(recordID: recordID, token: token) }
            guard let record = self.activities.first(where: { $0.id == recordID }) else {
                return
            }
            guard await self.limiter.acquire(
                topicID: record.topicKey,
                workID: record.id
            ) else {
                return
            }
            defer {
                Task { await self.limiter.release(workID: record.id) }
            }
            guard !Task.isCancelled else { return }
            await self.run(recordID: recordID, token: token)
        }
        runningTasks[recordID] = (token, task)
    }

    /// The task `token` launched is still the record's: not cancelled or
    /// paused (and maybe launched again since).
    private func isCurrentLaunch(_ recordID: UUID, token: UUID) -> Bool {
        runningTasks[recordID]?.token == token
    }

    /// A job's task is done (finished, failed, cancelled or paused).
    private func jobEnded(recordID: UUID, token: UUID) {
        // A paused job launched again has a new task: leave that one.
        if isCurrentLaunch(recordID, token: token) { runningTasks.removeValue(forKey: recordID) }
        // Nothing runs any more (finished or paused): the grace period is
        // not needed.
        if backgroundWork != nil, runningTasks.isEmpty { endBackgroundWork() }
    }

    // MARK: Background

    /// The app left the foreground: running work goes on for the grace
    /// period the system gives, then pauses (`pauseActiveWork`).
    private func workEnteredBackground() {
        guard !runningTasks.isEmpty, backgroundWork == nil else { return }
        let id = backgroundGrace.begin(name: "Forumind work") { [weak self] in
            // On the main thread; the task must end before the handler returns.
            MainActor.assumeIsolated {
                self?.pauseActiveWork()
                self?.endBackgroundWork()
            }
        }
        if id == .invalid {
            pauseActiveWork()
        } else {
            backgroundWork = id
        }
    }

    /// Back in the foreground: paused work starts again.
    private func workEnteredForeground() {
        endBackgroundWork()
        // At launch, `restorePendingTasksIfNeeded` (once the UI is up) does it.
        guard didRestoreTasks else { return }
        for record in activities where record.status == .queued && runningTasks[record.id] == nil {
            mutateRecord(record.id) { $0.statusText = WorkRecord.waitingStatusText }
            launch(recordID: record.id)
        }
    }

    private func endBackgroundWork() {
        guard let id = backgroundWork else { return }
        backgroundWork = nil
        backgroundGrace.end(id)
    }

    /// Puts every queued or running job back in the queue, as a relaunch
    /// would (the pages it read are kept): the grace period ended, or a
    /// job's request failed because the app is in the background. On disk
    /// before the app is suspended.
    func pauseActiveWork() {
        for record in activities where !record.status.isTerminal {
            pause(recordID: record.id)
        }
        save()
        store.flush()
    }

    /// The developer's list changed (a daily refresh). Output made under
    /// the old rules is dropped by each job's rules guard; the work the user
    /// asked for then runs again under the new rules instead of ending as
    /// cancelled. A block the user makes cancels instead (`block`), and Ask
    /// the forum runs still stop: they keep earlier observations, which a
    /// list without block dates cannot recheck.
    func remoteModerationDidChange() {
        let old = browser.moderationRules
        applyModerationRules()
        guard browser.moderationRules != old else { return }
        for record in activities where !record.status.isTerminal {
            // A resumed Ask the forum run would replay what it read to its
            // planner, and the list has no block date to filter that by: its
            // turn starts again from scratch (a paused one when it resumes).
            if record.type == .agent { mutateAgentRun(for: record) { $0.restartTurn() } }
            guard runningTasks[record.id] != nil else { continue }
            pause(recordID: record.id)
            mutateRecord(record.id) { $0.statusText = WorkRecord.waitingStatusText }
            launch(recordID: record.id)
        }
        if digestTask != nil {
            pauseDigest()
            makeTodaysDigest()
        }
        podcast.restartGeneration()
    }

    private func pause(recordID: UUID) {
        runningTasks[recordID]?.task.cancel()
        runningTasks.removeValue(forKey: recordID)
        summaryFeeds.removeValue(forKey: recordID)?.cancel()
        streams.remove(recordID)
        progress.remove(recordID)
        Task { await limiter.cancel(workID: recordID) }
        mutateRecord(recordID) {
            $0.status = .queued
            $0.statusText = String(localized: "Paused until Forumind is open again", comment: "Status of AI work stopped because the app went to the background; it continues when the app is opened")
        }
    }

    /// The settings a job runs with, taken when it starts (not when it was
    /// queued): the provider, model and key selected at that moment, and the
    /// limits and instructions then. Edits made while it runs apply to the
    /// next job. Agent step and topic budgets can still be lowered mid-run.
    ///
    /// Ask the forum runs with the agent model, everything else with the
    /// assistant model; the agent's `summarize_topic` tool also uses the
    /// assistant model (`summarizer`).
    private func runSettings(for record: WorkRecord) -> RunSettings {
        runSettings(
            role: record.type == .agent ? .agent : .assistant,
            topicKey: record.topicKey,
            batchLimit: record.batchLimit
        )
    }

    /// The same snapshot for work outside the queue (the daily digest).
    func runSettings(role: ModelRole, topicKey: String, batchLimit: Int? = nil) -> RunSettings {
        let resolved = { (role: ModelRole) -> RunSettings.Model in
            let provider = self.settings.model(for: role).provider
            return RunSettings.Model(
                provider: provider,
                configuration: RunSettings.resolvingAppleIntelligence(
                    self.settings.configuration(for: role),
                    provider: provider,
                    status: self.appleIntelligenceStatus
                )
            )
        }
        let main = resolved(role)
        return RunSettings(
            provider: main.provider,
            configuration: main.configuration,
            summarizer: role == .assistant ? main : resolved(.assistant),
            batchLimit: batchLimit ?? settings.summaryBatchLimit,
            contextLimit: settings.forumContextLimit,
            topicInstructions: effectiveInstructions(for: topicKey),
            globalInstructions: settings.systemPrompt,
            agentMaxSteps: settings.agentMaxSteps,
            agentMaxTopicReads: settings.agentMaxTopicReads,
            agentReadLimit: settings.agentReadLimit,
            forumRequestPace: settings.forumRequestPace
        )
    }

    /// The job is still wanted: not cancelled, and its record was not
    /// cancelled or deleted (cancel, clear data, remove forum) meanwhile.
    private func isLive(_ recordID: UUID) -> Bool {
        !Task.isCancelled && activities.first(where: { $0.id == recordID })?.status == .running
    }

    /// Call after every await, before writing results back.
    private func ensureLive(_ recordID: UUID) throws {
        guard isLive(recordID) else { throw CancellationError() }
    }

    /// Runs a job. `token`: its launch; a task of a paused job still
    /// unwinding must not touch the record a newer launch is running.
    private func run(recordID: UUID, token: UUID) async {
        guard var record = activities.first(where: { $0.id == recordID }),
              record.status == .queued
        else {
            return
        }
        let context = runSettings(for: record)
        // Recorded so Manage and the saved summary show what actually ran.
        record.provider = context.provider
        record.model = context.configuration.model
        // A restored record starts over; progress then only moves forward.
        progress.remove(recordID)
        mutateRecord(recordID) {
            $0.status = .running
            $0.statusText = String(localized: "Reading forum responses…", comment: "Status while downloading a topic's replies")
            $0.startedAt = Date()
            $0.provider = context.provider
            $0.model = context.configuration.model
        }
        if record.type == .agent {
            // The run keeps the provider of its first answer; each turn's
            // record (Manage) shows what that turn used.
            mutateAgentRun(for: record) {
                guard $0.followUps.isEmpty else { return }
                $0.provider = context.provider
                $0.model = context.configuration.model
            }
        }
        save()

        do {
            if record.type != .pull {
                try context.requireReadyProvider()
                // Work the user started waits for the consent page; work the
                // app started by itself never shows it.
                try await authorizeSending(
                    to: context.provider,
                    baseURL: context.configuration.baseURL,
                    mayAsk: record.origin == .user
                ) {
                    mutateRecord(recordID) {
                        $0.statusText = String(localized: "Waiting for your OK to send forum content to \(context.provider.displayName)…", comment: "Status of AI work while the AI data consent page is up; the placeholder is an AI provider's name")
                    }
                }
                try ensureLive(recordID)
            }
            switch record.type {
            case .summary:
                try await runSummary(recordID: recordID, record: record, context: context)
            case .pull:
                try await runPull(recordID: recordID, record: record, context: context)
            case .chat:
                try await runChat(recordID: recordID, record: record, context: context)
            case .agent:
                try await runAgent(recordID: recordID, record: record, context: context)
            }
            // Finished after it was cancelled (a provider that ignores
            // cancellation): it stays cancelled.
            try ensureLive(recordID)
            let completedAt = Date()
            mutateRecord(recordID) {
                $0.status = .completed
                $0.statusText = String(localized: "Completed", comment: "Status of finished AI work")
                $0.completedAt = completedAt
            }
            if record.type == .agent,
               isAIViewShown,
               assistantMode == .agent,
               panelRoute == .topic,
               !agentComposesNewQuestion,
               agentRunID(for: record) == selectedAgentRunID {
                router.answersSeenAt = max(router.answersSeenAt, completedAt)
            }
        } catch is CancellationError {
            // A paused job is back in the queue (or already running again):
            // it stays there. `cancel(record:)` wrote its own status.
            if isCurrentLaunch(recordID, token: token),
               activities.first(where: { $0.id == recordID })?.status == .running {
                mutateRecord(recordID) {
                    $0.status = .cancelled
                    $0.statusText = String(localized: "Cancelled", comment: "Status of AI work the user cancelled")
                    $0.completedAt = Date()
                }
                if record.type == .agent {
                    mutateAgentRun(for: record) {
                        $0.result = .cancelled
                        $0.completedAt = Date()
                    }
                }
            }
        } catch where backgroundWork != nil && isLive(recordID) && NetworkFailure.isUnreachable(error) {
            // The system cut the connection in the background: it waits for
            // the app to come back instead of failing.
            pause(recordID: recordID)
        } catch where !isLive(recordID) {
            // Cancelled or deleted meanwhile; its request failing is expected.
            if isCurrentLaunch(recordID, token: token),
               activities.first(where: { $0.id == recordID })?.status == .running {
                mutateRecord(recordID) {
                    $0.status = .cancelled
                    $0.statusText = String(localized: "Cancelled", comment: "Status of AI work the user cancelled")
                    $0.completedAt = Date()
                }
                if record.type == .agent {
                    mutateAgentRun(for: record) {
                        $0.result = .cancelled
                        $0.completedAt = Date()
                    }
                }
            }
        } catch {
            mutateRecord(recordID) {
                $0.status = .failed
                $0.statusText = String(localized: "Failed", comment: "Status of AI work that failed")
                $0.error = error.localizedDescription
                $0.completedAt = Date()
            }
            if record.type == .agent {
                mutateAgentRun(for: record) {
                    $0.result = .failed
                    $0.error = error.localizedDescription
                    $0.completedAt = Date()
                }
            }
            // Work the app started by itself shows its failure in Activity;
            // a consent block shows in place (the not-ready card).
            if record.origin == .user, !error.isAIConsentError { presentError(error.localizedDescription) }
        }
        if isCurrentLaunch(recordID, token: token) {
            streams.remove(recordID)
            progress.remove(recordID)
        }
        activities = Array(
            activities
                .filter {
                    !$0.status.isTerminal
                        || Date().timeIntervalSince($0.completedAt ?? $0.updatedAt)
                            < 24 * 60 * 60
                }
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(100)
        )
        pruneSessions()
        save()
    }

    private func runPull(recordID: UUID, record: WorkRecord, context: RunSettings) async throws {
        guard let adapter = adapter(for: record.siteURL) else { throw AssistantError.noForum }
        var session = sessions[record.topicKey] ?? TopicSession(
            siteURL: record.siteURL,
            topicID: record.topicID,
            url: record.url,
            title: record.title
        )
        let fetch = try await fetchTopicPages(of: session, adapter: adapter, recordID: recordID, pace: context.forumRequestPace) { progress in
            await self.updateFetchProgress(recordID: recordID, progress: progress)
        }

        // Cancelled (or its forum's data deleted) while the page fetch was
        // finishing: do not write the session back.
        try ensureLive(recordID)
        session = sessions[record.topicKey] ?? session
        let now = Date()
        session.apply(fetch, at: now)
        session.updatedAt = now
        sessions[record.topicKey] = session
        save()
        progress.advance(recordID, to: 1)
    }

    /// Keeps a topic's freshly read pages in its existing session (the
    /// daily digest); a topic without one gets none.
    func storeFetchedPages(_ fetch: ForumFetchResult, topicKey: String) {
        guard var session = sessions[topicKey] else { return }
        session.apply(fetch, at: Date())
        sessions[topicKey] = session
        save()
    }

    private func runSummary(recordID: UUID, record: WorkRecord, context: RunSettings) async throws {
        #if DEBUG
        if AssistantDebug.has("-dc-fake-summary") {
            // `-dc-fake-summary-fails`: fails until Retry (`regenerate`).
            if AssistantDebug.has("-dc-fake-summary-fails"), record.regenerate != true {
                throw AssistantError.missingConfiguration("The sample summary failed on purpose.")
            }
            try await runFakeSummary(recordID: recordID, record: record)
            return
        }
        #endif
        guard let adapter = adapter(for: record.siteURL) else { throw AssistantError.noForum }
        var session = sessions[record.topicKey] ?? TopicSession(
            siteURL: record.siteURL,
            topicID: record.topicID,
            url: record.url,
            title: record.title
        )
        let tracker = SummaryProgressTracker(
            cachedPages: session.rawPages.count,
            inputCharacters: session.source.count,
            previousSummaryCharacters: session.hasSummary ? session.summary.count : nil
        )
        let feed = startSummaryFeed(recordID: recordID, tracker: tracker)
        defer { stopSummaryFeed(recordID, feed) }
        let fetch = try await fetchTopicPages(of: session, adapter: adapter, recordID: recordID, pace: context.forumRequestPace) { progress in
            await self.updateFetchProgress(recordID: recordID, progress: progress)
        }

        // Cancelled (or its forum's data deleted) while the page fetch was
        // finishing: do not write the session back.
        try ensureLive(recordID)
        session = sessions[record.topicKey] ?? session
        let now = Date()
        session.apply(fetch, at: now)
        session.updatedAt = now
        sessions[record.topicKey] = session
        save()

        if fetch.unchanged,
           record.regenerate != true,
           canUseSummaryAsContext(session),
           session.summaryPostCount == fetch.totalPosts {
            mutateRecord(recordID) {
                $0.statusText = String(localized: "Saved summary already includes every reply.")
            }
            feed.finish()
            return
        }

        mutateRecord(recordID) {
            $0.statusText = fetch.newPosts > 0 && session.hasSummary
                ? String(localized: "Updating summary with \(fetch.newPosts) new posts…", comment: "Status while a saved summary is updated with the topic's new replies")
                : String(localized: "Generating summary…")
        }
        let rules = browser.moderationRules
        let content = moderated(fetch.content, siteURL: session.siteURL, topicID: session.topicID)
        feed.setInputCharacters(content.count)
        streams.start(recordID)
        let summary = try await aiService.generateSummary(
            content: content,
            configuration: context.configuration,
            provider: context.provider,
            customPrompt: context.topicInstructions,
            discussion: adapter.discussion,
            batchLimit: context.batchLimit,
            onDelta: { delta in
                // Deltas of a cancelled job must not recreate its stream.
                guard self.isLive(recordID) else { return }
                self.streams.append(delta, to: recordID)
            },
            onProgress: { feed.handle($0) }
        )

        try ensureLive(recordID)
        guard rules == browser.moderationRules else { throw CancellationError() }
        feed.finish()
        session = sessions[record.topicKey] ?? session
        session.summary = summary
        session.summaryPostCount = fetch.totalPosts
        session.provider = context.provider
        session.model = context.configuration.model
        let finishedAt = Date()
        session.summaryUpdatedAt = finishedAt
        session.updatedAt = finishedAt
        sessions[record.topicKey] = session
    }

    #if DEBUG
    /// `-dc-fake-summary`: a summary run that reads nothing and calls no AI.
    /// It streams the sample summary (with `#N` citations) one section at a
    /// time, then saves it as the open topic's summary.
    private func runFakeSummary(recordID: UUID, record: WorkRecord) async throws {
        let text = SampleContent.current.tipsSummary
        let sections = text.components(separatedBy: "\n\n## ")
        streams.start(recordID)
        try await Task.sleep(for: .seconds(1.2))
        for (index, section) in sections.enumerated() {
            guard activities.contains(where: { $0.id == recordID && !$0.status.isTerminal }) else { return }
            streams.append(index == 0 ? section : "\n\n## " + section, to: recordID)
            try await Task.sleep(for: .milliseconds(500))
        }
        var session = sessions[record.topicKey] ?? TopicSession(
            siteURL: record.siteURL, topicID: record.topicID, url: record.url, title: record.title
        )
        if session.source.isEmpty { session.seedSource("Sample post and replies for \(record.title).") }
        session.summary = text
        session.totalPosts = max(session.totalPosts ?? 0, 68)
        session.summaryPostCount = session.totalPosts
        session.provider = record.provider
        session.model = record.model
        session.summaryUpdatedAt = Date()
        session.updatedAt = Date()
        sessions[record.topicKey] = session
    }
    #endif

    private func runChat(recordID: UUID, record: WorkRecord, context: RunSettings) async throws {
        guard let adapter = adapter(for: record.siteURL) else { throw AssistantError.noForum }
        var session = sessions[record.topicKey] ?? TopicSession(
            siteURL: record.siteURL,
            topicID: record.topicID,
            url: record.url,
            title: record.title
        )

        let fetch = try await fetchTopicPages(of: session, adapter: adapter, recordID: recordID, pace: context.forumRequestPace) { progress in
            await self.updateFetchProgress(recordID: recordID, progress: progress)
        }
        // Cancelled (or its forum's data deleted) while the page fetch was
        // finishing: do not write the session back.
        try ensureLive(recordID)
        session = sessions[record.topicKey] ?? session
        let now = Date()
        session.apply(fetch, at: now)
        session.updatedAt = now
        sessions[record.topicKey] = session

        mutateRecord(recordID) {
            $0.statusText = String(localized: "Answering follow-up question…")
        }
        // How long an answer takes is unknowable: indeterminate until done.
        progress.advance(recordID, to: nil)
        // Cleared or edited while the topic was being read: nothing to ask.
        guard session.history.last(where: { $0.role == .user })?.content == record.question else {
            mutateRecord(recordID) { $0.statusText = String(localized: "Chat changed; answer discarded", comment: "Chat status: the conversation was edited while an answer was being written") }
            return
        }
        streams.start(recordID)
        let useSummary = canUseSummaryAsContext(session)
        let rules = browser.moderationRules
        let blockedAt = latestBlockDate(on: session.siteURL)
        let answer = try await aiService.answer(
            source: moderated(session.source, siteURL: session.siteURL, topicID: session.topicID),
            summary: useSummary ? session.summary : "",
            history: session.history.filter { message in
                message.role != .assistant || blockedAt.map { message.createdAt > $0 } ?? true
            },
            contextLimit: context.contextLimit,
            customPrompt: context.topicInstructions,
            discussion: adapter.discussion,
            configuration: context.configuration,
            provider: context.provider,
            onDelta: { delta in
                guard self.isLive(recordID) else { return }
                self.streams.append(delta, to: recordID)
            },
            summaryIsStale: useSummary && session.hasStaleSummary
        )

        try ensureLive(recordID)
        guard rules == browser.moderationRules else { throw CancellationError() }
        session = sessions[record.topicKey] ?? session
        // The chat was cleared, or the question edited, while it was being
        // answered: the answer no longer belongs to the conversation.
        guard session.history.last(where: { $0.role == .user })?.content == record.question else {
            mutateRecord(recordID) { $0.statusText = String(localized: "Chat changed; answer discarded", comment: "Chat status: the conversation was edited while an answer was being written") }
            return
        }
        session.history.append(ChatMessage(role: .assistant, content: answer))
        session.history = Array(session.history.suffix(100))
        session.chatUpdatedAt = Date()
        session.updatedAt = Date()
        sessions[record.topicKey] = session
    }

    // MARK: Agent runner

    func agentRunID(for record: WorkRecord) -> UUID? {
        guard record.topicID.hasPrefix(Self.agentTopicPrefix) else { return nil }
        return UUID(uuidString: String(record.topicID.dropFirst(Self.agentTopicPrefix.count)))
    }

    private func mutateAgentRun(for record: WorkRecord, mutation: (inout AgentRun) -> Void) {
        guard let id = agentRunID(for: record),
              let index = agentRuns.firstIndex(where: { $0.id == id })
        else {
            return
        }
        mutation(&agentRuns[index])
        agentRuns[index].updatedAt = Date()
    }

    private func runAgent(recordID: UUID, record: WorkRecord, context: RunSettings) async throws {
        guard let runID = agentRunID(for: record),
              var run = agentRuns.first(where: { $0.id == runID })
        else {
            throw AgentError.runNotFound
        }
        guard let adapter = adapter(for: run.siteURL) else { throw AssistantError.noForum }
        let profile = adapter.agent
        run.result = nil
        run.error = ""
        storeAgentRun(run)
        mutateRecord(recordID) {
            $0.statusText = String(localized: "Planning…", comment: "Ask the forum: the AI is deciding its first step")
        }
        let isFollowUp = !run.followUps.isEmpty && run.followUps.last?.role == .user
        var stepsUsed: Int
        if isFollowUp {
            if let followUpIndex = run.transcript.lastIndex(where: AgentPrompt.isFollowUp) {
                stepsUsed = run.transcript[(followUpIndex + 1)...].filter { $0.role == .assistant }.count
            } else {
                stepsUsed = 0
            }
        } else {
            stepsUsed = run.steps.count
        }
        progress.advance(recordID, to: WorkProgress.agent(completedSteps: stepsUsed, maxSteps: context.agentMaxSteps))

        let configuration = context.configuration
        let forumName = forum(for: run.siteURL)?.displayName
            ?? ForumSite.displayName(siteURL: run.siteURL, name: nil)
        let system = AgentPrompt.system(
            profile: profile,
            forumName: forumName,
            siteURL: run.siteURL,
            maxSteps: context.agentMaxSteps,
            maxTopicReads: context.agentMaxTopicReads,
            customInstructions: context.globalInstructions
        )

        while true {
            try ensureLive(recordID)
            // Budgets are spending caps: lowering one in Settings mid-run
            // takes effect at the next step (the run then answers with what
            // it has); raising one only affects later runs.
            let maxSteps = min(context.agentMaxSteps, settings.agentMaxSteps)
            let outOfBudget = stepsUsed >= maxSteps
            if outOfBudget {
                run.transcript.append(AgentPrompt.outOfBudgetMessage())
            }
            let rules = browser.moderationRules
            let blockedAt = latestBlockDate(on: run.siteURL)
            let action = try await planner.nextAction(
                system: system,
                transcript: run.transcript.filter { message in
                    guard let blockedAt, message.createdAt <= blockedAt else { return true }
                    return message.role == .user
                        && !message.content.hasPrefix("OBSERVATION from ")
                        && !message.content.hasPrefix("ERROR from ")
                },
                configuration: configuration,
                provider: context.provider
            )
            try ensureLive(recordID)
            guard rules == browser.moderationRules else { throw CancellationError() }
            stepsUsed += 1
            run.transcript.append(ChatMessage(role: .assistant, content: Self.encode(action)))
            var step = AgentStep(tool: action.tool, arguments: action.arguments, thought: action.thought)
            mutateRecord(recordID) {
                $0.statusText = String(localized: "Step \(stepsUsed): \(Self.describe(action))", comment: "Ask the forum progress: step number, then the tool being used (a technical name such as search_forum) and its argument")
            }
            progress.advance(
                recordID,
                to: WorkProgress.agent(completedSteps: stepsUsed - 1, maxSteps: maxSteps, within: 0.1)
            )

            if action.tool == AgentPrompt.finalAnswerTool || outOfBudget {
                let answer = action.arguments["answer"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? action.thought
                step.outcome = action.tool == AgentPrompt.finalAnswerTool
                    ? String(localized: "Answered", comment: "Ask the forum step outcome: the final answer was written")
                    : String(localized: "Stopped at the step budget", comment: "Ask the forum step outcome: the run used all its allowed steps")
                step.finishedAt = Date()
                run.steps.append(step)
                run.answer = answer
                if isFollowUp {
                    run.followUps.append(ChatMessage(role: .assistant, content: answer))
                } else {
                    run.initialAnswer = answer
                }
                run.result = .completed
                run.completedAt = Date()
                storeAgentRun(run)
                save()
                return
            }

            let completedSteps = stepsUsed - 1
            do {
                let (outcome, observation) = try await executeAgentTool(
                    action,
                    adapter: adapter,
                    run: &run,
                    recordID: recordID,
                    context: context,
                    stepProgress: { within in
                        WorkProgress.agent(completedSteps: completedSteps, maxSteps: maxSteps, within: within)
                    }
                )
                guard rules == browser.moderationRules else { throw CancellationError() }
                step.outcome = outcome
                step.topicID = action.arguments["topic_id"]
                if let topicID = try? requiredTopicID(action) {
                    step.topicID = topicID
                    step.topicKey = ForumSite.topicKey(siteURL: run.siteURL, topicID: topicID)
                }
                run.transcript.append(
                    AgentPrompt.observation(tool: action.tool, result: observation, isError: false)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch where !isLive(recordID) {
                throw CancellationError()
            } catch {
                step.isError = true
                step.outcome = error.localizedDescription
                run.transcript.append(
                    AgentPrompt.observation(
                        tool: action.tool,
                        result: (error as? AgentError)?.modelDescription ?? error.localizedDescription,
                        isError: true
                    )
                )
            }
            try ensureLive(recordID)
            step.finishedAt = Date()
            run.steps.append(step)
            storeAgentRun(run)
            progress.advance(recordID, to: WorkProgress.agent(completedSteps: stepsUsed, maxSteps: maxSteps))
            save()
        }
    }

    private func storeAgentRun(_ run: AgentRun) {
        var updated = run
        updated.updatedAt = Date()
        // Runs are inserted when started; one that is gone was deleted (e.g.
        // with its forum) while its task was finishing, so it stays deleted.
        guard let index = agentRuns.firstIndex(where: { $0.id == run.id }) else { return }
        agentRuns[index] = updated
    }

    private static func encode(_ action: AgentAction) -> String {
        let object: [String: Any] = [
            "thought": action.thought,
            "tool": action.tool,
            "arguments": action.arguments
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"tool\": \"\(action.tool)\"}"
    }

    private static func describe(_ action: AgentAction) -> String {
        let detail = action.arguments["query"] ?? action.arguments["topic_id"] ?? ""
        return detail.isEmpty ? action.tool : "\(action.tool) \(detail)"
    }

    /// Runs one tool. Returns a short outcome for the step log and the full
    /// observation handed back to the model.
    private func executeAgentTool(
        _ action: AgentAction,
        adapter: any SiteAdapter,
        run: inout AgentRun,
        recordID: UUID,
        context: RunSettings,
        stepProgress: @escaping @Sendable (_ within: Double) -> Double
    ) async throws -> (String, String) {
        let siteURL = run.siteURL
        let profile = adapter.agent
        // Only the run's own tools exist for the model, whatever the app knows.
        let available = AgentPrompt.tools(for: profile).map(\.name)
        guard let tool = AgentToolName(rawValue: action.tool), available.contains(action.tool) else {
            throw AgentError.unknownTool(action.tool, available: available)
        }

        switch tool {
        case .searchForum, .searchComments:
            let results = try await runSiteQuery(tool, action, adapter: adapter, siteURL: siteURL, pace: context.forumRequestPace)
            run.remember(results.topics.map { ($0.url, $0.topicID) } + results.hits.map { ($0.url, $0.topic.topicID) }, links: adapter.links)
            return (
                String(localized: "\(results.topics.count) topics", comment: "Ask the forum step outcome: number of topics found"),
                AgentPrompt.format(listings: results.topics, hits: results.hits)
            )

        case .listLatest:
            let listings = try await runSiteQuery(tool, action, adapter: adapter, siteURL: siteURL, pace: context.forumRequestPace).topics
            run.remember(listings.map { ($0.url, $0.topicID) }, links: adapter.links)
            return (String(localized: "\(listings.count) topics", comment: "Ask the forum step outcome: number of topics found"), AgentPrompt.format(listings: listings, limit: 30))

        case .readTopic:
            let session = try await readTopicForAgent(
                action, adapter: adapter, run: &run, recordID: recordID, context: context,
                progress: { stepProgress(0.1 + 0.8 * $0) }
            )
            run.remember([(session.url, session.topicID)], links: adapter.links)
            return try await formatAgentTopicRead(
                action, session: session, adapter: adapter, profile: profile, context: context
            )

        case .summarizeTopic:
            // Bulk summarizing runs on the assistant (low-cost) model. When
            // that one isn't ready, the tool fails and the agent can read the
            // topic instead.
            let summarizer = context.summarizer
            try RunSettings.requireReady(provider: summarizer.provider, configuration: summarizer.configuration)
            try await authorizeSending(
                to: summarizer.provider,
                baseURL: summarizer.configuration.baseURL,
                mayAsk: activities.first(where: { $0.id == recordID })?.origin == .user
            )
            try ensureLive(recordID)
            var session = try await readTopicForAgent(
                action, adapter: adapter, run: &run, recordID: recordID, context: context,
                progress: { stepProgress(0.1 + 0.3 * $0) }
            )
            mutateRecord(recordID) {
                $0.statusText = String(localized: "Summarizing \(session.title)…", comment: "Status; the placeholder is a forum topic's title")
            }
            let rules = browser.moderationRules
            let content = moderated(session.source, siteURL: session.siteURL, topicID: session.topicID)
            let tracker = SummaryProgressTracker(
                inputCharacters: content.count,
                previousSummaryCharacters: session.hasSummary ? session.summary.count : nil
            )
            let feed = startSummaryFeed(recordID: recordID, tracker: tracker, keepsStatusText: true) { stepProgress(0.4 + 0.55 * $0) }
            defer { stopSummaryFeed(recordID, feed) }
            let summary = try await aiService.generateSummary(
                content: content,
                configuration: summarizer.configuration,
                provider: summarizer.provider,
                customPrompt: PromptBuilder.effectiveInstructions(
                    topic: session.instructions,
                    global: context.globalInstructions
                ),
                discussion: adapter.discussion,
                batchLimit: context.batchLimit,
                onDelta: { _ in },
                onProgress: { feed.handle($0) }
            )
            try ensureLive(recordID)
            guard rules == browser.moderationRules else { throw CancellationError() }
            try settings.requireAIConsent(for: summarizer.provider, baseURL: summarizer.configuration.baseURL)
            feed.finish()
            session = sessions[session.topicKey] ?? session
            session.summary = summary
            session.summaryPostCount = session.totalPosts
            session.provider = summarizer.provider
            session.model = summarizer.configuration.model
            let finishedAt = Date()
            session.summaryUpdatedAt = finishedAt
            session.updatedAt = finishedAt
            sessions[session.topicKey] = session
            return (
                String(localized: "Summarized \(session.totalPosts ?? 0) posts", comment: "Ask the forum step outcome: number of posts summarized in a topic"),
                "Summary of \(moderatedTopicTitle(session.title, siteURL: session.siteURL, topicID: session.topicID)) (\(session.url.absoluteString)):\n\n\(summary)"
            )

        case .savedSummaries:
            let query = action.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let saved = sessions.values
                .filter { $0.siteURL == siteURL && canUseSummaryAsContext($0) }
                .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.summary.localizedCaseInsensitiveContains(query) }
                .sorted { $0.updatedAt > $1.updatedAt }
            guard !saved.isEmpty else { return (String(localized: "None found", comment: "Ask the forum step outcome: no saved summaries matched"), "No saved summaries match.") }
            let text = saved.prefix(query.isEmpty ? 40 : 6).map { session in
                let title = moderatedTopicTitle(session.title, siteURL: session.siteURL, topicID: session.topicID)
                var line = "- id \(session.topicID): \(title) — "
                    + "\(session.summaryPostCount ?? session.totalPosts ?? 0) posts — "
                    + session.url.absoluteString
                if !query.isEmpty { line += "\n\(session.summary.prefix(3_000))" }
                return line
            }.joined(separator: "\n\n")
            return (String(localized: "\(saved.count) saved", comment: "Ask the forum step outcome: number of saved summaries found"), text)

        case .watchTopic:
            let topicID = try requiredTopicID(action)
            let topicKey = TopicIdentity.key(siteURL: siteURL, topicID: topicID)
            if let session = sessions[topicKey] {
                try ensureLive(recordID)
                await watch(
                    siteURL: siteURL,
                    topicID: topicID,
                    url: session.url,
                    title: session.title,
                    knownPostCount: session.totalPosts ?? 0
                )
            } else {
                let overview = try await adapter.overview(
                    TopicRef(siteURL: siteURL, topicID: topicID),
                    net: await network(for: siteURL, pace: context.forumRequestPace)
                )
                try ensureLive(recordID)
                await watch(
                    siteURL: siteURL,
                    topicID: topicID,
                    url: overview.url,
                    title: overview.title,
                    knownPostCount: overview.postCount
                )
            }
            return (String(localized: "Watching", comment: "Ask the forum step outcome: the topic was added to the watch list"), "Topic \(topicID) is now on the watch list.")

        case .finalAnswer:
            // The run loop ends on it before any tool runs.
            throw AgentError.unknownTool(action.tool, available: available)
        }
    }

    /// A site tool of the agent run through the run's adapter, which turns the
    /// arguments into its query.
    private func runSiteQuery(
        _ tool: AgentToolName,
        _ action: AgentAction,
        adapter: any SiteAdapter,
        siteURL: String,
        pace: ForumRequestPace
    ) async throws -> SiteQueryResult {
        let query = try adapter.agent.query(tool, action.arguments)
        let raw = try await adapter.run(query, net: await network(for: siteURL, pace: pace))
        return moderatedSiteQueryResult(raw, siteURL: siteURL)
    }

    func moderatedSiteQueryResult(_ result: SiteQueryResult, siteURL: String) -> SiteQueryResult {
        let rules = browser.moderationRules
        let hits = result.hits.filter { hit in
            !(hit.username.map { rules.hidesUser($0, siteURL: siteURL) } ?? false)
                && !isSearchHitPostHidden(hit, siteURL: siteURL, rules: rules)
                && !(hit.blurb.map(rules.hidesText) ?? false)
                && !rules.hidesText(hit.topic.title)
        }.map { hit in
            var copy = hit
            copy.topic.title = moderatedTopicTitle(hit.topic.title, siteURL: siteURL, topicID: hit.topic.topicID, openingPoster: hit.topic.author)
            return copy
        }
        let hadHitsByTopic = Set(result.hits.map(\.topic.topicID))
        let keptHitsByTopic = Dictionary(grouping: hits, by: \.topic.topicID)
        let topics = result.topics.compactMap { topic -> ForumTopicListing? in
            guard !rules.hidesText(topic.title) else { return nil }
            if hadHitsByTopic.contains(topic.topicID), keptHitsByTopic[topic.topicID] == nil {
                return nil
            }
            var copy = topic
            copy.title = moderatedTopicTitle(topic.title, siteURL: siteURL, topicID: topic.topicID, openingPoster: topic.author)
            if hadHitsByTopic.contains(topic.topicID) {
                copy.excerpt = keptHitsByTopic[topic.topicID]?.first?.blurb
            } else if isPostOneHidden(siteURL: siteURL, topicID: topic.topicID, rules: rules) {
                copy.excerpt = nil
            } else if let excerpt = copy.excerpt, rules.hidesText(excerpt) {
                copy.excerpt = nil
            }
            return copy
        }
        return SiteQueryResult(topics: topics, hits: hits)
    }

    private func isSearchHitPostHidden(_ hit: ForumSearchHit, siteURL: String, rules: ModerationRules) -> Bool {
        let topicID = hit.topic.topicID
        let key = TopicIdentity.key(siteURL: siteURL, topicID: topicID)
        let block = hit.url.fragment.flatMap { anchor in
            sessions[key]?.rawPages.lazy.flatMap(\.blocks).first { $0.anchor == anchor }
        }
        if let block, rules.hidesUser(block.author, siteURL: siteURL) { return true }
        if let anchor = hit.url.fragment,
           let id = adapter(for: siteURL)?.capabilities.postIdentity.id(anchor: anchor) {
            return rules.hidesPost(id, siteURL: siteURL, topicID: topicID)
        }
        let rules = topicModerationRules(siteURL: siteURL, topicID: topicID, rules: rules)
        if let number = hit.postNumber {
            return rules.hidesPost(number, siteURL: siteURL, topicID: topicID)
        }
        if let block { return rules.hidesPost(block.number, siteURL: siteURL, topicID: topicID) }
        return browser.moderationRules.hasHiddenPosts(siteURL: siteURL, topicID: topicID)
    }

    private func formatAgentTopicRead(
        _ action: AgentAction,
        session: TopicSession,
        adapter: any SiteAdapter,
        profile: AgentSiteProfile,
        context: RunSettings
    ) async throws -> (String, String) {
        let totalPages = max(
            1,
            session.rawPages.isEmpty
                ? RawTopicFormat.pageCount(of: session.source)
                : session.rawPages.count
        )
        let rawPage = action.arguments["page"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pageNumber: Int?
        if !rawPage.isEmpty {
            guard let parsed = Int(rawPage), (1...totalPages).contains(parsed) else {
                throw AgentError.invalidArgument("page", reason: "use a number from 1 to \(totalPages).")
            }
            pageNumber = parsed
        } else {
            pageNumber = nil
        }

        let query = (action.arguments["query"] ?? action.arguments["q"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fullModerated = moderated(session.source, siteURL: session.siteURL, topicID: session.topicID)
        let title = moderatedTopicTitle(session.title, siteURL: session.siteURL, topicID: session.topicID)
        let headerBase = (title.isEmpty ? "" : "Topic: \(title)\n") + "URL: \(session.url.absoluteString)"
            + " \(profile.postLinkHint(session.url))"

        if !query.isEmpty {
            let targetModerated: String
            if let page = pageNumber {
                let rawPageText = RawTopicFormat.pageText(page, pages: session.rawPages, fallbackText: session.source)
                targetModerated = moderated(rawPageText, siteURL: session.siteURL, topicID: session.topicID)
            } else {
                targetModerated = fullModerated
            }
            let openingPost = RawTopicFormat.postBlocks(fullModerated).first
            var (op, matches, opMatched) = RawTopicFormat.matchingBlocks(
                in: targetModerated,
                query: query,
                openingPost: openingPost
            )
            if matches.isEmpty, pageNumber == nil, totalPages > 1 {
                let net = await network(for: session.siteURL, pace: context.forumRequestPace)
                if let searchResult = try? await adapter.run(.search(text: query, scope: .topic(id: session.topicID)), net: net) {
                    let moderatedSearch = moderatedSiteQueryResult(searchResult, siteURL: session.siteURL)
                    var seen: Set<Int> = []
                    let hits = moderatedSearch.hits.filter { hit in
                        guard hit.topic.topicID == session.topicID,
                              let num = hit.postNumber, num > 1,
                              seen.insert(num).inserted
                        else { return false }
                        return true
                    }.prefix(20)
                    let numbers = hits.compactMap(\.postNumber)
                    if !numbers.isEmpty {
                        let rules = aiModerationRules
                        if let lookup = adapter.capabilities.postLookup,
                           let facts = (try? await adapter.overview(TopicRef(siteURL: session.siteURL, topicID: session.topicID), net: net))?.facts,
                           let fetched = try? await lookup.posts(
                               Array(numbers),
                               in: TopicRef(siteURL: session.siteURL, topicID: session.topicID),
                               facts: facts,
                               net: net
                           ),
                           !fetched.isEmpty {
                            matches = fetched.compactMap { post in
                                guard post.number > 1,
                                      !rules.hidesUser(post.username, siteURL: session.siteURL),
                                      !browser.moderationRules.hidesPost(adapter.capabilities.postIdentity.id(number: post.number, nativeID: post.id), siteURL: session.siteURL, topicID: session.topicID),
                                      !rules.hidesText(post.text)
                                else { return nil }
                                return "\(RawTopicFormat.authorToken(post.username)) | #\(post.number)\n\(RawTopicFormat.sanitizedBody(post.text))"
                            }
                        } else {
                            matches = hits.compactMap { hit in
                                guard let number = hit.postNumber,
                                      let blurb = hit.blurb, !blurb.isEmpty
                                else { return nil }
                                let author = RawTopicFormat.authorToken(hit.username ?? "unknown")
                                return "\(author) | #\(number)\n\(RawTopicFormat.sanitizedBody(blurb))"
                            }
                        }
                    }
                }
            }
            if !matches.isEmpty {
                let combined = ([op].compactMap { $0 } + matches).joined(separator: RawTopicFormat.blockSeparator)
                let bounded = PromptBuilder.boundedForumContext(combined, limit: context.agentReadLimit)
                let noun = matches.count == 1 ? "matching post" : "matching posts"
                let suffix = pageNumber.map { " on page \($0) of \(totalPages)" }
                    ?? (session.totalPosts.map { " (of \($0) posts)" } ?? "")
                return (
                    String(localized: "Read \(matches.count) matching posts", comment: "Ask the forum step outcome: number of posts matching a query in a topic"),
                    "\(headerBase)\nShowing: \(matches.count) \(noun) for \"\(query)\"\(suffix)\n\n\(bounded)"
                )
            } else if !opMatched {
                let body = op.map { PromptBuilder.boundedForumContext($0, limit: context.agentReadLimit) } ?? ""
                let suffix = pageNumber.map { " on page \($0) of \(totalPages)" } ?? ""
                return (
                    String(localized: "Read 0 matching posts", comment: "Ask the forum step outcome: number of posts matching a query in a topic"),
                    "\(headerBase)\nShowing: 0 matching posts for \"\(query)\"\(suffix)\n\n\(body)"
                )
            }
        }

        if let page = pageNumber {
            let rawPageText = RawTopicFormat.pageText(page, pages: session.rawPages, fallbackText: session.source)
            let pageModerated = moderated(rawPageText, siteURL: session.siteURL, topicID: session.topicID)
            let bounded = PromptBuilder.boundedForumContext(pageModerated, limit: context.agentReadLimit)
            return (
                String(localized: "Read page \(page) of \(totalPages)", comment: "Ask the forum step outcome: page read in a topic"),
                "\(headerBase)\nShowing: page \(page) of \(totalPages)\n\n\(bounded)"
            )
        }

        let bounded = PromptBuilder.boundedForumContext(
            fullModerated,
            limit: context.agentReadLimit,
            totalPages: totalPages
        )
        return (
            String(localized: "Read \(session.totalPosts ?? 0) posts", comment: "Ask the forum step outcome: number of posts read in a topic"),
            "\(headerBase)\n\n\(bounded)"
        )
    }

    private func requiredTopicID(_ action: AgentAction) throws -> String {
        let raw = action.arguments["topic_id"] ?? action.arguments["id"] ?? ""
        let digits = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "/").last?
            .filter(\.isNumber) ?? ""
        guard !digits.isEmpty else { throw AgentError.missingArgument("topic_id") }
        return digits
    }

    /// Pulls a topic for the agent (cached pages are reused), enforcing the
    /// per-run topic-read budget, and records the topic on the run.
    private func readTopicForAgent(
        _ action: AgentAction,
        adapter: any SiteAdapter,
        run: inout AgentRun,
        recordID: UUID,
        context: RunSettings,
        progress: @escaping @Sendable (_ fetched: Double) -> Double
    ) async throws -> TopicSession {
        let topicID = try requiredTopicID(action)
        if action.tool == AgentToolName.readTopic.rawValue,
           let rawPage = action.arguments["page"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPage.isEmpty {
            guard let parsed = Int(rawPage), parsed >= 1 else {
                throw AgentError.invalidArgument("page", reason: "use a positive integer.")
            }
        }
        let alreadyRead = run.topicIDs.contains(topicID)
        if !alreadyRead {
            let limit = min(context.agentMaxTopicReads, settings.agentMaxTopicReads)
            guard run.topicIDs.count < limit else {
                throw AgentError.topicBudgetExhausted(limit)
            }
        }
        let siteURL = run.siteURL
        let topicKey = TopicIdentity.key(siteURL: siteURL, topicID: topicID)
        if alreadyRead, let existing = sessions[topicKey], !existing.source.isEmpty {
            return existing
        }
        var session: TopicSession
        if let existing = sessions[topicKey] {
            session = existing
        } else {
            let overview = try await adapter.overview(
                TopicRef(siteURL: siteURL, topicID: topicID),
                net: await network(for: siteURL, pace: context.forumRequestPace)
            )
            session = TopicSession(
                siteURL: siteURL,
                topicID: topicID,
                url: overview.url,
                title: overview.title
            )
        }
        mutateRecord(recordID) {
            $0.statusText = String(localized: "Reading \(session.title)…", comment: "Status; the placeholder is a forum topic's title")
        }
        let fetch = try await fetchTopicPages(of: session, adapter: adapter, recordID: recordID, pace: context.forumRequestPace) { fetchProgress in
            await self.advanceProgress(recordID: recordID, to: progress(fetchProgress.fraction))
        }
        // Cancelled (or its forum's data deleted) while the page fetch was
        // finishing: do not write the session back.
        try ensureLive(recordID)
        session = sessions[topicKey] ?? session
        let now = Date()
        session.apply(fetch, at: now)
        session.updatedAt = now
        sessions[topicKey] = session
        if !run.topicIDs.contains(topicID) {
            run.topicIDs.append(topicID)
        }
        return session
    }

    /// Reads a job's topic, cached pages reused. Every new page goes into
    /// the topic's session as it arrives, so a read that fails, is paused or
    /// is killed keeps what it fetched; a later read fetches only the rest.
    private func fetchTopicPages(
        of session: TopicSession,
        adapter siteAdapter: any SiteAdapter,
        recordID: UUID,
        pace: ForumRequestPace,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void
    ) async throws -> ForumFetchResult {
        let net = await network(for: session.siteURL, pace: pace)
        let template = session
        let result = try await siteAdapter.readTopic(
            TopicReadRequest(
                topic: TopicRef(siteURL: session.siteURL, topicID: session.topicID),
                cachedPages: session.rawPages,
                knownTotalPosts: session.totalPosts
            ),
            net: net,
            progress: progress,
            onPage: { page in await self.keepFetchedPage(page, recordID: recordID, into: template) }
        )
        return result
    }

    /// A page a job fetched, into its topic's session (made from `template`
    /// for a topic read for the first time). Not once the job ended (a
    /// cancel) or its record is gone (its forum's data was deleted).
    private func keepFetchedPage(_ page: RawForumPage, recordID: UUID, into template: TopicSession) {
        guard activities.contains(where: { $0.id == recordID && !$0.status.isTerminal }) else { return }
        var session = sessions[template.topicKey] ?? template
        session.apply(page: page)
        sessions[template.topicKey] = session
        save()
    }

    private func updateFetchProgress(recordID: UUID, progress: ForumFetchProgress) {
        // A late page report of a cancelled job must not touch its record.
        guard isLive(recordID),
              let record = activities.first(where: { $0.id == recordID })
        else { return }
        if let feed = summaryFeeds[recordID] {
            feed.handle(.fetched(completedPages: progress.completedPages, totalPages: progress.totalPages))
        } else {
            self.progress.advance(recordID, to: WorkProgress.fetch(progress.fraction, type: record.type))
        }
        if record.statusText != progress.message {
            mutateRecord(recordID) { $0.statusText = progress.message }
        }
    }

    /// Moves a running job's determinate progress forward (never back).
    private func advanceProgress(recordID: UUID, to fraction: Double) {
        guard isLive(recordID) else { return }
        progress.advance(recordID, to: fraction)
    }

    /// Starts a clock-driven summary feed; ticks go only through `ProgressStore`.
    private func startSummaryFeed(
        recordID: UUID,
        tracker: SummaryProgressTracker,
        keepsStatusText: Bool = false,
        map: @escaping (Double) -> Double = { $0 }
    ) -> SummaryProgressFeed {
        summaryFeeds.removeValue(forKey: recordID)?.cancel()
        let token = runningTasks[recordID]?.token
        let output = ThrottledProgress { [weak self] fraction, statusText in
            guard let self, let token, self.isCurrentLaunch(recordID, token: token), self.isLive(recordID) else { return }
            self.progress.advance(recordID, to: fraction)
            if let statusText, !keepsStatusText,
               self.activities.first(where: { $0.id == recordID })?.statusText != statusText {
                self.mutateRecord(recordID) { $0.statusText = statusText }
            }
        }
        let feed = SummaryProgressFeed(tracker: tracker, output: output, map: map)
        summaryFeeds[recordID] = feed
        return feed
    }

    private func stopSummaryFeed(_ recordID: UUID, _ feed: SummaryProgressFeed) {
        feed.cancel()
        if summaryFeeds[recordID] === feed { summaryFeeds.removeValue(forKey: recordID) }
    }

    private func mutateRecord(_ id: UUID, mutation: (inout WorkRecord) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        mutation(&activities[index])
        activities[index].updatedAt = Date()
    }

    /// Drops old sessions and agent-read pages (SessionRetention.swift).
    private func pruneSessions(now: Date = Date()) {
        var protected = Set(watchedTopics.map(\.topicKey))
        for record in activities where !record.status.isTerminal { protected.insert(record.topicKey) }
        if let topicKey = currentTopic?.topicKey { protected.insert(topicKey) }
        let plan = SessionRetention.plan(
            sessions: sessions,
            protected: protected,
            citedByRuns: SessionRetention.topicKeys(citedBy: agentRuns),
            now: now
        )
        guard !plan.isEmpty else { return }
        var kept = sessions
        for key in plan.remove { kept.removeValue(forKey: key) }
        for key in plan.dropPages {
            kept[key]?.dropFetchedText()
        }
        sessions = kept
        // Pruned, not deleted: other devices keep their copies.
        cloudSync.notePruned(kind: .session, ids: plan.remove)
    }

    /// Saves the snapshot (and any changed API keys). Data changes save at
    /// once; settings edits are coalesced through `saveSettings()`. The file
    /// is written in the background (`PersistentStore.scheduleSave`);
    /// `flushPendingSaves()` waits for it.
    func save() {
        settingsSaveTask?.cancel()
        settingsSaveTask = nil
        cloudSync.localDataDidChange()
        #if DEBUG
        // Sample data for screenshots is never written over the real snapshot,
        // and its placeholder key stays in memory.
        if AssistantDebug.isActive { return }
        #endif
        persistChangedAPIKeys()
        let snapshot = AppSnapshot(
            settings: settings.persistable,
            sessions: Array(sessions.values),
            activities: activities,
            agentRuns: agentRuns,
            watchedTopics: watchedTopics,
            forums: forums
        )
        // Encoded and written off the main actor; rapid saves coalesce.
        store.scheduleSave(snapshot) { [weak self] error in
            self?.presentError(String(localized: "Unable to save app data: \(error.localizedDescription)", comment: "Error; the placeholder is the system's reason"))
        }
    }

    private var activeTaskCount: Int {
        activities.lazy.filter { !$0.status.isTerminal }.count
    }

    // MARK: Sync hooks (AppModel+CloudSync.swift)

    /// Replaces the synced collections with merged ones and saves.
    func replaceSyncedData(
        sessions: [String: TopicSession],
        agentRuns: [AgentRun],
        watchedTopics: [WatchedTopic],
        forums: [Forum]
    ) {
        if self.sessions != sessions {
            self.sessions = sessions
            if case .editing(let editTopicKey, let messageID, _) = chatEdit,
               sessions[editTopicKey]?.history.contains(where: { $0.id == messageID && $0.role == .user }) != true {
                chatEdit = .none
            }
        }
        if self.agentRuns != agentRuns {
            self.agentRuns = agentRuns
            reconcileAgentSelection()
        }
        if self.watchedTopics != watchedTopics { self.watchedTopics = watchedTopics }
        if self.forums != forums {
            let removed = Set(self.forums.map(\.siteURL)).subtracting(forums.map(\.siteURL))
            self.forums = forums
            // Like `removeForum`: its open page must not add it straight back,
            // and a current forum removed elsewhere falls back.
            if let page = pageContext.siteURL, removed.contains(page) { suppressedAutoAddSiteURL = page }
            if let current = currentSiteURL, forum(for: current) == nil {
                currentSiteURL = (pageContext.siteURL.flatMap { forum(for: $0) } ?? Self.startForum(in: forums))?.siteURL
                if agentSiteURL == current { agentSiteURL = nil }
                if browser.homeSiteURL == current, (pageContext.siteURL != current || browser.showsForumsHome) {
                    browser.homeSiteURL = currentSiteURL
                }
            }
        }
        save()
    }

    /// Every synced record the app holds, as "kind/id" (to notice deletes).
    func syncRecordKeys() -> Set<String> {
        var keys = Set<String>(minimumCapacity: sessions.count + agentRuns.count + watchedTopics.count + forums.count + 1)
        for key in sessions.keys { keys.insert(SyncRecord.recordKey(kind: .session, id: key)) }
        for run in agentRuns { keys.insert(SyncRecord.recordKey(kind: .run, id: run.id.uuidString)) }
        for watched in watchedTopics { keys.insert(SyncRecord.recordKey(kind: .watched, id: watched.topicKey)) }
        for forum in forums { keys.insert(SyncRecord.recordKey(kind: .forum, id: forum.siteURL)) }
        return keys
    }

    /// Adopts API keys that changed in the key store behind the app's back
    /// (iCloud Keychain delivered them). A key with an unsaved edit here is
    /// left alone. Called at the start of every sync pass.
    func reloadProviderKeysFromKeychain() {
        var updated = settings
        for provider in AIProvider.allCases {
            let stored = keyStore.value(for: provider)
            let persisted = persistedAPIKeys[provider] ?? ""
            guard stored != persisted, updated.configuration(for: provider).apiKey == persisted else { continue }
            var configuration = updated.configuration(for: provider)
            configuration.apiKey = stored
            updated.setConfiguration(configuration, for: provider)
            persistedAPIKeys[provider] = stored
        }
        if updated != settings { settings = updated }
    }

    #if DEBUG
    func upsertSessionForTesting(_ session: TopicSession) {
        sessions[session.topicKey] = session
    }

    func setActivitiesForTesting(_ records: [WorkRecord]) {
        activities = records
    }
    #endif
}

/// What a job runs with, captured when it starts (see `AppModel.runSettings`).
/// In memory only: the key is never written into a record.
struct RunSettings {
    /// A provider and its settings with the model to run.
    struct Model {
        var provider: AIProvider
        var configuration: ProviderConfiguration
    }

    /// The job's own model: the agent model for Ask the forum, else the
    /// assistant model.
    var provider: AIProvider
    var configuration: ProviderConfiguration
    /// The assistant model, for the agent's `summarize_topic` tool.
    var summarizer: Model
    var batchLimit: Int
    var contextLimit: Int
    /// The topic's own instructions, else the global ones.
    var topicInstructions: String
    var globalInstructions: String
    var agentMaxSteps: Int
    var agentMaxTopicReads: Int
    var agentReadLimit: Int
    /// How quickly this job's requests go to the forum (taken at the start).
    var forumRequestPace: ForumRequestPace = .default

    /// Fails with a clear message when the provider was disconnected (key
    /// deleted, settings reset) between queueing and starting.
    func requireReadyProvider() throws {
        try Self.requireReady(provider: provider, configuration: configuration)
    }

    static func requireReady(provider: AIProvider, configuration: ProviderConfiguration) throws {
        if configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AssistantError.missingConfiguration(String(localized: "Choose a model in Settings › AI models.", comment: "Error; Settings › AI models names the app's own Settings page"))
        }
        if provider.requiresAPIKey,
           configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AssistantError.missingConfiguration(
                String(localized: "\(provider.displayName) isn’t connected. Add an API key in Settings › AI models.", comment: "Error; the placeholder is the AI provider's name. Settings › AI models names the app's own Settings page.")
            )
        }
    }
}

/// A shared link waiting for its page to be detected.
private struct PendingShare {
    enum Action: String {
        case open, summary, chat, agent
    }

    var url: URL
    var action: Action
    /// Topic id in the shared URL (base path unknown until the probe).
    var topicID: String?
    /// Start the summary / pull once the topic is detected (false for deep
    /// links that the share extension did not queue).
    var autoRun = true
    /// The browser has reported the shared page itself (loading or loaded).
    var sawSharedPage = false
}

/// Extra time to run after the app leaves the foreground
/// (`UIApplication.beginBackgroundTask`); tests fake it.
@MainActor
protocol BackgroundGracing {
    /// `.invalid` when the system gives no time.
    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ id: UIBackgroundTaskIdentifier)
}

struct ApplicationBackgroundGrace: BackgroundGracing {
    func begin(name: String, expiration: @escaping () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: expiration)
    }

    func end(_ id: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(id)
    }
}
