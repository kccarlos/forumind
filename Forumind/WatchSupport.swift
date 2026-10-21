import BackgroundTasks
import Foundation
import UserNotifications

/// Local notifications for watched topics and the daily digest. Tapping a
/// watched topic's opens it in the embedded browser via
/// `openURLNotification`; the digest's opens the Today page
/// (`openTodayNotification`).
final class WatchNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotifier()
    static let openURLNotification = Notification.Name(AppIdentity.identifier("openURL"))
    static let openTodayNotification = Notification.Name(AppIdentity.identifier("openToday"))
    private static let urlKey = "url"
    private static let routeKey = "route"
    private static let todayRoute = "today"
    /// A digest notification was tapped before the app model observed it
    /// (cold launch); the model opens the Today page when it's ready.
    @MainActor static var pendingTodayOpen = false

    func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func notifyNewReplies(topic: WatchedTopic, count: Int) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = topic.title
        content.body = String(
            localized: "\(count) new replies in a watched topic.",
            comment: "Notification body; the title is the topic's title"
        )
        content.sound = .default
        content.userInfo = [Self.urlKey: topic.url.absoluteString]
        content.threadIdentifier = topic.topicKey
        let request = UNNotificationRequest(
            identifier: "watch-\(topic.topicKey)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// "Today's digest is ready to make": the forum data is fetched, the
    /// summaries are made when the app opens (never claims they are ready).
    func notifyDigestReady(topicCount: Int) async {
        guard await isAuthorized() else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Today’s digest is ready to make", comment: "Notification title after the daily digest's forum data was fetched in the background; the AI summaries are made when the app opens")
        content.body = String(
            localized: "\(topicCount) topics are waiting. Open Forumind to summarize them.",
            comment: "Digest notification body; the number is how many topics the digest will have"
        )
        content.sound = .default
        content.userInfo = [Self.routeKey: Self.todayRoute]
        content.threadIdentifier = "digest"
        let request = UNNotificationRequest(identifier: "digest-ready", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if response.notification.request.content.userInfo[Self.routeKey] as? String == Self.todayRoute {
            await MainActor.run { Self.pendingTodayOpen = true }
            NotificationCenter.default.post(name: Self.openTodayNotification, object: nil)
            return
        }
        guard let urlString = response.notification.request.content.userInfo[Self.urlKey] as? String,
              let url = URL(string: urlString)
        else {
            return
        }
        NotificationCenter.default.post(name: Self.openURLNotification, object: url)
    }
}

/// System-scheduled background refresh of watched topics (best effort; iOS
/// decides when it runs). Registration must happen before launch finishes.
enum WatchBackgroundRefresh {
    /// Matches `BGTaskSchedulerPermittedIdentifiers` in Info.plist.
    static let identifier = AppIdentity.identifier("watchRefresh")
    static var perform: (() async -> Void)?
    private static let minimumInterval: TimeInterval = 30 * 60

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            handle(task)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        // Submitting fails on the simulator and when Background App Refresh is
        // off; foreground checks still cover those cases.
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGTask) {
        schedule()
        let work = Task {
            await perform?()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
