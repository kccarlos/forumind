import Foundation

struct ModeratedSourceCacheEntry {
    struct SourceIdentity: Equatable {
        let length: Int
        let headHash: Int
        let tailHash: Int
        let generation: Int

        init(_ source: String, generation: Int) {
            let utf8 = source.utf8
            self.length = utf8.count
            let sample = min(64, length)
            var headHasher = Hasher()
            for byte in utf8.prefix(sample) { headHasher.combine(byte) }
            self.headHash = headHasher.finalize()
            var tailHasher = Hasher()
            for byte in utf8.suffix(sample) { tailHasher.combine(byte) }
            self.tailHash = tailHasher.finalize()
            self.generation = generation
        }
    }

    let sourceIdentity: SourceIdentity
    let rules: ModerationRules
    let moderated: String
}

// MARK: - Moderation (AppModel API for the UI; see Moderation.swift)
//
// - `moderationRules`                  blocks + words + the developer's list
// - `moderated(_:siteURL:topicID:)`    topic text with hidden posts removed;
//                                      every prompt goes through it
// - `block(_:on:)`, `unblock(_:)`, `addFilteredWord(_:)`,
//   `removeFilteredWords(atOffsets:)`
// - `acceptTerms()`, `needsTermsAcceptance`
// - `refreshRemoteModerationIfNeeded()` at most once a day

extension AppModel {
    var moderationRules: ModerationRules {
        ModerationRules(settings: settings, remote: remoteModeration)
    }

    /// AI text and citations use positional numbers; storage and page bridges
    /// use the adapter's stable identity. This is derived, never persisted.
    var aiModerationRules: ModerationRules {
        let nativeRules = browser.moderationRules
        var rules = nativeRules
        for key in nativeRules.hiddenPosts.keys {
            guard let separator = key.lastIndex(of: "|") else { continue }
            let siteURL = String(key[..<separator])
            let topicID = String(key[key.index(after: separator)...])
            guard let identity = adapter(for: siteURL)?.capabilities.postIdentity,
                  case .native = identity else { continue }
            rules.hiddenPosts[key] = topicModerationRules(siteURL: siteURL, topicID: topicID, rules: nativeRules).hiddenPosts[key]
        }
        return rules
    }

    func topicModerationRules(siteURL: String, topicID: String, blocks: [PostBlock]? = nil,
                              facts: TopicFacts? = nil, rules: ModerationRules? = nil) -> ModerationRules {
        let rules = rules ?? browser.moderationRules
        guard let identity = adapter(for: siteURL)?.capabilities.postIdentity,
              case .native = identity else { return rules }
        let key = TopicIdentity.key(siteURL: siteURL, topicID: topicID)
        let cachedBlocks = blocks ?? sessions[key]?.rawPages.flatMap(\.blocks) ?? []
        return identity.aiRules(rules, siteURL: siteURL, topicID: topicID,
                                blocks: cachedBlocks,
                                facts: facts ?? (blocks == nil && cachedBlocks.isEmpty ? topicOverviews[key]?.facts : nil))
    }

    func applyModerationRules() {
        browser.moderationRules = moderationRules
        moderatedSourceCache.removeAll()
    }

    /// Topic text for a prompt, without blocked or filtered posts. Applied
    /// when the prompt is built, so text cached before a block is covered.
    func moderated(_ source: String, siteURL: String, topicID: String, blocks: [PostBlock]? = nil, facts: TopicFacts? = nil) -> String {
        ModerationFilter.filter(source, siteURL: siteURL, topicID: topicID,
                                rules: topicModerationRules(siteURL: siteURL, topicID: topicID, blocks: blocks, facts: facts))
    }

    func isPostOneHidden(siteURL: String, topicID: String, rules: ModerationRules) -> Bool {
        if topicModerationRules(siteURL: siteURL, topicID: topicID, rules: rules).hidesPost(1, siteURL: siteURL, topicID: topicID) { return true }
        let key = TopicIdentity.key(siteURL: siteURL, topicID: topicID)
        if let poster = topicOverviews[key]?.facts?.openingPoster, rules.hidesUser(poster, siteURL: siteURL) {
            return true
        }
        if let author = sessions[key]?.rawPages.first?.blocks.first(where: { $0.number == 1 })?.author,
           rules.hidesUser(author, siteURL: siteURL) {
            return true
        }
        if let poster = digestPrefetch?.topics[key]?.openingPoster,
           rules.hidesUser(poster, siteURL: siteURL) { return true }
        if let author = topicOverviews[key]?.facts?.posts.first(where: { $0.number == 1 })?.username
            ?? sessions[key].flatMap({ RawTopicFormat.parseHeaders($0.source).first(where: { $0.number == 1 })?.author }),
           rules.hidesUser(author, siteURL: siteURL) { return true }
        return false
    }

    func isTopicTitleHidden(_ title: String, siteURL: String, topicID: String, openingPoster: String? = nil) -> Bool {
        let rules = moderationRules
        guard !rules.isEmpty else { return false }
        return topicModerationRules(siteURL: siteURL, topicID: topicID, rules: rules).hidesTopicTitle(title, siteURL: siteURL, topicID: topicID, openingPoster: openingPoster)
            || isPostOneHidden(siteURL: siteURL, topicID: topicID, rules: rules)
    }

    func moderatedTopicTitle(_ title: String, siteURL: String, topicID: String, openingPoster: String? = nil) -> String {
        isTopicTitleHidden(title, siteURL: siteURL, topicID: topicID, openingPoster: openingPoster) ? "" : title
    }

    /// The open topic's cached posts with blocked users and filtered words removed.
    var currentModeratedSource: String {
        guard let session = currentSession, !session.source.isEmpty else { return "" }
        let topicKey = session.topicKey
        let identity = ModeratedSourceCacheEntry.SourceIdentity(session.source, generation: sessionsGeneration)
        let rules = topicModerationRules(siteURL: session.siteURL, topicID: session.topicID)
        if let cached = moderatedSourceCache[topicKey],
           cached.sourceIdentity == identity,
           cached.rules == rules {
            return cached.moderated
        }
        let filtered = ModerationFilter.filter(session.source, siteURL: session.siteURL, topicID: session.topicID, rules: rules)
        moderatedSourceCache[topicKey] = ModeratedSourceCacheEntry(
            sourceIdentity: identity,
            rules: rules,
            moderated: filtered
        )
        return filtered
    }

    func isBlocked(_ username: String, on siteURL: String) -> Bool {
        settings.blockedUsers.contains { $0.matches(siteURL: siteURL, username: username) }
    }

    /// Blocks `username` on one forum: their posts disappear from the page
    /// at once and are left out of summaries, chat and Ask the forum.
    func block(_ username: String, on siteURL: String) {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !name.isEmpty, !isBlocked(name, on: siteURL) else { return }
        settings.blockedUsers.append(BlockedUser(siteURL: siteURL, username: name, blockedAt: nextBlockTimestamp(on: siteURL)))
    }

    func unblock(_ user: BlockedUser) {
        settings.blockedUsers.removeAll { $0.id == user.id }
    }

    func isPostBlocked(_ number: Int, topicID: String, on siteURL: String) -> Bool {
        settings.blockedPosts.contains { $0.matches(siteURL: siteURL, topicID: topicID, postNumber: number) }
    }

    /// Blocks the page bridge's moderation identity (post number or native ID).
    func blockPost(_ number: Int, topicID: String, on siteURL: String) {
        guard number >= 0, !topicID.isEmpty, !isPostBlocked(number, topicID: topicID, on: siteURL) else { return }
        settings.blockedPosts.append(BlockedPost(siteURL: siteURL, topicID: topicID, postNumber: number, blockedAt: nextBlockTimestamp(on: siteURL)))
    }

    func unblockPost(_ post: BlockedPost) {
        settings.blockedPosts.removeAll { $0.id == post.id }
    }

    /// Latest block timestamp on `siteURL` across blocked users and posts.
    /// A whole-second timestamp from sync cannot order content within that second.
    func latestBlockDate(on siteURL: String) -> Date? {
        let userDates = settings.blockedUsers.lazy.filter { $0.siteURL == siteURL }.map(\.blockedAt)
        let postDates = settings.blockedPosts.lazy.filter { $0.siteURL == siteURL }.map(\.blockedAt)
        return (Array(userDates) + Array(postDates)).map { date in
            date == SyncCoding.stamp(date) ? date.addingTimeInterval(1) : date
        }.max()
    }

    private func nextBlockTimestamp(on siteURL: String) -> Date {
        let latestSummary = sessions.values.lazy
            .filter { $0.siteURL == siteURL }
            .compactMap(\.summaryUpdatedAt)
            .max() ?? .distantPast
        return max(Date(), latestSummary)
    }

    /// A saved summary has no per-post provenance, so one generated before
    /// the latest block on its site is not sent to a model as context.
    func canUseSummaryAsContext(_ session: TopicSession) -> Bool {
        canUseSummaryAsContext(session.summary, title: session.title, siteURL: session.siteURL, updatedAt: session.summaryUpdatedAt)
    }

    func canUseSummaryAsContext(_ summary: String, title: String, siteURL: String, updatedAt: Date?) -> Bool {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let rules = browser.moderationRules
        guard !rules.hidesText(title), !rules.hidesText(summary) else { return false }
        if let blockedAt = latestBlockDate(on: siteURL) {
            guard let updatedAt, updatedAt > blockedAt else { return false }
        }
        return true
    }

    /// Post numbers hidden on the open topic (blocked posts, or posts by a
    /// blocked user in the topic's cached pages or overview).
    var currentHiddenPosts: Set<Int> {
        guard let topic = currentTopic else { return [] }
        let rules = aiModerationRules
        var hidden = rules.hiddenPosts["\(topic.siteURL)|\(topic.topicID)"] ?? []
        if let overview = topicOverviews[topic.topicKey]?.facts {
            for post in overview.posts where rules.hidesUser(post.username, siteURL: topic.siteURL) {
                hidden.insert(post.number)
            }
        }
        if let session = currentSession {
            for page in session.rawPages {
                for block in page.blocks where rules.hidesUser(block.author, siteURL: topic.siteURL) {
                    hidden.insert(block.number)
                }
            }
        }
        return hidden
    }

    /// Returns false when the word is empty or already listed.
    @discardableResult
    func addFilteredWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !settings.filteredWords.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else {
            return false
        }
        settings.filteredWords.append(trimmed)
        return true
    }

    func removeFilteredWords(atOffsets offsets: IndexSet) {
        settings.filteredWords.remove(atOffsets: offsets)
    }

    var needsTermsAcceptance: Bool { !settings.hasAcceptedCurrentTerms }

    func acceptTerms() {
        settings.acceptedTermsVersion = ModerationTerms.currentVersion
    }

    /// Downloads the developer's list when the copy here is a day old (or
    /// missing). Failures keep the last good copy.
    func refreshRemoteModerationIfNeeded(now: Date = Date()) async {
        if let last = RemoteModerationCache.lastFetch(),
           now.timeIntervalSince(last) < RemoteModerationList.refreshInterval,
           remoteModeration != nil
        {
            return
        }
        guard let list = try? await RemoteModerationList.fetch() else { return }
        RemoteModerationCache.store(list, at: now)
        if list != remoteModeration { remoteModeration = list }
    }
}

// MARK: - Report AI output (App Review 1.2)

extension AppModel {
    /// The open topic's saved summary or (in chat) its latest answer, as a
    /// report; nil when there is nothing written yet.
    func currentAIOutputReport(feature: AIOutput.Feature) -> ReportTarget? {
        guard let topic = currentTopic, let session = currentSession else { return nil }
        let lastAssistantIndex = session.history.lastIndex(where: { $0.role == .assistant })
        let text: String
        switch feature {
        case .summary: text = session.summary
        case .chatAnswer: text = lastAssistantIndex.map { session.history[$0].content } ?? ""
        case .askAnswer, .digest, .podcast, .voiceAnswer: return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Who wrote it: the summary's own model; for a chat answer, the
        // finished chat job that answered that question (kept a day), else the
        // current model.
        let writer: (AIProvider, String)?
        switch feature {
        case .summary:
            writer = session.provider.map { ($0, session.model) }
        default:
            let question = lastAssistantIndex.flatMap { idx in
                session.history[..<idx].last(where: { $0.role == .user })?.content
            }
            let completedChats = activities.filter {
                $0.topicKey == topic.topicKey && $0.type == .chat && $0.status == .completed
            }
            let record = (question.flatMap { q in completedChats.first(where: { $0.question == q }) })
                ?? completedChats.first
            writer = record.map { ($0.provider, $0.model) }
        }
        let current = selection(for: .assistant)
        let (provider, model) = writer ?? (current.provider, current.model)
        return ReportTarget(
            siteURL: topic.siteURL,
            forumName: reportForumName(for: topic),
            topicTitle: topic.title,
            topicURL: topic.url,
            kind: .aiOutput(AIOutput(feature: feature, model: Self.reportModel(provider, model), text: text))
        )
    }

    /// Reportable AI outputs on the open topic (its summary and/or latest chat
    /// answer), independent of whether `assistantMode` is `.summary` or `.chat`.
    var currentTopicAIOutputReports: [ReportTarget] {
        guard assistantMode != .agent else { return [] }
        return [AIOutput.Feature.summary, .chatAnswer].compactMap(currentAIOutputReport(feature:))
    }

    /// An Ask the forum answer as a report.
    func aiOutputReport(for run: AgentRun, answer: String, isInitial: Bool = false) -> ReportTarget {
        var question = run.goal
        var provider = run.provider
        var model = run.model
        if !isInitial,
           let followUpIndex = run.followUps.lastIndex(where: { $0.role == .assistant && $0.content == answer }) {
            if let userQuestion = run.followUps[..<followUpIndex].last(where: { $0.role == .user })?.content {
                question = userQuestion
                let topicID = Self.agentTopicPrefix + run.id.uuidString
                if let record = activities.first(where: {
                    $0.topicID == topicID && $0.type == .agent && $0.title == userQuestion
                }) {
                    provider = record.provider
                    model = record.model
                }
            }
        }
        return ReportTarget(
            siteURL: run.siteURL,
            forumName: forumInfo(siteURL: run.siteURL).displayName,
            topicTitle: "",
            topicURL: nil,
            kind: .aiOutput(AIOutput(
                feature: .askAnswer,
                model: Self.reportModel(provider, model),
                text: answer,
                question: question
            ))
        )
    }

    /// A single digest card's AI summary as a report.
    func aiOutputReport(for card: DigestCard, digest: DailyDigest? = nil) -> ReportTarget? {
        let text = card.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let current = selection(for: .assistant)
        return ReportTarget(
            siteURL: card.siteURL,
            forumName: forumInfo(siteURL: card.siteURL).displayName,
            topicTitle: card.title,
            topicURL: url(for: card),
            kind: .aiOutput(AIOutput(
                feature: .digest,
                model: Self.reportModel(current.provider, current.model),
                text: text
            ))
        )
    }

    /// A daily digest as a report (all summarized cards).
    func aiOutputReport(for digest: DailyDigest) -> ReportTarget? {
        let summarized = digest.cards.filter { !$0.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = summarized.first else { return nil }
        let text = summarized.map { "\($0.title)\n\($0.summary)" }.joined(separator: "\n\n")
        let current = selection(for: .assistant)
        return ReportTarget(
            siteURL: first.siteURL,
            forumName: forumInfo(siteURL: first.siteURL).displayName,
            topicTitle: summarized.count == 1 ? first.title : "",
            topicURL: summarized.count == 1 ? url(for: first) : nil,
            kind: .aiOutput(AIOutput(
                feature: .digest,
                model: Self.reportModel(current.provider, current.model),
                text: text
            ))
        )
    }

    /// A podcast episode (or its active topic chapter) as a report.
    func aiOutputReport(for episode: PodcastEpisode, chapter: PodcastChapter? = nil) -> ReportTarget? {
        let selection = selection(for: .assistant)
        let model = "\(Self.reportModel(selection.provider, selection.model)) · \(episode.engine.label)"
        if let chapter, chapter.kind == .topic, !chapter.turns.isEmpty {
            let text = chapter.turns.map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let siteURL = chapter.siteURL ?? episode.entries.compactMap(\.chapter.siteURL).first ?? currentForum?.siteURL ?? ""
            let topicURL: URL? = if let site = chapter.siteURL, let topicID = chapter.topicID {
                adapter(for: site)?.links.topicURL(siteURL: site, topicID: topicID, slug: chapter.slug)
            } else {
                nil
            }
            return ReportTarget(
                siteURL: siteURL,
                forumName: siteURL.isEmpty ? "" : forumInfo(siteURL: siteURL).displayName,
                topicTitle: chapter.title,
                topicURL: topicURL,
                kind: .aiOutput(AIOutput(feature: .podcast, model: model, text: text))
            )
        }
        let sections = episode.entries.compactMap { entry -> String? in
            guard !entry.chapter.turns.isEmpty else { return nil }
            let turns = entry.chapter.turns.map { "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
            return "\(entry.chapter.title)\n\(turns)"
        }
        let text = sections.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let siteURL = episode.entries.compactMap(\.chapter.siteURL).first ?? currentForum?.siteURL ?? ""
        return ReportTarget(
            siteURL: siteURL,
            forumName: siteURL.isEmpty ? "" : forumInfo(siteURL: siteURL).displayName,
            topicTitle: episode.title,
            topicURL: nil,
            kind: .aiOutput(AIOutput(feature: .podcast, model: model, text: text))
        )
    }

    /// A live voice session's latest answer as a report.
    func aiOutputReport(for session: VoiceSession) -> ReportTarget? {
        let text = session.lastModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let topic = currentTopic
        let siteURL = topic?.siteURL ?? pageContext.siteURL ?? currentForum?.siteURL ?? ""
        let forumName: String = if let topic {
            reportForumName(for: topic)
        } else if !siteURL.isEmpty {
            forumInfo(siteURL: siteURL).displayName
        } else {
            ""
        }
        let provider: VoiceProvider = switch session.configuration.endpoint {
        case .aiStudio: .aiStudio
        case .vertex: .vertex
        }
        let question = session.lastUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        return ReportTarget(
            siteURL: siteURL,
            forumName: forumName,
            topicTitle: topic?.title ?? "",
            topicURL: topic?.url ?? pageContext.url,
            kind: .aiOutput(AIOutput(
                feature: .voiceAnswer,
                model: "\(provider.displayName) · \(session.configuration.model)",
                text: text,
                question: question.isEmpty ? nil : question
            ))
        )
    }

    /// Shows the report form (a routed sheet).
    func report(_ target: ReportTarget) {
        router.item = .reportAIOutput(target)
    }

    private static func reportModel(_ provider: AIProvider, _ model: String) -> String {
        model.isEmpty ? provider.displayName : "\(provider.displayName) · \(model)"
    }
}
