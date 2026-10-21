import Foundation

/// What the in-page probe reported about a document (the same signals Discourse
/// renders server-side: meta generator, `discourse-base-uri`,
/// `#data-discourse-setup[data-base-uri]`, `og:site_name`, touch icon/favicon).
struct PageProbe: Equatable {
    var url: URL
    var isDiscourse: Bool
    var basePath = ""
    var forumName = ""
    var iconURL: URL?
}

/// A forum the app already knows (from the forum directory). Pages on it are
/// treated as Discourse before the probe reports, so topics are detected
/// immediately on load.
struct KnownForumSite: Equatable {
    var siteURL: String
    var name: String
    var iconURL: URL?
}

/// The browser's current page as the assistant sees it. States:
///
///   loading     no page yet, or the page has not been checked yet
///   notForum    the page is not a Discourse forum
///   maybe       a `/t/…/{id}` URL the probe has not confirmed yet
///   forumHome   a Discourse page that is not a topic
///   topic       a Discourse topic
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
    var isDiscourse = false
    /// Site URL (origin + base path) when the page is on a Discourse forum.
    var siteURL: String?
    var basePath = ""
    var forumName = ""
    var iconURL: URL?
    var topic: ForumTopic?
    var state: State = .loading
    /// The post number in the topic URL (`/t/slug/id/N`); nil at the top of
    /// a topic Discourse hasn't rewritten yet, and off topics.
    var postNumber: Int?
    /// Rendered posts in the viewport, top to bottom (not hidden ones).
    var visiblePosts: [Int] = []
    /// Posts the bridge has highlighted on the page now.
    var highlightedPosts: [Int] = []
    /// From the topic's facts (`ForumTopicFacts`), when AppModel has them.
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
    func merging(report: BrowseBridgeReport?, facts: ForumTopicFacts?) -> PageContext {
        guard state == .topic, let topic else { return self }
        var merged = self
        if let report, ForumSite.looseTopicID(from: report.url) == topic.topicID {
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
    ///   - probe: the latest probe result; ignored unless it is for `url`.
    ///   - knownForum: the directory forum `url` belongs to, if any.
    static func make(
        url: URL?,
        title: String?,
        probe: PageProbe?,
        knownForum: KnownForumSite?
    ) -> PageContext {
        guard let url, let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else {
            return PageContext(url: url, state: url == nil || url?.scheme == "about" ? .loading : .notForum)
        }
        let matchingProbe = probe.flatMap { samePage($0.url, url) ? $0 : nil }

        if let matchingProbe, matchingProbe.isDiscourse,
           let siteURL = ForumSite.siteURL(fromPage: url, basePath: matchingProbe.basePath) {
            let known = knownForum.flatMap { $0.siteURL == siteURL ? $0 : nil }
            let name = ForumSite.displayName(
                siteURL: siteURL,
                name: matchingProbe.forumName.isEmpty ? known?.name : matchingProbe.forumName
            )
            return forum(
                url: url,
                title: title,
                siteURL: siteURL,
                name: name,
                iconURL: matchingProbe.iconURL ?? known?.iconURL
            )
        }

        // A directory forum is trusted until the probe says otherwise for a
        // page outside it; this also covers challenge and error pages there.
        if let knownForum, ForumSite.isSameForum(url: url, siteURL: knownForum.siteURL) {
            return forum(
                url: url,
                title: title,
                siteURL: knownForum.siteURL,
                name: ForumSite.displayName(siteURL: knownForum.siteURL, name: knownForum.name),
                iconURL: knownForum.iconURL
            )
        }

        if matchingProbe != nil {
            return PageContext(url: url, state: .notForum)
        }
        if ForumSite.looseTopicID(from: url) != nil {
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
        iconURL: URL?
    ) -> PageContext {
        let basePath = ForumSite.parse(siteURL: siteURL)?.basePath ?? ""
        let topic = ForumTopic.parse(url: url, title: title, basePath: basePath, forumName: name)
        return PageContext(
            url: url,
            isDiscourse: true,
            siteURL: siteURL,
            basePath: basePath,
            forumName: name,
            iconURL: iconURL,
            topic: topic,
            state: topic == nil ? .forumHome : .topic,
            postNumber: topic == nil ? nil : ForumSite.postNumber(from: url)
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
