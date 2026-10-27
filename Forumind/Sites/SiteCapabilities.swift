import Foundation

/// What a site supports. Each operation is a value: present and working, or
/// nil, so no capability says yes and then throws. There are no flags for
/// data the pages themselves show (accepted answers, scores, author blocking):
/// consumers gate on the data (`facts?.acceptedAnswer`, `likeCount > 0`).
struct SiteCapabilities: Sendable {
    /// Candidates for the digest and podcast.
    var activeTopics: (any ActiveTopicsSource)?
    /// Post text by number from the API when the page doesn't have it.
    var postLookup: (any PostLookup)?
    /// Narrowed views of a topic (top posts, one author); nil = none.
    var topicFilters: (any TopicFilterSource)?
    /// The in-page bridge and DOM moderation.
    var pageBridge: PageBridgeProfile?
    /// The site's sign-in page.
    var loginURL: (@Sendable (_ siteURL: String) -> URL?)?
    /// The site's own search page for typed words.
    var searchPageURL: (@Sendable (_ siteURL: String, _ query: String) -> URL?)?
    /// The browser reads signed-in state and username from page facts.
    var session: (any SessionReader)?
    /// First-party paths the content blocker must never block.
    var firstPartyPathPatterns: [String]
}

protocol ActiveTopicsSource: Sendable {
    /// At most `budget` requests. Reports how many it used, so the digest's cap holds.
    func activeTopics(siteURL: String, budget: Int, net: SiteNetwork) async -> ActiveTopicsResult
}

struct ActiveTopicsResult: Sendable {
    var topics: [ForumTopicListing]?
    var requests: Int
    var failures: Int
}

protocol PostLookup: Sendable {
    func posts(_ numbers: [Int], in topic: TopicRef, facts: TopicFacts, net: SiteNetwork) async throws -> [ForumPost]
}

enum TopicFilter: Equatable, Sendable {
    case top
    case author(String)
}

protocol TopicFilterSource: Sendable {
    /// The topic URL narrowed by `filter`; `slug` is the page's own, when known.
    func url(topic: TopicRef, slug: String?, filter: TopicFilter) -> URL?
    /// True when `url` already is a filtered view.
    func isFiltered(_ url: URL) -> Bool
    /// The filtered topic's overview (the posts the filter shows).
    func overview(_ topic: TopicRef, filter: TopicFilter, net: SiteNetwork) async throws -> ForumTopicOverview
}

protocol SessionReader: Sendable {
    /// Signed-in state and the user's name from the page's facts.
    func session(from facts: PageFacts) -> (authenticated: Bool, username: String?)
}

/// What the page DOM scripts need.
struct PageBridgeProfile: Sendable {
    var bridgeInstaller: String
    var moderationInstaller: String
}
