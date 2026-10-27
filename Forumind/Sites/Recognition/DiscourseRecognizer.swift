import Foundation

extension SiteKind {
    static let discourse = SiteKind("discourse")
}

/// Discourse renders these tags server-side: a generator containing
/// `Discourse`, `discourse-base-uri`, or `#data-discourse-setup`.
struct DiscourseRecognizer: SiteRecognizer {
    var kind: SiteKind { .discourse }
    var platformName: String { "Discourse" }

    var factKeys: PageFactKeys {
        PageFactKeys(
            meta: ["generator", "discourse-base-uri", "og:site_name"],
            elements: [
                "data-discourse-setup": ["baseUri"],
                "data-preloaded": [Self.preloadedUsername]
            ],
            selectors: Self.currentUserSelectors
        )
    }

    /// The signed-in user, from the page's preloaded data (a JSON string).
    static let preloadedUsername = "preloaded:currentUser.username"
    /// Present on a signed-in page.
    static let currentUserSelectors = [".current-user", "[data-current-user]"]

    func recognize(facts: PageFacts, url: URL) -> SitePageMatch? {
        let setup = facts.elements["data-discourse-setup"]
        let baseURIMeta = facts.meta["discourse-base-uri"]
        let generator = facts.meta["generator"] ?? ""
        guard generator.range(of: #"\bDiscourse\b"#, options: [.regularExpression, .caseInsensitive]) != nil
            || baseURIMeta != nil || setup != nil
        else {
            return nil
        }
        // The first non-empty: the setup's dataset, else the meta.
        let basePath = [setup?["baseUri"], baseURIMeta].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        guard let siteURL = ForumSite.siteURL(fromPage: url, basePath: basePath) else { return nil }
        let normalized = ForumSite.parse(siteURL: siteURL)?.basePath ?? ""
        return SitePageMatch(
            siteURL: siteURL,
            basePath: normalized,
            forumName: facts.meta["og:site_name"] ?? "",
            kind: kind,
            platformName: platformName,
            topicID: topicID(fromURL: url, basePath: normalized)
        )
    }

    /// `/t/{slug}/{id}` or `/t/{id}` under the base path; URL-only, so callers
    /// must combine it with page detection before treating a page as a forum.
    func topicID(fromURL url: URL, basePath: String = "") -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        let normalized = ForumSite.normalizeBasePath(basePath)
        let path = url.path
        guard ForumSite.hasBasePathPrefix(path, basePath: normalized) else { return nil }
        let segments = path.dropFirst(normalized.count)
            .split(separator: "/")
            .map(String.init)
        guard segments.first == "t", segments.count >= 2 else { return nil }
        if let id = ForumSite.positiveTopicID(segments[1]) { return id }
        return segments.count >= 3 ? ForumSite.positiveTopicID(segments[2]) : nil
    }

    /// A topic id found anywhere in the path (`…/t/{slug}/{id}`), for URLs whose
    /// base path is not known yet (the "maybe" page state, shared links).
    func looseTopicID(in url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            return nil
        }
        let segments = url.path.split(separator: "/").map(String.init)
        for index in segments.indices where segments[index] == "t" {
            let rest = segments.dropFirst(index + 1)
            if let first = rest.first, let id = ForumSite.positiveTopicID(first) { return id }
            if rest.count >= 2, let id = ForumSite.positiveTopicID(rest[rest.startIndex + 1]) { return id }
        }
        return nil
    }

    /// The post number of a topic URL (`/t/slug/123/45` → 45), read only from
    /// a numeric segment right after the topic id; nil for `/t/slug/123`,
    /// `/t/slug/123/last` and non-topic URLs.
    func postNumber(in url: URL) -> Int? {
        // The same topic id `looseTopicID` finds, then the segment after it.
        let segments = url.path.split(separator: "/").map(String.init)
        for index in segments.indices where segments[index] == "t" {
            let rest = Array(segments[(index + 1)...])
            let idIndex: Int
            if let first = rest.first, ForumSite.positiveTopicID(first) != nil {
                idIndex = 0
            } else if rest.count >= 2, ForumSite.positiveTopicID(rest[1]) != nil {
                idIndex = 1
            } else {
                continue
            }
            guard idIndex + 1 < rest.count, let number = ForumSite.positiveTopicID(rest[idIndex + 1]) else { return nil }
            return Int(number)
        }
        return nil
    }
}
