//
//  ForumindApp.swift
//  Forumind
//
//

import SwiftUI
import UserNotifications

/// Registers the watched-topic background refresh and receives notification
/// taps; both must be wired before launch finishes. In CloudKit builds it
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
            WorkspaceCommands()
        }
    }
}

/// ContentView plus the app-level covers: the first-launch walkthrough and
/// provider setup requested by a shared link.
private struct RootView: View {
    @ObservedObject var app: AppModel
    @State private var replayingOnboarding = false
    @State private var showingProviderSetup = false
    #if DEBUG
    @State private var debugSettings: DebugSettingsRoute?
    @State private var keychainProbeResult: String?
    #endif

    private var showsOnboarding: Binding<Bool> {
        Binding(
            get: { !app.settings.hasCompletedOnboarding || replayingOnboarding },
            set: { presented in
                if !presented {
                    replayingOnboarding = false
                    if !app.settings.hasCompletedOnboarding { app.completeOnboarding() }
                }
            }
        )
    }

    var body: some View {
        ContentView(app: app)
            .environment(\.replayOnboarding, ReplayOnboardingAction { replayingOnboarding = true })
            .fullScreenCover(isPresented: showsOnboarding) {
                OnboardingFlow(app: app, initialStep: initialStep) {
                    replayingOnboarding = false
                }
            }
            .sheet(isPresented: $showingProviderSetup, onDismiss: {
                app.needsProviderSetup = nil
            }) {
                ProviderSetupSheet(app: app, role: app.needsProviderSetup ?? .assistant)
            }
            .onChange(of: app.settings.hasCompletedOnboarding) {
                presentProviderSetupIfNeeded()
            }
            .onChange(of: app.needsProviderSetup) { presentProviderSetupIfNeeded() }
            // A request that arrived during the walkthrough is shown after it.
            .onChange(of: replayingOnboarding) { presentProviderSetupIfNeeded() }
            // "Sync API keys" (Settings › iCloud Sync, reset, or a synced
            // settings change): move keys between iCloud Keychain and local.
            .onChange(of: app.settings.syncAPIKeys) { _, synchronizes in
                let keys = Dictionary(uniqueKeysWithValues: AIProvider.allCases.map {
                    ($0, app.settings.configuration(for: $0).apiKey)
                })
                KeychainProviderKeyStore.shared.setSynchronizes(synchronizes, keys: keys)
            }
            #if DEBUG
            .fullScreenCover(item: $debugSettings) { route in
                NavigationStack {
                    SettingsRootView(app: app, initialPage: route.page)
                        .navigationTitle("Settings")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .alert(
                Text(verbatim: "Keychain sync probe"),
                isPresented: Binding(get: { keychainProbeResult != nil }, set: { if !$0 { keychainProbeResult = nil } })
            ) {
                Button(role: .cancel) {} label: { Text(verbatim: "OK") }
            } message: {
                Text(keychainProbeResult ?? "")
            }
            .task {
                if KeychainSyncProbe.isRequested {
                    keychainProbeResult = KeychainSyncProbe.run().summary
                }
                if OnboardingDebug.arguments.contains("-dc-panel-settings") {
                    try? await Task.sleep(for: .seconds(1))
                    app.panelRoute = .settings
                    app.presentAssistant = true
                }
                if let value = OnboardingDebug.settingsPage {
                    debugSettings = DebugSettingsRoute(page: SettingsPage.parse(value))
                }
            }
            #endif
    }

    private var initialStep: OnboardingStep {
        #if DEBUG
        if let step = OnboardingDebug.initialStep, !replayingOnboarding { return step }
        #endif
        return .welcome
    }

    /// A shared link needs an AI provider first; not over the walkthrough.
    private func presentProviderSetupIfNeeded() {
        guard let role = app.needsProviderSetup, app.settings.hasCompletedOnboarding, !replayingOnboarding else { return }
        if app.isProviderReady(for: role) {
            app.needsProviderSetup = nil
        } else {
            showingProviderSetup = true
        }
    }
}

#if DEBUG
private struct DebugSettingsRoute: Identifiable {
    var page: SettingsPage?
    var id: String { page?.rawValue ?? "root" }
}
#endif
