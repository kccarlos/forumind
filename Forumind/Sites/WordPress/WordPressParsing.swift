import Foundation

/// The article of a post or page, as the REST API gave it.
struct WordPressArticle: Equatable, Sendable {
    var id: Int
    /// One line, entities decoded; empty when the post has no title.
    var title: String
    var link: String
    var published: Date?
    /// `modified_gmt` as sent (zone-less); the cache's revision token.
    var modified: String?
    var html: String
    /// The author's display name from `_embedded.author`; nil when not embedded.
    var author: String?
}

/// One reader comment.
struct WordPressComment: Equatable, Sendable {
    var id: Int
    /// The comment it answers, 0 for a top-level comment.
    var parent: Int
    var author: String
    var date: Date?
    var html: String
}

/// WordPress's REST JSON, as pure functions from response bytes to the shared
/// types, and the shared raw text (`RawTopicFormat`) of an article and its comments.
nonisolated enum WordPressParsing {
    /// The REST index (`/wp-json/?_fields=name,namespaces,home,site_icon_url`).
    /// Nil unless `namespaces` lists `wp/v2`: that is what tells a WordPress
    /// REST root from any other JSON.
    static func parseSiteInfo(_ data: Data) -> ForumSiteInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let namespaces = json["namespaces"] as? [Any],
              namespaces.contains(where: { ($0 as? String) == "wp/v2" })
        else {
            return nil
        }
        let name = HTMLText.decodeEntities(json["name"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let icon = (json["site_icon_url"] as? String)
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
        return ForumSiteInfo(name: name, iconURL: icon)
    }

    // MARK: JSON

    /// Nil without an id. Missing fields read as empty: the API may drop them (`_fields`, old sites).
    static func parseArticle(_ json: [String: Any]) -> WordPressArticle? {
        guard let id = json["id"] as? Int else { return nil }
        let embedded = json["_embedded"] as? [String: Any]
        let author = ((embedded?["author"] as? [Any])?.first as? [String: Any])?["name"] as? String
        return WordPressArticle(
            id: id,
            title: oneLine(rendered(json["title"])),
            link: (json["link"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            published: date(gmt: json["date_gmt"] as? String),
            modified: json["modified_gmt"] as? String,
            html: rendered(json["content"]),
            author: author.map(oneLine).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// Entries without an id are dropped.
    static func parseComments(_ list: [Any]) -> [WordPressComment] {
        list.compactMap { entry in
            guard let json = entry as? [String: Any], let id = json["id"] as? Int else { return nil }
            return WordPressComment(
                id: id,
                parent: json["parent"] as? Int ?? 0,
                author: oneLine(json["author_name"] as? String ?? ""),
                date: date(gmt: json["date_gmt"] as? String),
                html: rendered(json["content"])
            )
        }
    }

    static func rendered(_ field: Any?) -> String {
        (field as? [String: Any])?["rendered"] as? String ?? ""
    }

    // MARK: Text

    /// Entities decoded once, whitespace runs collapsed.
    static func oneLine(_ value: String) -> String {
        HTMLText.decodeEntities(value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `2026-05-14T17:02:05` (GMT, no zone) → `2026-05-14 17:02 UTC`; nil when it is not a date.
    static func timestamp(_ value: String?) -> String? {
        guard let value, let match = timePattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value)
        else {
            return nil
        }
        return value[range].replacingOccurrences(of: "T", with: " ") + " UTC"
    }

    /// The zone-less GMT stamp as a UTC date; nil when missing.
    static func date(gmt value: String?) -> Date? {
        guard let value,
              let match = datePattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
        else {
            return nil
        }
        func part(_ index: Int) -> Int {
            Range(match.range(at: index), in: value).flatMap { Int(value[$0]) } ?? 0
        }
        return utc.date(from: DateComponents(
            year: part(1), month: part(2), day: part(3), hour: part(4), minute: part(5), second: part(6)
        ))
    }

    private static let timePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}"#)
    private static let datePattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?"#
    )
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// What a cached page 1 is compared with: the article's edit time, or `unknown`.
    static func revision(of article: WordPressArticle) -> String {
        timestamp(article.modified) ?? "unknown"
    }

    // MARK: Raw text

    /// One page of the post as raw text: the article (page 1 only) then the
    /// page's comments. Numbers are positional: article #1, comments from #2,
    /// 100 to a page. A reply names the comment it answers by number when that
    /// comment is on the same page, so the text never depends on which other
    /// pages were fetched or cached.
    static func page(_ page: Int, article: WordPressArticle?, comments: [WordPressComment], revision: String?) -> RawForumPage {
        var posts: [(block: PostBlock, body: String)] = []
        if let article {
            let updated = timestamp(article.modified) ?? "unknown"
            let header = [
                "Article: \(article.title.isEmpty ? "(untitled)" : article.title)",
                article.link.isEmpty ? nil : "URL: \(article.link)",
                "Updated: \(updated)"
            ].compactMap { $0 }.joined(separator: "\n")
            posts.append((
                PostBlock(number: 1, author: RawTopicFormat.authorToken(article.author ?? ""), date: article.published, anchor: "", score: nil),
                header + "\n\n" + text(article.html)
            ))
        }
        let first = (page - 1) * WordPressAPI.commentsPerPage + 2
        let numbers = Dictionary(comments.enumerated().map { ($1.id, first + $0) }, uniquingKeysWith: { first, _ in first })
        for (index, comment) in comments.enumerated() {
            var body = text(comment.html)
            if comment.parent > 0 {
                let marker = numbers[comment.parent].map { "[Reply to #\($0)]" } ?? "[Reply to an earlier comment]"
                body = marker + "\n" + body
            }
            posts.append((
                PostBlock(number: first + index, author: RawTopicFormat.authorToken(comment.author), date: comment.date, anchor: "comment-\(comment.id)", score: nil),
                body
            ))
        }
        // A page past the last (comments deleted since the count) is empty text.
        return RawForumPage(
            page: page,
            content: posts.isEmpty ? "" : RawTopicFormat.render(posts),
            blocks: posts.map(\.block),
            revision: revision
        )
    }

    private static func text(_ html: String) -> String {
        let text = HTMLText.plainText(html)
        return text.isEmpty ? "(no text)" : text
    }
}

/// Candidate site URLs for an address typed in Add forum. A permalink path
/// does not say where WordPress is installed, so the deepest guesses come
/// first: origin plus the first two path segments, the first segment, the
/// origin (at most three requests).
nonisolated enum WordPressAddress {
    static func candidates(fromAddress address: String) -> [String] {
        guard let address = SiteAddress.parse(address) else { return [] }
        var result: [String] = []
        for depth in stride(from: min(2, address.pathSegments.count), through: 1, by: -1) {
            let basePath = ForumSite.normalizeBasePath("/" + address.pathSegments.prefix(depth).joined(separator: "/"))
            if !basePath.isEmpty { result.append(address.origin + basePath) }
        }
        result.append(address.origin)
        return result
    }
}
