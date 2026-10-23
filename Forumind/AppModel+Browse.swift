import Foundation
import SwiftUI

// MARK: - Browsing and Home (UI engineer A)
//
// - `goHome()`                     current forum's /latest, else Home
// - `showForumsHome()`             Home over the current page (HomeView.swift)
// - `showsTodayPage`               the Today page pushed over Home
// - `todayModuleState`             the Today module's state (HomeState.swift)
// - `applyLaunchRuleIfNeeded()`    the first activation: Home or the last forum
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

    /// The Today page, pushed over Home (Home's Today module, a digest
    /// notification, the Open Today and Play Today intents). Setting it
    /// false goes back to Home.
    var showsTodayPage: Bool {
        get { browser.showsForumsHome && homePath.first == .today }
        set {
            if newValue {
                browser.showForumsHome()
                if homePath != [.today] { homePath = [.today] }
            } else if !homePath.isEmpty {
                homePath = []
            }
        }
    }

    /// Home hid (a page loaded, Back): the pages pushed over it go too.
    func homeVisibilityChanged() {
        if !browser.showsForumsHome, !homePath.isEmpty { homePath = [] }
    }

    var todayModuleState: TodayModuleState {
        let digest = todaysDigest
        return TodayModuleState.resolve(
            digest: digest,
            digestActivity: digestActivity,
            providerReady: isProviderReady(for: .assistant),
            episode: podcast.episode?.digestID == digest?.id ? podcast.episode : nil,
            podcastActivity: podcast.activity
        )
    }

    // MARK: Launch rule (§7.2)

    /// A link, notification, Siri, Spotlight or the share extension opened
    /// something: before the rule has run, the page is left to it.
    func noteExternalEntry() {
        if launchPhase == .waiting { launchPhase = .openedExternally }
    }

    /// Once, on the first activation (after the share inbox and today's
    /// digest have started): Home or the last forum, which the browser has
    /// been loading since launch. A request from outside always wins.
    func applyLaunchRuleIfNeeded(now: Date = Date()) {
        guard launchPhase != .settled, settings.hasCompletedOnboarding else { return }
        let openedExternally = launchPhase == .openedExternally
        launchPhase = .settled
        #if DEBUG
        // UI tests and samples land where their arguments say, unless they
        // ask for the rule (`-dc-launch automatic|home|lastForum`).
        let arguments = ProcessInfo.processInfo.arguments
        let override = AssistantDebug.value("-dc-launch").flatMap(LaunchDestination.init(rawValue:))
        if override == nil, arguments.contains(where: { $0.hasPrefix("-dc-") || $0.hasPrefix("-ui-test-") }) { return }
        let setting = override ?? settings.launchDestination
        #else
        let setting = settings.launchDestination
        #endif
        podcast.refresh()
        let defaults = UserDefaults.standard
        let decision = LaunchRule.decide(
            setting: setting,
            openedExternally: openedExternally,
            todayHasSomething: todayModuleState.hasSomething,
            lastHomeAutoShownDay: defaults.string(forKey: LaunchRule.lastHomeAutoShownDayKey),
            now: now
        )
        switch decision {
        case .external, .lastForum:
            break
        case .home(let marksDay):
            if marksDay { defaults.set(DailyDigest.dayKey(for: now), forKey: LaunchRule.lastHomeAutoShownDayKey) }
            // Over the restored forum's first load, which would otherwise
            // dismiss it as it starts.
            browser.showForumsHome(overPendingLoad: true)
        }
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
        requestAssistant()
        if !isProviderReady(for: .agent) { needsProviderSetup = .agent }
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
    /// - `-dc-forums-home`   starts on Home even when a forum was restored
    /// - `-dc-launch <destination>` applies the launch rule (automatic | home |
    ///                       lastForum) although this is a `-dc-` launch
    /// - `-dc-open <url>`    opens a page on launch
    /// - `-dc-show-switcher` opens the forum switcher after launch (ContentView)
    /// - `-dc-browse-post`, `-dc-browse-find`, `-dc-browse-debug` post-level
    ///                       browsing (AppModel+Navigation.swift)
    func applyDebugLaunchArguments() {
        applyBrowseDebugArguments()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-dc-seed-forums"), forums.isEmpty {
            // Discourse Meta plus fictional communities on reserved example
            // domains (screenshots show no real companies).
            // Names in the app's language (SampleContent.swift).
            let text = SampleContent.current
            let pinned = [text.meta, text.makers, text.trailRunners].map {
                Forum(siteURL: $0.siteURL, name: $0.name)
            }
            pinned.forEach(pin)
            recordVisit(siteURL: text.homeLab.siteURL, name: text.homeLab.name, iconURL: nil)
            recordVisit(siteURL: text.bakers.siteURL, name: text.bakers.name, iconURL: nil)
            if ForumIconPolicy.loadsRemoteIcons {
                for forum in forums { refreshForumInfo(siteURL: forum.siteURL) }
            }
        }
        if let index = arguments.firstIndex(of: "-dc-open"), index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            browser.load(url)
        } else if arguments.contains("-dc-forums-home") {
            // Kept over the restored forum's first load.
            browser.showForumsHome(overPendingLoad: true)
        }
    }
}
#endif
