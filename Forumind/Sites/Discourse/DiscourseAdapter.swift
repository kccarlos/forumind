import Foundation

/// Discourse behind the site-adapter protocol: requests go through
/// `DiscourseAPI`, URLs through `DiscourseRoutes`, responses through
/// `DiscourseParsing`.
struct DiscourseAdapter: SiteAdapter {
    var kind: SiteKind { .discourse }
    var recognizer: any SiteRecognizer { DiscourseRecognizer() }
    var links: any SiteLinks { DiscourseLinks() }

    var capabilities: SiteCapabilities {
        SiteCapabilities(
            activeTopics: DiscourseActiveTopics(),
            postLookup: DiscoursePostLookup(),
            topicFilters: DiscourseTopicFilters(),
            pageBridge: PageBridgeProfile(
                bridgeInstaller: DiscourseDOM.bridgeInstaller,
                moderationInstaller: DiscourseDOM.moderationInstaller
            ),
            loginURL: { DiscourseRoutes.loginURL(siteURL: $0) },
            searchPageURL: { DiscourseRoutes.searchPageURL(siteURL: $0, query: $1) },
            session: DiscourseSession(),
            firstPartyPathPatterns: Self.firstPartyPathPatterns
        )
    }

    /// The requests a Discourse page must always be able to make: the app's
    /// in-page `fetch()` (topic JSON, `/raw`, search, latest, site info) and
    /// Discourse sign-in.
    static let firstPartyPathPatterns = [
        #"^https?://[^?#]*\.json"#,           // /t/1.json, /latest.json, /search.json, /site/basic-info.json, /about.json…
        #"^https?://[^?#]*/raw/[0-9]"#,
        #"^https?://[^?#]*/session"#,          // /session, /session/csrf, other sign-in routes
        #"^https?://[^?#]*/auth/"#,
        #"^https?://[^?#]*/login"#,
        #"^https?://[^?#]*/u/"#,
        #"^https?://[^?#]*/message-bus/"#,
        #"^https?://[^?#]*/cdn-cgi/challenge-platform/"#
    ]

    var agent: AgentSiteProfile { DiscourseAgent.profile }
    var voice: VoiceSiteProfile { DiscourseAgent.voice }
    var discussion: DiscussionProfile { DiscourseAgent.discussion }

    func siteURLCandidates(fromAddress address: String) -> [String] {
        Self.candidateSiteURLs(fromAddress: address)
    }

    /// Candidate site URLs for an address typed in "Add forum": a full URL or
    /// a bare host, optionally with a page path. A path is cut before known
    /// Discourse routes (`/t/`, `/latest`, `/c/`, …) to find a subfolder base
    /// path; the bare origin is always tried last.
    private static func candidateSiteURLs(fromAddress address: String) -> [String] {
        guard let address = SiteAddress.parse(address) else { return [] }
        let routes: Set<String> = [
            "t", "latest", "top", "new", "unread", "categories", "c", "tag", "tags",
            "u", "users", "search", "login", "session", "about", "g", "groups", "posts",
            "raw", "badges", "faq", "guidelines", "tos", "privacy", "my"
        ]
        var baseSegments: [String] = []
        for segment in address.pathSegments {
            if routes.contains(segment) || segment.hasSuffix(".json") { break }
            baseSegments.append(segment)
        }
        var candidates: [String] = []
        if !baseSegments.isEmpty {
            let basePath = ForumSite.normalizeBasePath("/" + baseSegments.joined(separator: "/"))
            if !basePath.isEmpty { candidates.append(address.origin + basePath) }
        }
        candidates.append(address.origin)
        return candidates
    }

    func siteInfo(siteURL: String, net: SiteNetwork) async throws -> ForumSiteInfo {
        // Never inside the page: the forum may not be the open one yet.
        var context = net.context
        context.resourceLoader = nil
        let scoped = SiteNetwork(service: net.service, siteURL: siteURL, context: context)
        return try await DiscourseAPI(net: scoped).fetchSiteInfo()
    }

    func overview(_ topic: TopicRef, net: SiteNetwork) async throws -> ForumTopicOverview {
        try await DiscourseAPI(net: net).fetchOverview(topicID: topic.topicID)
    }

    func readTopic(
        _ request: TopicReadRequest,
        net: SiteNetwork,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void,
        onPage: (@Sendable (RawForumPage) async -> Void)?
    ) async throws -> ForumFetchResult {
        try await DiscourseAPI(net: net).fetchTopic(
            topicID: request.topic.topicID,
            cachedPages: request.cachedPages,
            knownTotalPosts: request.knownTotalPosts,
            progress: progress,
            onPage: onPage
        )
    }

    func run(_ query: SiteQuery, net: SiteNetwork) async throws -> SiteQueryResult {
        let api = DiscourseAPI(net: net)
        switch query {
        case .search(let text, let scope, _):
            var search = text
            switch scope {
            case .forum: break
            case .topic(let id): search += " topic:\(id)"
            case .comments: throw SiteQueryError.unsupported
            }
            let results = try await api.searchResults(query: search)
            return SiteQueryResult(topics: results.topics, hits: results.hits)
        case .latest:
            return SiteQueryResult(topics: try await api.latestTopics())
        }
    }
}

struct DiscourseLinks: SiteLinks {
    func homeURL(siteURL: String) -> URL? {
        DiscourseRoutes.latestURL(siteURL: siteURL)
    }

    func topicURL(siteURL: String, topicID: String, slug: String?) -> URL? {
        DiscourseRoutes.topicURL(siteURL: siteURL, topicID: topicID, slug: slug)
    }

    func postURL(topicURL: URL, number: Int, anchor: String?) -> URL {
        DiscourseRoutes.postURL(topicURL: topicURL, number: number)
    }

    func topicPageURL(_ url: URL) -> URL {
        DiscourseRoutes.topicPageURL(url)
    }

    func parse(_ url: URL, basePath: String) -> SiteLink? {
        guard let id = DiscourseRecognizer().topicID(fromURL: url, basePath: basePath) else { return nil }
        // `/t/{slug}/{id}[/{n}]`: the slug is the segment between `t` and a numeric id.
        let segments = url.path.split(separator: "/").map(String.init)
        var slug: String?
        if let t = segments.firstIndex(of: "t"), t + 2 < segments.count, segments[t + 2] == id {
            slug = segments[t + 1]
        }
        return SiteLink(topicID: id, slug: slug, postNumber: DiscourseRecognizer().postNumber(in: url))
    }

    func lastPostURL(topicURL: URL) -> URL? {
        DiscourseRoutes.topicPageURL(topicURL).appendingPathComponent("last")
    }
}

/// Signed in: the `logged-in` class on `html` or `body`, or the current-user
/// element; the name is in the page's preloaded data.
struct DiscourseSession: SessionReader {
    func session(from facts: PageFacts) -> (authenticated: Bool, username: String?) {
        let authenticated = facts.hasClass("logged-in")
            || DiscourseRecognizer.currentUserSelectors.contains { facts.matches.contains($0) }
        let username = facts.elements["data-preloaded"]?[DiscourseRecognizer.preloadedUsername]
        return (authenticated, username?.isEmpty == false ? username : nil)
    }
}

/// Today's digest rule: the day's top topics, else the latest ones.
struct DiscourseActiveTopics: ActiveTopicsSource {
    func activeTopics(siteURL: String, budget: Int, net: SiteNetwork) async -> ActiveTopicsResult {
        let api = DiscourseAPI(net: net)
        var result = ActiveTopicsResult(topics: nil, requests: 0, failures: 0)
        guard budget > 0 else { return result }
        result.requests += 1
        do {
            result.topics = try await api.topTopics()
        } catch {
            if Task.isCancelled { return result }
            result.failures += 1
        }
        // Top lists can be turned off or empty on a quiet day.
        if result.topics?.isEmpty ?? true, result.requests < budget {
            result.requests += 1
            do {
                result.topics = try await api.latestTopics()
            } catch {
                if !Task.isCancelled { result.failures += 1 }
            }
        }
        return result
    }
}

struct DiscoursePostLookup: PostLookup {
    func posts(_ numbers: [Int], in topic: TopicRef, facts: TopicFacts, net: SiteNetwork) async throws -> [ForumPost] {
        try await DiscourseAPI(net: net).fetchPosts(topicID: topic.topicID, numbers: numbers, facts: facts)
    }
}

struct DiscourseTopicFilters: TopicFilterSource {
    func url(topic: TopicRef, slug: String?, filter: TopicFilter) -> URL? {
        DiscourseRoutes.topicURL(siteURL: topic.siteURL, topicID: topic.topicID, slug: slug, filter: Self.forumFilter(filter))
    }

    func isFiltered(_ url: URL) -> Bool {
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        return names.contains("username_filters") || names.contains("filter")
    }

    func overview(_ topic: TopicRef, filter: TopicFilter, net: SiteNetwork) async throws -> ForumTopicOverview {
        try await DiscourseAPI(net: net).fetchOverview(topicID: topic.topicID, filter: Self.forumFilter(filter))
    }

    private static func forumFilter(_ filter: TopicFilter) -> DiscourseRoutes.TopicFilter {
        switch filter {
        case .top: .summary
        case .author(let name): .username(name)
        }
    }
}
