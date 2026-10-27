import Foundation

/// WordPress behind the site-adapter protocol: a post (or page) is a topic,
/// the article is post #1 and its reader comments follow, oldest first.
/// Requests go through `WordPressAPI`, URLs through `WordPressLinks`,
/// responses through `WordPressParsing`.
struct WordPressAdapter: SiteAdapter {
    var kind: SiteKind { .wordpress }
    var recognizer: any SiteRecognizer { WordPressRecognizer() }
    var links: any SiteLinks { WordPressLinks() }

    /// No topic filters, page bridge, sign-in page or session reader. Search
    /// is WordPress's own `?s=` page, on every install. A post's text by
    /// number is page arithmetic; the digest reads recent comments and the newest posts.
    var capabilities: SiteCapabilities {
        SiteCapabilities(
            activeTopics: WordPressActiveTopics(),
            postLookup: WordPressPostLookup(),
            topicFilters: nil,
            pageBridge: nil,
            loginURL: nil,
            searchPageURL: { ForumSite.url(siteURL: $0, path: "/", query: [URLQueryItem(name: "s", value: $1)]) },
            session: nil,
            firstPartyPathPatterns: Self.firstPartyPathPatterns
        )
    }

    /// The requests a WordPress page must always be able to make: the app's
    /// REST reads and the browser sign-in (`wp-login.php`, reached by URL).
    static let firstPartyPathPatterns = [
        #"^https?://[^?#]*/wp-json/"#,
        #"^https?://[^?#]*/wp-login\.php"#,
        #"^https?://[^?#]*/wp-admin/admin-ajax\.php"#
    ]

    var agent: AgentSiteProfile { WordPressAgent.profile }
    var voice: VoiceSiteProfile { WordPressAgent.voice }
    var discussion: DiscussionProfile { WordPressAgent.discussion }

    /// None: the app offers no WordPress sites to add.
    var suggestedForums: SuggestedForums {
        #if DEBUG
        SuggestedForums(general: [], chinese: [], sample: [])
        #else
        SuggestedForums(general: [], chinese: [])
        #endif
    }

    func siteURLCandidates(fromAddress address: String) -> [String] {
        WordPressAddress.candidates(fromAddress: address)
    }

    func siteInfo(siteURL: String, net: SiteNetwork) async throws -> ForumSiteInfo {
        try await WordPressAPI.fetchSiteInfo(siteURL: siteURL, net: net)
    }

    func overview(_ topic: TopicRef, net: SiteNetwork) async throws -> ForumTopicOverview {
        try await WordPressAPI(net: net).fetchOverview(topicID: topic.topicID)
    }

    func readTopic(
        _ request: TopicReadRequest,
        net: SiteNetwork,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void,
        onPage: (@Sendable (RawForumPage) async -> Void)?
    ) async throws -> ForumFetchResult {
        try await WordPressAPI(net: net).fetchTopic(
            topicID: request.topic.topicID,
            cachedPages: request.cachedPages,
            knownTotalPosts: request.knownTotalPosts,
            progress: progress,
            onPage: onPage
        )
    }

    func run(_ query: SiteQuery, net: SiteNetwork) async throws -> SiteQueryResult {
        let api = WordPressAPI(net: net)
        switch query {
        case .search(let text, let scope, let options):
            switch scope {
            case .forum: return try await api.searchPosts(text, options: options)
            case .comments: return try await api.searchComments(text, options: options)
            // Posts are not searched inside one topic.
            case .topic: throw SiteQueryError.unsupported
            }
        case .latest:
            return try await api.latestPosts()
        }
    }
}
