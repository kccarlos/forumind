import Foundation

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

    func applyModerationRules() {
        browser.moderationRules = moderationRules
    }

    /// Topic text for a prompt, without blocked or filtered posts. Applied
    /// when the prompt is built, so text cached before a block is covered.
    func moderated(_ source: String, siteURL: String, topicID: String) -> String {
        ModerationFilter.filter(source, siteURL: siteURL, topicID: topicID, rules: moderationRules)
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
        settings.blockedUsers.append(BlockedUser(siteURL: siteURL, username: name))
    }

    func unblock(_ user: BlockedUser) {
        settings.blockedUsers.removeAll { $0.id == user.id }
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
        let text: String
        switch feature {
        case .summary: text = session.summary
        case .chatAnswer: text = session.history.last(where: { $0.role == .assistant })?.content ?? ""
        case .askAnswer: return nil
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Who wrote it: the summary's own model; for a chat answer, the
        // latest finished chat job (kept a day), else the current model.
        let writer: (AIProvider, String)?
        switch feature {
        case .summary:
            writer = session.provider.map { ($0, session.model) }
        default:
            writer = activities
                .first { $0.topicKey == topic.topicKey && $0.type == .chat && $0.status == .completed }
                .map { ($0.provider, $0.model) }
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

    /// An Ask the forum answer as a report.
    func aiOutputReport(for run: AgentRun, answer: String) -> ReportTarget {
        ReportTarget(
            siteURL: run.siteURL,
            forumName: forumInfo(siteURL: run.siteURL).displayName,
            topicTitle: "",
            topicURL: nil,
            kind: .aiOutput(AIOutput(
                feature: .askAnswer,
                model: Self.reportModel(run.provider, run.model),
                text: answer,
                question: run.goal
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
