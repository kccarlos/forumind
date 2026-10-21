import Foundation
import UIKit

// MARK: - System entry points (App Intents, Spotlight, Siri suggestions)
//
// The intents (AppIntents.swift) run in the app's own process: there is no
// extension. Each one opens the app and hands a `SystemEntryAction` to
// `SystemEntry`, which delivers it to the AppModel (AppModel+System.swift)
// once RootView is on screen; an action that arrives during launch waits in
// `pending` until then. The forum entity's query reads the forums from the
// AppModel when it is there, else from the saved snapshot on disk (Siri and
// Shortcuts can launch the app in the background just to list them).

enum SystemEntryAction: Equatable {
    /// Summarize Link: open the topic and summarize it (the share
    /// extension's path).
    case summarize(URL)
    /// Ask a Forum: start Ask the forum on that forum.
    case ask(siteURL: String, question: String)
    case openToday
    /// Play today's episode if there is one, else open Today.
    case playToday
    /// Start voice through its consent gate, or open Settings › Voice.
    case startVoice
    /// A topic from Spotlight, a Siri suggestion or Open Topic.
    case openTopic(topicKey: String)
}

/// The AppModel side (a fake in tests).
@MainActor
protocol SystemEntryRouting: AnyObject {
    var forums: [Forum] { get }
    var topicEntities: [TopicEntity] { get }
    func perform(_ action: SystemEntryAction)
}

enum SystemEntryError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case noLink
    case emptyQuestion

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noLink: "There’s no web link to summarize. Copy a forum topic’s link first, or choose one."
        case .emptyQuestion: "Say or type a question to ask."
        }
    }
}

@MainActor
enum SystemEntry {
    private(set) static var pending: [SystemEntryAction] = []
    private(set) static weak var router: SystemEntryRouting?
    /// The clipboard's text or link (tests replace it).
    static var clipboard: () -> String? = {
        UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string
    }
    /// Forums when no router is attached (tests replace it).
    static var storedForums: () -> [Forum] = { StoredSnapshot.forums() }
    static var storedTopics: () -> [TopicEntity] = { StoredSnapshot.topics() }

    /// RootView is up: deliver what waited.
    static func attach(_ router: SystemEntryRouting) {
        self.router = router
        let queued = pending
        pending = []
        for action in queued { router.perform(action) }
    }

    static func send(_ action: SystemEntryAction) {
        if let router {
            router.perform(action)
        } else {
            pending.append(action)
        }
    }

    /// The link to summarize: the given one, else the first web link in
    /// the clipboard.
    static func summaryLink(_ url: URL?) throws -> URL {
        if let url, IncomingLink.isWebURL(url) { return url }
        if url == nil, let text = clipboard(), let link = IncomingLink.extractWebURL(from: text) { return link }
        throw SystemEntryError.noLink
    }

    /// The user's forums for the forum parameter: pinned in their order,
    /// then the recent ones.
    static func forumChoices() -> [Forum] {
        let forums = router?.forums ?? storedForums()
        let directory = ForumDirectory(forums: forums)
        return directory.pinned + directory.recent
    }

    static func topicChoices() -> [TopicEntity] {
        router?.topicEntities ?? storedTopics()
    }

    /// Tests: forget the router and anything queued.
    static func reset() {
        router = nil
        pending = []
    }
}

/// Reads only what the intents need from the saved snapshot
/// (`PersistentStore`'s state.json), without the topics' text.
enum StoredSnapshot {
    private struct Forums: Decodable {
        var forums: [Forum]?
    }

    private struct Topics: Decodable {
        struct Session: Decodable {
            var siteURL: String?
            var topicID: String
            var title: String
            var lastAccessedAt: Date?
        }
        var sessions: [Session]?
        var forums: [Forum]?
    }

    /// Test hook: when set, read instead of the app's snapshot.
    static var fileURLOverride: URL?

    /// `PersistentStore`'s default location.
    static var fileURL: URL? {
        if let fileURLOverride { return fileURLOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Forumind", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private static func decode<Value: Decodable>(_ type: Value.Type) -> Value? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    static func forums() -> [Forum] {
        decode(Forums.self)?.forums ?? []
    }

    static func topics() -> [TopicEntity] {
        guard let snapshot = decode(Topics.self) else { return [] }
        let names = Dictionary((snapshot.forums ?? []).map { ($0.siteURL, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        return (snapshot.sessions ?? [])
            .sorted { ($0.lastAccessedAt ?? .distantPast) > ($1.lastAccessedAt ?? .distantPast) }
            .compactMap { session in
                guard let siteURL = session.siteURL, let name = names[siteURL] else { return nil }
                return TopicEntity(
                    id: TopicIdentity.key(siteURL: siteURL, topicID: session.topicID),
                    title: session.title,
                    forumName: name
                )
            }
    }
}

// MARK: - Siri suggestions (NSUserActivity)

/// Offers the topics the user reads to Siri suggestions. Never eligible
/// for search (Spotlight has its own switch) or public indexing.
@MainActor
protocol TopicActivityDonating: AnyObject {
    func donate(topicKey: String, title: String, forumName: String, url: URL)
    /// The user left the topic.
    func resign()
    /// The switch went off: forget every donation.
    func deleteAll()
}

@MainActor
final class SystemTopicActivityDonor: TopicActivityDonating {
    private var current: NSUserActivity?

    func donate(topicKey: String, title: String, forumName: String, url: URL) {
        let activity = NSUserActivity(activityType: TopicActivity.type)
        activity.title = title
        activity.userInfo = [TopicActivity.topicKeyKey: topicKey, TopicActivity.urlKey: url.absoluteString]
        activity.requiredUserInfoKeys = [TopicActivity.topicKeyKey]
        activity.persistentIdentifier = topicKey
        activity.isEligibleForPrediction = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        activity.isEligibleForHandoff = false
        current?.invalidate()
        current = activity
        activity.becomeCurrent()
    }

    func resign() {
        current?.resignCurrent()
        current = nil
    }

    func deleteAll() {
        current?.invalidate()
        current = nil
        NSUserActivity.deleteAllSavedUserActivities {}
    }
}

/// Donates nothing (tests and preview stores).
@MainActor
final class DisabledTopicActivityDonor: TopicActivityDonating {
    func donate(topicKey: String, title: String, forumName: String, url: URL) {}
    func resign() {}
    func deleteAll() {}
}

enum TopicActivity {
    /// Listed in Info.plist `NSUserActivityTypes`.
    static var type: String { AppIdentity.identifier("topic") }
    static let topicKeyKey = "topicKey"
    static let urlKey = "url"

    /// The topic key of a continued activity (a Siri suggestion).
    static func topicKey(from activity: NSUserActivity) -> String? {
        activity.userInfo?[topicKeyKey] as? String
    }
}
