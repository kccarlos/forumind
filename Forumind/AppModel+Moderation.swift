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
