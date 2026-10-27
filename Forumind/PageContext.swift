import Foundation

/// A forum the app already knows (from the forum directory). Pages on it are
/// treated as its platform before the probe reports, so topics are detected
/// immediately on load.
struct KnownForumSite: Equatable {
    var siteURL: String
    var name: String
    var iconURL: URL?
    var kind: SiteKind
}

/// The browser's current page as the assistant sees it. States:
///
///   loading     no page yet, or the page has not been checked yet
///   notForum    the page is not a forum of a supported platform
///   maybe       a topic-looking URL the probe has not confirmed yet
///   forumHome   a forum page that is not a topic
///   topic       a forum topic
///
/// On a topic it also says where the reader is: the post in the URL
/// (Discourse rewrites `/t/slug/id/N` with `replaceState` while scrolling),
/// the posts on screen and the highlighted ones (from the browser bridge,
/// BrowseBridge.swift), and, once AppModel has the topic's facts, the post
/// count and the accepted answer. Those position fields change while the
/// reader scrolls; `sameDocument(as:)` ignores them.
struct PageContext: Equatable {
    enum State: String, Equatable {
        case loading
        case notForum
        case maybe
        case forumHome
        case topic
    }

    var url: URL?
    /// The platform of the page: non-nil exactly when `state` is `.forumHome` or `.topic`.
    var site: SiteKind?
    /// Site URL (origin + base path) when the page is on a forum.
    var siteURL: String?
    var basePath = ""
    var forumName = ""
    var iconURL: URL?
    var topic: ForumTopic?
    var state: State = .loading
    /// The post number in the topic URL (Discourse `/t/slug/id/N`); nil at the
    /// top of a topic the site hasn't rewritten yet, and off topics.
    var postNumber: Int?
    /// Rendered posts in the viewport, top to bottom (not hidden ones).
    var visiblePosts: [Int] = []
    /// Posts the bridge has highlighted on the page now.
    var highlightedPosts: [Int] = []
    /// From the topic's facts (`TopicFacts`), when AppModel has them.
    var postsCount: Int?
    var acceptedAnswerPost: Int?

    static let empty = PageContext()

    var isForum: Bool { state == .forumHome || state == .topic }

    /// The post the reader is at: the URL's, else the first one on screen.
    var currentPost: Int? { postNumber ?? visiblePosts.first }

    /// Same page apart from the position fields (visible and highlighted
    /// posts, post count, accepted answer), which change while scrolling.
    func sameDocument(as other: PageContext) -> Bool {
        var lhs = self, rhs = other
        lhs.clearPosition()
        rhs.clearPosition()
        return lhs == rhs
    }

    private mutating func clearPosition() {
        visiblePosts = []
        highlightedPosts = []
        postsCount = nil
        acceptedAnswerPost = nil
    }

    /// Adds the bridge's report and the topic's facts, when they are about
    /// this page's topic.
    func merging(report: BrowseBridgeReport?, facts: TopicFacts?, registry: SiteRegistry) -> PageContext {
        guard state == .topic, let topic else { return self }
        var merged = self
        if let report, site.flatMap(registry.adapter(for:))?.recognizer.looseTopicID(in: report.url) == topic.topicID {
            merged.visiblePosts = report.visible
            merged.highlightedPosts = report.highlighted
        }
        if let facts {
            merged.postsCount = facts.postsCount ?? facts.highestPostNumber
            merged.acceptedAnswerPost = facts.acceptedAnswer?.postNumber
        }
        return merged
    }

    /// Derives the page context (pure).
    /// - Parameters:
    ///   - facts: the latest page facts; ignored unless they are for `url`.
    ///   - knownForum: the directory forum `url` belongs to, if any.
    ///   - registry: the platforms that can recognize the page.
    static func make(
        url: URL?,
        title: String?,
        facts: PageFacts?,
        knownForum: KnownForumSite?,
        registry: SiteRegistry
    ) -> PageContext {
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            return PageContext(url: url, state: url == nil || url?.scheme == "about" ? .loading : .notForum)
        }
        let matchingFacts = facts.flatMap { samePage($0.url, url) ? $0 : nil }

        if let matchingFacts, let (adapter, match) = registry.recognize(facts: matchingFacts, url: url) {
            let known = knownForum.flatMap { $0.siteURL == match.siteURL ? $0 : nil }
            let name = ForumSite.displayName(
                siteURL: match.siteURL,
                name: match.forumName.isEmpty ? known?.name : match.forumName
            )
            return forum(
                url: url,
                title: title,
                siteURL: match.siteURL,
                name: name,
                iconURL: matchingFacts.iconURL ?? known?.iconURL,
                adapter: adapter,
                topicID: match.topicID
            )
        }

        // A directory forum is trusted until the facts say otherwise for a
        // page outside it; this also covers challenge and error pages there.
        // A kind this build has no adapter for is not a forum here.
        if let knownForum, ForumSite.isSameForum(url: url, siteURL: knownForum.siteURL),
           let adapter = registry.adapter(for: knownForum.kind) {
            return forum(
                url: url,
                title: title,
                siteURL: knownForum.siteURL,
                name: ForumSite.displayName(siteURL: knownForum.siteURL, name: knownForum.name),
                iconURL: knownForum.iconURL,
                adapter: adapter,
                topicID: adapter.recognizer.topicID(
                    fromURL: url, basePath: ForumSite.parse(siteURL: knownForum.siteURL)?.basePath ?? ""
                )
            )
        }

        if matchingFacts != nil {
            return PageContext(url: url, state: .notForum)
        }
        if registry.looseTopicID(in: url) != nil {
            return PageContext(url: url, state: .maybe)
        }
        // Not checked yet: the browser probes every finished load, so this
        // settles once the page (or its failure) is reported.
        return PageContext(url: url, state: .loading)
    }

    private static func forum(
        url: URL,
        title: String?,
        siteURL: String,
        name: String,
        iconURL: URL?,
        adapter: any SiteAdapter,
        topicID: String?
    ) -> PageContext {
        let basePath = ForumSite.parse(siteURL: siteURL)?.basePath ?? ""
        let topic = topicID.flatMap {
            ForumTopic.parse(url: url, title: title, basePath: basePath, forumName: name, topicID: $0, links: adapter.links)
        }
        return PageContext(
            url: url,
            site: adapter.kind,
            siteURL: siteURL,
            basePath: basePath,
            forumName: name,
            iconURL: iconURL,
            topic: topic,
            state: topic == nil ? .forumHome : .topic,
            postNumber: topic == nil ? nil : adapter.recognizer.postNumber(in: url)
        )
    }

    /// Same document address, ignoring the fragment.
    static func samePage(_ lhs: URL, _ rhs: URL) -> Bool {
        func strip(_ url: URL) -> String {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.fragment = nil
            return components?.string ?? url.absoluteString
        }
        return strip(lhs) == strip(rhs)
    }
}
