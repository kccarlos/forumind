import BackgroundTasks
import Foundation
import UserNotifications

/// Local notifications for watched topics. Tapping one opens the topic in the
/// embedded browser via `openURLNotification`.
final class WatchNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotifier()
    static let openURLNotification = Notification.Name(AppIdentity.identifier("openURL"))
    private static let urlKey = "url"

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
        content.body = count == 1
            ? "1 new reply in a watched topic."
            : "\(count) new replies in a watched topic."
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
