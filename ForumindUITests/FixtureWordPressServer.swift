import Foundation
import Network

/// A made-up WordPress site (and an Ollama-shaped model) served from the UI
/// test process on `127.0.0.1`, so a WordPress test never touches the network.
/// The app under test runs in the same simulator and reaches it over loopback;
/// `ForumSite` accepts http on loopback and ATS exempts IP addresses.
///
/// Serves `/hello-world/` (REST-root link, shortlink, `postid-1001` body class,
/// site name "Fixture Blog"), `/wp-json/`, the post, 250 comments in pages of
/// 100 with `X-WP-Total` / `X-WP-TotalPages`, post search, and `POST /api/chat`.
/// Everything it is asked is logged.
final class FixtureWordPressServer: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: Data

        /// `path?query` with the query sorted.
        var line: String {
            let sorted = query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&")
            return path + (sorted.isEmpty ? "" : "?" + sorted)
        }
    }

    static let postID = 1001
    static let commentCount = 250
    static let summaryMarker = "FIXTURE-SUMMARY-ANSWER"
    static let chatMarker = "FIXTURE-CHAT-ANSWER"
    static let chatQuestion = "What do readers say about the card?"

    private let queue = DispatchQueue(label: "fixture-wordpress")
    private let lock = NSLock()
    private var listener: NWListener?
    private var log: [Request] = []
    private(set) var port: UInt16 = 0

    var baseURL: String { "http://127.0.0.1:\(port)" }
    var postURL: String { baseURL + "/hello-world/" }

    var requests: [Request] { lock.withLock { log } }

    // MARK: Lifecycle

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
        self.listener = listener
        self.port = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: HTTP

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.lock.withLock { self.log.append(request) }
                connection.send(content: self.response(for: request), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// A complete request (headers and the declared body), else nil.
    private static func parse(_ data: Data) -> Request? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8)
        else {
            return nil
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ").map(String.init)
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = data[split.upperBound...]
        if body.count < (Int(headers["content-length"] ?? "") ?? 0) { return nil }
        let components = URLComponents(string: requestLine[1])
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: requestLine[0], path: components?.path ?? requestLine[1], query: query, headers: headers, body: Data(body))
    }

    private func response(for request: Request) -> Data {
        let (status, type, headers, body) = answer(request)
        var text = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        text += "Content-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        // Same-origin pages read every header; a real site lists them too.
        text += "Access-Control-Expose-Headers: X-WP-Total, X-WP-TotalPages\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        return Data(text.utf8) + Data("\r\n".utf8) + body
    }

    // MARK: Site

    private typealias Answer = (Int, String, [String: String], Data)

    private func json(_ object: Any, headers: [String: String] = [:], status: Int = 200) -> Answer {
        (status, "application/json", headers, (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    private func answer(_ request: Request) -> Answer {
        switch (request.method, request.path) {
        case ("POST", "/api/chat"):
            return chat(request)
        case (_, "/hello-world/"), (_, "/"):
            return (200, "text/html; charset=utf-8", [:], Data(page.utf8))
        case (_, "/wp-json/"), (_, "/wp-json"):
            return json([
                "name": "Fixture Blog",
                "home": baseURL,
                "namespaces": ["wp/v2"]
            ])
        case (_, "/wp-json/wp/v2/posts/\(Self.postID)"):
            return json(article)
        case (_, "/wp-json/wp/v2/comments"):
            return comments(request)
        case (_, "/wp-json/wp/v2/posts"):
            return paged([article].map { post in
                ["id": post["id"]!, "title": post["title"]!, "link": post["link"]!, "date_gmt": post["date_gmt"]!,
                 "categories": [Int](), "excerpt": ["rendered": "<p>The fixture article.</p>"]]
            }, request)
        case (_, "/wp-json/wp/v2/categories"):
            return paged([[String: Any]](), request)
        default:
            return json(["code": "rest_no_route"], status: 404)
        }
    }

    private var page: String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Sample Cards - Fixture Blog</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta property="og:site_name" content="Fixture Blog">
        <link rel="https://api.w.org/" href="\(baseURL)/wp-json/">
        <link rel="shortlink" href="\(baseURL)/?p=\(Self.postID)">
        </head><body class="post-template-default single single-post postid-\(Self.postID)">
        <h1>Sample Cards</h1><p>The opening article of the fixture blog. Readers leave comments below.</p>
        </body></html>
        """
    }

    private var article: [String: Any] {
        [
            "id": Self.postID,
            "date_gmt": "2026-05-14T16:00:00",
            "modified_gmt": "2026-05-14T16:00:00",
            "link": "\(baseURL)/hello-world/",
            "title": ["rendered": "Sample Cards"],
            "content": ["rendered": "<p>The opening article of the fixture blog. Readers leave comments below.</p>"],
            "excerpt": ["rendered": "<p>The fixture article.</p>"],
            "comment_status": "open",
            "_embedded": ["author": [["name": "alice"]]]
        ]
    }

    private func comments(_ request: Request) -> Answer {
        let all = (1...Self.commentCount).map { index -> [String: Any] in
            [
                "id": 5000 + index, "post": Self.postID, "parent": 0,
                "author_name": "user\(index)",
                "date_gmt": String(format: "2026-05-14T%02d:%02d:05", 10 + index / 60, index % 60),
                "content": ["rendered": "<p>Comment number \(index) is worth it.</p>"]
            ]
        }
        let search = (request.query["search"] ?? "").lowercased()
        let matching = search.isEmpty ? all : all.filter { (($0["content"] as? [String: Any])?["rendered"] as? String ?? "").lowercased().contains(search) }
        return paged(matching, request)
    }

    private func paged(_ items: [[String: Any]], _ request: Request) -> Answer {
        let perPage = max(1, Int(request.query["per_page"] ?? "") ?? 10)
        let page = Int(request.query["page"] ?? "") ?? 1
        let totalPages = (items.count + perPage - 1) / perPage
        if page > max(totalPages, 1) {
            return json(["code": "rest_post_invalid_page_number", "message": "The page number requested is larger than the number of pages available."], status: 400)
        }
        return json(
            Array(items.dropFirst((page - 1) * perPage).prefix(perPage)),
            headers: ["X-WP-Total": String(items.count), "X-WP-TotalPages": String(totalPages)]
        )
    }

    // MARK: Model

    /// Ollama's `/api/chat`: newline-delimited JSON. A request that carries the
    /// UI test's question is the chat; anything else is the summary.
    private func chat(_ request: Request) -> Answer {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        let messages = body?["messages"] as? [[String: Any]] ?? []
        let lastUser = messages.last { ($0["role"] as? String) == "user" }?["content"] as? String ?? ""
        let reply = lastUser.contains(Self.chatQuestion) ? Self.chatMarker : Self.summaryMarker
        let lines = [
            ["message": ["role": "assistant", "content": reply + " "], "done": false],
            ["message": ["role": "assistant", "content": "Readers liked it."], "done": true]
        ].compactMap { try? JSONSerialization.data(withJSONObject: $0) }
        let text = lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        return (200, "application/x-ndjson", [:], Data(text.utf8))
    }

    /// The text of every model request: the system prompt and each message.
    var modelRequests: [String] {
        requests.filter { $0.path == "/api/chat" }.map { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
            let messages = body?["messages"] as? [[String: Any]] ?? []
            return messages.compactMap { $0["content"] as? String }.joined(separator: "\n---\n")
        }
    }

    /// Comment requests of the app's two read paths: the in-page `fetch()`
    /// sends a `Referer` (the shown page), `URLSession` does not.
    var commentRequests: [Request] {
        requests.filter { $0.path == "/wp-json/wp/v2/comments" }
    }
}
