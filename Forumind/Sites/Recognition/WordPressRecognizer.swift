import Foundation

extension SiteKind {
    static let wordpress = SiteKind("wordpress")
}

/// A WordPress page advertises its REST root in
/// `<link rel="https://api.w.org/" href=".../wp-json/">`; a single post or page
/// names its id in `<link rel="shortlink" href=".../?p=ID">` and in the body
/// class (`postid-ID`, `page-id-ID`). Permalinks are slugs, so the topic id
/// comes from these facts, not from the URL. Plain-permalink sites (REST root
/// at `?rest_route=`) are not supported.
struct WordPressRecognizer: SiteRecognizer {
    var kind: SiteKind { .wordpress }
    var platformName: String { "WordPress" }

    static let restRootRel = "https://api.w.org/"
    static let shortlinkRel = "shortlink"
    private static let restRootSuffix = "/wp-json"
    /// `PageFactsProbe` cuts the body class at this many characters.
    private static let bodyClassLimit = 2000

    var factKeys: PageFactKeys {
        PageFactKeys(meta: ["og:site_name"], links: [Self.restRootRel, Self.shortlinkRel])
    }

    func recognize(facts: PageFacts, url: URL) -> SitePageMatch? {
        guard let basePath = basePath(fromRestRoot: facts.links[Self.restRootRel], pageURL: url),
              let siteURL = ForumSite.siteURL(fromPage: url, basePath: basePath)
        else {
            return nil
        }
        return SitePageMatch(
            siteURL: siteURL,
            basePath: basePath,
            forumName: (facts.meta["og:site_name"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            platformName: platformName,
            topicID: topicID(fromFacts: facts, pageURL: url)
        )
    }

    /// `https://example.com/blog/wp-json/` → `/blog`; nil unless it is a
    /// same-origin pretty REST root without query or fragment.
    private func basePath(fromRestRoot restRoot: String?, pageURL: URL) -> String? {
        guard let restRoot, !restRoot.isEmpty,
              let root = URL(string: restRoot, relativeTo: pageURL)?.absoluteURL,
              let components = URLComponents(url: root, resolvingAgainstBaseURL: true),
              components.query == nil, components.fragment == nil,
              let rootOrigin = ForumSite.origin(of: root), let pageOrigin = ForumSite.origin(of: pageURL),
              rootOrigin.origin == pageOrigin.origin
        else {
            return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        guard path.hasSuffix(Self.restRootSuffix) else { return nil }
        let basePath = String(path.dropLast(Self.restRootSuffix.count))
        return basePath == ForumSite.normalizeBasePath(basePath) ? basePath : nil
    }

    /// The shortlink's `p`, else a `postid-N` / `page-id-N` body class token.
    /// A body class at the probe's limit may end in a cut token: that one is ignored.
    private func topicID(fromFacts facts: PageFacts, pageURL: URL) -> String? {
        if let shortlink = facts.links[Self.shortlinkRel],
           let link = URL(string: shortlink, relativeTo: pageURL)?.absoluteURL,
           let id = Self.queryID(in: link, names: ["p"]) {
            return id
        }
        var tokens = facts.bodyClass.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if facts.bodyClass.count >= Self.bodyClassLimit, !(facts.bodyClass.last?.isWhitespace ?? true) {
            tokens = Array(tokens.dropLast())
        }
        for token in tokens {
            for prefix in ["postid-", "page-id-"] where token.hasPrefix(prefix) {
                if let id = Self.validID(String(token.dropFirst(prefix.count))) { return id }
            }
        }
        return nil
    }

    /// WordPress ids are positive integers of at most 12 digits.
    private static func validID(_ text: String?) -> String? {
        guard let text, text.count <= 12, text.first != "0" else { return nil }
        return ForumSite.positiveTopicID(text)
    }

    /// The first of `names` that is a valid id in the URL's query.
    static func queryID(in url: URL, names: [String]) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for name in names {
            if let id = validID(items.first(where: { $0.name == name })?.value) { return id }
        }
        return nil
    }

    // MARK: URL-only

    /// `?p=N` or `?page_id=N` under the base path; slug permalinks carry no id.
    func topicID(fromURL url: URL, basePath: String = "") -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              ForumSite.hasBasePathPrefix(url.path, basePath: ForumSite.normalizeBasePath(basePath))
        else {
            return nil
        }
        return Self.queryID(in: url, names: ["p", "page_id"])
    }

    func looseTopicID(in url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              Self.rootPaths.contains(url.path)
        else {
            return nil
        }
        return Self.queryID(in: url, names: ["p", "page_id"])
    }

    /// Without a known site, `?p=` counts only where WordPress puts its short
    /// links (the site root or `index.php`): other sites paginate with `?p=` too.
    private static let rootPaths: Set<String> = ["", "/", "/index.php"]

    /// A comment fragment (`#comment-12`) holds a comment id, not a number.
    func postNumber(in url: URL) -> Int? { nil }
}
