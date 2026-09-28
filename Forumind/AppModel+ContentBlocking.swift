import Foundation

// MARK: - Ad and tracker blocking (AppModel API for the UI)
//
// - `settings.contentBlockingEnabled` / `settings.blockTrackers` /
//   `settings.adBlockAllowedSites`   edited directly; applied at once
// - `contentRules`                     the shared rule library (manifest, phase)
// - `contentBlockingStatus(for:)`      what the browser bar shows for a page
// - `turnOnContentBlocking()`           the shield's "Turn on ad blocking"
// - `isAdBlockingAllowed(on:)`, `setAdsAllowed(_:on:)`,
//   `removeAllowedSites(atOffsets:)`
//
// DEBUG: `-dc-content-blocking off` turns blocking off for this launch only
// (saved settings are not changed; used for before/after screenshots).

extension AppModel {
    var contentRules: ContentRuleLibrary { browser.contentBlocker.library }

    /// Applies the saved policy, and starts the rule library only when
    /// something is blocked. Called from `init` before the first page load.
    /// Blocking is off by default: then nothing is looked up or compiled
    /// and the first page load never waits.
    func configureContentBlocking() {
        let policy = effectiveContentBlockingPolicy
        browser.applyContentBlocking(policy)
        if !policy.enabledCategories.isEmpty {
            contentRules.start()
        }
    }

    /// Settings edits apply right away; the page shown now reloads only when
    /// the change affects it. Browsing has no running work to protect.
    /// Turning blocking on for the first time starts the lists (compiled in
    /// the background on a first run); the page reloads once they're ready.
    func contentBlockingSettingsDidChange(from old: AppSettings) {
        guard old.contentBlockingEnabled != settings.contentBlockingEnabled
            || old.blockTrackers != settings.blockTrackers
            || old.adBlockAllowedSites != settings.adBlockAllowedSites
        else {
            return
        }
        let policy = effectiveContentBlockingPolicy
        let needsStart = !policy.enabledCategories.isEmpty && contentRules.phase == .idle
        if needsStart { contentRules.start() }
        guard browser.applyContentBlocking(policy), !browser.showsForumsHome else { return }
        if needsStart || contentRules.isPreparing {
            let page = browser.currentURL
            Task { [weak self] in
                guard let self else { return }
                await self.contentRules.waitUntilReady()
                // Still on that page, and still blocking.
                guard self.browser.currentURL == page,
                      !self.effectiveContentBlockingPolicy.enabledCategories.isEmpty,
                      !self.browser.showsForumsHome
                else {
                    return
                }
                self.browser.reload()
            }
        } else {
            browser.reload()
        }
    }

    /// The shield's "Turn on ad blocking": ads and trackers, for every site.
    func turnOnContentBlocking() {
        // One settings change, so the page reloads once.
        var updated = settings
        updated.contentBlockingEnabled = true
        updated.blockTrackers = true
        settings = updated
    }

    var effectiveContentBlockingPolicy: ContentBlockingPolicy {
        var policy = ContentBlockingPolicy(settings: settings)
        #if DEBUG
        if let value = OnboardingDebug.value(after: "-dc-content-blocking"), value == "off" {
            policy.blockAds = false
            policy.blockTrackers = false
        }
        #endif
        return policy
    }

    func contentBlockingStatus(for url: URL?) -> ContentBlockingStatus {
        ContentBlockingStatus.make(policy: effectiveContentBlockingPolicy, url: url)
    }

    func isAdBlockingAllowed(on url: URL?) -> Bool {
        ContentBlockingRules.isAllowed(url, allowedSites: settings.adBlockAllowedSites)
    }

    /// Allows (or blocks again) ads on `url`'s site. Blocking again removes
    /// every allowed entry that covers the host.
    func setAdsAllowed(_ allowed: Bool, on url: URL?) {
        guard let host = url?.host.flatMap(ContentBlockingRules.normalizedHost) else { return }
        var sites = settings.adBlockAllowedSites
        if allowed {
            guard !ContentBlockingRules.isAllowed(url, allowedSites: sites) else { return }
            sites.append(host)
        } else {
            sites.removeAll { entry in
                guard let allowedHost = ContentBlockingRules.normalizedHost(entry) else { return true }
                return host == allowedHost || host.hasSuffix("." + allowedHost)
            }
        }
        settings.adBlockAllowedSites = sites
    }

    func removeAllowedSites(atOffsets offsets: IndexSet) {
        settings.adBlockAllowedSites.remove(atOffsets: offsets)
    }
}
