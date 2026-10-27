import Foundation

/// The agent's WordPress reads: search posts and comments, list the newest,
/// and one post by its number. Ported from the extension's `wordpress-tools.mjs`.
/// A post is a topic and a comment is a hit that is not numbered until its post
/// is read (`ForumSearchHit.postNumber == nil`).
extension WordPressAPI {
    static let postsPerSearch = 20
    static let commentsPerSearch = 10
    static let latestCount = 30
    static let listFields = "id,title,link,date_gmt,excerpt"

    // MARK: Posts

    /// Posts matching `text`, in a category and a date range when the options say so.
    func searchPosts(_ text: String, options: SearchOptions) async throws -> SiteQueryResult {
        var query = [
            URLQueryItem(name: "search", value: text),
            URLQueryItem(name: "per_page", value: String(Self.postsPerSearch)),
            URLQueryItem(name: "page", value: String(options.page)),
            URLQueryItem(name: "_fields", value: Self.listFields)
        ]
        query += Self.dateFilters(options)
        if let category = options.category {
            query.append(URLQueryItem(name: "categories", value: try await categoryID(matching: category)))
        }
        return SiteQueryResult(topics: try await listings(query: query))
    }

    /// The newest posts (about 30).
    func latestPosts() async throws -> SiteQueryResult {
        let query = [
            URLQueryItem(name: "per_page", value: String(Self.latestCount)),
            URLQueryItem(name: "orderby", value: "date"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "_fields", value: Self.listFields)
        ]
        return SiteQueryResult(topics: Array(try await listings(query: query).prefix(Self.latestCount)))
    }

    /// The id of the category a name or slug refers to: an exact name or slug,
    /// else the first match; no match is a mistake the model can correct.
    func categoryID(matching name: String) async throws -> String {
        let wanted = String(name.prefix(80))
        let list = try await jsonList("/categories", [
            URLQueryItem(name: "search", value: wanted),
            URLQueryItem(name: "per_page", value: "10"),
            URLQueryItem(name: "_fields", value: "id,name,slug")
        ])
        let categories = list.compactMap { $0 as? [String: Any] }.filter { $0["id"] is Int }
        let lower = wanted.lowercased()
        let match = categories.first {
            HTMLText.decodeEntities($0["name"] as? String ?? "").lowercased() == lower
                || ($0["slug"] as? String ?? "").lowercased() == lower
        } ?? categories.first
        guard let id = match?["id"] as? Int else {
            throw AgentError.invalidArgument("category", reason: "no category matches \"\(wanted)\". Search without category, or try another name.")
        }
        return String(id)
    }

    // MARK: Comments

    /// Comments matching `text`, newest first, each with the post it belongs
    /// to. The site's comment search is slow, so few come back. A site that
    /// closes it is `AgentError.commentsUnavailable`; a failed title lookup
    /// keeps the hits, titled `Post <id>`.
    func searchComments(_ text: String, options: SearchOptions) async throws -> SiteQueryResult {
        var query = [
            URLQueryItem(name: "search", value: text),
            URLQueryItem(name: "per_page", value: String(Self.commentsPerSearch)),
            URLQueryItem(name: "page", value: String(options.page)),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "orderby", value: "date_gmt"),
            URLQueryItem(name: "_fields", value: "id,post,parent,author_name,date_gmt,content")
        ]
        query += Self.dateFilters(options)
        let list: [Any]
        do {
            list = try await jsonList("/comments", query)
        } catch AssistantError.http(let status, _) where [401, 403, 404].contains(status) {
            throw AgentError.commentsUnavailable
        }
        let found = list.compactMap { entry -> (id: Int, post: Int, json: [String: Any])? in
            guard let json = entry as? [String: Any], let id = json["id"] as? Int, let post = json["post"] as? Int, post > 0
            else {
                return nil
            }
            return (id, post, json)
        }
        // Comments carry only their post's id; one request names the posts.
        var posts: [Int: ForumTopicListing] = [:]
        var ids: [Int] = []
        for comment in found where !ids.contains(comment.post) { ids.append(comment.post) }
        if !ids.isEmpty {
            do {
                let titled = try await jsonList("/posts", [
                    URLQueryItem(name: "include", value: ids.map(String.init).joined(separator: ",")),
                    URLQueryItem(name: "per_page", value: String(ids.count)),
                    URLQueryItem(name: "_fields", value: "id,title,link")
                ])
                for case let json as [String: Any] in titled {
                    if let listing = WordPressParsing.listing(json, siteURL: net.siteURL) { posts[listing.id] = listing }
                }
            } catch {
                // The hits are worth having without their titles.
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
            }
        }
        let links = WordPressLinks()
        let siteURL = net.siteURL
        func listing(_ post: Int) -> ForumTopicListing {
            posts[post] ?? WordPressParsing.placeholderListing(id: post, siteURL: siteURL)
        }
        let hits = found.map { comment -> ForumSearchHit in
            let topic = listing(comment.post)
            let author = WordPressParsing.oneLine(comment.json["author_name"] as? String ?? "")
            let text = WordPressParsing.oneLine(HTMLText.plainText(WordPressParsing.rendered(comment.json["content"])))
            return ForumSearchHit(
                topic: topic,
                postNumber: nil,
                username: author.isEmpty ? "anonymous" : author,
                blurb: String(text.prefix(500)),
                postedAt: WordPressParsing.timestamp(comment.json["date_gmt"] as? String),
                url: links.postURL(topicURL: topic.url, number: 0, anchor: "comment-\(comment.id)")
            )
        }
        var seen = Set<Int>()
        let topics = found.map(\.post).filter { seen.insert($0).inserted }.map(listing)
        return SiteQueryResult(topics: topics, hits: hits)
    }

    // MARK: Requests

    func listings(query: [URLQueryItem]) async throws -> [ForumTopicListing] {
        try await jsonList("/posts", query).compactMap { entry in
            (entry as? [String: Any]).flatMap { WordPressParsing.listing($0, siteURL: net.siteURL) }
        }
    }

    func jsonList(_ path: String, _ query: [URLQueryItem]) async throws -> [Any] {
        guard let url = Self.restURL(siteURL: net.siteURL, path: "/wp-json/wp/v2" + path, query: query) else {
            throw AssistantError.invalidResponse
        }
        let data = try await net.data(url, accept: "application/json")
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw AssistantError.invalidResponse
        }
        return list
    }

    /// A `+` in search text must reach WordPress as itself, not as a space.
    private static func restURL(siteURL: String, path: String, query: [URLQueryItem]) -> URL? {
        guard let url = ForumSite.url(siteURL: siteURL, path: path, query: query) else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "+", with: "%2B"))
    }

    /// `after` / `before` as the start of that day, the form the REST filters take.
    private static func dateFilters(_ options: SearchOptions) -> [URLQueryItem] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func start(_ date: Date) -> String {
            let day = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02dT00:00:00", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        }
        var items: [URLQueryItem] = []
        if let after = options.after { items.append(URLQueryItem(name: "after", value: start(after))) }
        if let before = options.before { items.append(URLQueryItem(name: "before", value: start(before))) }
        return items
    }
}

extension WordPressParsing {
    /// A post of a list response; nil without a positive id. The title falls
    /// back to `Post <id>`, the link to `/?p=<id>` when it is missing or not
    /// on the site.
    static func listing(_ json: [String: Any], siteURL: String) -> ForumTopicListing? {
        guard let id = json["id"] as? Int, id > 0 else { return nil }
        let title = oneLine(rendered(json["title"]))
        var listing = placeholderListing(id: id, siteURL: siteURL)
        if !title.isEmpty { listing.title = title }
        if let link = (json["link"] as? String).flatMap({ URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
           ForumSite.isSameForum(url: link, siteURL: siteURL) {
            listing.url = link
        }
        listing.lastPostedAt = timestamp(json["date_gmt"] as? String)
        let excerpt = oneLine(HTMLText.plainText(rendered(json["excerpt"])))
        listing.excerpt = excerpt.isEmpty ? nil : String(excerpt.prefix(300))
        return listing
    }

    /// A post known by its id only.
    static func placeholderListing(id: Int, siteURL: String) -> ForumTopicListing {
        ForumTopicListing(
            siteURL: siteURL,
            id: id,
            title: "Post \(id)",
            slug: "",
            url: WordPressLinks().topicURL(siteURL: siteURL, topicID: String(id), slug: nil) ?? URL(string: siteURL)!,
            postsCount: nil
        )
    }
}

/// Post `N` of a WordPress post by arithmetic: #1 is the article, #N the
/// comment at index `N-2`, on comment page `(N-2)/100 + 1`.
struct WordPressPostLookup: PostLookup {
    func posts(_ numbers: [Int], in topic: TopicRef, facts: TopicFacts, net: SiteNetwork) async throws -> [ForumPost] {
        let api = WordPressAPI(net: net)
        var result: [ForumPost] = []
        var pages: [Int: [WordPressComment]] = [:]
        for number in numbers where number >= 1 {
            try Task.checkCancellation()
            if number == 1 {
                let article = try await api.fetchArticleText(topicID: topic.topicID)
                result.append(ForumPost(
                    id: article.id, number: 1, username: article.author ?? "anonymous",
                    text: HTMLText.plainText(article.html), likeCount: nil
                ))
                continue
            }
            let index = number - 2
            let page = index / WordPressAPI.commentsPerPage + 1
            if pages[page] == nil {
                pages[page] = try await api.fetchCommentPage(postID: topic.topicID, page: page).comments
            }
            let slot = index % WordPressAPI.commentsPerPage
            // A short page: the comment is gone or never was.
            guard let comments = pages[page], slot < comments.count else { continue }
            let comment = comments[slot]
            result.append(ForumPost(
                id: comment.id, number: number,
                username: comment.author.isEmpty ? "anonymous" : comment.author,
                text: HTMLText.plainText(comment.html), likeCount: nil
            ))
        }
        return result
    }
}
