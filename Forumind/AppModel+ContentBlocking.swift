import Foundation

// MARK: - Ad and tracker blocking (AppModel API for the UI)
//
// - `settings.contentBlockingEnabled` / `settings.blockTrackers` /
//   `settings.adBlockAllowedSites`   edited directly; applied at once
// - `contentRules`                     the shared rule library (manifest, phase)
// - `contentBlockingStatus(for:)`      what the browser bar shows for a page
// - `isAdBlockingAllowed(on:)`, `setAdsAllowed(_:on:)`,
//   `removeAllowedSites(atOffsets:)`
//
// DEBUG: `-dc-content-blocking off` turns blocking off for this launch only
// (saved settings are not changed; used for before/after screenshots).

extension AppModel {
    var contentRules: ContentRuleLibrary { browser.contentBlocker.library }

    /// Starts the rule library and applies the saved policy. Called from
    /// `init` before the first page load.
    func configureContentBlocking() {
        browser.applyContentBlocking(effectiveContentBlockingPolicy)
        contentRules.start()
    }

    /// Settings edits apply right away; the page shown now reloads only when
    /// the change affects it. Browsing has no running work to protect.
    func contentBlockingSettingsDidChange(from old: AppSettings) {
        guard old.contentBlockingEnabled != settings.contentBlockingEnabled
            || old.blockTrackers != settings.blockTrackers
            || old.adBlockAllowedSites != settings.adBlockAllowedSites
        else {
            return
        }
        if browser.applyContentBlocking(effectiveContentBlockingPolicy), !browser.showsForumsHome {
            browser.reload()
        }
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
