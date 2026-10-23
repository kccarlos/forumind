import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

// MARK: - Spotlight (CoreSpotlight)
//
// Read topics and saved summaries are searchable in Spotlight: one item per
// topic key (`topic:<topicKey>`, the forum's site URL as the domain), with
// the title, the forum's name, the start of the saved summary and, when the
// forum's icon is already in the URL cache, its icon. Everything stays on
// the device (the items are never public).
//
// The index follows the data rather than each delete button: every change
// to the sessions or forums (summaries deleted, a forum removed, "clear all",
// a deletion synced from another device) schedules one reconcile, which
// diffs the wanted items against the last indexed ones (a fingerprint per
// item, kept in UserDefaults) and sends only the difference, in batches.
// A new `SpotlightIndexer.version` re-indexes everything once on launch.
// Turning the switch off (Settings › Data & privacy) deletes the app's
// whole index. Tapping a result arrives as `CSSearchableItemActionType`
// (RootView) and opens the topic.

/// One topic in Spotlight.
struct SpotlightEntry: Equatable {
    var topicKey: String
    var siteURL: String
    var title: String
    var forumName: String
    /// The start of the saved summary, as plain text; empty without one.
    var excerpt: String
    /// The topic page (with the post it was last opened at, when known).
    var url: URL
    var lastUsed: Date
    var iconURL: URL?

    var identifier: String { SpotlightCatalog.identifier(forTopicKey: topicKey) }

    /// Changes when anything the item shows changes.
    var fingerprint: String {
        let joined = [title, forumName, excerpt, url.absoluteString, iconURL?.absoluteString ?? ""]
            .joined(separator: "\u{1F}")
        return String(SyncCoding.hash(Data(joined.utf8)).prefix(16))
    }
}

enum SpotlightCatalog {
    static let identifierPrefix = "topic:"
    /// At most this many topics, most recently read first (summaries are
    /// always in).
    static let maximumEntries = 500
    static let excerptLength = 300

    static func identifier(forTopicKey topicKey: String) -> String { identifierPrefix + topicKey }

    static func topicKey(fromIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let key = String(identifier.dropFirst(identifierPrefix.count))
        return key.isEmpty ? nil : key
    }

    /// The topics to index: sessions of forums in the user's list (a forum
    /// removed from the list takes its topics out of Spotlight), summaries
    /// first, then the topics the user opened most recently (never ones only
    /// the agent read).
    static func entries(sessions: [TopicSession], forums: [Forum], limit: Int = maximumEntries) -> [SpotlightEntry] {
        let forumsBySite = Dictionary(forums.map { ($0.siteURL, $0) }, uniquingKeysWith: { first, _ in first })
        let entries: [SpotlightEntry] = sessions.compactMap { session in
            guard let forum = forumsBySite[session.siteURL],
                  session.hasSummary || session.openedByUserAt != nil
            else {
                return nil
            }
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return SpotlightEntry(
                topicKey: session.topicKey,
                siteURL: session.siteURL,
                title: title,
                forumName: forum.displayName,
                excerpt: session.hasSummary ? excerpt(of: session.summary) : "",
                url: session.url,
                lastUsed: max(session.openedByUserAt ?? .distantPast, session.summaryUpdatedAt ?? .distantPast),
                iconURL: forum.iconURL
            )
        }
        return entries
            .sorted {
                if $0.excerpt.isEmpty != $1.excerpt.isEmpty { return !$0.excerpt.isEmpty }
                return $0.lastUsed == $1.lastUsed ? $0.topicKey < $1.topicKey : $0.lastUsed > $1.lastUsed
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The summary as one plain line: no Markdown markers, links as their
    /// text, cut at a word near `excerptLength`.
    static func excerpt(of markdown: String) -> String {
        var text = markdown
        // [text](url) → text; images and code fences go.
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*```.*$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*(?:#{1,6}|[-*+]|\d{1,3}[.)]|>)\s+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[*_`|]+"#, with: "", options: .regularExpression)
        let words = text.split(whereSeparator: { $0.isWhitespace })
        var result = ""
        for word in words {
            let next = result.isEmpty ? String(word) : "\(result) \(word)"
            if next.count > excerptLength {
                return result.isEmpty ? String(next.prefix(excerptLength)) + "…" : result + "…"
            }
            result = next
        }
        return result
    }

    /// The Spotlight item for an entry; `thumbnail` is image data already
    /// on the device (never fetched for this).
    static func item(for entry: SpotlightEntry, thumbnail: Data? = nil) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = entry.title
        attributes.displayName = entry.title
        attributes.contentDescription = entry.excerpt.isEmpty ? entry.forumName : "\(entry.forumName) · \(entry.excerpt)"
        attributes.keywords = [entry.forumName, ForumSite.host(of: entry.siteURL)]
        attributes.contentURL = entry.url
        attributes.lastUsedDate = entry.lastUsed
        attributes.thumbnailData = thumbnail
        let item = CSSearchableItem(
            uniqueIdentifier: entry.identifier,
            domainIdentifier: entry.siteURL,
            attributeSet: attributes
        )
        // Kept until the app removes it.
        item.expirationDate = .distantFuture
        if #available(iOS 18, *) {
            item.associateAppEntity(TopicEntity(entry: entry), priority: 0)
        }
        return item
    }
}

// MARK: - The index

/// What the indexer needs from CoreSpotlight (tests use a fake).
protocol SpotlightIndexing: AnyObject {
    func index(_ items: [CSSearchableItem]) async throws
    func delete(identifiers: [String]) async throws
    func deleteAll() async throws
}

/// The app's index on the device.
final class SystemSpotlightIndex: SpotlightIndexing {
    private let index = CSSearchableIndex.default()

    func index(_ items: [CSSearchableItem]) async throws {
        try await index.indexSearchableItems(items)
    }

    func delete(identifiers: [String]) async throws {
        try await index.deleteSearchableItems(withIdentifiers: identifiers)
    }

    func deleteAll() async throws {
        try await index.deleteAllSearchableItems()
    }
}

/// Indexes nothing: tests and preview stores (see `AppModel.makeSpotlightIndexer`).
final class DisabledSpotlightIndex: SpotlightIndexing {
    func index(_ items: [CSSearchableItem]) async throws {}
    func delete(identifiers: [String]) async throws {}
    func deleteAll() async throws {}
}

/// What was last indexed: the index version and one fingerprint per item.
struct SpotlightBaseline: Codable, Equatable {
    var version: Int
    var fingerprints: [String: String]
}

protocol SpotlightBaselineStoring: AnyObject {
    func load() -> SpotlightBaseline?
    func save(_ baseline: SpotlightBaseline?)
}

final class UserDefaultsSpotlightBaseline: SpotlightBaselineStoring {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "dc.spotlightBaseline") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> SpotlightBaseline? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SpotlightBaseline.self, from: $0) }
    }

    func save(_ baseline: SpotlightBaseline?) {
        if let baseline, let data = try? JSONEncoder().encode(baseline) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

final class InMemorySpotlightBaseline: SpotlightBaselineStoring {
    var baseline: SpotlightBaseline?
    func load() -> SpotlightBaseline? { baseline }
    func save(_ baseline: SpotlightBaseline?) { self.baseline = baseline }
}

/// Keeps the index equal to the wanted entries (see the top of this file).
@MainActor
final class SpotlightIndexer {
    /// Bump when the items' content or identifiers change: the next launch
    /// re-indexes everything once.
    static let version = 1
    static let batchSize = 100

    let index: SpotlightIndexing
    let baseline: SpotlightBaselineStoring
    /// How long changes settle before a reconcile (pages bump a topic's
    /// last-read date on every visit).
    var delay: Duration = .seconds(2)
    /// Icon data already on the device for a forum icon URL.
    var thumbnail: (URL) -> Data? = SpotlightIndexer.cachedImageData

    /// The last queued job; jobs run one after another.
    private var tail: Task<Void, Never>?
    /// The queued reconcile, which a newer change replaces.
    private var pendingReconcile: Task<Void, Never>?

    init(index: SpotlightIndexing, baseline: SpotlightBaselineStoring) {
        self.index = index
        self.baseline = baseline
    }

    /// Reconciles after `delay`; a newer call replaces a pending one.
    /// `entries` nil means Spotlight is off.
    func schedule(_ entries: @escaping @MainActor () -> [SpotlightEntry]?) {
        pendingReconcile?.cancel()
        let previous = tail
        let delay = delay
        let job = Task { @MainActor [weak self] in
            await previous?.value
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            await self.reconcile(entries())
        }
        pendingReconcile = job
        tail = job
    }

    /// Deletes the app's whole index (the switch turned off, reset),
    /// after any job already running; a pending reconcile is dropped.
    func deleteAll() {
        pendingReconcile?.cancel()
        pendingReconcile = nil
        let previous = tail
        tail = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            try? await self.index.deleteAll()
            self.baseline.save(nil)
        }
    }

    /// Waits for the queued jobs (tests).
    func settle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }

    /// Sends the difference between the last indexed items and `entries`
    /// (nil: Spotlight is off, so the app's index goes).
    func reconcile(_ entries: [SpotlightEntry]?) async {
        let previous = baseline.load()
        guard let entries else {
            if previous != nil {
                try? await index.deleteAll()
                baseline.save(nil)
            }
            return
        }
        var known = previous?.fingerprints ?? [:]
        if previous?.version != Self.version {
            // A first run, or a new item format: start from an empty index.
            try? await index.deleteAll()
            known = [:]
        }
        let wanted = Dictionary(entries.map { ($0.identifier, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
        let removed = known.keys.filter { wanted[$0] == nil }.sorted()
        let changed = entries.filter { known[$0.identifier] != $0.fingerprint }
        var indexed = known.filter { wanted[$0.key] != nil }
        if !removed.isEmpty {
            do {
                try await index.delete(identifiers: removed)
            } catch {
                // Kept in the baseline, so the next reconcile tries again.
                for identifier in removed { indexed[identifier] = known[identifier] }
            }
        }
        for start in stride(from: 0, to: changed.count, by: Self.batchSize) {
            let batch = Array(changed[start..<min(start + Self.batchSize, changed.count)])
            let items = batch.map { entry in
                SpotlightCatalog.item(for: entry, thumbnail: entry.iconURL.flatMap(thumbnail))
            }
            do {
                try await index.index(items)
                for entry in batch { indexed[entry.identifier] = entry.fingerprint }
            } catch {
                continue
            }
            await Task.yield()
        }
        baseline.save(SpotlightBaseline(version: Self.version, fingerprints: indexed))
    }

    /// The forum icon from the URL cache (filled by the forum lists'
    /// AsyncImage), so indexing never makes a request.
    nonisolated static func cachedImageData(_ url: URL) -> Data? {
        URLCache.shared.cachedResponse(for: URLRequest(url: url))?.data
    }
}
