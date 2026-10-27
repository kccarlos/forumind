import Foundation

/// One platform Forumind can read, as a value of pure functions plus network
/// calls through the `SiteNetwork` they are handed. Adapters hold no state.
/// What a site supports lives only in `capabilities`; the UI reads it and never
/// re-declares it. See dev/docs/SITE_ADAPTERS_PLAN.md.
protocol SiteAdapter: Sendable {
    var kind: SiteKind { get }
    /// Reads this platform's pages (shared with the share extension).
    var recognizer: any SiteRecognizer { get }
    /// Pure URL building and parsing.
    var links: any SiteLinks { get }
    var capabilities: SiteCapabilities { get }
    /// Site tool specs and how their arguments become a query (§3).
    var agent: AgentSiteProfile { get }
    /// The words of this site in the voice agent (§3.4).
    var voice: VoiceSiteProfile { get }
    /// What the material is in the summary, chunk and chat prompts (§11).
    var discussion: DiscussionProfile { get }

    // Add forum / directory
    /// Well-known public forums offered before the user adds any.
    var suggestedForums: SuggestedForums { get }
    /// Candidate site URLs for an address typed in Add forum.
    func siteURLCandidates(fromAddress address: String) -> [String]
    /// Name and icon; throws when the site is not this platform (validation for Add forum).
    func siteInfo(siteURL: String, net: SiteNetwork) async throws -> ForumSiteInfo

    // Reading
    /// Title, post count and facts without pulling the posts. Filtered views
    /// are `capabilities.topicFilters`.
    func overview(_ topic: TopicRef, net: SiteNetwork) async throws -> ForumTopicOverview
    func readTopic(
        _ request: TopicReadRequest,
        net: SiteNetwork,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void,
        onPage: (@Sendable (RawForumPage) async -> Void)?
    ) async throws -> ForumFetchResult
    func run(_ query: SiteQuery, net: SiteNetwork) async throws -> SiteQueryResult
}

extension SiteAdapter {
    /// Ask the forum is not a stored capability: an adapter that offers site
    /// tools has an agent (one source).
    var supportsAgent: Bool { !agent.siteTools.isEmpty }
}

struct TopicRef: Hashable, Sendable {
    var siteURL: String
    var topicID: String

    /// `host[/basePath]/t/{id}`, stable across page URLs and unique across forums.
    var topicKey: String? { ForumSite.topicKey(siteURL: siteURL, topicID: topicID) }
}

struct TopicReadRequest: Sendable {
    var topic: TopicRef
    /// A hint, not an obligation. Discourse reuses full pages; an adapter whose
    /// content is not append-only may ignore it.
    var cachedPages: [RawForumPage]
    var knownTotalPosts: Int?
}

enum SearchScope: Equatable, Sendable {
    case forum
    case topic(id: String)
    case comments
}

/// What a search or list tool asks for, already validated. Adapters may reject
/// cases they don't support (`SiteQueryError.unsupported`), but the agent never
/// offers a tool whose query they reject, because tool specs come from the same adapter.
enum SiteQuery: Equatable, Sendable {
    case search(text: String, scope: SearchScope, options: SearchOptions = SearchOptions())
    case latest
}

/// Filters of a search that is not written in the query text. Discourse puts
/// them in its query syntax and ignores these; a platform with a REST search
/// reads them. The profile's `query` validates the model's arguments into this.
struct SearchOptions: Equatable, Sendable {
    /// A category name or slug.
    var category: String?
    var after: Date?
    var before: Date?
    /// 1-based result page.
    var page = 1
}

extension SearchOptions {
    /// From a search tool's string arguments: `category` (when the tool has
    /// one), dates as `YYYY-MM-DD`, `page` 1 to 3. Anything else throws
    /// `AgentError.invalidArgument` (the model sees it and corrects the call).
    init(arguments: [String: String], allowsCategory: Bool = true) throws {
        self.init()
        if allowsCategory, let category = arguments["category"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !category.isEmpty {
            self.category = category
        }
        func date(_ name: String) throws -> Date? {
            guard let text = arguments[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let format = Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!).year().month().day()
            guard text.count == 10, let parsed = try? Date(text, strategy: format) else {
                throw AgentError.invalidArgument(name, reason: "use the form YYYY-MM-DD.")
            }
            return parsed
        }
        after = try date("after")
        before = try date("before")
        if let text = arguments["page"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            guard let number = Int(text), (1...3).contains(number) else {
                throw AgentError.invalidArgument("page", reason: "use a number from 1 to 3.")
            }
            page = number
        }
    }
}

enum SiteQueryError: Error, Equatable {
    case unsupported
}

struct SiteQueryResult: Sendable {
    var topics: [ForumTopicListing] = []
    var hits: [ForumSearchHit] = []
}

/// Pure link logic of one platform. No network, no state.
protocol SiteLinks: Sendable {
    /// The site's home in the browser (Discourse `/latest`).
    func homeURL(siteURL: String) -> URL?
    func topicURL(siteURL: String, topicID: String, slug: String?) -> URL?
    /// A post inside a topic. `anchor` is `PostBlock.anchor` (Discourse ignores it and uses the number).
    func postURL(topicURL: URL, number: Int, anchor: String?) -> URL
    /// The topic page without post, query or fragment.
    func topicPageURL(_ url: URL) -> URL
    /// The address a shown topic page is remembered by (`ForumTopic.url`). Kept
    /// apart from `topicPageURL` because Discourse keeps the post number the
    /// page is at and WordPress must keep its `?p=` query.
    func canonicalPageURL(_ url: URL) -> URL
    /// A URL on this platform's site → topic id, slug, post number.
    func parse(_ url: URL, basePath: String) -> SiteLink?
    /// Lands on the newest post when its number is unknown (Discourse `/last`), else nil.
    func lastPostURL(topicURL: URL) -> URL?
}

extension SiteLinks {
    /// The page address without query and fragment.
    func canonicalPageURL(_ url: URL) -> URL {
        ForumSite.withoutQueryAndFragment(url)
    }

    /// The topic, or with a `postNumber` that post of it. Nil for an invalid
    /// topic or a post number below 1. `anchor` is the post's `PostBlock.anchor`
    /// when the caller has the read page.
    func url(siteURL: String, topicID: String, slug: String?, postNumber: Int?, anchor: String? = nil) -> URL? {
        guard let topic = topicURL(siteURL: siteURL, topicID: topicID, slug: slug) else { return nil }
        guard let postNumber else { return topic }
        guard postNumber >= 1 else { return nil }
        return postURL(topicURL: topic, number: postNumber, anchor: anchor)
    }
}

struct SiteLink: Equatable, Sendable {
    var topicID: String
    var slug: String?
    var postNumber: Int?
}

/// Stable tool names shared by every site (the model, the transcript and Apple Intelligence's
/// guided enum use them). Adding one is a deliberate app change, not an adapter's.
enum AgentToolName: String, CaseIterable, Sendable {
    case searchForum = "search_forum", searchComments = "search_comments", listLatest = "list_latest"
    case readTopic = "read_topic", summarizeTopic = "summarize_topic", savedSummaries = "saved_summaries"
    case watchTopic = "watch_topic", finalAnswer = "final_answer"

    /// Specified and run by the app, whatever the site, in `AgentPrompt` order.
    static let appTools: [AgentToolName] = [.readTopic, .summarizeTopic, .savedSummaries, .watchTopic, .finalAnswer]
}

/// A site's part of the agent: the phrases its prompt uses, the tools it
/// specifies and how their arguments become a typed query.
struct AgentSiteProfile: Sendable {
    /// "a Discourse forum": completes "a research agent for <name> (<url>), …".
    var siteDescription: String
    /// "forum": what the run's site is called in the prompt and tool texts.
    var siteNoun: String
    /// "topic": what a thread is called there.
    var topicNoun: String
    /// The prompt's rule on post numbers and how to cite one (the whole sentence).
    var postNumbering: String
    /// The `final_answer` sentence on citing a post.
    var postCitation: String
    /// Ordered; the site's search and list tools.
    var siteTools: [AgentToolSpec]
    /// Arguments of a site tool → query; throws `AgentError.missingArgument`.
    var query: @Sendable (_ tool: AgentToolName, _ arguments: [String: String]) throws -> SiteQuery
    /// "(post N: <topic page>/N)": how the model builds a link to one post.
    var postLinkHint: @Sendable (_ topicURL: URL) -> String
}
