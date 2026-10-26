//
//  ForumindApp.swift
//  Forumind
//
//

import CoreSpotlight
import SwiftUI
import UserNotifications

/// Registers the watched-topic background refresh and the daily digest's
/// background prefetch, and receives notification taps; all must be wired
/// before launch finishes. In CloudKit builds it
/// also registers for the silent pushes that announce iCloud changes.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Called for each remote (CloudKit) notification. The sync engine sets
    /// it; without a handler the push is acknowledged with `.noData`.
    @MainActor static var remoteNotificationHandler: (([AnyHashable: Any]) async -> UIBackgroundFetchResult)?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = WatchNotifier.shared
        WatchBackgroundRefresh.register()
        DigestBackgroundPrefetch.register()
        #if CLOUDKIT_ENABLED
        // Silent pushes only: no permission prompt.
        application.registerForRemoteNotifications()
        #endif
        return true
    }

    #if CLOUDKIT_ENABLED
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {}

    /// Simulators without push support and devices offline end up here; sync
    /// still runs on launch, foreground, and local changes.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    @MainActor
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        guard let handler = Self.remoteNotificationHandler else { return .noData }
        return await handler(userInfo)
    }
    #endif
}

@main
struct ForumindApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var app: AppModel = {
        let model = AppModel()
        #if DEBUG
        model.applyOnboardingDebugArguments()
        #endif
        return model
    }()

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
        }
        .onChange(of: scenePhase) {
            app.handleScenePhase(scenePhase)
        }
        .commands {
            // Hardware keyboard: menu bar and the ⌘-hold overlay on iPad.
            WorkspaceCommands(playPause: app.playPauseShortcut)
        }
    }
}

/// ContentView plus the app-level hooks. The walkthrough, Terms of Use,
/// provider setup and Settings presentations go through the presentation
/// router (PresentationRouter.swift), which ContentView hosts.
private struct RootView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var router: PresentationRouter

    init(app: AppModel) {
        self.app = app
        router = app.router
    }

    var body: some View {
        ContentView(app: app)
            .environment(\.replayOnboarding, ReplayOnboardingAction { app.replayOnboarding() })
            .onChange(of: app.settings.hasCompletedOnboarding) {
                app.presentProviderSetupIfNeeded()
            }
            .onChange(of: app.needsProviderSetup) { app.presentProviderSetupIfNeeded() }
            // App Intents (Siri, Shortcuts, the Action button) wait for the
            // UI, so their sheets and panes can show.
            .task {
                SystemEntry.attach(app)
                // Siri learns the forum names for "Ask … in Forumind".
                app.forumsDidChangeForShortcuts()
            }
            // A Spotlight result or a Siri suggestion: open the topic.
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                if let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                   let topicKey = SpotlightCatalog.topicKey(fromIdentifier: identifier) {
                    app.noteExternalEntry()
                    app.openTopic(topicKey: topicKey)
                }
            }
            .onContinueUserActivity(TopicActivity.type) { activity in
                if let topicKey = TopicActivity.topicKey(from: activity) {
                    app.noteExternalEntry()
                    app.openTopic(topicKey: topicKey)
                }
            }
            // A request that arrived during the walkthrough is shown after it.
            .onChange(of: router.onboardingReplay) { app.presentProviderSetupIfNeeded() }
            // "Sync API keys" (Settings › iCloud Sync, reset, or a synced
            // settings change): move keys between iCloud Keychain and local.
            .onChange(of: app.settings.syncAPIKeys) { _, synchronizes in
                let keys = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map {
                    ($0, app.settings.configuration(for: $0).apiKey)
                })
                KeychainProviderKeyStore.shared.setSynchronizes(synchronizes, keys: keys)
            }
            #if DEBUG
            .task {
                if KeychainSyncProbe.isRequested {
                    app.router.keychainProbeResult = KeychainSyncProbe.run().summary
                }
                if OnboardingDebug.arguments.contains("-dc-panel-settings") {
                    try? await Task.sleep(for: .seconds(1))
                    // Once the page is up: the AI view going away (Home at
                    // launch) sends it back to the topic.
                    for _ in 0..<40 where app.browser.showsForumsHome {
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                    app.openPanelRoute(.settings)
                }
                if let value = OnboardingDebug.settingsPage {
                    app.router.item = .debugSettings(SettingsPage.parse(value))
                }
            }
            #endif
    }
}
