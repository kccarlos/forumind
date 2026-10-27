import Foundation

// The navigation model: one "current list" (`BrowseCursor`) that next and
// previous move along, where a topic opens (`BrowseLanding`), what a focus
// narrows the topic to (`BrowseFocus`), and the small value every action
// hands back (`BrowseResult`) for the voice layer to turn into a tool result.
// AppModel+Navigation.swift drives the browser with them.

/// One entry of the current list: a search hit, an agent source, or a post
/// of a focused set.
struct BrowseItem: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case searchHit
        case source
        case post
    }

    var kind: Kind
    var siteURL: String
    var topicID: String
    var slug: String?
    /// The post it points at; nil for a whole topic (a topic-level source).
    var postNumber: Int?
    var title: String
    var username: String?
    /// One line of text: the hit's blurb or the post's start (plain text).
    var excerpt: String

    var id: String { "\(kind.rawValue)|\(siteURL)|\(topicID)/\(postNumber ?? 0)" }

    var topicKey: String { TopicIdentity.key(siteURL: siteURL, topicID: topicID) }

    init(
        kind: Kind,
        siteURL: String,
        topicID: String,
        slug: String? = nil,
        postNumber: Int?,
        title: String,
        username: String? = nil,
        excerpt: String = ""
    ) {
        self.kind = kind
        self.siteURL = siteURL
        self.topicID = topicID
        self.slug = slug
        self.postNumber = postNumber
        self.title = title
        self.username = username
        self.excerpt = excerpt
    }

    init(hit: ForumSearchHit) {
        self.init(
            kind: .searchHit,
            siteURL: hit.topic.siteURL,
            topicID: hit.topic.topicID,
            slug: hit.topic.slug,
            postNumber: hit.postNumber,
            title: hit.topic.title,
            username: hit.username,
            excerpt: BrowseText.oneLine(hit.blurb ?? hit.topic.excerpt ?? "")
        )
    }

    /// A source of an agent answer; nil when its URL is not a topic on
    /// `siteURL`'s forum.
    init?(source: AgentSources.Source, siteURL: String, adapter: any SiteAdapter) {
        guard ForumSite.isSameForum(url: source.url, siteURL: siteURL),
              let topicID = adapter.recognizer.looseTopicID(in: source.url)
        else {
            return nil
        }
        let basePath = ForumSite.parse(siteURL: siteURL)?.basePath ?? ""
        self.init(
            kind: .source,
            siteURL: siteURL,
            topicID: topicID,
            slug: adapter.links.parse(source.url, basePath: basePath)?.slug,
            postNumber: source.postNumber,
            title: source.title
        )
    }
}

/// The current list and the position in it. Filled from search hits,
/// research sources or a focused set of posts; `next` and `previous` move
/// along it and never wrap.
struct BrowseCursor: Equatable {
    enum Origin: Equatable {
        case search(String)
        case research(String)
        case focus
        /// A source tapped in Ask the forum: its run's sources.
        case sources
    }

    /// How the result cards show it.
    enum Cards: Equatable {
        case hidden
        case expanded
        /// The small "N results" chip.
        case collapsed
    }

    private(set) var items: [BrowseItem] = []
    /// The current item; nil before the first `next` after a search.
    private(set) var index: Int?
    private(set) var origin: Origin?
    var cards: Cards = .hidden

    var isEmpty: Bool { items.isEmpty }
    var current: BrowseItem? { index.map { items[$0] } }
    var hasNext: Bool { !items.isEmpty && (index ?? -1) < items.count - 1 }
    var hasPrevious: Bool { (index ?? 0) > 0 }

    /// Replaces the list. `current` nil leaves no item current (after a
    /// search, `next` opens the first hit).
    mutating func replace(with items: [BrowseItem], origin: Origin, current: Int? = nil) {
        self.items = items
        self.origin = origin
        index = current.flatMap { items.indices.contains($0) ? $0 : nil }
        cards = items.isEmpty ? .hidden : .expanded
    }

    mutating func clear() {
        items = []
        index = nil
        origin = nil
        cards = .hidden
    }

    /// Moves to the next item and returns it; nil at the end (or empty),
    /// where the position stays.
    mutating func next() -> BrowseItem? {
        guard hasNext else { return nil }
        let next = (index ?? -1) + 1
        index = next
        return items[next]
    }

    /// Moves to the previous item; nil at the start (or before any item).
    mutating func previous() -> BrowseItem? {
        guard let index, index > 0 else { return nil }
        self.index = index - 1
        return items[index - 1]
    }

    /// Makes item `index` current and returns it.
    mutating func select(_ index: Int) -> BrowseItem? {
        guard items.indices.contains(index) else { return nil }
        self.index = index
        return items[index]
    }

    /// "2 of 5" (English, for the voice model).
    var positionText: String? {
        guard let index else { return nil }
        return "\(index + 1) of \(items.count)"
    }
}

/// Where `openTopic` lands.
enum BrowseLanding: Equatable {
    /// Post N (`/t/slug/id/N`).
    case post(Int)
    /// The accepted answer (Solved plugin); needs the topic's facts.
    case solution
    /// The last post (`/t/slug/id/last`, or its number once known).
    case last
    /// The topic's top posts (`?filter=summary`).
    case top
    /// The first post the reader hasn't seen: after a watched topic's known
    /// replies, else the plain topic URL, where Discourse puts a signed-in
    /// reader at their last-read post and a visitor at the top.
    case firstNew
}

/// What `focus` narrows the topic to.
enum BrowseFocus: Equatable {
    /// Only this author's posts (`?username_filters=`).
    case user(String)
    /// Only the opening poster's posts.
    case op
    /// The top posts (`?filter=summary`).
    case top
    /// Highlight these posts (a tour); the first is shown.
    case posts([Int])
    /// The whole topic again, nothing highlighted.
    case clear
}

/// What a navigation action did, for the voice layer to turn into a tool
/// result. English throughout: the model reads it, not the user.
struct BrowseResult: Codable, Equatable {
    enum Status: String, Codable {
        /// A topic or post is on screen.
        case opened
        /// Moved along the current list or the topic.
        case moved
        /// The topic is narrowed (or back to whole).
        case focused
        /// Search hits are on the cards.
        case found
        /// A post's text.
        case read
        /// Research finished; its first source is open.
        case answered
        case cancelled
        /// Nothing matched the search.
        case noResults
        /// The topic has no accepted answer; opened at the top instead.
        case noSolution
        /// `next` / `previous` at the end of the current list.
        case endOfList
        /// No current list to move along.
        case emptyList
        /// The post or topic doesn't exist (or isn't readable).
        case notFound
        /// Hidden by the user's blocks or filters: never shown or read.
        case hidden
        /// Not possible here: no forum, not a topic, offline.
        case unavailable
        case failed
    }

    /// One search hit or source, as the model is told it.
    struct Hit: Codable, Equatable {
        var number: Int
        var title: String
        var topicID: String
        var postNumber: Int?
        var username: String?
        var excerpt: String
    }

    var status: Status
    /// What the screen shows now, e.g. "Post 37 of 120 by alice (accepted answer)".
    var shown: String
    /// The landing post's text (author, then text), trimmed; or the answer.
    var content: String?
    var hits: [Hit]?

    init(status: Status, shown: String, content: String? = nil, hits: [Hit]? = nil) {
        self.status = status
        self.shown = shown
        self.content = content.map { BrowseText.trimmed($0) }
        self.hits = hits
    }
}

/// Text handling for the navigation layer (pure).
enum BrowseText {
    /// About 800 tokens: what a navigation result carries of a post.
    static let contentLimit = 3_000

    /// `text` cut to `limit` characters at a paragraph, sentence or word end
    /// near the limit, with "…" when cut.
    static func trimmed(_ text: String, limit: Int = contentLimit) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        // Prefer a break in the last fifth, so little is lost.
        let floor = head.index(head.startIndex, offsetBy: limit * 4 / 5)
        for separator in ["\n\n", ". ", "。", "\n", " "] {
            if let range = head.range(of: separator, options: .backwards), range.lowerBound >= floor {
                // Keep a sentence's period.
                let end = separator == ". " ? head.index(after: range.lowerBound) : range.lowerBound
                return String(head[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
            }
        }
        return head + "…"
    }

    /// Whitespace collapsed to one line, at most `limit` characters.
    static func oneLine(_ text: String, limit: Int = 160) -> String {
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
    }

    /// "Post 37 of 120 by alice (accepted answer)".
    static func postDescription(number: Int, total: Int?, username: String?, acceptedAnswer: Int?) -> String {
        var text = "Post \(number)"
        if let total, total >= number { text += " of \(total)" }
        if let username, !username.isEmpty { text += " by \(username)" }
        if acceptedAnswer == number { text += " (accepted answer)" }
        return text
    }

    /// A post as navigation results carry it: author line, then text.
    static func content(of post: BrowsePostText) -> String {
        "\(post.username), post \(post.number):\n\(post.text)"
    }
}
