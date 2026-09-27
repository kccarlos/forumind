import Foundation
import SwiftUI

// MARK: - Browsing and the Forums home (UI engineer A)
//
// - `goHome()`                     current forum's /latest, else the Forums home
// - `showForumsHome()`             Forums home over the current page
// - `suggestedForumsToOffer`       suggested forums not added yet
// - `pinSuggested(_:)`             pins a suggested forum at once, then fetches its name/icon
// - `askForum(_:)`                 opens the forum and the Agent ("Ask the forum") for it
// - `isCurrent(_:)`                forum of the current page (or the current forum)

extension AppModel {
    /// Home button: the current forum's /latest; with no forum, the Forums home.
    func goHome() {
        if !browser.loadHome() {
            browser.showForumsHome()
        }
    }

    func showForumsHome() {
        browser.showForumsHome()
    }

    /// Suggested forums the user has not added yet.
    var suggestedForumsToOffer: [SuggestedForum] {
        Self.suggestedForums.filter { forum(for: $0.siteURL) == nil }
    }

    /// Pins a suggested forum immediately (no network), then refreshes its name
    /// and icon from `basic-info.json` in the background.
    func pinSuggested(_ suggested: SuggestedForum) {
        pin(Forum(siteURL: suggested.siteURL, name: suggested.name))
        refreshForumInfo(siteURL: suggested.siteURL)
    }

    /// "Ask the forum": opens the forum and prepares the Agent for it.
    func askForum(_ forum: Forum) {
        if !isCurrent(forum) || browser.showsForumsHome {
            openForum(forum)
        }
        agentSiteURL = forum.siteURL
        assistantMode = .agent
        panelRoute = .topic
        presentAssistant = true
        if !isProviderReady { needsProviderSetup = true }
    }

    /// The forum of the current page (or, off-forum, the current forum).
    func isCurrent(_ forum: Forum) -> Bool {
        (pageContext.siteURL ?? currentForum?.siteURL) == forum.siteURL
    }

    /// The forum the browser bar shows: the page's forum, else the current one.
    var barForum: Forum? {
        if let siteURL = pageContext.siteURL, let forum = forum(for: siteURL) {
            return forum
        }
        if pageContext.isForum, let siteURL = pageContext.siteURL {
            return Forum(siteURL: siteURL, name: pageContext.forumName, iconURL: pageContext.iconURL)
        }
        return currentForum
    }
}

#if DEBUG
extension AppModel {
    /// Screenshot / QA states:
    /// - `-dc-seed-forums`   pins three forums and adds two recents (icons fetched
    ///                       live unless `-dc-no-forum-icons`)
    /// - `-dc-no-forum-icons` letter monograms instead of forum icons (ForumIconPolicy)
    /// - `-dc-forums-home`   starts on the Forums home even when a forum was restored
    /// - `-dc-open <url>`    opens a page on launch
    /// - `-dc-show-switcher` opens the forum switcher after launch (ContentView)
    func applyDebugLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-dc-seed-forums"), forums.isEmpty {
            // Discourse Meta plus fictional communities on reserved example
            // domains (screenshots show no real companies).
            let pinned = [
                Forum(siteURL: "https://meta.discourse.org", name: "Discourse Meta"),
                Forum(siteURL: "https://community.example.org", name: "Maker Space Community"),
                Forum(siteURL: "https://talk.example.com", name: "Trail Runners Club")
            ]
            pinned.forEach(pin)
            recordVisit(siteURL: "https://forum.example.net", name: "Home Lab Forum", iconURL: nil)
            recordVisit(siteURL: "https://bakers.example.org", name: "Sourdough Bakers", iconURL: nil)
            if ForumIconPolicy.loadsRemoteIcons {
                for forum in forums { refreshForumInfo(siteURL: forum.siteURL) }
            }
        }
        if let index = arguments.firstIndex(of: "-dc-open"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            browser.load(url)
        } else if arguments.contains("-dc-forums-home") {
            // After the restored forum's first navigation starts (which
            // would otherwise dismiss it).
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.browser.showForumsHome()
            }
        }
    }
}
#endif
