import Foundation

/// Every Discourse URL: topic pages, JSON and raw endpoints, search, login.
/// Site identity (parsing, topic keys, cookies) stays in `ForumSite`.
enum DiscourseRoutes {
    static func topicURL(siteURL: String, topicID: String, slug: String? = nil) -> URL? {
        guard let id = ForumSite.positiveTopicID(topicID) else { return nil }
        // Listings without a slug fall back to the id as slug; skip it then.
        if let slug = slug?.trimmingCharacters(in: .whitespacesAndNewlines),
           !slug.isEmpty, slug != id,
           let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
               .replacingOccurrences(of: "/", with: "-"),
           let slugged = ForumSite.url(siteURL: siteURL, path: "/t/\(encoded)/\(id)") {
            return slugged
        }
        return ForumSite.url(siteURL: siteURL, path: "/t/\(id)")
    }

    /// `/t/{slug}/{id}/{postNumber}`: Discourse opens the topic at that post.
    static func topicURL(siteURL: String, topicID: String, slug: String? = nil, postNumber: Int) -> URL? {
        guard postNumber >= 1, let topic = topicURL(siteURL: siteURL, topicID: topicID, slug: slug) else {
            return nil
        }
        return postURL(topicURL: topic, number: postNumber)
    }

    /// `{topic URL without a post number}/{number}`, from any topic page URL
    /// (`/t/slug/123`, `/t/slug/123/45`, with or without a base path).
    static func postURL(topicURL: URL, number: Int) -> URL {
        let topic = topicPageURL(topicURL)
        guard var components = URLComponents(url: topic, resolvingAgainstBaseURL: false) else {
            return topic.appendingPathComponent(String(number))
        }
        components.path += "/\(number)"
        return components.url ?? topic.appendingPathComponent(String(number))
    }

    /// A topic page URL without its post number, query or fragment.
    static func topicPageURL(_ topicURL: URL) -> URL {
        var components = URLComponents(url: topicURL, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        var path = components?.path ?? topicURL.path
        while path.hasSuffix("/") { path.removeLast() }
        // /t/slug/123 or /t/slug/123/45: keep up to the topic ID.
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if let t = parts.firstIndex(of: "t") {
            let afterT = parts[(t + 1)...]
            let idIndex = afterT.firstIndex { Int($0) != nil }
            if let idIndex {
                path = parts[...idIndex].joined(separator: "/")
            }
        }
        components?.path = path
        return components?.url ?? topicURL
    }

    /// Ways Discourse can narrow a topic: its top posts (`?filter=summary`)
    /// or one author's posts (`?username_filters=name`).
    enum TopicFilter: Equatable {
        case summary
        case username(String)

        var queryItems: [URLQueryItem] {
            switch self {
            case .summary: [URLQueryItem(name: "filter", value: "summary")]
            case .username(let name): [URLQueryItem(name: "username_filters", value: name)]
            }
        }
    }

    /// A filtered topic page for the browser.
    static func topicURL(siteURL: String, topicID: String, slug: String? = nil, filter: TopicFilter) -> URL? {
        guard let topic = topicURL(siteURL: siteURL, topicID: topicID, slug: slug),
              var components = URLComponents(url: topic, resolvingAgainstBaseURL: false)
        else {
            return nil
        }
        components.queryItems = filter.queryItems
        return components.url
    }

    static func topicJSONURL(siteURL: String, topicID: String, filter: TopicFilter? = nil) -> URL? {
        guard let id = ForumSite.positiveTopicID(topicID) else { return nil }
        return ForumSite.url(siteURL: siteURL, path: "/t/\(id).json", query: filter?.queryItems)
    }

    /// `/t/{id}/posts.json?post_ids[]=…`: specific posts of a topic by post id
    /// (ids come from `post_stream.stream`, not post numbers).
    static func topicPostsJSONURL(siteURL: String, topicID: String, postIDs: [Int]) -> URL? {
        guard let id = ForumSite.positiveTopicID(topicID), !postIDs.isEmpty, postIDs.allSatisfy({ $0 > 0 }) else {
            return nil
        }
        return ForumSite.url(
            siteURL: siteURL,
            path: "/t/\(id)/posts.json",
            query: postIDs.map { URLQueryItem(name: "post_ids[]", value: String($0)) }
        )
    }

    static func rawPageURL(siteURL: String, topicID: String, page: Int = 1) -> URL? {
        guard let id = ForumSite.positiveTopicID(topicID), page >= 1 else { return nil }
        return ForumSite.url(siteURL: siteURL, path: "/raw/\(id)", query: [URLQueryItem(name: "page", value: String(page))])
    }

    static func searchURL(siteURL: String, query: String) -> URL? {
        ForumSite.url(siteURL: siteURL, path: "/search.json", query: [URLQueryItem(name: "q", value: query)])
    }

    /// The forum's search page in the browser (the iPhone bar's search).
    static func searchPageURL(siteURL: String, query: String) -> URL? {
        ForumSite.url(siteURL: siteURL, path: "/search", query: [URLQueryItem(name: "q", value: query)])
    }

    /// `/latest` (the forum home in the browser) or `/latest.json`.
    static func latestURL(siteURL: String, json: Bool = false) -> URL? {
        ForumSite.url(siteURL: siteURL, path: json ? "/latest.json" : "/latest")
    }

    /// `/top.json?period=daily` (or another period): the period's top topics.
    static func topURL(siteURL: String, period: String = "daily") -> URL? {
        ForumSite.url(siteURL: siteURL, path: "/top.json", query: [URLQueryItem(name: "period", value: period)])
    }

    static func loginURL(siteURL: String) -> URL? {
        ForumSite.url(siteURL: siteURL, path: "/login")
    }

    static func basicInfoURL(siteURL: String) -> URL? {
        ForumSite.url(siteURL: siteURL, path: "/site/basic-info.json")
    }

    static func aboutURL(siteURL: String) -> URL? {
        ForumSite.url(siteURL: siteURL, path: "/about.json")
    }
}
