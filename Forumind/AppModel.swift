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
// - `currentForum`                  forum of the current page, else the last one shown
// - `forum(for:)`                   directory entry for a site URL
// - `addForum(fromAddress:pin:)`    validates a URL/host via basic-info.json, adds it
// - `pin(_:)` / `unpin(_:)` / `togglePin(_:)` / `movePinned(fromOffsets:toOffset:)`
// - `removeForum(_:deleteData:)`    optionally deletes its summaries/chats/runs/watches
// - `openForum(_:)`                 loads its /latest in the browser
// - `recordVisit(siteURL:name:iconURL:)` called automatically for detected Discourse pages
//
// Page and assistant:
// - `pageContext`                   browser page state (.loading/.notForum/.maybe/.forumHome/.topic)
// - `currentTopic`, `currentSession` topic of the page and its saved session
// - `isProviderReady`               an AI provider is configured (key present when required)
// - `agentSiteURL`                  forum the next agent run targets (nil → current forum)
// - `startAgentRun(goal:siteURL:)`  runs are scoped to one forum (`AgentRun.siteURL`)
// - `sessions` is keyed by topic key (`host[/basePath]/t/{id}`); per-topic calls take
//   `topicKey:` (`setKept`, `deleteSession`, `setInstructions`, `isWatched`, `unwatch`,
//   `markWatchedSeen`)
//
// Onboarding / hand-off:
// - `settings.hasCompletedOnboarding`, `completeOnboarding()`
// - `handle(_ request: IncomingLinkRequest)` share-extension / deep-link hand-off (deduped by id)
// - `drainSharedInbox()`            deliver the App Group inbox (also runs on scene .active)
// - `openShared(url:action:)`       open a shared link; "summary" | "chat" | "agent" | "open"
// - `presentAssistant`              set when a hand-off wants the Assistant pane (UI resets it)
// - `needsProviderSetup`            set when a hand-off needs a provider first (UI resets it)
// - `handleDeepLink(_:)`            forumind://open?url=…&action=…
//
// Ad and tracker blocking: see AppModel+ContentBlocking.swift.

enum PanelRoute: String, CaseIterable {
    case topic = "Topic"
    case activity = "Manage"
    case settings = "Settings"
}

enum AssistantMode: String, CaseIterable, Identifiable {
    case summary = "Summary"
    case chat = "Chat"
    case agent = "Agent"

    var id: String { rawValue }
}

enum AgentError: LocalizedError {
    case missingArgument(String)
    case topicBudgetExhausted(Int)
    case unknownTool(String)
    case runNotFound

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name): "Missing argument \"\(name)\"."
        case .topicBudgetExhausted(let limit):
            "The topic-read budget (\(limit)) is used up; answer with what you have."
        case .unknownTool(let name):
            "Unknown tool \"\(name)\". Available: "
                + AgentPrompt.tools.map(\.name).joined(separator: ", ")
        case .runNotFound: "The agent run no longer exists."
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

@MainActor
final class AppModel: ObservableObject {
    /// Edits apply at once: work that has not started yet uses them, work
    /// already running keeps the values it started with (`RunSettings`). Every
    /// change is persisted, coalesced (see `saveSettings()`).
    @Published var settings: AppSettings {
        didSet { settingsDidChange(from: oldValue) }
    }
    @Published private(set) var sessions: [String: TopicSession]
    @Published private(set) var activities: [WorkRecord]
    @Published private(set) var currentTopic: ForumTopic?
    @Published var panelRoute: PanelRoute = .topic
    /// Shared between the inline panel and its full-screen copy so opening the
    /// assistant full screen keeps the same mode.
    @Published var assistantMode: AssistantMode = .summary
    @Published var summaryStreams: [UUID: String] = [:]
    @Published var chatStreams: [UUID: String] = [:]
    @Published var chatDraft = ""
    @Published var presentedError: String?
    @Published var settingsStatus = ""
    @Published var discoveredModels: [String] = []
    @Published private(set) var agentRuns: [AgentRun]
    @Published private(set) var watchedTopics: [WatchedTopic]
    @Published var selectedAgentRunID: UUID?
    @Published var agentGoalDraft = ""
    @Published var agentFollowUpDraft = ""
    @Published private(set) var notificationsAuthorized = false
    /// The user's forums (pinned and recent); see the API list above.
    @Published private(set) var forums: [Forum] {
        didSet { syncCurrentForum() }
    }
    /// The forum of the current page, or the last forum shown.
    @Published private(set) var currentForum: Forum?
    /// The browser's current page as the assistant sees it.
    @Published private(set) var pageContext = PageContext.empty
    /// Forum the next agent run targets; nil means `currentForum`.
    @Published var agentSiteURL: String?
    /// A share/deep-link hand-off wants the Assistant pane shown.
    @Published var presentAssistant = false
    /// A hand-off needed an AI provider that is not configured yet.
    @Published var needsProviderSetup = false

    nonisolated static var suggestedForums: [SuggestedForum] {
        #if DEBUG
        if ForumDirectory.usesSampleSuggestions { return ForumDirectory.sampleSuggested }
        #endif
        return ForumDirectory.suggested
    }

    let browser: ForumBrowserModel
    /// iCloud (CloudKit) sync (see CloudSyncController.swift).
    let cloudSync: CloudSyncController

    private let store: PersistentStore
    private let forumService: ForumService
    private let aiService: AIService
    private let planner: AgentPlanner
    private let notifier: WatchNotifier
    private let limiter = TaskLimiter(limit: 2)
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
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
    /// Bumped when the selected provider, its base URL, or its key changes,
    /// and when a new test / model load starts: an older result is dropped.
    private var connectionTestGeneration = 0
    private var modelDiscoveryGeneration = 0
    private var isCheckingWatches = false
    /// A forum the user removed while its page is still open: the page must
    /// not add it straight back as a recent forum.
    private var suppressedAutoAddSiteURL: String?
    /// Delay before coalesced settings edits are written.
    var settingsSaveDelay: Duration = .milliseconds(400)
    private static let watchInterval: TimeInterval = 30 * 60
    private static let agentTopicPrefix = "agent:"
    /// When true, agent tools and watch checks call the forum through
    /// ForumService's URLSession instead of the embedded web view (tests).
    var usesDirectForumRequests = false

    /// Loader that runs forum requests in the authenticated web view context.
    private var webViewResourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? {
        guard !usesDirectForumRequests else { return nil }
        return { [browser] url in try await browser.fetchForumResource(url) }
    }

    init(
        store: PersistentStore = PersistentStore(),
        forumService: ForumService = ForumService(),
        aiService: AIService = AIService(),
        browser: ForumBrowserModel? = nil,
        planner: AgentPlanner? = nil,
        notifier: WatchNotifier = .shared,
        cloudSync: CloudSyncController? = nil
    ) {
        self.store = store
        self.keyStore = store.keys
        self.cloudSync = cloudSync ?? CloudSyncController.makeDefault(for: store)
        self.forumService = forumService
        self.aiService = aiService
        self.browser = browser ?? ForumBrowserModel()
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
        activities = snapshot.activities
            .filter {
                !$0.status.isTerminal
                    || now.timeIntervalSince($0.completedAt ?? $0.updatedAt) < 24 * 60 * 60
            }
            .map {
                guard !$0.status.isTerminal else { return $0 }
                var interrupted = $0
                interrupted.status = .queued
                interrupted.phase = "queued"
                interrupted.statusText = "Restoring interrupted work…"
                return interrupted
            }
            .sorted { $0.createdAt > $1.createdAt }

        // Interrupted agent runs resume with their re-queued record; a run whose
        // record is gone cannot resume and is closed out instead of spinning.
        let restorableRunIDs = Set(
            activities
                .filter { $0.type == .agent && !$0.status.isTerminal }
                .compactMap { UUID(uuidString: String($0.topicID.dropFirst(Self.agentTopicPrefix.count))) }
        )
        agentRuns = agentRuns.map { run in
            guard !run.status.isTerminal else { return run }
            var updated = run
            if restorableRunIDs.contains(run.id) {
                updated.status = .queued
            } else {
                updated.status = .cancelled
                updated.error = "Interrupted before the run could finish."
                updated.completedAt = now
            }
            return updated
        }

        self.browser.knownForumLookup = { [weak self] url in
            guard let forum = self?.directory.forum(containing: url) else { return nil }
            return KnownForumSite(siteURL: forum.siteURL, name: forum.name, iconURL: forum.iconURL)
        }
        self.browser.onPageContextChanged = { [weak self] context in
            self?.handlePageContext(context)
        }
        // Start on the most recently visited forum (or the first pinned one);
        // with none, the browser stays empty and the UI shows the Forums home.
        currentForum = Self.startForum(in: forums)
        self.browser.homeSiteURL = currentForum?.siteURL
        // Ad/tracker blocking starts before the first page load.
        configureContentBlocking()
        if self.browser.webView.url == nil {
            self.browser.loadHome()
        }
        openURLObserver = NotificationCenter.default.addObserver(
            forName: WatchNotifier.openURLNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            Task { @MainActor [weak self] in
                self?.browser.load(url)
                self?.panelRoute = .topic
            }
        }
        WatchBackgroundRefresh.perform = { [weak self] in
            await self?.checkWatchedTopics(reason: .background)
        }
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
        applyStateDebugScript()
        #endif
        self.cloudSync.attach(self)
    }

    var currentSession: TopicSession? {
        guard let topicKey = currentTopic?.topicKey else { return nil }
        return sessions[topicKey]
    }

    /// The selected provider has what it needs to run (a key, unless local).
    var isProviderReady: Bool {
        if settings.selectedProvider == .appleIntelligence { return appleIntelligenceStatus.isAvailable }
        let configuration = selectedConfiguration
        let hasModel = !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasKey = !settings.selectedProvider.requiresAPIKey
            || !configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasModel && hasKey
    }

    /// Live availability of the Apple Intelligence provider (through
    /// `aiService`, so tests can fake it).
    var appleIntelligenceStatus: AppleIntelligenceStatus {
        aiService.appleIntelligence.currentStatus()
    }

    var selectedConfiguration: ProviderConfiguration {
        settings.configuration(for: settings.selectedProvider)
    }

    /// "Provider · model" for headers and Settings. Apple Intelligence shows
    /// its live backend ("Apple Intelligence · On-device") rather than the
    /// placeholder model name.
    var providerSummary: String {
        let provider = settings.selectedProvider
        let model = provider.isAppleIntelligence
            ? (appleIntelligenceStatus.backend?.label ?? "")
            : selectedConfiguration.model
        return model.isEmpty ? provider.displayName : "\(provider.displayName) · \(model)"
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
    /// opens the page and Assistant without starting a summary or pull.
    func handle(_ request: IncomingLinkRequest, autoRun: Bool = true) {
        guard handledShareIDs.insert(request.id).inserted else { return }
        openShared(url: request.url, action: request.action.rawValue, autoRun: autoRun)
    }

    /// Delivers the newest request the share extension queued in the App Group
    /// inbox (older ones are superseded) — call on launch/foreground.
    func drainSharedInbox() {
        let requests = SharedInbox.drainAll().filter { !handledShareIDs.contains($0.id) }
        if let latest = requests.last { handle(latest) }
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
                topicID: ForumSite.looseTopicID(from: url),
                autoRun: autoRun
            )
        panelRoute = .topic
        browser.load(url)
    }

    private func handlePageContext(_ context: PageContext) {
        pageContext = context
        if let suppressed = suppressedAutoAddSiteURL {
            // A forum removed while its page is open stays removed until the
            // browser settles on another forum or a non-forum page.
            if let siteURL = context.siteURL, siteURL != suppressed {
                suppressedAutoAddSiteURL = nil
            } else if context.state == .notForum {
                suppressedAutoAddSiteURL = nil
            }
        }
        if context.isDiscourse, let siteURL = context.siteURL, siteURL != suppressedAutoAddSiteURL {
            recordVisit(siteURL: siteURL, name: context.forumName, iconURL: context.iconURL)
        }
        select(topic: context.topic)
        completePendingShare(with: context)
    }

    private func completePendingShare(with context: PageContext) {
        guard var pending = pendingShare, let url = context.url else { return }
        if !pending.sawSharedPage, PageContext.samePage(url, pending.url) {
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
        let topicMatches = pending.topicID != nil && context.topic?.topicID == pending.topicID
        switch pending.action {
        case .open:
            pendingShare = nil
        case .agent:
            pendingShare = nil
            agentSiteURL = context.siteURL
            assistantMode = .agent
            panelRoute = .topic
            presentAssistant = true
            if !isProviderReady { needsProviderSetup = true }
        case .summary, .chat:
            guard topicMatches else {
                // A Discourse page that is not the shared topic: stop waiting
                // once loading finished somewhere else. For a topic page that
                // needs the shared page to have been reached first (a late
                // report from the page before it must not cancel the share);
                // after that, the user went elsewhere, and visiting the
                // shared topic later must not start work by surprise.
                if !browser.isLoading, !PageContext.samePage(url, pending.url),
                   context.state == .forumHome || pending.sawSharedPage {
                    pendingShare = nil
                }
                return
            }
            pendingShare = nil
            assistantMode = pending.action == .summary ? .summary : .chat
            panelRoute = .topic
            presentAssistant = true
            guard isProviderReady else {
                needsProviderSetup = true
                return
            }
            // A deep link that did not come from the share extension only
            // opens the Assistant; the user starts the work.
            guard pending.autoRun else { return }
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
        currentTopic = topic
        guard let topic else { return }
        #if DEBUG
        let resetForPullUITest = ProcessInfo.processInfo.arguments.contains(
            "-ui-test-pull-mode"
        )
        #else
        let resetForPullUITest = false
        #endif
        if resetForPullUITest {
            sessions[topic.topicKey] = TopicSession(
                siteURL: topic.siteURL,
                topicID: topic.topicID,
                url: topic.url,
                title: topic.title
            )
        } else if var existing = sessions[topic.topicKey] {
            existing.url = topic.url
            existing.title = topic.title
            existing.lastAccessedAt = Date()
            sessions[topic.topicKey] = existing
        } else {
            sessions[topic.topicKey] = TopicSession(
                siteURL: topic.siteURL,
                topicID: topic.topicID,
                url: topic.url,
                title: topic.title
            )
        }
        save()
    }

    /// Starts a summary; `batchLimit` overrides the hierarchical-summary batch
    /// size for this run only.
    func startSummary(batchLimit: Int? = nil) {
        guard let topic = currentTopic else {
            presentedError = AssistantError.noTopic.localizedDescription
            return
        }
        if activities.contains(where: {
            $0.topicKey == topic.topicKey && $0.type == .summary && !$0.status.isTerminal
        }) {
            panelRoute = .activity
            return
        }
        enqueueSummary(for: topic, batchLimit: batchLimit)
    }

    /// Queues a summary task for any topic (used by watched-topic refreshes).
    @discardableResult
    func enqueueSummary(for topic: ForumTopic, batchLimit: Int? = nil) -> Bool {
        guard !activities.contains(where: {
            $0.topicKey == topic.topicKey && $0.type == .summary && !$0.status.isTerminal
        }) else {
            return false
        }
        guard activeTaskCount < 50 else {
            presentedError = "The task queue is full. Cancel or wait for an existing task."
            return false
        }

        let configuration = selectedConfiguration
        var record = WorkRecord(
            type: .summary,
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            title: topic.title,
            url: topic.url,
            provider: settings.selectedProvider,
            model: configuration.model
        )
        record.batchLimit = batchLimit.map(SummaryBatchLimit.normalized)
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

    /// `currentForum` is a copy: keep its name, icon and pin state in step
    /// with the directory (a forum that left the directory is handled by
    /// `removeForum`).
    private func syncCurrentForum() {
        guard let current = currentForum,
              let fresh = forums.first(where: { $0.siteURL == current.siteURL }),
              fresh != current
        else {
            return
        }
        currentForum = fresh
    }

    /// After runs were deleted: select a remaining run, and drop a follow-up
    /// draft that belonged to a deleted one.
    func reconcileAgentSelection() {
        guard let selectedAgentRunID, !agentRuns.contains(where: { $0.id == selectedAgentRunID }) else {
            return
        }
        self.selectedAgentRunID = agentRuns.first?.id
        agentFollowUpDraft = ""
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
    func recordVisit(siteURL: String, name: String?, iconURL: URL?) {
        var directory = self.directory
        let previous = directory.forum(siteURL: siteURL)
        let now = Date()
        // Visits within a minute on the same forum do not rewrite the snapshot.
        let isFreshVisit = previous?.lastVisitedAt.map { now.timeIntervalSince($0) > 60 } ?? true
        guard let forum = directory.upsert(
            siteURL: siteURL,
            name: name,
            iconURL: iconURL,
            visitedAt: isFreshVisit ? now : nil
        ) else {
            return
        }
        let changed = forum != previous
        if changed { self.directory = directory }
        if currentForum != forum { currentForum = forum }
        if changed { save() }
    }

    /// Validates an address (URL or host, optionally a page on the forum) by
    /// fetching `/site/basic-info.json` (fallback `/about.json`), then adds the
    /// forum with its name and icon. Existing forums are refreshed.
    @discardableResult
    func addForum(fromAddress address: String, pin: Bool = false) async throws -> Forum {
        let candidates = ForumDirectory.candidateSiteURLs(fromAddress: address)
        guard let first = candidates.first else { throw ForumDirectoryError.invalidAddress }
        for siteURL in candidates {
            if let host = ForumSite.parse(siteURL: siteURL).flatMap({ URLComponents(string: $0.origin)?.host }) {
                let cookies = await browser.cookieHeader(forHost: host)
                guard let info = try? await forumService.fetchSiteInfo(
                    siteURL: siteURL,
                    cookieHeader: cookies
                ) else {
                    continue
                }
                var directory = self.directory
                guard var forum = directory.upsert(
                    siteURL: siteURL,
                    name: info.name,
                    iconURL: info.iconURL
                ) else {
                    continue
                }
                if pin {
                    directory.setPinned(true, siteURL: forum.siteURL)
                    forum = directory.forum(siteURL: forum.siteURL) ?? forum
                }
                if suppressedAutoAddSiteURL == forum.siteURL { suppressedAutoAddSiteURL = nil }
                self.directory = directory
                save()
                browser.refreshPageContext()
                return forum
            }
        }
        throw ForumDirectoryError.notDiscourse(ForumSite.host(of: first))
    }

    /// Fetches a forum's name and icon in the background. Only the name and
    /// icon change: a forum removed meanwhile is not added back, and its pin
    /// state is whatever the user set while the request ran.
    func refreshForumInfo(siteURL: String) {
        guard let normalized = ForumSite.normalizeSiteURL(siteURL),
              let host = ForumSite.parse(siteURL: normalized).flatMap({ URLComponents(string: $0.origin)?.host })
        else {
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let cookies = await self.browser.cookieHeader(forHost: host)
            guard let info = try? await self.forumService.fetchSiteInfo(siteURL: normalized, cookieHeader: cookies),
                  self.forum(for: normalized) != nil
            else {
                return
            }
            var directory = self.directory
            directory.upsert(siteURL: normalized, name: info.name, iconURL: info.iconURL)
            guard directory.forums != self.forums else { return }
            self.directory = directory
            self.save()
        }
    }

    func pin(_ forum: Forum) {
        if suppressedAutoAddSiteURL == forum.siteURL { suppressedAutoAddSiteURL = nil }
        var directory = self.directory
        if directory.forum(siteURL: forum.siteURL) == nil {
            directory.upsert(siteURL: forum.siteURL, name: forum.name, iconURL: forum.iconURL)
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
    /// deleted. The agent's forum falls back to the page's forum, and a page
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
        }
        if pageContext.siteURL == siteURL { suppressedAutoAddSiteURL = siteURL }
        var directory = self.directory
        directory.remove(siteURL: siteURL)
        self.directory = directory
        if currentForum?.siteURL == siteURL {
            currentForum = pageContext.siteURL.flatMap { self.directory.forum(siteURL: $0) }
                ?? Self.startForum(in: forums)
        }
        if agentSiteURL == siteURL { agentSiteURL = nil }
        if browser.homeSiteURL == siteURL, pageContext.siteURL != siteURL {
            browser.homeSiteURL = currentForum?.siteURL
        }
        save()
        browser.refreshPageContext()
    }

    /// Makes the forum current and loads its /latest.
    func openForum(_ forum: Forum) {
        if suppressedAutoAddSiteURL == forum.siteURL { suppressedAutoAddSiteURL = nil }
        currentForum = directory.forum(siteURL: forum.siteURL) ?? forum
        browser.homeSiteURL = forum.siteURL
        browser.loadHome()
        panelRoute = .topic
    }

    /// Opens a suggested forum (added to the directory as recent on arrival).
    func openForum(_ suggested: SuggestedForum) {
        openForum(Forum(siteURL: suggested.siteURL, name: suggested.name))
    }

    // MARK: Agent runs

    /// Starts an agent run on `siteURL` (default: `agentSiteURL`, else the
    /// current forum). Every tool call and follow-up stays on that forum.
    func startAgentRun(goal rawGoal: String, siteURL: String? = nil) {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        guard let forumSiteURL = (siteURL ?? agentSiteURL ?? currentForum?.siteURL)
            .flatMap(ForumSite.normalizeSiteURL)
        else {
            presentedError = AssistantError.noForum.localizedDescription
            return
        }
        guard activeTaskCount < 50 else {
            presentedError = "The task queue is full. Cancel or wait for an existing task."
            return
        }
        let configuration = selectedConfiguration
        var run = AgentRun(
            siteURL: forumSiteURL,
            goal: goal,
            provider: settings.selectedProvider,
            model: configuration.model
        )
        run.transcript = [AgentPrompt.goalMessage(goal)]
        agentRuns.insert(run, at: 0)
        cloudSync.notePruned(kind: .run, ids: agentRuns.dropFirst(50).map(\.id.uuidString))
        agentRuns = Array(agentRuns.prefix(50))
        selectedAgentRunID = run.id
        agentGoalDraft = ""
        launchAgentRecord(for: run, title: goal)
    }

    /// Continues a finished run with a follow-up question; the agent keeps the
    /// topics it already read and may call tools again.
    func continueAgentRun(id: UUID, question rawQuestion: String) {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty,
              let index = agentRuns.firstIndex(where: { $0.id == id }),
              agentRuns[index].status.isTerminal
        else {
            return
        }
        guard activeTaskCount < 50 else {
            presentedError = "The task queue is full. Cancel or wait for an existing task."
            return
        }
        agentRuns[index].followUps.append(ChatMessage(role: .user, content: question))
        agentRuns[index].transcript.append(AgentPrompt.followUpMessage(question))
        agentRuns[index].status = .queued
        agentRuns[index].error = ""
        agentRuns[index].updatedAt = Date()
        agentFollowUpDraft = ""
        selectedAgentRunID = id
        launchAgentRecord(for: agentRuns[index], title: question)
    }

    func deleteAgentRun(id: UUID) {
        guard let run = agentRuns.first(where: { $0.id == id }), run.status.isTerminal else {
            return
        }
        agentRuns.removeAll { $0.id == id }
        reconcileAgentSelection()
        save()
    }

    func openAgentRun(id: UUID) {
        selectedAgentRunID = id
        assistantMode = .agent
        panelRoute = .topic
    }

    var selectedAgentRun: AgentRun? {
        guard let selectedAgentRunID else { return agentRuns.first }
        return agentRuns.first { $0.id == selectedAgentRunID } ?? agentRuns.first
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
            url: ForumSite.latestURL(siteURL: run.siteURL) ?? URL(string: run.siteURL)
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
            if count == nil {
                let cookies = await self.browser.cookieHeader(forSite: topic.siteURL)
                count = try? await self.forumService.fetchOverview(
                    siteURL: topic.siteURL,
                    topicID: topic.topicID,
                    cookieHeader: cookies,
                    resourceLoader: self.webViewResourceLoader
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
        markWatchedSeen(topicKey: watched.topicKey)
        browser.load(watched.url)
        panelRoute = .topic
    }

    /// Checks every watched topic (on every forum) for new replies. In the
    /// foreground new replies can queue a summary refresh; in the background
    /// they post a notification.
    ///
    /// One check runs at a time (a timer, foreground, and background refresh
    /// can overlap; the later ones return at once). Topics unwatched while the
    /// check is fetching are skipped, and the auto-refresh setting is read
    /// when the replies arrive, so toggling it mid-check takes effect.
    func checkWatchedTopics(reason: WatchCheckReason) async {
        guard !watchedTopics.isEmpty, !isCheckingWatches else { return }
        isCheckingWatches = true
        defer { isCheckingWatches = false }
        lastWatchCheck = Date()
        var cookiesBySite: [String: String?] = [:]
        var arrivals: [(WatchedTopic, Int)] = []
        // The web view cannot run scripts while the app is in the background,
        // so background checks go straight to URLSession with each forum's cookies.
        let webViewLoader = reason == .background ? nil : webViewResourceLoader

        for watched in watchedTopics {
            if Task.isCancelled { break }
            if cookiesBySite[watched.siteURL] == nil {
                cookiesBySite[watched.siteURL] = .some(await browser.cookieHeader(forSite: watched.siteURL))
            }
            let result: Result<ForumTopicOverview, Error>
            do {
                result = .success(try await forumService.fetchOverview(
                    siteURL: watched.siteURL,
                    topicID: watched.topicID,
                    cookieHeader: cookiesBySite[watched.siteURL] ?? nil,
                    resourceLoader: webViewLoader
                ))
            } catch {
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
        if reason != .background, settings.watchAutoRefreshSummaries, isProviderReady {
            for (watched, _) in arrivals
            where isWatched(topicKey: watched.topicKey) && sessions[watched.topicKey]?.hasSummary == true {
                enqueueSummary(
                    for: ForumTopic(
                        siteURL: watched.siteURL,
                        topicID: watched.topicID,
                        url: watched.url,
                        title: watched.title
                    )
                )
            }
        }
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
        case .inactive:
            // Coalesced edits must not be lost if the app is closed next.
            flushPendingSaves()
        case .background:
            flushPendingSaves()
            watchTimer?.cancel()
            watchTimer = nil
            if !watchedTopics.isEmpty { WatchBackgroundRefresh.schedule() }
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
        notificationsAuthorized = await notifier.isAuthorized()
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
            presentedError = AssistantError.noTopic.localizedDescription
            return
        }
        if activities.contains(where: {
            $0.topicKey == topic.topicKey && $0.type == .pull && !$0.status.isTerminal
        }) {
            panelRoute = .activity
            return
        }
        guard activeTaskCount < 50 else {
            presentedError = "The task queue is full. Cancel or wait for an existing task."
            return
        }

        let configuration = selectedConfiguration
        let record = WorkRecord(
            type: .pull,
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            title: topic.title,
            url: topic.url,
            provider: settings.selectedProvider,
            model: configuration.model
        )
        activities.insert(record, at: 0)
        save()
        launch(recordID: record.id)
    }

    func sendChat() {
        let question = chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let topic = currentTopic,
              var session = sessions[topic.topicKey],
              !session.source.isEmpty
        else {
            presentedError = "Pull the post and responses or create a summary before asking a follow-up question."
            return
        }
        if activities.contains(where: {
            $0.topicKey == topic.topicKey && $0.type == .chat && !$0.status.isTerminal
        }) {
            presentedError = "Wait for the current answer or cancel it in Manage."
            return
        }
        guard activeTaskCount < 50 else {
            presentedError = "The task queue is full. Cancel or wait for an existing task."
            return
        }

        let userMessage = ChatMessage(role: .user, content: question)
        session.history.append(userMessage)
        session.history = Array(session.history.suffix(100))
        session.chatUpdatedAt = Date()
        session.updatedAt = Date()
        sessions[topic.topicKey] = session
        chatDraft = ""

        let configuration = selectedConfiguration
        let record = WorkRecord(
            type: .chat,
            siteURL: topic.siteURL,
            topicID: topic.topicID,
            title: topic.title,
            url: topic.url,
            question: question,
            provider: settings.selectedProvider,
            model: configuration.model
        )
        activities.insert(record, at: 0)
        save()
        launch(recordID: record.id)
    }

    func cancel(record: WorkRecord) {
        runningTasks[record.id]?.cancel()
        runningTasks.removeValue(forKey: record.id)
        summaryStreams.removeValue(forKey: record.id)
        chatStreams.removeValue(forKey: record.id)
        Task {
            await limiter.cancel(workID: record.id)
        }
        mutateRecord(record.id) {
            $0.status = .cancelled
            $0.phase = "cancelled"
            $0.statusText = "Cancelled"
            $0.completedAt = Date()
        }
        if record.type == .agent {
            mutateAgentRun(for: record) {
                $0.status = .cancelled
                $0.completedAt = Date()
            }
        }
        save()
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
        browser.load(record.url)
        panelRoute = .topic
    }

    func open(session: TopicSession) {
        browser.load(session.url)
        panelRoute = .topic
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
            presentedError = "Cancel this topic’s active tasks before deleting it."
            return
        }
        sessions.removeValue(forKey: topicKey)
        save()
    }

    func clearChat() {
        guard let topicKey = currentTopic?.topicKey, var session = sessions[topicKey] else {
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
              var session = sessions[topicKey],
              let index = session.history.firstIndex(where: { $0.id == messageID }),
              session.history[index].role == .user
        else {
            return
        }
        chatDraft = session.history[index].content
        session.history = Array(session.history[..<index])
        session.chatUpdatedAt = session.history.isEmpty ? nil : Date()
        session.updatedAt = Date()
        sessions[topicKey] = session
        save()
    }

    func activateFavorite(_ favorite: FavoriteModel) {
        settings.selectedProvider = favorite.provider
        var configuration = settings.configuration(for: favorite.provider)
        configuration.model = favorite.model
        settings.setConfiguration(configuration, for: favorite.provider)
        saveSettings()
    }

    func addCurrentFavorite() {
        let model = selectedConfiguration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        let favorite = FavoriteModel(provider: settings.selectedProvider, model: model)
        if !settings.favoriteModels.contains(favorite) {
            settings.favoriteModels.append(favorite)
            settings.favoriteModels = Array(settings.favoriteModels.prefix(30))
            saveSettings()
        }
    }

    func removeFavorite(_ favorite: FavoriteModel) {
        settings.favoriteModels.removeAll { $0 == favorite }
        saveSettings()
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
            self?.flushPendingSaves()
        }
    }

    /// Writes coalesced settings edits now (scene inactive/background, tests).
    func flushPendingSaves() {
        guard settingsSaveTask != nil else { return }
        save()
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
                presentedError = error.localizedDescription
                return false
            }
        }
        return true
    }

    /// Reacts to any settings edit (Settings, favorites, onboarding, reset).
    private func settingsDidChange(from old: AppSettings) {
        guard old != settings else { return }
        let oldConfiguration = old.configuration(for: old.selectedProvider)
        let newConfiguration = selectedConfiguration
        let providerChanged = old.selectedProvider != settings.selectedProvider
        let endpointChanged = providerChanged || oldConfiguration.baseURL != newConfiguration.baseURL
        if endpointChanged || oldConfiguration.apiKey != newConfiguration.apiKey {
            // Results of a test or model load for the old configuration are stale.
            connectionTestGeneration &+= 1
            modelDiscoveryGeneration &+= 1
            settingsStatus = ""
        }
        if endpointChanged, !discoveredModels.isEmpty { discoveredModels = [] }
        if needsProviderSetup, isProviderReady { needsProviderSetup = false }
        contentBlockingSettingsDidChange(from: old)
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
        settings = fresh
        discoveredModels = []
        settingsStatus = ""
        save()
    }

    /// Ends the walkthrough (first run or replay). Browsing, the Assistant,
    /// and running work are left as they are.
    func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        save()
    }

    /// Loads the selected provider's models into `discoveredModels`. A result
    /// that arrives after the provider, base URL, or key changed (or after a
    /// newer load started) is dropped and reported as `.stale`.
    @discardableResult
    func discoverModels() async -> ProviderCheckResult {
        modelDiscoveryGeneration &+= 1
        let generation = modelDiscoveryGeneration
        let provider = settings.selectedProvider
        let configuration = selectedConfiguration
        settingsStatus = "Loading models…"
        do {
            let models = try await aiService.discoverModels(configuration: configuration, provider: provider)
            guard generation == modelDiscoveryGeneration else { return .stale }
            discoveredModels = models
            settingsStatus = "Loaded \(models.count) models"
            return .success
        } catch {
            guard generation == modelDiscoveryGeneration else { return .stale }
            settingsStatus = "Model loading failed"
            return .failure(error.localizedDescription)
        }
    }

    /// Tests the selected provider. A result for a configuration the user has
    /// since changed (or superseded by a newer test) is `.stale` and leaves
    /// the status alone.
    @discardableResult
    func testConnection() async -> ProviderCheckResult {
        connectionTestGeneration &+= 1
        let generation = connectionTestGeneration
        let provider = settings.selectedProvider
        let configuration = selectedConfiguration
        settingsStatus = "Testing connection…"
        do {
            try await aiService.testConnection(configuration: configuration, provider: provider)
            guard generation == connectionTestGeneration else { return .stale }
            settingsStatus = "Connection successful"
            return .success
        } catch {
            guard generation == connectionTestGeneration else { return .stale }
            settingsStatus = "Connection failed"
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
        session.source = "Sample forum source for UI verification."
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
        pageContext = PageContext(
            url: topic.url,
            isDiscourse: true,
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
        currentForum = seed.currentForum
        pageContext = seed.pageContext
        selectedAgentRunID = seed.agentRuns.first?.id
        // No automatic watch check (network, summary refresh) for the seed.
        lastWatchCheck = Date()
    }

    /// Advances a seeded running record (DEBUG sample only), the way a real
    /// job would: progress moves forward only.
    func debugAdvanceSample(recordID: UUID, progress: Double, statusText: String? = nil) {
        guard activities.first(where: { $0.id == recordID })?.status == .running else { return }
        mutateRecord(recordID) {
            $0.progress = WorkProgress.advanced(from: $0.progress, to: progress)
            if let statusText { $0.statusText = statusText }
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
        recent.phase = "completed"
        recent.statusText = "Completed"
        recent.progress = 1
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
        runningTasks[recordID] = Task { [weak self] in
            guard let self else { return }
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
                Task { await self.limiter.release(topicID: record.topicKey) }
            }
            guard !Task.isCancelled else { return }
            await self.run(recordID: recordID)
        }
    }

    /// The settings a job runs with, taken when it starts (not when it was
    /// queued): the provider, model and key selected at that moment, and the
    /// limits and instructions then. Edits made while it runs apply to the
    /// next job. Agent step and topic budgets can still be lowered mid-run.
    private func runSettings(for record: WorkRecord) -> RunSettings {
        RunSettings(
            provider: settings.selectedProvider,
            configuration: RunSettings.resolvingAppleIntelligence(
                selectedConfiguration,
                provider: settings.selectedProvider,
                status: appleIntelligenceStatus
            ),
            batchLimit: record.batchLimit ?? settings.summaryBatchLimit,
            contextLimit: settings.forumContextLimit,
            topicInstructions: effectiveInstructions(for: record.topicKey),
            globalInstructions: settings.systemPrompt,
            agentMaxSteps: settings.agentMaxSteps,
            agentMaxTopicReads: settings.agentMaxTopicReads,
            agentReadLimit: settings.agentReadLimit
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

    private func run(recordID: UUID) async {
        guard var record = activities.first(where: { $0.id == recordID }),
              record.status == .queued
        else {
            return
        }
        let context = runSettings(for: record)
        // Recorded so Manage and the saved summary show what actually ran.
        record.provider = context.provider
        record.model = context.configuration.model
        mutateRecord(recordID) {
            $0.status = .running
            $0.phase = "fetching"
            $0.statusText = "Reading forum responses…"
            // A restored record starts over; progress then only moves forward.
            $0.progress = nil
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
            if record.type != .pull { try context.requireReadyProvider() }
            switch record.type {
            case .summary:
                try await runSummary(recordID: recordID, record: record, context: context)
            case .pull:
                try await runPull(recordID: recordID, record: record)
            case .chat:
                try await runChat(recordID: recordID, record: record, context: context)
            case .agent:
                try await runAgent(recordID: recordID, record: record, context: context)
            }
            // Finished after it was cancelled (a provider that ignores
            // cancellation): it stays cancelled.
            try ensureLive(recordID)
            mutateRecord(recordID) {
                $0.status = .completed
                $0.phase = "completed"
                $0.statusText = "Completed"
                $0.progress = 1
                $0.completedAt = Date()
            }
        } catch is CancellationError {
            mutateRecord(recordID) {
                $0.status = .cancelled
                $0.phase = "cancelled"
                $0.statusText = "Cancelled"
                $0.completedAt = Date()
            }
            if record.type == .agent {
                mutateAgentRun(for: record) {
                    $0.status = .cancelled
                    $0.completedAt = Date()
                }
            }
        } catch where !isLive(recordID) {
            // Cancelled or deleted meanwhile; its request failing is expected.
            if activities.first(where: { $0.id == recordID })?.status == .running {
                mutateRecord(recordID) {
                    $0.status = .cancelled
                    $0.phase = "cancelled"
                    $0.statusText = "Cancelled"
                    $0.completedAt = Date()
                }
            }
        } catch {
            mutateRecord(recordID) {
                $0.status = .failed
                $0.phase = "failed"
                $0.statusText = "Failed"
                $0.error = error.localizedDescription
                $0.completedAt = Date()
            }
            if record.type == .agent {
                mutateAgentRun(for: record) {
                    $0.status = .failed
                    $0.error = error.localizedDescription
                    $0.completedAt = Date()
                }
            }
            presentedError = error.localizedDescription
        }
        runningTasks.removeValue(forKey: recordID)
        summaryStreams.removeValue(forKey: recordID)
        chatStreams.removeValue(forKey: recordID)
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

    private func runPull(recordID: UUID, record: WorkRecord) async throws {
        var session = sessions[record.topicKey] ?? TopicSession(
            siteURL: record.siteURL,
            topicID: record.topicID,
            url: record.url,
            title: record.title
        )
        let cookies = await browser.cookieHeader(forSite: record.siteURL)
        let fetch = try await forumService.fetchTopic(
            siteURL: record.siteURL,
            topicID: record.topicID,
            cachedPages: session.rawPages,
            knownTotalPosts: session.totalPosts,
            cookieHeader: cookies,
            resourceLoader: webViewResourceLoader
        ) { progress in
            await self.updateFetchProgress(recordID: recordID, progress: progress)
        }

        // Cancelled (or its forum's data deleted) while the page fetch was
        // finishing: do not write the session back.
        try ensureLive(recordID)
        session = sessions[record.topicKey] ?? session
        session.source = fetch.content
        session.rawPages = fetch.rawPages
        session.totalPosts = fetch.totalPosts
        session.lastCheckedAt = Date()
        session.updatedAt = Date()
        sessions[record.topicKey] = session
        save()
    }

    private func runSummary(recordID: UUID, record: WorkRecord, context: RunSettings) async throws {
        var session = sessions[record.topicKey] ?? TopicSession(
            siteURL: record.siteURL,
            topicID: record.topicID,
            url: record.url,
            title: record.title
        )
        let cookies = await browser.cookieHeader(forSite: record.siteURL)
        let fetch = try await forumService.fetchTopic(
            siteURL: record.siteURL,
            topicID: record.topicID,
            cachedPages: session.rawPages,
            knownTotalPosts: session.totalPosts,
            cookieHeader: cookies,
            resourceLoader: webViewResourceLoader
        ) { progress in
            await self.updateFetchProgress(recordID: recordID, progress: progress)
        }

        // Cancelled (or its forum's data deleted) while the page fetch was
        // finishing: do not write the session back.
        try ensureLive(recordID)
        session = sessions[record.topicKey] ?? session
        session.source = fetch.content
        session.rawPages = fetch.rawPages
        session.totalPosts = fetch.totalPosts
        session.lastCheckedAt = Date()
        session.updatedAt = Date()
        sessions[record.topicKey] = session
        save()

        if fetch.unchanged,
           session.hasSummary,
           session.summaryPostCount == fetch.totalPosts {
            mutateRecord(recordID) {
                $0.statusText = "Saved summary already includes every reply."
            }
            return
        }

        mutateRecord(recordID) {
            $0.phase = "generating"
            $0.statusText = fetch.newPosts > 0 && session.hasSummary
                ? "Updating summary with \(fetch.newPosts) new posts…"
                : "Generating summary…"
            // The fetch filled its share of the bar; each summary step fills the rest.
            $0.progress = WorkProgress.advanced(from: $0.progress, to: WorkProgress.summary(ai: 0))
        }
        summaryStreams[recordID] = ""
        let progress = summaryProgressOutput(recordID: recordID)
        defer { progress.cancel() }
        let feed = SummaryProgressFeed(output: progress, map: WorkProgress.summary(ai:))
        let summary = try await aiService.generateSummary(
            content: fetch.content,
            configuration: context.configuration,
            provider: context.provider,
            customPrompt: context.topicInstructions,
            batchLimit: context.batchLimit,
            onDelta: { delta in
                // Deltas of a cancelled job must not recreate its stream.
                guard self.isLive(recordID) else { return }
                self.summaryStreams[recordID, default: ""] += delta
            },
            onProgress: { feed.handle($0) }
        )

        try ensureLive(recordID)
        session = sessions[record.topicKey] ?? session
        session.summary = summary
        session.summaryPostCount = fetch.totalPosts
        session.provider = context.provider
        session.model = context.configuration.model
        session.summaryUpdatedAt = Date()
        session.updatedAt = Date()
        sessions[record.topicKey] = session
    }

    private func runChat(recordID: UUID, record: WorkRecord, context: RunSettings) async throws {
        guard var session = sessions[record.topicKey],
              !session.source.isEmpty
        else {
            throw AssistantError.missingConfiguration(
                "Pull the post and responses or create a summary before chatting."
            )
        }

        let cookies = await browser.cookieHeader(forSite: record.siteURL)
        let fetch = try await forumService.fetchTopic(
            siteURL: record.siteURL,
            topicID: record.topicID,
            cachedPages: session.rawPages,
            knownTotalPosts: session.totalPosts,
            cookieHeader: cookies,
            resourceLoader: webViewResourceLoader
        ) { progress in
            await self.updateFetchProgress(recordID: recordID, progress: progress)
        }
        // Cancelled (or its forum's data deleted) while the page fetch was
        // finishing: do not write the session back.
        try ensureLive(recordID)
        session = sessions[record.topicKey] ?? session
        session.source = fetch.content
        session.rawPages = fetch.rawPages
        session.totalPosts = fetch.totalPosts
        session.lastCheckedAt = Date()
        session.updatedAt = Date()
        sessions[record.topicKey] = session

        mutateRecord(recordID) {
            $0.phase = "generating"
            $0.statusText = "Answering follow-up question…"
            // How long an answer takes is unknowable: indeterminate until done.
            $0.progress = nil
        }
        // Cleared or edited while the topic was being read: nothing to ask.
        guard session.history.last(where: { $0.role == .user })?.content == record.question else {
            mutateRecord(recordID) { $0.statusText = "Chat changed; answer discarded" }
            return
        }
        chatStreams[recordID] = ""
        let answer = try await aiService.answer(
            source: session.source,
            summary: session.summary,
            history: session.history,
            contextLimit: context.contextLimit,
            customPrompt: context.topicInstructions,
            configuration: context.configuration,
            provider: context.provider,
            onDelta: { delta in
                guard self.isLive(recordID) else { return }
                self.chatStreams[recordID, default: ""] += delta
            },
            summaryIsStale: session.hasStaleSummary
        )

        try ensureLive(recordID)
        session = sessions[record.topicKey] ?? session
        // The chat was cleared, or the question edited, while it was being
        // answered: the answer no longer belongs to the conversation.
        guard session.history.last(where: { $0.role == .user })?.content == record.question else {
            mutateRecord(recordID) { $0.statusText = "Chat changed; answer discarded" }
            return
        }
        session.history.append(ChatMessage(role: .assistant, content: answer))
        session.history = Array(session.history.suffix(100))
        session.chatUpdatedAt = Date()
        session.updatedAt = Date()
        sessions[record.topicKey] = session
    }

    // MARK: Agent runner

    private func agentRunID(for record: WorkRecord) -> UUID? {
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
        run.status = .running
        run.error = ""
        storeAgentRun(run)
        mutateRecord(recordID) {
            $0.phase = "planning"
            $0.statusText = "Planning…"
            $0.progress = WorkProgress.agent(completedSteps: 0, maxSteps: context.agentMaxSteps)
        }

        let configuration = context.configuration
        let forumName = forum(for: run.siteURL)?.displayName
            ?? ForumSite.displayName(siteURL: run.siteURL, name: nil)
        let system = AgentPrompt.system(
            forumName: forumName,
            siteURL: run.siteURL,
            maxSteps: context.agentMaxSteps,
            maxTopicReads: context.agentMaxTopicReads,
            customInstructions: context.globalInstructions
        )
        let isFollowUp = !run.followUps.isEmpty && run.followUps.last?.role == .user
        var stepsUsed = 0

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
            let action = try await planner.nextAction(
                system: system,
                transcript: run.transcript,
                configuration: configuration,
                provider: context.provider
            )
            try ensureLive(recordID)
            stepsUsed += 1
            run.transcript.append(ChatMessage(role: .assistant, content: Self.encode(action)))
            var step = AgentStep(tool: action.tool, arguments: action.arguments, thought: action.thought)
            mutateRecord(recordID) {
                $0.phase = "running"
                $0.statusText = "Step \(stepsUsed): \(Self.describe(action))"
                $0.progress = WorkProgress.advanced(
                    from: $0.progress,
                    to: WorkProgress.agent(completedSteps: stepsUsed - 1, maxSteps: maxSteps, within: 0.1)
                )
            }

            if action.tool == AgentPrompt.finalAnswerTool || outOfBudget {
                let answer = action.arguments["answer"]?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? action.thought
                step.outcome = action.tool == AgentPrompt.finalAnswerTool
                    ? "Answered"
                    : "Stopped at the step budget"
                step.finishedAt = Date()
                run.steps.append(step)
                run.answer = answer
                if isFollowUp {
                    run.followUps.append(ChatMessage(role: .assistant, content: answer))
                } else {
                    run.initialAnswer = answer
                }
                run.status = .completed
                run.completedAt = Date()
                storeAgentRun(run)
                save()
                return
            }

            let completedSteps = stepsUsed - 1
            do {
                let (outcome, observation) = try await executeAgentTool(
                    action,
                    run: &run,
                    recordID: recordID,
                    context: context,
                    stepProgress: { within in
                        WorkProgress.agent(completedSteps: completedSteps, maxSteps: maxSteps, within: within)
                    }
                )
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
                        result: error.localizedDescription,
                        isError: true
                    )
                )
            }
            try ensureLive(recordID)
            step.finishedAt = Date()
            run.steps.append(step)
            storeAgentRun(run)
            mutateRecord(recordID) {
                $0.progress = WorkProgress.advanced(
                    from: $0.progress,
                    to: WorkProgress.agent(completedSteps: stepsUsed, maxSteps: maxSteps)
                )
            }
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
        run: inout AgentRun,
        recordID: UUID,
        context: RunSettings,
        stepProgress: @escaping @Sendable (_ within: Double) -> Double
    ) async throws -> (String, String) {
        let configuration = context.configuration
        let provider = context.provider
        let siteURL = run.siteURL
        let cookies = await browser.cookieHeader(forSite: siteURL)
        let loader = webViewResourceLoader

        switch action.tool {
        case "search_forum":
            guard let query = action.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !query.isEmpty
            else {
                throw AgentError.missingArgument("query")
            }
            let listings = try await forumService.search(
                siteURL: siteURL,
                query: query,
                cookieHeader: cookies,
                resourceLoader: loader
            )
            return ("\(listings.count) topics", AgentPrompt.format(listings: listings))

        case "list_latest":
            let listings = try await forumService.latestTopics(
                siteURL: siteURL,
                cookieHeader: cookies,
                resourceLoader: loader
            )
            return ("\(listings.count) topics", AgentPrompt.format(listings: listings, limit: 30))

        case "read_topic":
            let session = try await readTopicForAgent(
                action, run: &run, recordID: recordID, context: context,
                progress: { stepProgress(0.1 + 0.8 * $0) }
            )
            let bounded = PromptBuilder.boundedForumContext(
                session.source,
                limit: context.agentReadLimit
            )
            return (
                "Read \(session.totalPosts ?? 0) posts",
                "Topic: \(session.title)\nURL: \(session.url.absoluteString)\n\n\(bounded)"
            )

        case "summarize_topic":
            var session = try await readTopicForAgent(
                action, run: &run, recordID: recordID, context: context,
                progress: { stepProgress(0.1 + 0.3 * $0) }
            )
            mutateRecord(recordID) {
                $0.statusText = "Summarizing \(session.title)…"
            }
            let progress = summaryProgressOutput(recordID: recordID, keepsStatusText: true)
            defer { progress.cancel() }
            let feed = SummaryProgressFeed(output: progress) { stepProgress(0.4 + 0.55 * $0) }
            let summary = try await aiService.generateSummary(
                content: session.source,
                configuration: configuration,
                provider: provider,
                customPrompt: PromptBuilder.effectiveInstructions(
                    topic: session.instructions,
                    global: context.globalInstructions
                ),
                batchLimit: context.batchLimit,
                onDelta: { _ in },
                onProgress: { feed.handle($0) }
            )
            try ensureLive(recordID)
            session = sessions[session.topicKey] ?? session
            session.summary = summary
            session.summaryPostCount = session.totalPosts
            session.provider = provider
            session.model = configuration.model
            session.summaryUpdatedAt = Date()
            session.updatedAt = Date()
            sessions[session.topicKey] = session
            return (
                "Summarized \(session.totalPosts ?? 0) posts",
                "Summary of \(session.title) (\(session.url.absoluteString)):\n\n\(summary)"
            )

        case "saved_summaries":
            let query = action.arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let saved = sessions.values
                .filter { $0.hasSummary && $0.siteURL == siteURL }
                .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                    || $0.summary.localizedCaseInsensitiveContains(query) }
                .sorted { $0.updatedAt > $1.updatedAt }
            guard !saved.isEmpty else { return ("None found", "No saved summaries match.") }
            let text = saved.prefix(query.isEmpty ? 40 : 6).map { session in
                var line = "- id \(session.topicID): \(session.title) — "
                    + "\(session.summaryPostCount ?? session.totalPosts ?? 0) posts — "
                    + session.url.absoluteString
                if !query.isEmpty { line += "\n\(session.summary.prefix(3_000))" }
                return line
            }.joined(separator: "\n\n")
            return ("\(saved.count) saved", text)

        case "watch_topic":
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
                let overview = try await forumService.fetchOverview(
                    siteURL: siteURL,
                    topicID: topicID,
                    cookieHeader: cookies,
                    resourceLoader: loader
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
            return ("Watching", "Topic \(topicID) is now on the watch list.")

        default:
            throw AgentError.unknownTool(action.tool)
        }
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
        run: inout AgentRun,
        recordID: UUID,
        context: RunSettings,
        progress: @escaping @Sendable (_ fetched: Double) -> Double
    ) async throws -> TopicSession {
        let topicID = try requiredTopicID(action)
        if !run.topicIDs.contains(topicID) {
            let limit = min(context.agentMaxTopicReads, settings.agentMaxTopicReads)
            guard run.topicIDs.count < limit else {
                throw AgentError.topicBudgetExhausted(limit)
            }
        }
        let siteURL = run.siteURL
        let topicKey = TopicIdentity.key(siteURL: siteURL, topicID: topicID)
        let cookies = await browser.cookieHeader(forSite: siteURL)
        var session: TopicSession
        if let existing = sessions[topicKey] {
            session = existing
        } else {
            let overview = try await forumService.fetchOverview(
                siteURL: siteURL,
                topicID: topicID,
                cookieHeader: cookies,
                resourceLoader: webViewResourceLoader
            )
            session = TopicSession(
                siteURL: siteURL,
                topicID: topicID,
                url: overview.url,
                title: overview.title
            )
        }
        mutateRecord(recordID) {
            $0.statusText = "Reading \(session.title)…"
        }
        let fetch = try await forumService.fetchTopic(
            siteURL: siteURL,
            topicID: topicID,
            cachedPages: session.rawPages,
            knownTotalPosts: session.totalPosts,
            cookieHeader: cookies,
            resourceLoader: webViewResourceLoader
        ) { fetchProgress in
            await self.advanceProgress(recordID: recordID, to: progress(fetchProgress.fraction))
        }
        // Cancelled (or its forum's data deleted) while the page fetch was
        // finishing: do not write the session back.
        try ensureLive(recordID)
        session = sessions[topicKey] ?? session
        session.source = fetch.content
        session.rawPages = fetch.rawPages
        session.totalPosts = fetch.totalPosts
        session.lastCheckedAt = Date()
        session.updatedAt = Date()
        sessions[topicKey] = session
        if !run.topicIDs.contains(topicID) {
            run.topicIDs.append(topicID)
        }
        return session
    }

    private func updateFetchProgress(recordID: UUID, progress: ForumFetchProgress) {
        // A late page report of a cancelled job must not touch its record.
        guard isLive(recordID) else { return }
        mutateRecord(recordID) {
            $0.phase = "fetching"
            $0.statusText = progress.message
            $0.progress = WorkProgress.advanced(
                from: $0.progress,
                to: WorkProgress.fetch(progress.fraction, type: $0.type)
            )
        }
    }

    /// Moves a running job's determinate progress forward (never back).
    private func advanceProgress(recordID: UUID, to fraction: Double) {
        guard isLive(recordID) else { return }
        mutateRecord(recordID) {
            $0.progress = WorkProgress.advanced(from: $0.progress, to: fraction)
        }
    }

    /// Throttled progress writes for a summary step; ignored once the job is
    /// no longer live. `keepsStatusText` leaves the caller's status (agent steps).
    private func summaryProgressOutput(recordID: UUID, keepsStatusText: Bool = false) -> ThrottledProgress {
        ThrottledProgress { [weak self] fraction, statusText in
            guard let self, self.isLive(recordID) else { return }
            self.mutateRecord(recordID) {
                $0.progress = WorkProgress.advanced(from: $0.progress, to: fraction)
                if let statusText, !keepsStatusText { $0.statusText = statusText }
            }
        }
    }

    private func mutateRecord(_ id: UUID, mutation: (inout WorkRecord) -> Void) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        mutation(&activities[index])
        activities[index].updatedAt = Date()
    }

    private func pruneSessions() {
        let unkept = sessions.values
            .filter { $0.hasSummary && !$0.kept }
            .sorted { $0.updatedAt > $1.updatedAt }
        for session in unkept.dropFirst(40) {
            sessions.removeValue(forKey: session.topicKey)
        }
        // Pruned, not deleted: other devices keep their copies.
        cloudSync.notePruned(kind: .session, ids: unkept.dropFirst(40).map(\.topicKey))
    }

    /// Writes the snapshot (and any changed API keys) now. Data changes save
    /// at once; settings edits are coalesced through `saveSettings()`.
    private func save() {
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
        do {
            try store.save(snapshot)
        } catch {
            presentedError = "Unable to save app data: \(error.localizedDescription)"
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
        if self.sessions != sessions { self.sessions = sessions }
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
            if let current = currentForum, forum(for: current.siteURL) == nil {
                currentForum = pageContext.siteURL.flatMap { forum(for: $0) } ?? Self.startForum(in: forums)
                if agentSiteURL == current.siteURL { agentSiteURL = nil }
                if browser.homeSiteURL == current.siteURL, pageContext.siteURL != current.siteURL {
                    browser.homeSiteURL = currentForum?.siteURL
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
}

/// What a job runs with, captured when it starts (see `AppModel.runSettings`).
/// In memory only: the key is never written into a record.
struct RunSettings {
    var provider: AIProvider
    var configuration: ProviderConfiguration
    var batchLimit: Int
    var contextLimit: Int
    /// The topic's own instructions, else the global ones.
    var topicInstructions: String
    var globalInstructions: String
    var agentMaxSteps: Int
    var agentMaxTopicReads: Int
    var agentReadLimit: Int

    /// Fails with a clear message when the provider was disconnected (key
    /// deleted, settings reset) between queueing and starting.
    func requireReadyProvider() throws {
        if configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AssistantError.missingConfiguration("Choose a model in Settings › AI provider.")
        }
        if provider.requiresAPIKey,
           configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AssistantError.missingConfiguration(
                "\(provider.displayName) isn’t connected. Add an API key in Settings › AI provider."
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
