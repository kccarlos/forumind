import Foundation

/// What a recognizer reads from a page: the keys it declares, collected by the
/// probe script in the page. Platform-neutral; each recognizer interprets the
/// bag. The probe's script is built from the registry's union of keys
/// (`PageFactsProbe`), so a page never reports more than a recognizer asked for.
struct PageFactKeys: Codable, Equatable, Sendable {
    /// `meta[name]` / `meta[property]` values. A declared meta that exists is
    /// present in the bag even when its content is empty.
    var meta: [String] = []
    /// `link[rel~=…]` hrefs (absolute).
    var links: [String] = []
    /// Element id → the dataset entries to read. An entry is a dataset key
    /// (`baseUri`) or `key:path.to.value`, where the dataset value is JSON and
    /// the path walks it (`preloaded:currentUser.username`). An empty list
    /// reports only that the element exists.
    var elements: [String: [String]] = [:]
    /// CSS selectors whose presence is reported.
    var selectors: [String] = []

    /// Read for every page, whatever the recognizers: the title falls back to
    /// `og:title` when `document.title` is empty (`PageFacts.pageTitle`).
    static let common = PageFactKeys(meta: ["og:title"])

    /// `common`, then every recognizer's keys in order, without repeats. The one
    /// place the app's registry and the share extension's list build the union.
    static func declared(by recognizers: [any SiteRecognizer]) -> PageFactKeys {
        recognizers.reduce(into: common) { $0.formUnion($1.factKeys) }
    }

    /// Adds `other`'s keys after this one's, without repeats.
    mutating func formUnion(_ other: PageFactKeys) {
        func merged(_ lhs: [String], _ rhs: [String]) -> [String] {
            var seen = Set<String>()
            return (lhs + rhs).filter { seen.insert($0).inserted }
        }
        meta = merged(meta, other.meta)
        links = merged(links, other.links)
        selectors = merged(selectors, other.selectors)
        for (id, keys) in other.elements { elements[id] = merged(elements[id] ?? [], keys) }
    }
}

/// The facts bag of one document. A missing key reads as empty, never as
/// malformed: the share extension's property list drops null and undefined
/// values, so any key may be absent.
struct PageFacts: Equatable, Sendable {
    /// Values are cut to this many characters in the page.
    static let valueLimit = 500

    var url: URL
    var title: String
    var meta: [String: String]
    var links: [String: String]
    /// Element id → dataset entries, for each declared element that exists.
    var elements: [String: [String: String]]
    /// The declared selectors that matched.
    var matches: Set<String>
    var htmlClass: String
    var bodyClass: String
    var iconURL: URL?

    init(
        url: URL,
        title: String = "",
        meta: [String: String] = [:],
        links: [String: String] = [:],
        elements: [String: [String: String]] = [:],
        matches: Set<String> = [],
        htmlClass: String = "",
        bodyClass: String = "",
        iconURL: URL? = nil
    ) {
        self.url = url
        self.title = title
        self.meta = meta
        self.links = links
        self.elements = elements
        self.matches = matches
        self.htmlClass = htmlClass
        self.bodyClass = bodyClass
        self.iconURL = iconURL
    }

    /// From the probe's dictionary (a `WKWebView` value, or the share
    /// extension's property list). `fallbackURL` stands in for a missing `url`.
    init(probe: [String: Any], fallbackURL: URL) {
        func strings(_ value: Any?) -> [String: String] {
            (value as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        }
        let elements = (probe["elements"] as? [String: Any] ?? [:]).mapValues { strings($0) }
        let icon = (probe["iconURL"] as? String).flatMap(URL.init(string:))
        self.init(
            url: (probe["url"] as? String).flatMap(URL.init(string:)) ?? fallbackURL,
            title: probe["title"] as? String ?? "",
            meta: strings(probe["meta"]),
            links: strings(probe["links"]),
            elements: elements,
            matches: Set((probe["matches"] as? [Any] ?? []).compactMap { $0 as? String }),
            htmlClass: probe["htmlClass"] as? String ?? "",
            bodyClass: probe["bodyClass"] as? String ?? "",
            iconURL: icon.flatMap { $0.scheme == "https" || $0.scheme == "http" ? $0 : nil }
        )
    }

    /// The document title, else its `og:title` (a page that sets no `<title>`).
    var pageTitle: String {
        title.isEmpty ? meta["og:title"] ?? "" : title
    }

    /// True when `htmlClass` or `bodyClass` has the class token `name`.
    func hasClass(_ name: String) -> Bool {
        let separators = CharacterSet.whitespacesAndNewlines
        return [htmlClass, bodyClass].contains { $0.components(separatedBy: separators).contains(name) }
    }
}
