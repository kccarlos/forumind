import Foundation

// MARK: - Live voice (Forumind/Voice)
//
// AppModel is the voice layer's navigator: the tools call the navigation
// layer (AppModel+Navigation.swift) and the silent context reads the page.
// No voice UI yet (plan B7); `makeVoiceSession` is where it will start one.

extension AppModel: VoiceNavigator {
    /// The text of every post on screen, without hidden ones.
    func readVisible() async -> BrowseResult {
        guard let ref = currentTopicRef else {
            return BrowseResult(status: .unavailable, shown: "No topic is open.")
        }
        let rules = browser.moderationRules
        let posts = await browser.postsOnScreen().filter {
            !rules.hidesUser($0.username, siteURL: ref.siteURL)
                && !rules.hidesPost($0.number, siteURL: ref.siteURL, topicID: ref.topicID)
        }
        guard !posts.isEmpty else {
            return BrowseResult(status: .notFound, shown: "No posts are on screen.")
        }
        var texts: [String] = []
        for post in posts.prefix(4) {
            if case .shown(let text) = await postText(post.number, in: ref, facts: topicOverviews[ref.topicKey]?.facts) {
                texts.append(BrowseText.content(of: text))
            }
        }
        let numbers = posts.map { "\($0.number)" }.joined(separator: ", ")
        return BrowseResult(status: .read, shown: "Posts \(numbers) on screen", content: texts.joined(separator: "\n\n"))
    }

    var researchProgress: String? {
        guard isResearching, let run = agentRuns.first(where: { $0.status == .running }),
              let step = run.steps.last
        else {
            return nil
        }
        let detail = step.arguments.values.sorted().first.map { " \($0)" } ?? ""
        let outcome = step.outcome.isEmpty ? "" : ": \(step.outcome)"
        return BrowseText.oneLine("Step \(run.steps.count), \(step.tool)\(detail)\(outcome)", limit: 200)
    }

    func voiceTopicBrief() async -> VoiceTopicBrief? {
        guard let ref = currentTopicRef else { return nil }
        let overview = await topicOverview(siteURL: ref.siteURL, topicID: ref.topicID)
        let facts = overview?.facts
        var opening: String?
        if let facts, case .shown(let text) = await postText(1, in: ref, facts: facts) {
            opening = text.text
        }
        let rules = browser.moderationRules
        let top = (facts?.posts ?? [])
            .filter { ($0.likeCount ?? 0) > 0 && !rules.hidesUser($0.username, siteURL: ref.siteURL) }
            .sorted { ($0.likeCount ?? 0) > ($1.likeCount ?? 0) }
            .prefix(5)
            .map { VoiceTopicBrief.Post(number: $0.number, username: $0.username, likes: $0.likeCount) }
        let solution = facts?.acceptedAnswer.map { answer in
            VoiceTopicBrief.Post(
                number: answer.postNumber,
                username: answer.username ?? facts?.posts.first { $0.number == answer.postNumber }?.username ?? "someone"
            )
        }
        let session = sessions[ref.topicKey]
        return VoiceTopicBrief(
            topicKey: ref.topicKey,
            title: ref.title ?? overview?.title ?? "",
            forumName: pageContext.forumName,
            opening: opening,
            openingPoster: facts?.openingPoster,
            postCount: facts?.postsCount ?? overview?.postCount,
            solution: solution,
            topPosts: Array(top),
            summary: session?.hasSummary == true ? session?.summary : nil
        )
    }

    func postsOnScreen() async -> [VisiblePost] {
        await browser.postsOnScreen()
    }

    /// Queues the topic's summary in the existing pipeline and waits for it
    /// (at most two minutes).
    func quickSummary(topicKey: String) async -> String? {
        if let saved = sessions[topicKey], saved.hasSummary { return saved.summary }
        guard let topic = pageContext.topic, topic.topicKey == topicKey else { return nil }
        enqueueSummary(for: topic)
        for _ in 0..<120 {
            try? await Task.sleep(for: .seconds(1))
            if Task.isCancelled { return nil }
            if let session = sessions[topicKey], session.hasSummary { return session.summary }
            if !activities.contains(where: { $0.topicKey == topicKey && $0.type == .summary && !$0.status.isTerminal }) {
                return nil
            }
        }
        return nil
    }

    // MARK: Session

    /// Providers the user can talk to: those with a key.
    var availableVoiceProviders: [VoiceProvider] {
        VoiceProvider.allCases.filter { !settings.configuration(for: $0.keyProvider).apiKey.isEmpty }
    }

    /// Records the user's consent for `provider` on this device.
    func grantVoiceConsent(_ provider: VoiceProvider) {
        settings.voiceConsent[provider.rawValue] = Date()
        saveSettings()
    }

    func revokeVoiceConsent(_ provider: VoiceProvider) {
        settings.voiceConsent[provider.rawValue] = nil
        saveSettings()
    }

    /// The configuration for a session with the chosen provider (falling
    /// back to the one with a key), or why there can't be one.
    func voiceConfiguration() -> Result<VoiceSession.Configuration, VoiceSession.Failure> {
        guard settings.voiceEnabled else { return .failure(.disabled) }
        let available = availableVoiceProviders
        guard let provider = available.contains(settings.voice.provider) ? settings.voice.provider : available.first else {
            return .failure(.noKey)
        }
        guard VoiceConsent.isGranted(provider, in: settings) else { return .failure(.noConsent) }
        let configuration = settings.configuration(for: provider.keyProvider)
        let endpoint: GeminiLive.Endpoint
        switch provider {
        case .aiStudio:
            endpoint = .aiStudio
        case .vertex:
            let project = GeminiLive.Endpoint.vertexProject(fromBaseURL: configuration.baseURL)
                ?? settings.voice.vertexProject.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !project.isEmpty else { return .failure(.noVertexProject) }
            endpoint = .vertex(project: project, location: GeminiLive.Endpoint.vertexLocation)
        }
        return .success(VoiceSession.Configuration(
            endpoint: endpoint,
            apiKey: configuration.apiKey,
            settings: settings.voice,
            hasConsent: true
        ))
    }

    /// A session on the current page, wired to the page changes. The caller
    /// starts it (on the user's tap) and keeps it.
    func makeVoiceSession(audio: VoiceAudioIO) -> Result<VoiceSession, VoiceSession.Failure> {
        voiceConfiguration().map { configuration in
            let session = VoiceSession(configuration: configuration, audio: audio, navigator: self)
            let subscription = pageChanges.sink { [weak session] page in session?.pageChanged(page) }
            voicePageSubscription = subscription
            return session
        }
    }
}
