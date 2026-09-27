import Foundation

// Links handed to the app from outside: the share extension (Safari, Chrome,
// any app sharing a web page) and `forumind://` deep links.
//
// Compiled into both the app and the ForumindShare extension, so it
// must stay Foundation-only and extension-safe.

struct IncomingLinkRequest: Codable, Equatable, Identifiable {
    enum Action: String, Codable, CaseIterable {
        case open
        case summary
        case chat
        case agent
    }

    var id: UUID
    var url: URL
    var action: Action
    var title: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        url: URL,
        action: Action = .open,
        title: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.action = action
        self.title = title
        self.createdAt = createdAt
    }
}

enum IncomingLink {
    static let scheme = "forumind"
    static let host = "open"

    /// `forumind://open?url=<enc>&action=<a>&title=<enc>&id=<uuid>`.
    /// `id` lets the app skip the matching SharedInbox entry, since the share
    /// extension both enqueues a request and opens this URL.
    static func url(for request: IncomingLinkRequest) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        var items = [
            URLQueryItem(name: "url", value: request.url.absoluteString),
            URLQueryItem(name: "action", value: request.action.rawValue)
        ]
        if let title = normalizedTitle(request.title) {
            items.append(URLQueryItem(name: "title", value: title))
        }
        items.append(URLQueryItem(name: "id", value: request.id.uuidString))
        components.queryItems = items
        // URLComponents leaves `+` unencoded; some parsers read it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    /// Accepts `forumind://open?...`.
    /// Returns nil unless the page URL is http(s). Unknown or missing actions
    /// fall back to `.open`.
    static func parse(_ url: URL, now: Date = Date()) -> IncomingLinkRequest? {
        guard let linkScheme = url.scheme?.lowercased(),
              linkScheme == scheme,
              url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems
        else {
            return nil
        }
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard let rawPageURL = value("url"),
              let pageURL = webURL(from: rawPageURL)
        else {
            return nil
        }
        let action = value("action").flatMap {
            IncomingLinkRequest.Action(rawValue: $0.lowercased())
        } ?? .open
        let id = value("id").flatMap(UUID.init(uuidString:)) ?? UUID()
        return IncomingLinkRequest(
            id: id,
            url: pageURL,
            action: action,
            title: normalizedTitle(value("title")),
            createdAt: now
        )
    }

    /// The first http(s) URL in shared text (Chrome shares "Title\nhttps://…").
    static func extractWebURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = webURL(from: trimmed) {
            return direct
        }
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        for match in detector.matches(in: trimmed, options: [], range: range) {
            if let url = match.url, isWebURL(url) {
                return url
            }
        }
        return nil
    }

    static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else {
            return false
        }
        return true
    }

    private static func webURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: { $0.isWhitespace }),
              let url = URL(string: trimmed),
              isWebURL(url)
        else {
            return nil
        }
        return url
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let collapsed = title
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(300))
    }
}

/// A small queue in the App Group container: the share extension enqueues,
/// the app drains on launch / foreground. Every call degrades to a no-op when
/// the container is unavailable (e.g. unsigned simulator builds).
enum SharedInbox {
    static var appGroupIdentifier: String { AppIdentity.appGroupIdentifier }
    static let fileName = "SharedInbox.json"
    static let maximumAge: TimeInterval = 24 * 60 * 60
    static let maximumCount = 20

    /// Test hook: when set, used instead of the App Group container file.
    static var storageURLOverride: URL?

    static var storageURL: URL? {
        if let storageURLOverride {
            return storageURLOverride
        }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Appends a request. Returns false when it could not be stored.
    @discardableResult
    static func enqueue(_ request: IncomingLinkRequest, now: Date = Date()) -> Bool {
        guard let fileURL = storageURL else { return false }
        var stored = false
        coordinate(fileURL) { url in
            var requests = fresh(read(url), now: now)
            requests.removeAll { $0.id == request.id }
            requests.append(request)
            requests.sort { $0.createdAt < $1.createdAt }
            if requests.count > maximumCount {
                requests.removeFirst(requests.count - maximumCount)
            }
            stored = write(requests, to: url)
        }
        return stored
    }

    /// Returns pending requests oldest first and empties the inbox. Entries
    /// older than `maximumAge` are dropped.
    static func drainAll(now: Date = Date()) -> [IncomingLinkRequest] {
        guard let fileURL = storageURL else { return [] }
        var drained: [IncomingLinkRequest] = []
        coordinate(fileURL) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            drained = fresh(read(url), now: now)
            try? FileManager.default.removeItem(at: url)
        }
        return drained
    }

    /// Removes one request (e.g. the one just delivered via deep link).
    /// Returns true when a fresh request with that id was queued, i.e. the
    /// link really came from the share extension.
    @discardableResult
    static func remove(id: UUID, now: Date = Date()) -> Bool {
        guard let fileURL = storageURL else { return false }
        var found = false
        coordinate(fileURL) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let requests = read(url)
            let remaining = requests.filter { $0.id != id }
            guard remaining.count != requests.count else { return }
            found = fresh(requests.filter { $0.id == id }, now: now).isEmpty == false
            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                _ = write(remaining, to: url)
            }
        }
        return found
    }

    private static func fresh(
        _ requests: [IncomingLinkRequest],
        now: Date
    ) -> [IncomingLinkRequest] {
        requests
            .filter { now.timeIntervalSince($0.createdAt) <= maximumAge }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private static func read(_ url: URL) -> [IncomingLinkRequest] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([IncomingLinkRequest].self, from: data)) ?? []
    }

    private static func write(_ requests: [IncomingLinkRequest], to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(requests)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Serializes access between the app and extension processes.
    private static func coordinate(_ fileURL: URL, _ body: (URL) -> Void) {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var didRun = false
        coordinator.coordinate(
            writingItemAt: fileURL,
            options: .forMerging,
            error: &coordinationError
        ) { url in
            didRun = true
            body(url)
        }
        if !didRun {
            body(fileURL)
        }
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()
}
