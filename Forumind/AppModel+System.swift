import AppIntents
import Foundation

// MARK: - System entry points (System/)
//
// - `perform(_:)`                 an App Intent's action (SystemEntry.swift)
// - `openTopic(topicKey:)`        Spotlight results, Siri suggestions, Open Topic
// - `requestedSettingsPage`       a Settings page RootView presents (AppModel.swift)
// - Spotlight: `spotlightDataDidChange()` after any session or forum change;
//   `spotlightEntries` is what should be indexed (nil while the switch is off)
// - Siri suggestions: `topicActivityDidChange(_:)` donates the open topic

extension AppModel: SystemEntryRouting {
    /// An outside request may start AI work only once the walkthrough and
    /// the Terms of Use are done; before that it only opens the app.
    var acceptsSystemWork: Bool {
        settings.hasCompletedOnboarding && settings.hasAcceptedCurrentTerms
    }

    func perform(_ action: SystemEntryAction) {
        switch action {
        case .summarize(let url):
            // The share extension's path: open the topic, then summarize
            // it once the page is detected (or ask for a provider).
            handle(IncomingLinkRequest(url: url, action: .summary), autoRun: acceptsSystemWork)
        case .ask(let siteURL, let question):
            ask(question, siteURL: siteURL)
        case .openToday:
            showsTodayPage = true
        case .playToday:
            podcast.refresh()
            if podcast.episode?.entries.contains(where: \.isReady) == true {
                podcast.playEpisode()
            } else {
                showsTodayPage = true
            }
        case .startVoice:
            startVoiceFromSystem()
        case .openTopic(let topicKey):
            openTopic(topicKey: topicKey)
        }
    }

    /// Ask a Forum: Ask the forum on that forum, its page in the browser.
    private func ask(_ question: String, siteURL: String) {
        if let forum = forum(for: siteURL), pageContext.siteURL != forum.siteURL {
            openForum(forum)
        }
        agentSiteURL = siteURL
        assistantMode = .agent
        panelRoute = .topic
        presentAssistant = true
        guard acceptsSystemWork, isProviderReady(for: .agent) else {
            // Kept as the draft: the user starts it once ready.
            agentGoalDraft = question
            if !isProviderReady(for: .agent) { needsProviderSetup = .agent }
            return
        }
        startAgentRun(goal: question, siteURL: siteURL)
    }

    /// Voice with its consent gate (`VoiceController.start()` asks once per
    /// provider); without a Gemini or Vertex key, Settings › Voice.
    private func startVoiceFromSystem() {
        guard voiceProvider != nil else {
            requestedSettingsPage = .voice
            return
        }
        voice.start()
        switch voice.startFailure {
        case .noKey, .noVertexProject:
            voice.dismiss()
            requestedSettingsPage = .voice
        default:
            break
        }
    }

    /// Opens a saved topic at the page it was last read at (its URL keeps
    /// the post number Discourse showed then).
    func openTopic(topicKey: String) {
        guard let session = sessions[topicKey] else { return }
        open(session: session)
    }

    var topicEntities: [TopicEntity] {
        (spotlightEntriesIgnoringSwitch ?? []).map(TopicEntity.init(entry:))
    }

    // MARK: Spotlight

    static func makeSpotlightIndexer(index: SpotlightIndexing?, store: PersistentStore) -> SpotlightIndexer {
        if let index {
            return SpotlightIndexer(index: index, baseline: InMemorySpotlightBaseline())
        }
        // Only the app's own store feeds the real index: never tests,
        // previews or the screenshot samples.
        guard store.usesDefaultLocation, !isRunningTests, !AssistantDebug.isActive else {
            return SpotlightIndexer(index: DisabledSpotlightIndex(), baseline: InMemorySpotlightBaseline())
        }
        return SpotlightIndexer(index: SystemSpotlightIndex(), baseline: UserDefaultsSpotlightBaseline())
    }

    static func makeTopicActivityDonor(store: PersistentStore) -> TopicActivityDonating {
        guard store.usesDefaultLocation, !isRunningTests, !AssistantDebug.isActive else {
            return DisabledTopicActivityDonor()
        }
        return SystemTopicActivityDonor()
    }

    /// The unit-test host: XCTest is loaded, or about to be (the test
    /// runner sets the configuration path before launch).
    nonisolated static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// What Spotlight should hold now; nil while the switch is off.
    var spotlightEntries: [SpotlightEntry]? {
        settings.spotlightEnabled ? spotlightEntriesIgnoringSwitch : nil
    }

    private var spotlightEntriesIgnoringSwitch: [SpotlightEntry]? {
        SpotlightCatalog.entries(sessions: Array(sessions.values), forums: forums)
    }

    /// Sessions or forums changed (any path: deletes, clear all, removing a
    /// forum, iCloud sync): reconcile once things settle.
    func spotlightDataDidChange() {
        spotlight.schedule { [weak self] in self?.spotlightEntries }
    }

    /// Reset settings: drop the index and build it again.
    func resetSpotlightIndex() {
        spotlight.deleteAll()
        spotlightDataDidChange()
    }

    // MARK: Settings

    func systemSettingsDidChange(from old: AppSettings) {
        if old.spotlightEnabled != settings.spotlightEnabled {
            if settings.spotlightEnabled {
                spotlightDataDidChange()
            } else {
                // Off: the app's whole index goes.
                spotlight.deleteAll()
            }
        }
        if old.donatesTopicActivity != settings.donatesTopicActivity {
            if settings.donatesTopicActivity {
                donatedTopicKey = nil
                topicActivityDidChange(currentTopic)
            } else {
                donatedTopicKey = nil
                topicActivityDonor.deleteAll()
            }
        }
    }

    // MARK: Siri suggestions

    /// The open topic changed: offer it to Siri suggestions (once per
    /// visit), or step down when no topic is open.
    func topicActivityDidChange(_ topic: ForumTopic?) {
        guard settings.donatesTopicActivity else { return }
        guard let topic else {
            if donatedTopicKey != nil {
                donatedTopicKey = nil
                topicActivityDonor.resign()
            }
            return
        }
        guard donatedTopicKey != topic.topicKey else { return }
        donatedTopicKey = topic.topicKey
        let forumName = forum(for: topic.siteURL)?.displayName ?? pageContext.forumName
        topicActivityDonor.donate(topicKey: topic.topicKey, title: topic.title, forumName: forumName, url: topic.url)
    }

    // MARK: Shortcuts

    /// New or renamed forums: Siri learns the names for "Ask … in Forumind".
    func forumsDidChangeForShortcuts() {
        guard !Self.isRunningTests else { return }
        ForumindShortcuts.updateAppShortcutParameters()
    }
}
