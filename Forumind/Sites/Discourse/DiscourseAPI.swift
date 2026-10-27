import Foundation

/// Discourse's JSON and raw endpoints of one forum, over a `SiteNetwork`
/// (pacing, retries, the in-page loader and cookies live there). Builds the
/// URLs with `DiscourseRoutes` and reads the responses with `DiscourseParsing`.
struct DiscourseAPI: Sendable {
    let net: SiteNetwork

    private var siteURL: String { net.siteURL }

    func fetchTopic(
        topicID: String,
        cachedPages: [RawForumPage],
        knownTotalPosts: Int?,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void,
        onPage: (@Sendable (RawForumPage) async -> Void)? = nil
    ) async throws -> ForumFetchResult {
        let topicJSON = try await topicJSON(topicID: topicID)
        let totalPosts = try DiscourseParsing.postCount(from: topicJSON)
        let facts = DiscourseParsing.parseTopicFacts(topicJSON)
        let totalPages = max(1, Int(ceil(Double(totalPosts) / Double(RawForumPage.size))))
        let plan = DiscoursePagePlan.make(
            cachedPages: cachedPages,
            knownTotalPosts: knownTotalPosts,
            currentTotalPosts: totalPosts,
            totalPages: totalPages
        )
        return try await PagedTopicFetch.run(
            plan: plan,
            cachedPages: cachedPages,
            knownTotalPosts: knownTotalPosts,
            totalPosts: totalPosts,
            totalPages: totalPages,
            facts: facts,
            pace: net.context.pace,
            progress: progress,
            onPage: onPage,
            fetchPage: { try await self.rawPage(topicID: topicID, page: $0) }
        )
    }

    /// Discourse search (`/search.json`), one listing per topic. The query
    /// accepts Discourse search syntax such as `#category`, `order:latest`,
    /// `after:2026-01-01`.
    func search(query: String) async throws -> [ForumTopicListing] {
        try await searchResults(query: query).topics
    }

    /// The same search, keeping every matching post (`topic:<id>` in the
    /// query searches one topic). Both come from one request.
    func searchResults(query: String) async throws -> (hits: [ForumSearchHit], topics: [ForumTopicListing]) {
        guard let url = DiscourseRoutes.searchURL(siteURL: siteURL, query: query) else {
            throw AssistantError.invalidResponse
        }
        return DiscourseParsing.parseSearch(try await net.data(url), siteURL: siteURL)
    }

    /// Posts of a topic by post number, in post order. Ids come from the
    /// facts (`likelyPostID`); a guess that lands on another post is dropped,
    /// so a number may be missing from the result.
    func fetchPosts(topicID: String, numbers: [Int], facts: TopicFacts) async throws -> [ForumPost] {
        let wanted = Set(numbers)
        var ids: [Int] = []
        for number in numbers {
            if let id = facts.likelyPostID(forNumber: number), !ids.contains(id) { ids.append(id) }
        }
        guard !ids.isEmpty else { return [] }
        return try await fetchPosts(topicID: topicID, postIDs: ids)
            .filter { wanted.contains($0.number) }
    }

    /// Specific posts of a topic by post id (`/t/{id}/posts.json`), in post
    /// order. Ids come from `TopicFacts.stream`; each post carries its
    /// real number.
    func fetchPosts(topicID: String, postIDs: [Int]) async throws -> [ForumPost] {
        guard let url = DiscourseRoutes.topicPostsJSONURL(siteURL: siteURL, topicID: topicID, postIDs: postIDs) else {
            throw AssistantError.invalidResponse
        }
        return DiscourseParsing.parsePosts(try await net.data(url))
    }

    /// Recently active topics (`/latest.json`).
    func latestTopics() async throws -> [ForumTopicListing] {
        guard let url = DiscourseRoutes.latestURL(siteURL: siteURL, json: true) else {
            throw AssistantError.invalidResponse
        }
        return DiscourseParsing.parseTopicList(try await net.data(url), siteURL: siteURL)
    }

    /// The day's (or another period's) top topics (`/top.json?period=`), in
    /// the forum's order.
    func topTopics(period: String = "daily") async throws -> [ForumTopicListing] {
        guard let url = DiscourseRoutes.topURL(siteURL: siteURL, period: period) else {
            throw AssistantError.invalidResponse
        }
        return DiscourseParsing.parseTopicList(try await net.data(url), siteURL: siteURL)
    }

    /// Name and icon of a forum, which also confirms it runs Discourse:
    /// `/site/basic-info.json`, falling back to `/about.json`. The caller's
    /// network has no in-page loader: the forum may not be the open one yet.
    func fetchSiteInfo() async throws -> ForumSiteInfo {
        if let url = DiscourseRoutes.basicInfoURL(siteURL: siteURL),
           let data = try? await net.data(url),
           let info = DiscourseParsing.parseBasicInfo(data, siteURL: siteURL) {
            return info
        }
        guard let url = DiscourseRoutes.aboutURL(siteURL: siteURL) else {
            throw AssistantError.invalidResponse
        }
        try Task.checkCancellation()
        guard let info = DiscourseParsing.parseAbout(try await net.data(url), siteURL: siteURL) else {
            throw AssistantError.invalidResponse
        }
        return info
    }

    /// Title and post count without pulling the posts (`/t/{id}.json`). With
    /// a filter (top posts, one author) the facts' posts and stream are the
    /// filtered ones.
    func fetchOverview(topicID: String, filter: DiscourseRoutes.TopicFilter? = nil) async throws -> ForumTopicOverview {
        let json = try await topicJSON(topicID: topicID, filter: filter)
        let slug = json["slug"] as? String ?? topicID
        return ForumTopicOverview(
            siteURL: siteURL,
            topicID: topicID,
            title: (json["title"] as? String ?? json["fancy_title"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            slug: slug,
            url: DiscourseParsing.topicURL(siteURL: siteURL, topicID: topicID, slug: slug),
            postCount: try DiscourseParsing.postCount(from: json),
            facts: DiscourseParsing.parseTopicFacts(json)
        )
    }

    private func topicJSON(topicID: String, filter: DiscourseRoutes.TopicFilter? = nil) async throws -> [String: Any] {
        guard let url = DiscourseRoutes.topicJSONURL(siteURL: siteURL, topicID: topicID, filter: filter) else {
            throw AssistantError.invalidResponse
        }
        guard let json = try JSONSerialization.jsonObject(with: try await net.data(url)) as? [String: Any] else {
            throw AssistantError.invalidResponse
        }
        return json
    }

    private func rawPage(topicID: String, page: Int) async throws -> RawForumPage {
        guard let url = DiscourseRoutes.rawPageURL(siteURL: siteURL, topicID: topicID, page: page) else {
            throw AssistantError.invalidResponse
        }
        guard let content = String(data: try await net.data(url), encoding: .utf8) else {
            throw AssistantError.invalidResponse
        }
        return RawForumPage(page: page, content: content, blocks: RawTopicFormat.blocks(in: content))
    }
}
