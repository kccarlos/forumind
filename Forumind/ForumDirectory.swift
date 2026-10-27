import Foundation
import SwiftUI

/// A forum the user added or visited. Pinned forums are ordered by
/// `pinOrder`; the rest are "recent", newest visit first.
struct Forum: Codable, Identifiable, Equatable, Hashable {
    /// Normalized site URL (origin + base path), e.g. `https://example.com/forum`.
    var siteURL: String
    /// The platform, which picks the site adapter (`AppModel.adapter(for:)`).
    /// Stored once here and synced with the record.
    var kind: SiteKind
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

    init(
        siteURL: String,
        kind: SiteKind,
        name: String,
        iconURL: URL? = nil,
        isPinned: Bool = false,
        pinOrder: Int = 0,
        addedAt: Date = Date(),
        lastVisitedAt: Date? = nil
    ) {
        self.siteURL = siteURL
        self.kind = kind
        self.name = name
        self.iconURL = iconURL
        self.isPinned = isPinned
        self.pinOrder = pinOrder
        self.addedAt = addedAt
        self.lastVisitedAt = lastVisitedAt
    }

    private enum CodingKeys: String, CodingKey {
        case siteURL, kind, name, iconURL, isPinned, pinOrder, addedAt, lastVisitedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        siteURL = try container.decode(String.self, forKey: .siteURL)
        // Synced-data exception (ENGINEERING_RULES): every forum saved or synced before kinds existed is Discourse. Remove once every device has run this build.
        kind = try container.decodeIfPresent(SiteKind.self, forKey: .kind) ?? .discourse
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        iconURL = try container.decodeIfPresent(URL.self, forKey: .iconURL)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        pinOrder = try container.decodeIfPresent(Int.self, forKey: .pinOrder) ?? 0
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastVisitedAt = try container.decodeIfPresent(Date.self, forKey: .lastVisitedAt)
    }
}

/// A well-known public forum offered before the user adds any.
struct SuggestedForum: Identifiable, Equatable {
    /// The platform it declares, which picks the adapter once it is added.
    var kind: SiteKind
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

/// Add forum: detecting the platform of a typed address and its outcome.
/// `detecting` is entered once per address (a repeated tap joins it);
/// `failed` is the network's fault and may be retried; `unsupported` is
/// shown as `ForumDirectoryError.notDiscourse` in P0.
enum AddForumPhase: Equatable {
    case idle
    case detecting(address: String)
    case recognized(kind: SiteKind, siteURL: String)
    case unsupported
    case failed(NetworkFailure)
}

/// What one Add forum detection is for; the same request joins a running one.
struct AddForumRequest: Equatable {
    var address: String
    var pin: Bool
}

/// The user's forums (pure; `AppModel` persists it in the snapshot).
struct ForumDirectory: Equatable {
    var forums: [Forum] = []

    #if DEBUG
    /// The DEBUG sample suggestions replace the real ones (`SuggestedForums.sample`).
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

    /// Adds the forum (unpinned) or refreshes its name/icon. Returns it. A stored
    /// forum keeps its kind: a different `kind` is a bug (DEBUG assert) unless
    /// the caller validated the site just now (`overwritingKind`, Add forum).
    @discardableResult
    mutating func upsert(
        siteURL: String,
        kind: SiteKind,
        name: String?,
        iconURL: URL?,
        visitedAt: Date? = nil,
        overwritingKind: Bool = false
    ) -> Forum? {
        // `.unknown` is a display placeholder (`AppModel.forumInfo`); it is never stored or synced.
        guard kind != .unknown, let normalized = ForumSite.normalizeSiteURL(siteURL) else { return nil }
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let index = forums.firstIndex(where: { $0.siteURL == normalized }) {
            if overwritingKind || forums[index].kind == .unknown {
                forums[index].kind = kind
            } else {
                assert(forums[index].kind == kind, "\(normalized) is \(forums[index].kind), not \(kind)")
            }
            if !trimmedName.isEmpty { forums[index].name = trimmedName }
            if let iconURL { forums[index].iconURL = iconURL }
            if let visitedAt { forums[index].lastVisitedAt = visitedAt }
            return forums[index]
        }
        let forum = Forum(
            siteURL: normalized,
            kind: kind,
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
}

/// A site's well-known public forums (`SiteAdapter.suggestedForums`).
struct SuggestedForums {
    var general: [SuggestedForum]
    /// Offered first in the walkthrough when the app language is Chinese.
    var chinese: [SuggestedForum]
    #if DEBUG
    /// Fictional communities on reserved example domains, offered instead with
    /// `-dc-sample` / `-dc-seed-forums` (names in the app's language, SampleContent.swift).
    var sample: [SuggestedForum] = []
    #endif
}
