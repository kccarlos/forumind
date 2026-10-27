import Foundation

/// WordPress URLs. A permalink is a slug with no id, so a topic is addressed
/// by `/?p={id}` (WordPress redirects it to the permalink; it works for pages
/// too) and a parsed link is only ever a `?p=` / `?page_id=` one.
struct WordPressLinks: SiteLinks {
    func homeURL(siteURL: String) -> URL? {
        ForumSite.url(siteURL: siteURL, path: "")
    }

    func topicURL(siteURL: String, topicID: String, slug: String?) -> URL? {
        guard let id = ForumSite.positiveTopicID(topicID) else { return nil }
        return ForumSite.url(siteURL: siteURL, path: "/", query: [URLQueryItem(name: "p", value: id)])
    }

    /// The topic page, plus `#anchor` (`comment-<id>`) when the anchor is known.
    func postURL(topicURL: URL, number: Int, anchor: String?) -> URL {
        let page = topicPageURL(topicURL)
        guard let anchor, !anchor.isEmpty,
              var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        else {
            return page
        }
        components.fragment = anchor
        return components.url ?? page
    }

    /// No fragment; the query only when it is a `p` / `page_id` id; no trailing
    /// `comment-page-N` segment (WordPress's paged comments).
    func topicPageURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        let id = components.queryItems?.first { ($0.name == "p" || $0.name == "page_id") && $0.value != nil }
        components.queryItems = id.map { [$0] }
        var segments = components.path.components(separatedBy: "/")
        let trailingSlash = segments.last == ""
        if trailingSlash { segments.removeLast() }
        if let last = segments.last, last.range(of: #"^comment-page-\d+$"#, options: .regularExpression) != nil {
            segments.removeLast()
            let path = segments.joined(separator: "/")
            components.path = path.isEmpty ? "/" : path + "/"
        }
        return components.url ?? url
    }

    func canonicalPageURL(_ url: URL) -> URL { topicPageURL(url) }

    func parse(_ url: URL, basePath: String) -> SiteLink? {
        guard let id = WordPressRecognizer().topicID(fromURL: url, basePath: basePath) else { return nil }
        return SiteLink(topicID: id, slug: nil, postNumber: nil)
    }

    /// There is no stable "newest comment" address (`#comments` depends on the theme).
    func lastPostURL(topicURL: URL) -> URL? { nil }
}
