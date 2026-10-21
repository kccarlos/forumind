import Foundation

/// Name and icon from `/site/basic-info.json` (or `/about.json`).
struct ForumSiteInfo: Equatable {
    var name: String
    var iconURL: URL?
}

/// Keeps a forum's cookies on that forum across redirects. URLSession copies
/// a hand-set `Cookie` header onto the redirected request, so a redirect to
/// another origin (another host, port, or an https → http downgrade) is
/// followed without the `Cookie` and `Authorization` headers.
final class ForumRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ForumRedirectGuard()

    /// The request to follow when `original` redirects to `redirect`.
    static func redirectRequest(_ redirect: URLRequest, from original: URLRequest?) -> URLRequest {
        let sameOrigin: Bool = {
            guard let from = original?.url.flatMap(ForumSite.origin(of:)),
                  let to = redirect.url.flatMap(ForumSite.origin(of:))
            else {
                return false
            }
            return from.origin == to.origin
        }()
        guard !sameOrigin else { return redirect }
        var stripped = redirect
        stripped.setValue(nil, forHTTPHeaderField: "Cookie")
        stripped.setValue(nil, forHTTPHeaderField: "Authorization")
        stripped.httpShouldHandleCookies = false
        return stripped
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirectRequest(request, from: task.currentRequest ?? task.originalRequest))
    }
}

/// Discourse JSON/raw endpoints of one forum per call (`siteURL` is the
/// forum's origin + base path). Every request is paced per host
/// (`ForumRequestPacer`, see ForumRequestPacing.swift); each call takes the
/// pace to use, so a running job keeps the one it started with.
final class ForumService {
    private let session: URLSession
    private let pageSize = 100
    private let maximumRetries = 6
    /// Shared by every request this service makes, so pacing covers all
    /// jobs, agent tools and watch checks on the same forum together.
    let pacer: ForumRequestPacer

    init(session: URLSession = .shared, pacer: ForumRequestPacer = ForumRequestPacer()) {
        self.session = session
        self.pacer = pacer
    }

    func fetchTopic(
        siteURL: String,
        topicID: String,
        cachedPages: [RawForumPage],
        knownTotalPosts: Int?,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? = nil,
        pace: ForumRequestPace = .default,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void
    ) async throws -> ForumFetchResult {
        let topicJSON = try await fetchTopicJSON(
            siteURL: siteURL,
            topicID: topicID,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
        let totalPosts = try Self.postCount(from: topicJSON)
        let facts = Self.parseTopicFacts(topicJSON)
        let totalPages = max(1, Int(ceil(Double(totalPosts) / Double(pageSize))))
        let plan = CachePlan.make(
            cachedPages: cachedPages,
            knownTotalPosts: knownTotalPosts,
            currentTotalPosts: totalPosts,
            totalPages: totalPages
        )

        switch plan {
        case .unchanged:
            let sorted = cachedPages.sorted { $0.page < $1.page }
            await progress(
                ForumFetchProgress(
                    completedPages: totalPages,
                    totalPages: totalPages,
                    totalPosts: totalPosts,
                    message: String(localized: "Saved pages already include every reply.", comment: "Progress while reading a forum topic: nothing new to download")
                )
            )
            return ForumFetchResult(
                content: sorted.map(\.content).joined(separator: "\n\n\n"),
                rawPages: sorted,
                totalPosts: totalPosts,
                unchanged: true,
                newPosts: 0,
                facts: facts
            )

        case .fetch(let reusablePages, let pageNumbers):
            var fetchedPages: [RawForumPage] = []
            var completed = reusablePages.count
            // Pages are requested in order, `maximumConcurrency` at a time;
            // the pacer spaces them out. Cached pages are never requested.
            let batchSize = max(1, pace.maximumConcurrency)
            if let first = pageNumbers.first {
                // Reported before the (paced) wait for the first page, so the
                // status says what is happening while the bar waits.
                await progress(
                    ForumFetchProgress(
                        completedPages: completed,
                        totalPages: totalPages,
                        totalPosts: totalPosts,
                        message: String(localized: "Reading response page \(first) of \(totalPages)…", comment: "Progress while downloading a forum topic's replies, before a page arrives")
                    )
                )
            }

            for start in stride(from: 0, to: pageNumbers.count, by: batchSize) {
                try Task.checkCancellation()
                let end = min(start + batchSize, pageNumbers.count)
                let batch = Array(pageNumbers[start..<end])
                let results = try await withThrowingTaskGroup(
                    of: RawForumPage.self,
                    returning: [RawForumPage].self
                ) { group in
                    for page in batch {
                        group.addTask {
                            try await self.fetchRawPage(
                                siteURL: siteURL,
                                topicID: topicID,
                                page: page,
                                cookieHeader: cookieHeader,
                                resourceLoader: resourceLoader,
                                pace: pace
                            )
                        }
                    }

                    var pages: [RawForumPage] = []
                    for try await page in group {
                        pages.append(page)
                        completed += 1
                        await progress(
                            ForumFetchProgress(
                                completedPages: completed,
                                totalPages: totalPages,
                                totalPosts: totalPosts,
                                message: String(localized: "Read response page \(page.page) of \(totalPages)", comment: "Progress while downloading a forum topic's replies, page by page")
                            )
                        )
                    }
                    return pages
                }
                fetchedPages.append(contentsOf: results)
            }

            let allPages = (reusablePages + fetchedPages).sorted { $0.page < $1.page }
            return ForumFetchResult(
                content: allPages.map(\.content).joined(separator: "\n\n\n"),
                rawPages: allPages,
                totalPosts: totalPosts,
                unchanged: false,
                newPosts: max(0, totalPosts - (knownTotalPosts ?? 0)),
                facts: facts
            )
        }
    }

    /// Discourse search (`/search.json`), one listing per topic. The query
    /// accepts Discourse search syntax such as `#category`, `order:latest`,
    /// `after:2026-01-01`.
    func search(
        siteURL: String,
        query: String,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? = nil,
        pace: ForumRequestPace = .default
    ) async throws -> [ForumTopicListing] {
        let data = try await searchData(
            siteURL: siteURL,
            query: query,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
        return Self.parseSearchResults(data, siteURL: siteURL)
    }

    /// The same search, keeping every matching post (`topic:<id>` in the
    /// query searches one topic). Both come from one request.
    func searchResults(
        siteURL: String,
        query: String,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? = nil,
        pace: ForumRequestPace = .default
    ) async throws -> (hits: [ForumSearchHit], topics: [ForumTopicListing]) {
        let data = try await searchData(
            siteURL: siteURL,
            query: query,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
        return Self.parseSearch(data, siteURL: siteURL)
    }

    private func searchData(
        siteURL: String,
        query: String,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)?,
        pace: ForumRequestPace
    ) async throws -> Data {
        guard let url = ForumSite.searchURL(siteURL: siteURL, query: query) else {
            throw AssistantError.invalidResponse
        }
        return try await requestData(
            url: url,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
    }

    /// Posts of a topic by post number, in post order. Ids come from the
    /// facts (`likelyPostID`); a guess that lands on another post is dropped,
    /// so a number may be missing from the result.
    func fetchPosts(
        siteURL: String,
        topicID: String,
        numbers: [Int],
        facts: ForumTopicFacts,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? = nil,
        pace: ForumRequestPace = .default
    ) async throws -> [ForumPost] {
        let wanted = Set(numbers)
        var ids: [Int] = []
        for number in numbers {
            if let id = facts.likelyPostID(forNumber: number), !ids.contains(id) { ids.append(id) }
        }
        guard !ids.isEmpty else { return [] }
        return try await fetchPosts(
            siteURL: siteURL,
            topicID: topicID,
            postIDs: ids,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
        .filter { wanted.contains($0.number) }
    }

    /// Specific posts of a topic by post id (`/t/{id}/posts.json`), in post
    /// order. Ids come from `ForumTopicFacts.stream`; each post carries its
    /// real number.
    func fetchPosts(
        siteURL: String,
        topicID: String,
        postIDs: [Int],
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? = nil,
        pace: ForumRequestPace = .default
    ) async throws -> [ForumPost] {
        guard let url = ForumSite.topicPostsJSONURL(siteURL: siteURL, topicID: topicID, postIDs: postIDs) else {
            throw AssistantError.invalidResponse
        }
        let data = try await requestData(
            url: url,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
        return Self.parsePosts(data)
    }

    /// Recently active topics (`/latest.json`).
    func latestTopics(
        siteURL: String,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? = nil,
        pace: ForumRequestPace = .default
    ) async throws -> [ForumTopicListing] {
        guard let url = ForumSite.latestURL(siteURL: siteURL, json: true) else {
            throw AssistantError.invalidResponse
        }
        let data = try await requestData(
            url: url,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
        return Self.parseTopicList(data, siteURL: siteURL)
    }

    /// The day's (or another period's) top topics (`/top.json?period=`), in
    /// the forum's order.
    func topTopics(
        siteURL: String,
        period: String = "daily",
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? = nil,
        pace: ForumRequestPace = .default
    ) async throws -> [ForumTopicListing] {
        guard let url = ForumSite.topURL(siteURL: siteURL, period: period) else {
            throw AssistantError.invalidResponse
        }
        let data = try await requestData(
            url: url,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
        return Self.parseTopicList(data, siteURL: siteURL)
    }

    /// Name and icon of a forum, which also confirms it runs Discourse:
    /// `/site/basic-info.json`, falling back to `/about.json`.
    func fetchSiteInfo(
        siteURL: String,
        cookieHeader: String? = nil,
        pace: ForumRequestPace = .default
    ) async throws -> ForumSiteInfo {
        if let url = ForumSite.basicInfoURL(siteURL: siteURL),
           let data = try? await requestData(url: url, cookieHeader: cookieHeader, resourceLoader: nil, pace: pace),
           let info = Self.parseBasicInfo(data, siteURL: siteURL) {
            return info
        }
        guard let url = ForumSite.aboutURL(siteURL: siteURL) else {
            throw AssistantError.invalidResponse
        }
        try Task.checkCancellation()
        let data = try await requestData(url: url, cookieHeader: cookieHeader, resourceLoader: nil, pace: pace)
        guard let info = Self.parseAbout(data, siteURL: siteURL) else {
            throw AssistantError.invalidResponse
        }
        return info
    }

    nonisolated static func parseBasicInfo(_ data: Data, siteURL: String) -> ForumSiteInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String
        else {
            return nil
        }
        let icon = [
            json["apple_touch_icon_url"],
            json["large_icon_url"],
            json["favicon_url"],
            json["logo_small_url"]
        ]
        .compactMap { $0 as? String }
        .first { !$0.isEmpty }
        return ForumSiteInfo(
            name: title.trimmingCharacters(in: .whitespacesAndNewlines),
            iconURL: icon.flatMap { resolve($0, siteURL: siteURL) }
        )
    }

    nonisolated static func parseAbout(_ data: Data, siteURL: String) -> ForumSiteInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let about = json["about"] as? [String: Any],
              let title = about["title"] as? String
        else {
            return nil
        }
        return ForumSiteInfo(name: title.trimmingCharacters(in: .whitespacesAndNewlines), iconURL: nil)
    }

    /// Icon paths may be relative (`/uploads/…`) or protocol-relative (`//cdn…`).
    private nonisolated static func resolve(_ value: String, siteURL: String) -> URL? {
        guard let base = ForumSite.parse(siteURL: siteURL).flatMap({ URL(string: $0.origin + "/") })
        else {
            return nil
        }
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
              url.scheme == "https" || url.scheme == "http"
        else {
            return nil
        }
        return url
    }

    /// Title and post count without pulling the posts (`/t/{id}.json`). With
    /// a filter (top posts, one author) the facts' posts and stream are the
    /// filtered ones.
    func fetchOverview(
        siteURL: String,
        topicID: String,
        filter: ForumSite.TopicFilter? = nil,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)? = nil,
        pace: ForumRequestPace = .default
    ) async throws -> ForumTopicOverview {
        let json = try await fetchTopicJSON(
            siteURL: siteURL,
            topicID: topicID,
            filter: filter,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
        return ForumTopicOverview(
            siteURL: siteURL,
            topicID: topicID,
            title: (json["title"] as? String ?? json["fancy_title"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            slug: json["slug"] as? String ?? topicID,
            postCount: try Self.postCount(from: json),
            facts: Self.parseTopicFacts(json)
        )
    }

    /// One listing per topic, in the `topics` order, with its first hit's
    /// blurb as the excerpt (topics without a hit are kept).
    nonisolated static func parseSearchResults(_ data: Data, siteURL: String) -> [ForumTopicListing] {
        parseSearch(data, siteURL: siteURL).topics
    }

    /// Every hit of `/search.json` in the forum's order (the `posts` array,
    /// joined to `topics`), and the topic listings with their excerpts. A
    /// post without a post number, or whose topic is missing from `topics`
    /// (no title), is not a hit.
    nonisolated static func parseSearch(
        _ data: Data,
        siteURL: String
    ) -> (hits: [ForumSearchHit], topics: [ForumTopicListing]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [])
        }
        let topicObjects = json["topics"] as? [[String: Any]] ?? []
        var bare: [Int: ForumTopicListing] = [:]
        for topic in topicObjects {
            if let listing = listing(from: topic, siteURL: siteURL, excerpt: nil) {
                bare[listing.id] = listing
            }
        }
        let posts = json["posts"] as? [[String: Any]] ?? []
        let hits: [ForumSearchHit] = posts.compactMap { post in
            guard let topicID = post["topic_id"] as? Int,
                  let topic = bare[topicID],
                  let number = post["post_number"] as? Int, number >= 1
            else {
                return nil
            }
            return ForumSearchHit(
                topic: topic,
                postNumber: number,
                username: post["username"] as? String,
                blurb: post["blurb"] as? String
            )
        }
        // Blurbs live on the posts; a topic's first one is its excerpt (also
        // from posts too incomplete to be a hit).
        var excerpts: [Int: String] = [:]
        for post in posts {
            if let topicID = post["topic_id"] as? Int,
               let blurb = post["blurb"] as? String,
               excerpts[topicID] == nil {
                excerpts[topicID] = blurb
            }
        }
        let topics = topicObjects.compactMap { topic in
            listing(
                from: topic,
                siteURL: siteURL,
                excerpt: (topic["id"] as? Int).flatMap { excerpts[$0] }
            )
        }
        return (hits, topics)
    }

    /// Topic facts from `/t/{id}.json`. The accepted answer comes from the
    /// Solved plugin: `accepted_answer` (older versions), `accepted_answers`
    /// (current), or the loaded post marked `accepted_answer: true`. Posts'
    /// `topic_accepted_answer` only says the topic is solved. Likes are
    /// `like_count`, which is null for visitors, else the like action count
    /// in `actions_summary` (id 2).
    nonisolated static func parseTopicFacts(_ json: [String: Any]) -> ForumTopicFacts {
        let stream = json["post_stream"] as? [String: Any]
        let posts: [ForumTopicFacts.Post] = (stream?["posts"] as? [[String: Any]] ?? []).compactMap { post in
            guard let id = post["id"] as? Int,
                  let number = post["post_number"] as? Int,
                  let username = post["username"] as? String
            else {
                return nil
            }
            return ForumTopicFacts.Post(id: id, number: number, username: username, likeCount: likeCount(of: post))
        }

        func answer(_ object: Any?) -> ForumTopicFacts.AcceptedAnswer? {
            guard let object = object as? [String: Any],
                  let number = object["post_number"] as? Int, number >= 1
            else {
                return nil
            }
            return ForumTopicFacts.AcceptedAnswer(postNumber: number, username: object["username"] as? String)
        }
        var accepted = answer(json["accepted_answer"])
            ?? answer((json["accepted_answers"] as? [Any])?.first)
        if accepted == nil,
           let marked = (stream?["posts"] as? [[String: Any]] ?? []).first(where: { $0["accepted_answer"] as? Bool == true }),
           let number = marked["post_number"] as? Int {
            accepted = ForumTopicFacts.AcceptedAnswer(postNumber: number, username: marked["username"] as? String)
        }

        let createdBy = ((json["details"] as? [String: Any])?["created_by"] as? [String: Any])?["username"] as? String
        return ForumTopicFacts(
            postsCount: json["posts_count"] as? Int,
            highestPostNumber: json["highest_post_number"] as? Int,
            stream: stream?["stream"] as? [Int] ?? [],
            openingPoster: createdBy ?? posts.first { $0.number == 1 }?.username,
            acceptedAnswer: accepted,
            posts: posts
        )
    }

    /// Posts of `/t/{id}/posts.json`, sorted by post number.
    nonisolated static func parsePosts(_ data: Data) -> [ForumPost] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let posts = (json["post_stream"] as? [String: Any])?["posts"] as? [[String: Any]]
        else {
            return []
        }
        return posts.compactMap { post -> ForumPost? in
            guard let id = post["id"] as? Int,
                  let number = post["post_number"] as? Int,
                  let username = post["username"] as? String
            else {
                return nil
            }
            return ForumPost(
                id: id,
                number: number,
                username: username,
                text: DiscourseHTML.plainText(post["cooked"] as? String ?? ""),
                likeCount: likeCount(of: post)
            )
        }
        .sorted { $0.number < $1.number }
    }

    private nonisolated static func likeCount(of post: [String: Any]) -> Int? {
        if let count = post["like_count"] as? Int { return count }
        guard let actions = post["actions_summary"] as? [[String: Any]] else { return nil }
        // An empty summary means no likes.
        return actions.first { $0["id"] as? Int == 2 }?["count"] as? Int ?? 0
    }

    nonisolated static func parseTopicList(_ data: Data, siteURL: String) -> [ForumTopicListing] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["topic_list"] as? [String: Any],
              let topics = list["topics"] as? [[String: Any]]
        else {
            return []
        }
        return topics.compactMap {
            listing(from: $0, siteURL: siteURL, excerpt: $0["excerpt"] as? String)
        }
    }

    private nonisolated static func listing(
        from topic: [String: Any],
        siteURL: String,
        excerpt: String?
    ) -> ForumTopicListing? {
        guard let id = topic["id"] as? Int,
              let title = (topic["title"] as? String ?? topic["fancy_title"] as? String)
        else {
            return nil
        }
        return ForumTopicListing(
            siteURL: siteURL,
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            slug: topic["slug"] as? String ?? String(id),
            postsCount: topic["posts_count"] as? Int ?? 0,
            lastPostedAt: topic["last_posted_at"] as? String ?? topic["bumped_at"] as? String,
            excerpt: excerpt,
            isPinned: topic["pinned"] as? Bool,
            likeCount: topic["like_count"] as? Int,
            hasAcceptedAnswer: topic["has_accepted_answer"] as? Bool
        )
    }

    private func fetchTopicJSON(
        siteURL: String,
        topicID: String,
        filter: ForumSite.TopicFilter? = nil,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)?,
        pace: ForumRequestPace
    ) async throws -> [String: Any] {
        guard let url = ForumSite.topicJSONURL(siteURL: siteURL, topicID: topicID, filter: filter) else {
            throw AssistantError.invalidResponse
        }
        let data = try await requestData(
            url: url,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw AssistantError.invalidResponse
        }
        return json
    }

    private nonisolated static func postCount(from json: [String: Any]) throws -> Int {
        let postsCount = json["posts_count"] as? Int
        let highestPostNumber = json["highest_post_number"] as? Int
        let streamCount = (
            (json["post_stream"] as? [String: Any])?["stream"] as? [Any]
        )?.count
        let candidates = [postsCount, highestPostNumber, streamCount].compactMap { $0 }
        guard let totalPosts = candidates.max(), totalPosts > 0 else {
            throw AssistantError.invalidResponse
        }
        return totalPosts
    }

    private func fetchRawPage(
        siteURL: String,
        topicID: String,
        page: Int,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)?,
        pace: ForumRequestPace
    ) async throws -> RawForumPage {
        guard let url = ForumSite.rawPageURL(siteURL: siteURL, topicID: topicID, page: page) else {
            throw AssistantError.invalidResponse
        }
        let data = try await requestData(
            url: url,
            cookieHeader: cookieHeader,
            resourceLoader: resourceLoader,
            pace: pace
        )
        guard let content = String(data: data, encoding: .utf8) else {
            throw AssistantError.invalidResponse
        }
        return RawForumPage(page: page, content: content)
    }

    /// One forum request, paced per host. A `429` gives the slot back, pushes
    /// the host's next start back by `Retry-After` (or an exponential
    /// backoff) and tries again, up to `maximumRetries` times.
    private func requestData(
        url: URL,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)?,
        pace: ForumRequestPace
    ) async throws -> Data {
        for attempt in 0...maximumRetries {
            try Task.checkCancellation()
            let host = try await pacer.acquire(for: url, pace: pace)
            let outcome: Outcome
            do {
                outcome = try await attemptRequest(
                    url: url,
                    cookieHeader: cookieHeader,
                    resourceLoader: resourceLoader
                )
            } catch {
                await pacer.release(host)
                throw error
            }

            switch outcome {
            case .success(let data):
                await pacer.release(host)
                return data
            case .failure(let status, let detail, let retryAfter):
                if status == 429 && attempt < maximumRetries {
                    // The back-off is in place before the slot passes on:
                    // a request waiting for it must not start inside it.
                    let wait = Double(retryAfter ?? "") ?? pow(2, Double(attempt + 1))
                    await pacer.release(host, backOff: min(60, max(1, wait)))
                    continue
                }
                await pacer.release(host)
                throw AssistantError.http(status, String(detail.prefix(300)))
            }
        }
        throw AssistantError.invalidResponse
    }

    private enum Outcome {
        case success(Data)
        case failure(status: Int, detail: String, retryAfter: String?)
    }

    private func attemptRequest(
        url: URL,
        cookieHeader: String?,
        resourceLoader: (@MainActor (URL) async throws -> ForumResourceResponse)?
    ) async throws -> Outcome {
        if let resourceLoader {
            let response = try await resourceLoader(url)
            if (200..<300).contains(response.statusCode) {
                return .success(response.data)
            }
            return .failure(
                status: response.statusCode,
                detail: String(data: response.data, encoding: .utf8) ?? response.statusText,
                retryAfter: response.retryAfter
            )
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 60
        request.setValue(
            "text/html,application/json;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("en-US,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        // Only the forum cookies passed in; nothing from the shared jar.
        request.httpShouldHandleCookies = false
        if let cookieHeader, !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(
            for: request,
            delegate: ForumRedirectGuard.shared
        )
        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) {
            return .success(data)
        }
        return .failure(
            status: http.statusCode,
            detail: String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
            retryAfter: http.value(forHTTPHeaderField: "Retry-After")
        )
    }
}

/// Plain text from Discourse's cooked HTML: block ends become line breaks,
/// tags are dropped and common entities decoded. Image captions (lightbox
/// file name and size) are left out.
enum DiscourseHTML {
    nonisolated static func plainText(_ html: String) -> String {
        var text = html
        let replacements: [(String, String)] = [
            (#"(?is)<div class="meta">.*?</div>"#, ""),
            (#"(?is)<(script|style)[^>]*>.*?</\1>"#, ""),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)<li[^>]*>"#, "\n- "),
            (#"(?i)</(p|div|pre|blockquote|aside|h[1-6]|ul|ol|li|tr|table)>"#, "\n"),
            (#"(?s)<[^>]+>"#, "")
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = decodeEntities(text)
        // Trailing spaces go and blank-line runs collapse; leading spaces
        // stay (code indentation).
        text = text.replacingOccurrences(of: #"(?m)[ \t]+$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”"
    ]

    nonisolated static func decodeEntities(_ text: String) -> String {
        guard text.contains("&"),
              let regex = try? NSRegularExpression(pattern: "&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z]+);")
        else {
            return text
        }
        let nsText = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)) {
            let name = nsText.substring(with: match.range(at: 1))
            let decoded: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                decoded = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                decoded = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                decoded = namedEntities[name]
            }
            guard let decoded else { continue }
            result += nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += decoded
            cursor = match.range.location + match.range.length
        }
        result += nsText.substring(from: cursor)
        return result
    }
}
