import Foundation

/// WordPress's REST endpoints (`/wp-json/wp/v2`) of one site, over a
/// `SiteNetwork` (pacing, retries, cookies and the in-page loader live there).
/// Builds the URLs, reads the paging headers and applies the reader's rules for
/// closed comments; `WordPressParsing` reads the JSON.
struct WordPressAPI: Sendable {
    let net: SiteNetwork

    /// WordPress caps `per_page` at 100 on every collection.
    static let commentsPerPage = 100
    /// Pages read forward when the site reports no total (50 x 100 comments).
    static let probePageLimit = 50
    private static let articleFields = "id,title,link,date_gmt,modified_gmt,content,author,_embedded,_links"
    private static let overviewFields = "id,title,link,modified_gmt"
    private static let commentFields = "id,parent,author_name,date_gmt,content"

    private var siteURL: String { net.siteURL }

    // MARK: Site

    /// Name and icon, which also confirms the site is WordPress. The caller's
    /// network has no in-page loader: the site may not be the open one yet.
    static func fetchSiteInfo(siteURL: String, net: SiteNetwork) async throws -> ForumSiteInfo {
        var context = net.context
        context.resourceLoader = nil
        let scoped = SiteNetwork(service: net.service, siteURL: siteURL, context: context)
        guard let url = ForumSite.url(
            siteURL: siteURL,
            path: "/wp-json/",
            query: [URLQueryItem(name: "_fields", value: "name,namespaces,home,site_icon_url")]
        ) else {
            throw AssistantError.invalidResponse
        }
        guard let info = WordPressParsing.parseSiteInfo(try await scoped.data(url)) else {
            throw AssistantError.invalidResponse
        }
        return info
    }

    // MARK: Reading

    func fetchTopic(
        topicID: String,
        cachedPages: [RawForumPage],
        knownTotalPosts: Int?,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void,
        onPage: (@Sendable (RawForumPage) async -> Void)?
    ) async throws -> ForumFetchResult {
        let id = try Self.requireID(topicID)
        // Sequential, not parallel: a missing article stops before the second
        // request and the request log is deterministic.
        let article = try await fetchArticle(id: id, fields: Self.articleFields, embedAuthor: true)
        let first = try await fetchCommentPage(postID: id, page: 1)

        var pages: [Int: [WordPressComment]] = [1: first.comments]
        let totalComments: Int
        let totalPages: Int
        if let total = first.total {
            totalComments = total
            totalPages = max(1, first.totalPages ?? Int((Double(total) / Double(Self.commentsPerPage)).rounded(.up)))
        } else {
            // No `X-WP-Total` (a proxy strips it, or the in-page loader did not
            // pass headers): a full page may have a next one, so read forward.
            var last = first.comments
            var page = 1
            while last.count >= Self.commentsPerPage {
                if page >= Self.probePageLimit {
                    await progress(
                        ForumFetchProgress(
                            completedPages: page,
                            totalPages: page,
                            totalPosts: pages.values.reduce(1) { $0 + $1.count },
                            message: String(localized: "The site does not report a comment total: stopped after \(page) pages of comments.", comment: "Progress while reading a WordPress post's comments when the site sends no total")
                        )
                    )
                    break
                }
                try Task.checkCancellation()
                let next = try await fetchCommentPage(postID: id, page: page + 1)
                if next.comments.isEmpty { break }
                page += 1
                pages[page] = next.comments
                last = next.comments
            }
            totalComments = pages.values.reduce(0) { $0 + $1.count }
            totalPages = page
        }

        let totalPosts = totalComments + 1
        let revision = WordPressParsing.revision(of: article)
        let plan = WordPressPagePlan.make(
            cachedPages: cachedPages,
            knownTotalPosts: knownTotalPosts,
            currentComments: totalComments,
            articleRevision: revision,
            totalPages: totalPages
        )
        let facts = TopicFacts(postsCount: totalPosts, highestPostNumber: totalPosts, openingPoster: article.author)
        let comments = pages
        return try await PagedTopicFetch.run(
            plan: plan,
            cachedPages: cachedPages.filter { $0.page <= totalPages },
            knownTotalPosts: knownTotalPosts,
            totalPosts: totalPosts,
            totalPages: totalPages,
            facts: facts,
            pace: net.context.pace,
            progress: progress,
            onPage: onPage,
            fetchPage: { page in
                if page == 1 {
                    return WordPressParsing.page(1, article: article, comments: comments[1] ?? [], revision: revision)
                }
                // Read forward already, or a page the plan asked for.
                var list = comments[page]
                if list == nil { list = try await self.fetchCommentPage(postID: id, page: page).comments }
                return WordPressParsing.page(page, article: nil, comments: list ?? [], revision: nil)
            }
        )
    }

    /// Title, comment count and permalink without the comments.
    func fetchOverview(topicID: String) async throws -> ForumTopicOverview {
        let id = try Self.requireID(topicID)
        let article = try await fetchArticle(id: id, fields: Self.overviewFields, embedAuthor: false)
        let total = try await commentCount(postID: id)
        let postCount = total + 1
        return ForumTopicOverview(
            siteURL: siteURL,
            topicID: topicID,
            title: article.title,
            slug: "",
            url: URL(string: article.link).flatMap { ForumSite.isSameForum(url: $0, siteURL: siteURL) ? $0 : nil }
                ?? WordPressLinks().topicURL(siteURL: siteURL, topicID: topicID, slug: nil)
                ?? URL(string: siteURL)!,
            postCount: postCount,
            facts: TopicFacts(postsCount: postCount, highestPostNumber: postCount)
        )
    }

    /// The article alone (post #1 by number).
    func fetchArticleText(topicID: String) async throws -> WordPressArticle {
        try await fetchArticle(id: Self.requireID(topicID), fields: Self.articleFields, embedAuthor: true)
    }

    // MARK: Requests

    /// A post, else a WordPress page with that id. An id that is neither (a
    /// product, another custom type) is a final 404: logging in does not change it.
    private func fetchArticle(id: String, fields: String, embedAuthor: Bool) async throws -> WordPressArticle {
        for kind in ["posts", "pages"] {
            var query = [URLQueryItem(name: "_fields", value: fields)]
            if embedAuthor { query.append(URLQueryItem(name: "_embed", value: "author")) }
            guard let url = ForumSite.url(siteURL: siteURL, path: "/wp-json/wp/v2/\(kind)/\(id)", query: query) else {
                throw AssistantError.invalidResponse
            }
            do {
                let response = try await net.response(url, accept: "application/json")
                guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
                      let article = WordPressParsing.parseArticle(json)
                else {
                    throw AssistantError.invalidResponse
                }
                return article
            } catch AssistantError.http(let status, _) where status == 404 {
                continue
            }
        }
        throw AssistantError.http(404, "No post or page with this id.")
    }

    /// One page of a post's comments, oldest first. A site may close the
    /// comments endpoint (a security plugin, a login wall on comments only)
    /// while the article stays readable: on page 1 that is a post without
    /// comments. A page number past the last one answers 400: empty. Any
    /// other failure on a later page fails the read, never a silent truncation.
    func fetchCommentPage(postID: String, page: Int) async throws -> WordPressCommentPage {
        let url = try commentsURL(postID: postID, perPage: Self.commentsPerPage, page: page, fields: Self.commentFields)
        let response: ForumHTTPResponse
        do {
            response = try await net.response(url, accept: "application/json")
        } catch AssistantError.http(let status, _) where page == 1 && [401, 403, 404].contains(status) {
            return WordPressCommentPage(comments: [], total: 0, totalPages: 1)
        } catch AssistantError.http(let status, _) where page > 1 && status == 400 {
            return WordPressCommentPage(comments: [], total: nil, totalPages: nil)
        }
        guard let list = try? JSONSerialization.jsonObject(with: response.data) as? [Any] else {
            throw AssistantError.invalidResponse
        }
        return WordPressCommentPage(
            comments: WordPressParsing.parseComments(list),
            total: Self.count(response.headers["x-wp-total"]),
            totalPages: Self.count(response.headers["x-wp-totalpages"])
        )
    }

    /// `X-WP-Total` of a one-item request; without the header, the first 100 counted.
    private func commentCount(postID: String) async throws -> Int {
        let url = try commentsURL(postID: postID, perPage: 1, page: 1, fields: "id")
        let response: ForumHTTPResponse
        do {
            response = try await net.response(url, accept: "application/json")
        } catch AssistantError.http(let status, _) where [401, 403, 404].contains(status) {
            return 0
        }
        if let total = Self.count(response.headers["x-wp-total"]) { return total }
        return try await fetchCommentPage(postID: postID, page: 1).comments.count
    }

    private func commentsURL(postID: String, perPage: Int, page: Int, fields: String) throws -> URL {
        guard let url = ForumSite.url(siteURL: siteURL, path: "/wp-json/wp/v2/comments", query: [
            URLQueryItem(name: "post", value: postID),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "order", value: "asc"),
            URLQueryItem(name: "orderby", value: "date_gmt"),
            URLQueryItem(name: "_fields", value: fields)
        ]) else {
            throw AssistantError.invalidResponse
        }
        return url
    }

    private static func count(_ header: String?) -> Int? {
        guard let header, let value = Int(header.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
        return value
    }

    /// A WordPress id is a positive integer of at most 12 digits.
    private static func requireID(_ topicID: String) throws -> String {
        guard topicID.count <= 12, topicID.first != "0", let id = ForumSite.positiveTopicID(topicID) else {
            throw AssistantError.invalidResponse
        }
        return id
    }
}

struct WordPressCommentPage: Sendable {
    var comments: [WordPressComment]
    /// `X-WP-Total` and `X-WP-TotalPages`; nil when the response did not carry them.
    var total: Int?
    var totalPages: Int?
}
