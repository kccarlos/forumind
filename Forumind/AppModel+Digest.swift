import Foundation

// MARK: - AppModel API for the daily digest (model: DailyDigest.swift)
//
// - `digests` / `todaysDigest` / `earlierDigests`   newest first, at most 7, device-local
// - `digestActivity`                  preparing, summarizing a card, or unreachable
// - `showsTodayPage`                  the Today page pushed over Home (notification tap, intents)
// - `makeTodaysDigest(replacing:)`    the Today page's button (works with the daily switch off)
// - `resumeDigestIfNeeded()`          Today page and foreground: continue today's digest, or
//                                     make it when the daily switch is on
// - `pauseDigest()`                   app to the background: the run continues from the same card
// - `retryDigestCard(_:)`, `deleteDigest(id:)`, `deleteAllDigests()`, `removeDigestCards(siteURL:)`
// - `prefetchDigestInputs(background:)` forum JSON only (no AI), within the request cap
// - `openDigestLink(_:card:)`         opens a card's topic or post in the browser

enum DigestActivity: Equatable {
    case idle
    /// Reading the forums' topic lists and topic JSON.
    case preparing
    /// Summarizing the card with this id (its topic key).
    case summarizing(String)
    /// The forums or the AI provider couldn't be reached (offline); the
    /// digest continues from the same card next time.
    case unreachable

    var isRunning: Bool {
        switch self {
        case .preparing, .summarizing: true
        case .idle, .unreachable: false
        }
    }
}

extension AppModel {
    var todayKey: String { DailyDigest.dayKey(for: Date()) }
    var todaysDigest: DailyDigest? { digests.first { $0.day == todayKey } }
    var earlierDigests: [DailyDigest] { digests.filter { $0.day != todayKey } }

    // MARK: Storage

    func loadDigests() {
        let archive = digestStore.load()
        digests = archive.digests
        digestPrefetch = archive.prefetch
        digestNotifiedDay = archive.notifiedDay
    }

    func saveDigests() {
        #if DEBUG
        // Sample data for screenshots is never written over the real file.
        if AssistantDebug.isActive { return }
        #endif
        digestStore.save(DigestStore.Archive(
            digests: digests,
            prefetch: digestPrefetch,
            notifiedDay: digestNotifiedDay
        ))
        // Deleted, made again or trimmed: their podcast audio goes too.
        podcast.reconcile()
    }

    // MARK: Settings and scheduling

    /// The background prefetch exists only while the daily digest is on.
    func digestSettingsDidChange(from old: AppSettings) {
        if old.dailyDigestEnabled != settings.dailyDigestEnabled {
            if settings.dailyDigestEnabled { scheduleDigestPrefetch() } else { cancelDigestPrefetch() }
        }
        if settings.dailyDigestNotifies, !old.dailyDigestNotifies, !notificationsAuthorized {
            requestNotificationAuthorization()
        }
    }

    /// Submitting replaces an earlier request. It fails on the simulator and
    /// when Background App Refresh is off; the digest is then fetched on open.
    func scheduleDigestPrefetch() {
        try? backgroundScheduler.submit(DigestBackgroundPrefetch.request())
    }

    func cancelDigestPrefetch() {
        backgroundScheduler.cancel(taskRequestWithIdentifier: DigestBackgroundPrefetch.identifier)
    }

    /// The BGProcessingTask: schedules the next one, fetches the forum JSON,
    /// and (when asked to) says the digest is ready to make, once a day.
    func performBackgroundDigestPrefetch() async {
        guard settings.dailyDigestEnabled else {
            cancelDigestPrefetch()
            return
        }
        scheduleDigestPrefetch()
        guard todaysDigest == nil else { return }
        let prefetch = await prefetchDigestInputs(background: true)
        guard !Task.isCancelled, prefetch.failedCount < prefetch.requestCount || prefetch.requestCount == 0,
              settings.dailyDigestNotifies, digestNotifiedDay != prefetch.day
        else {
            return
        }
        let count = planDigestCards(using: prefetch).cards.count
        guard count > 0 else { return }
        digestNotifiedDay = prefetch.day
        saveDigests()
        await notifier.notifyDigestReady(topicCount: count)
    }

    func openTodayFromNotification() {
        guard WatchNotifier.pendingTodayOpen else { return }
        WatchNotifier.pendingTodayOpen = false
        noteExternalEntry()
        showsTodayPage = true
    }

    // MARK: Inputs

    /// Fetches the forum JSON a digest is made from, without any AI call:
    /// first the topic JSON of watched topics (checked longest ago first, so
    /// replies that came in since the last watch check count), keeping room
    /// for the lists; then the day's top topics of each pinned forum
    /// (`/top.json?period=daily`, else `/latest.json`); then the topic JSON
    /// of the other planned cards, for post counts and post-level links.
    ///
    /// At most `DigestLimits.prefetchRequestCap` requests, each paced like
    /// every forum request; the background always uses the gentle pace and
    /// URLSession with each forum's cookies. Saved after every request, so a
    /// prefetch cut short keeps what it got. Watched topics are not changed
    /// here (the watch check owns their new-reply notifications).
    @discardableResult
    func prefetchDigestInputs(background: Bool) async -> DigestPrefetch {
        var prefetch = DigestPrefetch(day: todayKey)
        let cap = DigestLimits.prefetchRequestCap
        let pace: ForumRequestPace = background ? .gentle : settings.forumRequestPace
        let options = DigestPlanner.Options(settings: settings)
        // One transport per site (its cookies are read once). A site with no
        // adapter is skipped quietly: no request, no failure.
        var networks: [String: SiteNetwork] = [:]
        func network(_ siteURL: String) async -> SiteNetwork {
            if let known = networks[siteURL] { return known }
            let net = await self.network(for: siteURL, pace: pace, inPage: !background)
            networks[siteURL] = net
            return net
        }
        func checkpoint() {
            digestPrefetch = prefetch
            saveDigests()
        }

        func fetchFacts(siteURL: String, topicID: String, topicKey: String) async -> Bool {
            guard let adapter = adapter(for: siteURL) else { return true }
            prefetch.requestCount += 1
            do {
                let overview = try await adapter.overview(
                    TopicRef(siteURL: siteURL, topicID: topicID),
                    net: await network(siteURL)
                )
                prefetch.topics[topicKey] = DigestTopicFacts(overview: overview)
            } catch {
                if Task.isCancelled { return false }
                prefetch.failedCount += 1
            }
            checkpoint()
            return true
        }

        let listForums = options.includesTrending ? Array(pinnedForums.prefix(DigestLimits.trendingForums)) : []
        if options.includesWatched {
            for topic in Self.watchCheckOrder(watchedTopics) {
                guard !Task.isCancelled, prefetch.requestCount < cap - listForums.count else { break }
                guard await fetchFacts(siteURL: topic.siteURL, topicID: topic.topicID, topicKey: topic.topicKey) else { break }
            }
        }

        if options.includesTrending {
            for forum in listForums {
                guard !Task.isCancelled, prefetch.requestCount < cap else { break }
                guard let source = adapter(for: forum.siteURL)?.capabilities.activeTopics else { continue }
                let found = await source.activeTopics(
                    siteURL: forum.siteURL,
                    budget: cap - prefetch.requestCount,
                    net: await network(forum.siteURL)
                )
                prefetch.requestCount += found.requests
                prefetch.failedCount += found.failures
                if Task.isCancelled { break }
                if let list = found.topics { prefetch.trending[forum.siteURL] = list }
                checkpoint()
            }
        }

        for card in planDigestCards(using: prefetch).cards where prefetch.topics[card.topicKey] == nil {
            guard !Task.isCancelled, prefetch.requestCount < cap else { break }
            guard await fetchFacts(siteURL: card.siteURL, topicID: card.topicID, topicKey: card.topicKey) else { break }
        }
        prefetch.fetchedAt = Date()
        if Task.isCancelled {
            // Cut short: kept, but not fresh, so the next digest fetches again.
            prefetch.fetchedAt = .distantPast
        }
        checkpoint()
        return prefetch
    }

    /// The cards a digest made now would have, and the watched topics' post
    /// counts it records for the next one.
    func planDigestCards(using prefetch: DigestPrefetch?) -> (cards: [DigestCard], watchedCounts: [String: Int]) {
        let facts = prefetch?.topics ?? [:]
        let baselines = DigestPlanner.baselines(watched: watchedTopics, previous: earlierDigests.first)
        let trending = pinnedForums.compactMap { forum in
            prefetch?.trending[forum.siteURL].map { (siteURL: forum.siteURL, topics: $0) }
        }
        let cards = DigestPlanner.plan(
            watched: watchedTopics,
            baselines: baselines,
            trending: trending,
            facts: facts,
            options: DigestPlanner.Options(settings: settings),
            slug: { slug(of: $0.url, siteURL: $0.siteURL) }
        )
        return (cards, DigestPlanner.postCounts(watched: watchedTopics, facts: facts))
    }

    // MARK: Making the digest

    /// Makes today's digest: fetches the inputs unless a fresh prefetch has
    /// them, plans the cards, then summarizes them one at a time. With one
    /// already made today, `replacing` starts it over (cards whose topic has
    /// no new posts reuse their summary); otherwise it continues it.
    func makeTodaysDigest(replacing: Bool = false) {
        if let today = todaysDigest, !replacing {
            if !today.isComplete, digestTask == nil, canRunUnattended(.assistant) {
                startDigestRun { model, runID in await model.runDigest(id: today.id, runID: runID) }
            }
            return
        }
        guard canRunUnattended(.assistant) else { return }
        if digestTask != nil { pauseDigest() }
        digestActivity = .preparing
        startDigestRun { model, runID in
            guard let id = await model.prepareDigest(runID: runID) else { return }
            await model.runDigest(id: id, runID: runID)
        }
    }

    /// The Today page and the app coming to the foreground: continues
    /// today's unfinished digest, or makes it when the daily switch is on.
    /// Nothing starts without a ready assistant model whose provider may
    /// receive forum content (the digest never shows the consent page).
    func resumeDigestIfNeeded() {
        #if DEBUG
        // The sample's placeholder key must never reach a provider.
        if AssistantDebug.isActive { return }
        #endif
        guard digestTask == nil, settings.hasCompletedOnboarding, canRunUnattended(.assistant) else { return }
        if let today = todaysDigest {
            guard !today.isComplete else { return }
            makeTodaysDigest()
        } else if settings.dailyDigestEnabled {
            makeTodaysDigest()
        }
    }

    /// Stops the run (the app went to the background); the card being
    /// summarized goes back to waiting and is made again next time.
    func pauseDigest() {
        guard let task = digestTask else { return }
        task.cancel()
        digestTask = nil
        digestRunID = nil
        digests = digests.map(\.resumed)
        if digestActivity.isRunning { digestActivity = .idle }
        saveDigests()
    }

    func retryDigestCard(_ card: DigestCard) {
        guard let today = todaysDigest else { return }
        mutateDigestCard(card.id, in: today.id) {
            $0.state = .pending
            $0.error = ""
        }
        saveDigests()
        if digestActivity == .unreachable { digestActivity = .idle }
        makeTodaysDigest()
    }

    func deleteDigest(id: UUID) {
        if digests.first(where: { $0.id == id })?.isComplete == false { pauseDigest() }
        digests.removeAll { $0.id == id }
        if todaysDigest == nil, digestActivity == .unreachable { digestActivity = .idle }
        saveDigests()
    }

    func deleteAllDigests() {
        pauseDigest()
        podcast.deleteAll()
        digests = []
        digestPrefetch = nil
        digestNotifiedDay = nil
        digestActivity = .idle
        saveDigests()
    }

    /// A forum removed with its data, or its data cleared: its cards and
    /// prefetched lists go too.
    func removeDigestCards(siteURL: String) {
        let affected = digests.contains { $0.cards.contains { $0.siteURL == siteURL } }
            || digestPrefetch?.trending[siteURL] != nil
        guard affected else { return }
        pauseDigest()
        // Their podcasts talked about the forum's topics.
        podcast.deleteEpisodes(digests.filter { $0.cards.contains { $0.siteURL == siteURL } }.map(\.id))
        digests = digests.map { digest in
            var copy = digest
            copy.cards.removeAll { $0.siteURL == siteURL }
            return copy
        }
        if var prefetch = digestPrefetch {
            prefetch.trending[siteURL] = nil
            if let prefix = ForumSite.topicKey(siteURL: siteURL, topicID: "1")?.dropLast(1) {
                prefetch.topics = prefetch.topics.filter { !$0.key.hasPrefix(prefix) }
            }
            digestPrefetch = prefetch
        }
        saveDigests()
    }

    /// Opens a card's topic (or one of its posts) in the browser and closes
    /// the Today page. A watched topic counts as seen.
    func openDigestLink(_ url: URL, card: DigestCard) {
        if isWatched(topicKey: card.topicKey) { markWatchedSeen(topicKey: card.topicKey) }
        showsTodayPage = false
        // A post link lands on that post, highlighted.
        openLink(url)
        panelRoute = .topic
    }

    // MARK: Runner

    private func startDigestRun(_ work: @escaping @MainActor (AppModel, UUID) async -> Void) {
        let runID = UUID()
        digestRunID = runID
        digestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await work(self, runID)
            guard self.digestRunID == runID else { return }
            self.digestTask = nil
            self.digestRunID = nil
            if self.digestActivity.isRunning { self.digestActivity = .idle }
        }
    }

    private func isCurrentDigestRun(_ runID: UUID) -> Bool {
        !Task.isCancelled && digestRunID == runID
    }

    /// Plans today's cards (fetching the inputs first unless a fresh prefetch
    /// has them) and stores the new digest; nil when the forums couldn't be
    /// reached or the run was stopped.
    private func prepareDigest(runID: UUID) async -> UUID? {
        digestActivity = .preparing
        var prefetch = digestPrefetch
        if !(prefetch?.isFresh() ?? false) {
            prefetch = await prefetchDigestInputs(background: false)
        }
        guard isCurrentDigestRun(runID) else { return nil }
        let plan = planDigestCards(using: prefetch)
        if plan.cards.isEmpty, let prefetch, prefetch.requestCount > 0, prefetch.failedCount == prefetch.requestCount {
            digestActivity = .unreachable
            return nil
        }
        // Made again: cards whose topic has no new posts keep their summary.
        let replaced = todaysDigest?.cards ?? []
        let cards = plan.cards.map { card -> DigestCard in
            guard let old = replaced.first(where: {
                $0.topicKey == card.topicKey && $0.state == .done && $0.postCount == card.postCount
            }) else {
                return card
            }
            var kept = card
            kept.summary = old.summary
            kept.source = .earlierDigest
            kept.state = .done
            return kept
        }
        let digest = DailyDigest(day: todayKey, cards: cards, watchedPostCounts: plan.watchedCounts)
        digests.removeAll { $0.day == digest.day }
        digests.insert(digest, at: 0)
        digests = Array(digests.prefix(DigestLimits.historyCount))
        saveDigests()
        return digest.id
    }

    /// Summarizes the digest's waiting cards one at a time, saving after
    /// each, with the assistant model as it was when the run started.
    private func runDigest(id: UUID, runID: UUID) async {
        let context = runSettings(role: .assistant, topicKey: "")
        guard (try? context.requireReadyProvider()) != nil else { return }
        while isCurrentDigestRun(runID) {
            guard let digest = digests.first(where: { $0.id == id }),
                  var card = digest.cards.first(where: { $0.state == .pending })
            else {
                break
            }
            mutateDigestCard(card.id, in: id) {
                $0.state = .working
                $0.error = ""
            }
            digestActivity = .summarizing(card.id)
            saveDigests()
            do {
                card = try await summarizeDigestCard(card, digestID: id, context: context)
                // Paused or replaced meanwhile: `pauseDigest` already put the
                // card back to waiting.
                guard isCurrentDigestRun(runID) else { return }
                card.state = .done
            } catch {
                guard isCurrentDigestRun(runID) else { return }
                // No connection: the digest waits instead of failing every card.
                if NetworkFailure.isUnreachable(error) {
                    mutateDigestCard(card.id, in: id) { $0.state = .pending }
                    digestActivity = .unreachable
                    saveDigests()
                    return
                }
                card.state = .failed
                card.error = error.localizedDescription
            }
            mutateDigestCard(card.id, in: id) { $0 = card }
            saveDigests()
        }
        guard isCurrentDigestRun(runID),
              let index = digests.firstIndex(where: { $0.id == id }),
              digests[index].isComplete
        else {
            return
        }
        digests[index].completedAt = Date()
        saveDigests()
        // Done: the daily podcast may start right away.
        digestActivity = .idle
        podcast.digestCompleted(id)
    }

    /// The card's text, cheapest first:
    /// 1. an earlier digest's card for the same posts (no AI call);
    /// 2. the saved summary condensed, when it covers every post (the topic
    ///    is not read again);
    /// 3. the topic read (cached pages reused, the beginning and the newest
    ///    replies kept within the context limit) and summarized through the
    ///    summary pipeline with the digest's instructions.
    private func summarizeDigestCard(_ card: DigestCard, digestID: UUID, context: RunSettings) async throws -> DigestCard {
        var card = card
        let earlier = digests
            .filter { $0.id != digestID }
            .flatMap(\.cards)
            .first { $0.topicKey == card.topicKey && $0.state == .done && $0.postCount == card.postCount && !$0.summary.isEmpty }
        if let earlier {
            card.summary = earlier.summary
            card.source = .earlierDigest
            return card
        }

        if let session = sessions[card.topicKey], session.hasSummary,
           let covered = session.summaryPostCount, covered >= card.postCount {
            let text = try await aiService.generateSummary(
                content: session.summary,
                configuration: context.configuration,
                provider: context.provider,
                customPrompt: DigestPrompt.instructions(for: card, fromSavedSummary: true),
                batchLimit: context.batchLimit,
                onDelta: { _ in }
            )
            card.summary = DigestPrompt.cleaned(text)
            card.source = .savedSummary
            return card
        }

        let cached = sessions[card.topicKey]
        guard let adapter = adapter(for: card.siteURL) else { throw AssistantError.noForum }
        let fetch = try await adapter.readTopic(
            TopicReadRequest(
                topic: TopicRef(siteURL: card.siteURL, topicID: card.topicID),
                cachedPages: cached?.rawPages ?? [],
                knownTotalPosts: cached?.totalPosts
            ),
            net: await network(for: card.siteURL, pace: context.forumRequestPace),
            progress: { _ in },
            onPage: nil
        )
        try Task.checkCancellation()
        // Like a summary's fetch: an existing session keeps the pages (its
        // saved summary then shows as behind when new replies came in).
        storeFetchedPages(fetch, topicKey: card.topicKey)
        card.postCount = fetch.totalPosts
        if let facts = fetch.facts {
            card.acceptedAnswerPost = facts.acceptedAnswer?.postNumber ?? card.acceptedAnswerPost
            card.topPost = DigestTopicFacts.topPost(facts) ?? card.topPost
        }
        let content = PromptBuilder.boundedForumContext(
            moderated(fetch.content, siteURL: card.siteURL, topicID: card.topicID),
            limit: context.contextLimit
        )
        let text = try await aiService.generateSummary(
            content: content,
            configuration: context.configuration,
            provider: context.provider,
            customPrompt: DigestPrompt.instructions(for: card, fromSavedSummary: false),
            batchLimit: context.batchLimit,
            onDelta: { _ in }
        )
        card.summary = DigestPrompt.cleaned(text)
        card.source = .topic
        return card
    }

    private func mutateDigestCard(_ cardID: String, in digestID: UUID, mutation: (inout DigestCard) -> Void) {
        guard let digestIndex = digests.firstIndex(where: { $0.id == digestID }),
              let cardIndex = digests[digestIndex].cards.firstIndex(where: { $0.id == cardID })
        else {
            return
        }
        mutation(&digests[digestIndex].cards[cardIndex])
    }

    // MARK: Sample

    #if DEBUG
    /// `-dc-digest-sample` (with `-dc-sample`): today's digest with two
    /// finished cards and one waiting, in memory only.
    func seedDigestSample() {
        let text = SampleContent.current
        var watched = DigestCard(
            siteURL: text.meta.siteURL, topicID: "404728", title: text.unifiedNewTitle,
            slug: "introducing-the-unified-new-view-for-the-topic-list",
            reason: .newReplies(5), postCount: 68, firstNewPost: 64, topPost: 12
        )
        watched.summary = text.digestBlurbs.first ?? ""
        watched.state = .done
        watched.source = .topic
        var trending = DigestCard(
            siteURL: text.makers.siteURL, topicID: "18342", title: text.layerShiftsTitle,
            slug: "layer-shifts-on-long-prints-after-the-2-4-firmware-update",
            reason: .trending, postCount: 41, acceptedAnswerPost: 17
        )
        trending.summary = text.digestBlurbs.last ?? ""
        trending.state = .done
        trending.source = .savedSummary
        let waiting = DigestCard(
            siteURL: text.makers.siteURL, topicID: "18391", title: text.stepperHeatTitle,
            slug: "stepper-drivers-overheating-in-enclosed-printers",
            reason: .trending, postCount: 23
        )
        digests = [DailyDigest(day: todayKey, cards: [watched, trending, waiting])]
    }
    #endif
}
