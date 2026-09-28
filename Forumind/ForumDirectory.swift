import Foundation
import SwiftUI

/// A Discourse forum the user added or visited. Pinned forums are ordered by
/// `pinOrder`; the rest are "recent", newest visit first.
struct Forum: Codable, Identifiable, Equatable, Hashable {
    /// Normalized site URL (origin + base path), e.g. `https://example.com/forum`.
    var siteURL: String
    var name: String
    var iconURL: URL?
    var isPinned = false
    var pinOrder = 0
    var addedAt = Date()
    var lastVisitedAt: Date?

    var id: String { siteURL }
    /// `host[/basePath]` for display.
    var host: String { ForumSite.host(of: siteURL) }
    var displayName: String { ForumSite.displayName(siteURL: siteURL, name: name) }
    /// The forum home page (`/latest`).
    var latestURL: URL? { ForumSite.latestURL(siteURL: siteURL) }

    init(
        siteURL: String,
        name: String,
        iconURL: URL? = nil,
        isPinned: Bool = false,
        pinOrder: Int = 0,
        addedAt: Date = Date(),
        lastVisitedAt: Date? = nil
    ) {
        self.siteURL = siteURL
        self.name = name
        self.iconURL = iconURL
        self.isPinned = isPinned
        self.pinOrder = pinOrder
        self.addedAt = addedAt
        self.lastVisitedAt = lastVisitedAt
    }

    private enum CodingKeys: String, CodingKey {
        case siteURL, name, iconURL, isPinned, pinOrder, addedAt, lastVisitedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        iconURL = try container.decodeIfPresent(URL.self, forKey: .iconURL)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinOrder = try container.decodeIfPresent(Int.self, forKey: .pinOrder) ?? 0
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastVisitedAt = try container.decodeIfPresent(Date.self, forKey: .lastVisitedAt)
    }
}

/// A well-known public Discourse forum offered before the user adds any.
struct SuggestedForum: Identifiable, Equatable {
    var name: String
    var siteURL: String
    /// One line about the community.
    var description: String

    var id: String { siteURL }
    var host: String { ForumSite.host(of: siteURL) }
}

enum ForumDirectoryError: LocalizedError, Equatable {
    case invalidAddress
    case notDiscourse(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress:
            String(localized: "Enter a forum address such as meta.discourse.org.", comment: "Add forum error; keep the example address as is")
        case .notDiscourse(let host):
            String(localized: "\(host) doesn’t look like a Discourse forum.", comment: "Add forum error; the placeholder is a web address such as forum.example.com")
        }
    }
}

/// The user's forums (pure; `AppModel` persists it in the snapshot).
struct ForumDirectory: Equatable {
    var forums: [Forum] = []

    static let suggested: [SuggestedForum] = [
        SuggestedForum(
            name: "Discourse Meta",
            siteURL: "https://meta.discourse.org",
            description: String(localized: "Discourse’s own community for features, support, and plugins.", comment: "Description of a suggested forum")
        ),
        SuggestedForum(
            name: "OpenAI Developer Community",
            siteURL: "https://community.openai.com",
            description: String(localized: "Developers discussing the OpenAI API, models, and tools.", comment: "Description of a suggested forum")
        ),
        SuggestedForum(
            name: "Cursor Community Forum",
            siteURL: "https://forum.cursor.com",
            description: String(localized: "Help, bug reports, and tips for the Cursor code editor.", comment: "Description of a suggested forum")
        ),
        SuggestedForum(
            name: "Discussions on Python.org",
            siteURL: "https://discuss.python.org",
            description: String(localized: "Python language ideas, packaging, and help.", comment: "Description of a suggested forum")
        ),
        SuggestedForum(
            name: "Home Assistant Community",
            siteURL: "https://community.home-assistant.io",
            description: String(localized: "Home automation setups, integrations, and troubleshooting.", comment: "Description of a suggested forum")
        )
    ]

    #if DEBUG
    /// Offered instead of `suggested` with `-dc-sample` / `-dc-seed-forums`,
    /// so screenshots show fictional communities (reserved example domains).
    /// Names in the app's language (SampleContent.swift).
    static var sampleSuggested: [SuggestedForum] {
        let text = SampleContent.current
        return [
            SuggestedForum(
                name: text.boardGames.name,
                siteURL: text.boardGames.siteURL,
                description: text.boardGamesDescription
            ),
            SuggestedForum(
                name: text.gardeners.name,
                siteURL: text.gardeners.siteURL,
                description: text.gardenersDescription
            )
        ]
    }

    static var usesSampleSuggestions: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("-dc-sample") || arguments.contains("-dc-seed-forums")
    }
    #endif

    var pinned: [Forum] {
        forums.filter(\.isPinned).sorted { $0.pinOrder < $1.pinOrder }
    }

    /// Unpinned forums, most recently visited (or added) first.
    var recent: [Forum] {
        forums.filter { !$0.isPinned }.sorted {
            ($0.lastVisitedAt ?? $0.addedAt) > ($1.lastVisitedAt ?? $1.addedAt)
        }
    }

    func forum(siteURL: String) -> Forum? {
        let normalized = ForumSite.normalizeSiteURL(siteURL) ?? siteURL
        return forums.first { $0.siteURL == normalized }
    }

    /// The directory forum a page URL belongs to (longest base path wins).
    func forum(containing url: URL) -> Forum? {
        forums
            .filter { ForumSite.isSameForum(url: url, siteURL: $0.siteURL) }
            .max { $0.siteURL.count < $1.siteURL.count }
    }

    /// Adds the forum (unpinned) or refreshes its name/icon. Returns it.
    @discardableResult
    mutating func upsert(
        siteURL: String,
        name: String?,
        iconURL: URL?,
        visitedAt: Date? = nil
    ) -> Forum? {
        guard let normalized = ForumSite.normalizeSiteURL(siteURL) else { return nil }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let index = forums.firstIndex(where: { $0.siteURL == normalized }) {
            if !trimmedName.isEmpty { forums[index].name = trimmedName }
            if let iconURL { forums[index].iconURL = iconURL }
            if let visitedAt { forums[index].lastVisitedAt = visitedAt }
            return forums[index]
        }
        let forum = Forum(
            siteURL: normalized,
            name: ForumSite.displayName(siteURL: normalized, name: trimmedName),
            iconURL: iconURL,
            addedAt: visitedAt ?? Date(),
            lastVisitedAt: visitedAt
        )
        forums.append(forum)
        return forum
    }

    mutating func setPinned(_ pinned: Bool, siteURL: String) {
        guard let index = forums.firstIndex(where: { $0.siteURL == siteURL }),
              forums[index].isPinned != pinned
        else {
            return
        }
        forums[index].isPinned = pinned
        forums[index].pinOrder = pinned ? (self.pinned.map(\.pinOrder).max() ?? -1) + 1 : 0
        renumberPinned()
    }

    mutating func movePinned(fromOffsets source: IndexSet, toOffset destination: Int) {
        var ordered = pinned
        ordered.move(fromOffsets: source, toOffset: destination)
        for (order, forum) in ordered.enumerated() {
            if let index = forums.firstIndex(where: { $0.siteURL == forum.siteURL }) {
                forums[index].pinOrder = order
            }
        }
    }

    mutating func remove(siteURL: String) {
        forums.removeAll { $0.siteURL == siteURL }
        renumberPinned()
    }

    private mutating func renumberPinned() {
        for (order, forum) in pinned.enumerated() {
            if let index = forums.firstIndex(where: { $0.siteURL == forum.siteURL }) {
                forums[index].pinOrder = order
            }
        }
    }

    /// Candidate site URLs for an address typed in "Add forum": a full URL or
    /// a bare host, optionally with a page path. A path is cut before known
    /// Discourse routes (`/t/`, `/latest`, `/c/`, …) to find a subfolder base
    /// path; the bare origin is always tried last.
    static func candidateSiteURLs(fromAddress address: String) -> [String] {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return [] }
        if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) == nil {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let isLocal = host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1")
            guard host.contains(".") || isLocal else { return [] }
            text = (isLocal ? "http://" : "https://") + text
        }
        guard let url = URL(string: text),
              let origin = ForumSite.origin(of: url)
        else {
            return []
        }
        let routes: Set<String> = [
            "t", "latest", "top", "new", "unread", "categories", "c", "tag", "tags",
            "u", "users", "search", "login", "session", "about", "g", "groups", "posts",
            "raw", "badges", "faq", "guidelines", "tos", "privacy", "my"
        ]
        let segments = url.path.split(separator: "/").map(String.init)
        var baseSegments: [String] = []
        for segment in segments {
            if routes.contains(segment) || segment.hasSuffix(".json") { break }
            baseSegments.append(segment)
        }
        var candidates: [String] = []
        if !baseSegments.isEmpty {
            let basePath = ForumSite.normalizeBasePath("/" + baseSegments.joined(separator: "/"))
            if !basePath.isEmpty { candidates.append(origin.origin + basePath) }
        }
        candidates.append(origin.origin)
        return candidates
    }
}
