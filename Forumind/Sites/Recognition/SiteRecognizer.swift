import Foundation

/// Reads a platform's pages: from the page facts, and from URLs alone. Pure
/// and dependency-free, so the share extension can compile the same file
/// (nothing here may use an adapter or the network).
protocol SiteRecognizer: Sendable {
    var kind: SiteKind { get }
    /// The platform's proper noun ("Discourse"), not localized: the share badge
    /// and not-a-forum copy name it.
    var platformName: String { get }
    /// The facts the probe must collect for `recognize` and the adapter's `session`.
    var factKeys: PageFactKeys { get }
    /// nil when the page is not this platform. `url` is the page's address now
    /// (the facts may be about the same document at an earlier route).
    func recognize(facts: PageFacts, url: URL) -> SitePageMatch?
    /// Topic id from the URL alone, for a page on a known forum before the probe reports.
    func topicID(fromURL url: URL, basePath: String) -> String?
    /// Topic id anywhere in a URL whose base path is unknown (the `.maybe` state, shared links).
    func looseTopicID(in url: URL) -> String?
    /// The post a topic URL points at, nil when it names none.
    func postNumber(in url: URL) -> Int?
    /// The site URL when every page on `host` is one site whatever the path
    /// (Reddit); nil for platforms that are self-hosted.
    func claimedSiteURL(forHost host: String) -> String?
}

extension SiteRecognizer {
    func claimedSiteURL(forHost host: String) -> String? { nil }
}

struct SitePageMatch: Equatable, Sendable {
    var siteURL: String
    var basePath: String
    /// Empty when the page does not say.
    var forumName: String
    var kind: SiteKind
    /// The recognizer's `platformName`.
    var platformName: String
    /// The topic the page shows, when the recognizer can name it: from the
    /// facts where the URL carries no id (a WordPress slug permalink), else from
    /// its own `topicID(fromURL:basePath:)`. nil on a forum's home or list pages.
    var topicID: String?
}
