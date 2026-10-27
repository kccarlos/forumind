import Foundation
@testable import Forumind

/// A made-up WordPress site for the reader's tests, served through a
/// `URLProtocol`: post 1001 and page 2002 at `https://example.com`, comments
/// (`post=` filters like WordPress; default fixtures belong to post 1001) in pages with `X-WP-Total` / `X-WP-TotalPages`, the errors a real
/// site answers, and a request log. Shaped like a live probe of a public site
/// (100 comments to a page, oldest first, `rest_post_invalid_page_number` as 400).
final class WordPressFixtureSite: @unchecked Sendable {
    static let siteURL = "https://example.com"
    static let postID = "1001"
    static let pageID = "2002"

    struct Request: Equatable {
        var path: String
        var query: [String: String]
        var cookie: String?
        var line: String
    }

    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var contentType = "application/json"
        var body: Data
    }

    private static let latestLock = NSLock()
    nonisolated(unsafe) private static var latestSite: WordPressFixtureSite?
    /// The site most recently handed to a test that has no handle on it (the contract suite).
    static var latest: WordPressFixtureSite? {
        get { latestLock.withLock { latestSite } }
        set { latestLock.withLock { latestSite = newValue } }
    }

    private let lock = NSLock()
    private var commentList: [[String: Any]]
    private var modifiedGMT = "2026-10-25T11:50:59"
    private var requestLog: [Request] = []
    private var override: ((Request) -> Reply?)?
    private var totalHeaders = true
    private var postList = WordPressFixtureSite.defaultPosts
    private var categoryList = WordPressFixtureSite.defaultCategories

    init(commentCount: Int = 205) {
        commentList = (0..<commentCount).map { Self.comment($0 + 1) }
    }

    init(comments: [[String: Any]]) {
        commentList = comments
    }

    // MARK: Fixtures

    static func fixture(_ name: String) -> Data {
        let url = Bundle(for: WordPressFixtureSite.self).url(forResource: name, withExtension: "json")!
        return try! Data(contentsOf: url)
    }

    static func fixtureObject(_ name: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: fixture(name)) as! [String: Any]
    }

    static func fixtureComments(_ name: String = "comments-sample") -> [[String: Any]] {
        try! JSONSerialization.jsonObject(with: fixture(name)) as! [[String: Any]]
    }

    /// Comment `index` (1-based) of `post` (default 1001), one minute apart.
    static func comment(_ index: Int, post: Int = 1001, parent: Int = 0, author: String? = nil) -> [String: Any] {
        [
            "id": 5000 + index,
            "post": post,
            "parent": parent,
            "author_name": author ?? "user\(index)",
            "date_gmt": String(format: "2026-05-14T%02d:%02d:05", 10 + index / 60, index % 60),
            "content": ["rendered": "<p>Comment number \(index) &#8230; worth it?</p>"]
        ]
    }

    /// Posts of the collection (`/posts?search=...`), newest or oldest in any order.
    static let defaultPosts: [[String: Any]] = [
        post(1001, "(Update) Sample Cards &#038; Notes &#8211; Part 1", "2026-05-14T16:00:00", categories: [7], excerpt: "Opening post: the card is offering 10x &#038; more&hellip;", link: "https://example.com/2026/05/sample-cards-and-notes/"),
        post(1002, "Hotel Points Guide", "2026-06-01T09:00:00", categories: [8], excerpt: "How to book with points."),
        post(1003, "Weekend Deals", "2026-07-01T08:30:00", categories: [8, 7], excerpt: "")
    ]

    static let defaultCategories: [[String: Any]] = [
        ["id": 7, "name": "Credit Cards", "slug": "credit-cards"],
        ["id": 8, "name": "Travel &amp; Hotels", "slug": "travel"]
    ]

    static func post(_ id: Int, _ title: String, _ date: String, categories: [Int] = [], excerpt: String = "", link: String? = nil) -> [String: Any] {
        [
            "id": id,
            "title": ["rendered": title],
            "link": link ?? "https://example.com/\(date.prefix(4))/p\(id)/",
            "date_gmt": date,
            "categories": categories,
            "excerpt": ["rendered": excerpt.isEmpty ? "" : "<p>\(excerpt)</p>"]
        ]
    }

    // MARK: State (change between reads)

    var posts: [[String: Any]] {
        get { lock.withLock { postList } }
        set { lock.withLock { postList = newValue } }
    }

    var categories: [[String: Any]] {
        get { lock.withLock { categoryList } }
        set { lock.withLock { categoryList = newValue } }
    }

    var comments: [[String: Any]] {
        get { lock.withLock { commentList } }
        set { lock.withLock { commentList = newValue } }
    }

    var modified: String {
        get { lock.withLock { modifiedGMT } }
        set { lock.withLock { modifiedGMT = newValue } }
    }

    /// False: the site (or a proxy) sends no paging headers.
    var sendsTotalHeaders: Bool {
        get { lock.withLock { totalHeaders } }
        set { lock.withLock { totalHeaders = newValue } }
    }

    /// Answers a request itself (a refusal, a challenge page); nil lets the site answer.
    func respond(_ handler: ((Request) -> Reply?)?) {
        lock.withLock { override = handler }
    }

    func addComments(_ count: Int) {
        lock.withLock {
            let start = commentList.count
            commentList += (0..<count).map { Self.comment(start + $0 + 1) }
        }
    }

    // MARK: Log

    var requests: [Request] { lock.withLock { requestLog } }
    func clearRequests() { lock.withLock { requestLog = [] } }
    /// `path?query` of every request, the query sorted, as a golden.
    var requestLines: [String] { requests.map(\.line) }
    /// The `page` of every comments request, in order.
    var commentPages: [Int] {
        requests.filter { $0.path.hasSuffix("/comments") }.compactMap { $0.query["page"].flatMap(Int.init) }
    }

    // MARK: Network

    /// A network over this site; becomes the site `URLProtocol` answers for.
    func network(cookieHeader: String? = nil, siteURL: String = WordPressFixtureSite.siteURL) -> SiteNetwork {
        SiteNetwork(
            service: service(),
            siteURL: siteURL,
            context: SiteRequestContext(cookieHeader: cookieHeader, pace: .fast)
        )
    }

    /// A forum service over this site, for an `AppModel`.
    func service() -> ForumService {
        WordPressStubProtocol.serve(self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WordPressStubProtocol.self]
        return ForumService(
            session: URLSession(configuration: configuration),
            pacer: ForumRequestPacer(clock: InstantPacingClock())
        )
    }

    // MARK: Routes

    fileprivate func answer(_ url: URL, cookie: String?) -> Reply {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let sorted = (components.queryItems ?? []).sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
        let request = Request(
            path: components.path, query: query, cookie: cookie,
            line: components.path + (sorted.isEmpty ? "" : "?" + sorted)
        )
        let handler = lock.withLock {
            requestLog.append(request)
            return override
        }
        if let reply = handler?(request) { return reply }

        if components.path == "/wp-json/" { return Reply(body: Self.fixture("root-index")) }
        let parts = components.path.split(separator: "/").map(String.init)
        if parts.count == 5, parts[0] == "wp-json", parts[1] == "wp", parts[2] == "v2", let id = Int(parts[4]) {
            switch (parts[3], id) {
            case ("posts", 1001):
                var article = Self.fixtureObject("article-1001")
                article["modified_gmt"] = modified
                return Reply(body: try! JSONSerialization.data(withJSONObject: article))
            case ("pages", 2002):
                return Reply(body: Self.fixture("page-2002"))
            default:
                return Reply(status: 404, body: Self.fixture("error-invalid-id"))
            }
        }
        if parts == ["wp-json", "wp", "v2", "comments"] {
            var all = comments
            // As WordPress does: `post=ID` keeps that post's comments only.
            if let post = query["post"].flatMap(Int.init) {
                all = all.filter { ($0["post"] as? Int) == post }
            }
            if let search = query["search"]?.lowercased(), !search.isEmpty {
                all = all.filter { Self.text($0).contains(search) }
            }
            all = Self.dateFiltered(all, query)
            if query["order"] == "desc" { all.reverse() }
            return Self.paged(all, query, fields: query["_fields"], sendsTotalHeaders: sendsTotalHeaders)
        }
        if parts == ["wp-json", "wp", "v2", "posts"] {
            var all = posts
            if let search = query["search"]?.lowercased(), !search.isEmpty {
                all = all.filter { Self.text($0).contains(search) }
            }
            if let include = query["include"] {
                let ids = Set(include.split(separator: ",").compactMap { Int($0) })
                all = all.filter { ids.contains($0["id"] as? Int ?? 0) }
            }
            if let category = query["categories"].flatMap(Int.init) {
                all = all.filter { (($0["categories"] as? [Int]) ?? []).contains(category) }
            }
            all = Self.dateFiltered(all, query)
            all.sort { ($0["date_gmt"] as? String ?? "") > ($1["date_gmt"] as? String ?? "") }
            if query["order"] == "asc" { all.reverse() }
            return Self.paged(all, query, fields: query["_fields"], sendsTotalHeaders: sendsTotalHeaders)
        }
        if parts == ["wp-json", "wp", "v2", "categories"] {
            let search = (query["search"] ?? "").lowercased()
            let matches = categories.filter {
                search.isEmpty || Self.text($0).contains(search)
            }
            return Self.paged(matches, query, fields: query["_fields"], sendsTotalHeaders: sendsTotalHeaders)
        }
        return Reply(status: 404, body: Data(#"{"code":"rest_no_route"}"#.utf8))
    }
}

extension WordPressFixtureSite {
    /// Everything a search could match in one item, lowercased: its titles,
    /// bodies, names and slugs with tags and entities as the site stores them.
    fileprivate static func text(_ item: [String: Any]) -> String {
        var parts: [String] = []
        for key in ["title", "excerpt", "content"] {
            if let rendered = (item[key] as? [String: Any])?["rendered"] as? String { parts.append(rendered) }
        }
        for key in ["author_name", "name", "slug"] {
            if let value = item[key] as? String { parts.append(value) }
        }
        return parts.joined(separator: " ").lowercased()
    }

    /// `after` / `before` are `YYYY-MM-DDT00:00:00`, compared with `date_gmt` as text.
    fileprivate static func dateFiltered(_ items: [[String: Any]], _ query: [String: String]) -> [[String: Any]] {
        items.filter { item in
            let date = item["date_gmt"] as? String ?? ""
            if let after = query["after"], date <= after { return false }
            if let before = query["before"], date >= before { return false }
            return true
        }
    }

    /// One `page` of `per_page` items, with the paging headers and only the requested `_fields`.
    fileprivate static func paged(
        _ items: [[String: Any]], _ query: [String: String], fields: String?, sendsTotalHeaders: Bool
    ) -> Reply {
        let perPage = max(1, Int(query["per_page"] ?? "") ?? 10)
        let page = Int(query["page"] ?? "") ?? 1
        let totalPages = (items.count + perPage - 1) / perPage
        if page > max(totalPages, 1) { return Reply(status: 400, body: fixture("error-invalid-page")) }
        var slice = Array(items.dropFirst((page - 1) * perPage).prefix(perPage))
        if let fields {
            let keep = Set(fields.split(separator: ",").map(String.init))
            slice = slice.map { $0.filter { keep.contains($0.key) } }
        }
        var headers: [String: String] = [:]
        if sendsTotalHeaders {
            headers["X-WP-Total"] = String(items.count)
            headers["X-WP-TotalPages"] = String(totalPages)
        }
        return Reply(headers: headers, body: try! JSONSerialization.data(withJSONObject: slice))
    }
}

/// Answers every request from the current `WordPressFixtureSite`.
final class WordPressStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: WordPressFixtureSite?

    static func serve(_ site: WordPressFixtureSite) { lock.withLock { current = site } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let site = Self.lock.withLock { Self.current }
        let reply = site?.answer(url, cookie: request.value(forHTTPHeaderField: "Cookie"))
            ?? WordPressFixtureSite.Reply(status: 500, body: Data())
        var headers = reply.headers
        headers["Content-Type"] = reply.contentType
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
