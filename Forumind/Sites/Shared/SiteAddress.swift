import Foundation

/// The part of "Add forum" address handling every platform shares: what a
/// typed address names, before the platform decides which base paths to try.
enum SiteAddress {
    /// The origin and path segments of a typed address: a full URL or a bare
    /// host (https, or http for localhost), optionally with a page path. Nil for
    /// text that is not an address.
    static func parse(_ address: String) -> (origin: String, pathSegments: [String])? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if text.range(of: "^[A-Za-z][A-Za-z0-9+.-]*://", options: .regularExpression) == nil {
            let host = text.split(separator: "/").first.map(String.init) ?? text
            let isLocal = host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1")
            guard host.contains(".") || isLocal else { return nil }
            text = (isLocal ? "http://" : "https://") + text
        }
        guard let url = URL(string: text), let origin = ForumSite.origin(of: url) else { return nil }
        return (origin.origin, url.path.split(separator: "/").map(String.init))
    }
}
