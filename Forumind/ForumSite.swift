import Foundation

/// Single source of truth for Discourse forum identity: site URLs,
/// topic routes, and forum keys.
///
/// A forum is identified by its site URL: origin plus optional base path
/// (subfolder installs such as `https://example.com/forum`). Only https is
/// accepted, plus http for localhost. Topic identity is the topic key,
/// `host[/basePath]/t/{id}`, which is stable across page URLs and unique
/// across forums.
enum ForumSite {
    private static let localHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
    private static let basePathPattern = "^(/[A-Za-z0-9._~-]+)*$"

    struct Site: Equatable {
        /// `scheme://host[:port]`, lowercase, default port omitted.
        var origin: String
        /// `host[:port]` as used in topic keys.
        var host: String
        /// Normalized base path ("" or "/forum").
        var basePath: String

        var siteURL: String { origin + basePath }
    }

    // MARK: Parsing

    static func normalizeBasePath(_ value: String?) -> String {
        guard var trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return ""
        }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return "" }
        let withSlash = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        guard withSlash.range(of: basePathPattern, options: .regularExpression) != nil else {
            return ""
        }
        let segments = withSlash.split(separator: "/")
        return segments.contains { $0 == "." || $0 == ".." } ? "" : withSlash
    }

    static func hasBasePathPrefix(_ path: String, basePath: String) -> Bool {
        basePath.isEmpty || path == basePath || path.hasPrefix(basePath + "/")
    }

    /// Origin and topic-key host of an allowed (https, or http on localhost) URL.
    static func origin(of url: URL) -> (origin: String, host: String)? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(), !rawHost.isEmpty
        else {
            return nil
        }
        guard scheme == "https" || (scheme == "http" && localHosts.contains(rawHost)) else {
            return nil
        }
        let hostText = rawHost.contains(":") && !rawHost.hasPrefix("[") ? "[\(rawHost)]" : rawHost
        var host = hostText
        if let port = components.port,
           !(scheme == "https" && port == 443),
           !(scheme == "http" && port == 80) {
            host += ":\(port)"
        }
        return ("\(scheme)://\(host)", host)
    }

    static func parse(siteURL: String?) -> Site? {
        guard let text = siteURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let components = URLComponents(string: text),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let url = components.url,
              let origin = origin(of: url)
        else {
            return nil
        }
        var rawPath = components.percentEncodedPath
        while rawPath.hasSuffix("/") { rawPath.removeLast() }
        let basePath = normalizeBasePath(rawPath)
        guard basePath == rawPath else { return nil }
        return Site(origin: origin.origin, host: origin.host, basePath: basePath)
    }

    /// The canonical site URL string, or nil when the value is not a valid site.
    static func normalizeSiteURL(_ siteURL: String?) -> String? {
        parse(siteURL: siteURL)?.siteURL
    }

    /// The site URL of a page, given the forum's base path (from the page probe).
    /// Nil when the page is outside that base path or not an allowed URL.
    static func siteURL(fromPage url: URL, basePath: String = "") -> String? {
        let normalized = normalizeBasePath(basePath)
        guard hasBasePathPrefix(url.path, basePath: normalized),
              let origin = origin(of: url)
        else {
            return nil
        }
        return origin.origin + normalized
    }

    private static func positiveTopicID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.allSatisfy(\.isASCII),
              trimmed.allSatisfy(\.isNumber),
              let number = Int(trimmed), number > 0
        else {
            return nil
        }
        return trimmed
    }

    /// `/t/{slug}/{id}` or `/t/{id}` under the base path; URL-only, so callers
    /// must combine it with page detection before treating a page as a forum.
    static func extractTopicID(from url: URL, basePath: String = "") -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        let normalized = normalizeBasePath(basePath)
        let path = url.path
        guard hasBasePathPrefix(path, basePath: normalized) else { return nil }
        let segments = path.dropFirst(normalized.count)
            .split(separator: "/")
            .map(String.init)
        guard segments.first == "t", segments.count >= 2 else { return nil }
        if let id = positiveTopicID(segments[1]) { return id }
        return segments.count >= 3 ? positiveTopicID(segments[2]) : nil
    }

    /// A topic id found anywhere in the path (`…/t/{slug}/{id}`), for URLs whose
    /// base path is not known yet (the "maybe" page state, shared links).
    static func looseTopicID(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        let segments = url.path.split(separator: "/").map(String.init)
        for index in segments.indices where segments[index] == "t" {
            let rest = segments.dropFirst(index + 1)
            if let first = rest.first, let id = positiveTopicID(first) { return id }
            if rest.count >= 2, let id = positiveTopicID(rest[rest.startIndex + 1]) { return id }
        }
        return nil
    }

    // MARK: Identity

    static func topicKey(siteURL: String, topicID: String) -> String? {
        guard let site = parse(siteURL: siteURL), let id = positiveTopicID(topicID) else {
            return nil
        }
        return "\(site.host)\(site.basePath)/t/\(id)"
    }

    static func isSameForum(url: URL, siteURL: String) -> Bool {
        guard let site = parse(siteURL: siteURL), let origin = origin(of: url) else {
            return false
        }
        return origin.origin == site.origin && hasBasePathPrefix(url.path, basePath: site.basePath)
    }

    /// `host[/basePath]` for display (no scheme).
    static func host(of siteURL: String) -> String {
        guard let site = parse(siteURL: siteURL) else { return siteURL }
        return site.host + site.basePath
    }

    static func displayName(siteURL: String, name: String?) -> String {
        let trimmed = String(
            (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
        )
        if !trimmed.isEmpty { return trimmed }
        guard let site = parse(siteURL: siteURL) else { return siteURL }
        return URLComponents(string: site.origin)?.host ?? site.host
    }

    // MARK: URL builders

    private static func url(_ siteURL: String, _ path: String, query: [URLQueryItem]? = nil) -> URL? {
        guard let site = normalizeSiteURL(siteURL),
              var components = URLComponents(string: site + path)
        else {
            return nil
        }
        if let query { components.queryItems = query }
        return components.url
    }

    static func topicURL(siteURL: String, topicID: String, slug: String? = nil) -> URL? {
        guard let id = positiveTopicID(topicID) else { return nil }
        // Listings without a slug fall back to the id as slug; skip it then.
        if let slug = slug?.trimmingCharacters(in: .whitespacesAndNewlines),
           !slug.isEmpty, slug != id,
           let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)?
               .replacingOccurrences(of: "/", with: "-"),
           let slugged = url(siteURL, "/t/\(encoded)/\(id)") {
            return slugged
        }
        return url(siteURL, "/t/\(id)")
    }

    static func topicJSONURL(siteURL: String, topicID: String) -> URL? {
        guard let id = positiveTopicID(topicID) else { return nil }
        return url(siteURL, "/t/\(id).json")
    }

    static func rawPageURL(siteURL: String, topicID: String, page: Int = 1) -> URL? {
        guard let id = positiveTopicID(topicID), page >= 1 else { return nil }
        return url(siteURL, "/raw/\(id)", query: [URLQueryItem(name: "page", value: String(page))])
    }

    static func searchURL(siteURL: String, query: String) -> URL? {
        url(siteURL, "/search.json", query: [URLQueryItem(name: "q", value: query)])
    }

    /// `/latest` (the forum home in the browser) or `/latest.json`.
    static func latestURL(siteURL: String, json: Bool = false) -> URL? {
        url(siteURL, json ? "/latest.json" : "/latest")
    }

    static func loginURL(siteURL: String) -> URL? {
        url(siteURL, "/login")
    }

    static func basicInfoURL(siteURL: String) -> URL? {
        url(siteURL, "/site/basic-info.json")
    }

    static func aboutURL(siteURL: String) -> URL? {
        url(siteURL, "/about.json")
    }

    // MARK: Cookies

    /// RFC 6265 domain match: a cookie for `example.com` (or `.example.com`)
    /// applies to `example.com` and its subdomains, never to other hosts.
    static func cookieDomain(_ domain: String, matchesHost host: String) -> Bool {
        var cookieDomain = domain.lowercased()
        if cookieDomain.hasPrefix(".") { cookieDomain.removeFirst() }
        let host = host.lowercased()
        guard !cookieDomain.isEmpty else { return false }
        return host == cookieDomain || host.hasSuffix("." + cookieDomain)
    }

    /// The cookies to send to one forum host.
    static func cookies(_ cookies: [HTTPCookie], forHost host: String) -> [HTTPCookie] {
        cookies.filter { cookieDomain($0.domain, matchesHost: host) }
    }
}
