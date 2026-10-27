import Foundation

/// The one shape of a topic's AI-facing text, whatever the platform:
///
/// - a post is `author | YYYY-MM-DD HH:MM:SS UTC | #N`, a newline, its body;
/// - posts are joined with `blockSeparator`, and a page's text ends in a newline;
/// - pages are joined with `blockSeparator` too;
/// - no post contains `blockSeparator`.
///
/// Prompts state this format, `ModerationFilter` hides posts by it and
/// `PromptBuilder.splitForHierarchicalSummary` cuts at the separator.
enum RawTopicFormat {
    static let blockSeparator = "\n\n\n"

    /// A header line: author token, date, post number.
    static let headerPattern = try! NSRegularExpression(
        pattern: #"^(\S+) \| (\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2}) UTC \| #(\d+)$"#,
        options: [.anchorsMatchLines]
    )

    struct Header: Equatable {
        var number: Int
        var author: String
        var date: Date?
        /// The header line's range in the parsed text (UTF-16 units).
        var range: NSRange
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Every header line of `text`, in order.
    static func parseHeaders(_ text: String) -> [Header] {
        let string = text as NSString
        return headerPattern.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
            func part(_ index: Int) -> Int { Int(string.substring(with: match.range(at: index))) ?? 0 }
            let date = utc.date(from: DateComponents(
                year: part(2), month: part(3), day: part(4), hour: part(5), minute: part(6), second: part(7)
            ))
            return Header(
                number: part(8),
                author: string.substring(with: match.range(at: 1)),
                date: date,
                range: match.range
            )
        }
    }

    /// The blocks of a page's text: the headers it holds. Post numbers are
    /// the anchors (Discourse).
    static func blocks(in text: String) -> [PostBlock] {
        parseHeaders(text).map {
            PostBlock(number: $0.number, author: $0.author, date: $0.date, anchor: "\($0.number)", score: nil)
        }
    }

    /// Whitespace runs become `_`; `anonymous` when empty.
    static func authorToken(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        return words.isEmpty ? "anonymous" : words.joined(separator: "_")
    }

    static func headerLine(for block: PostBlock) -> String {
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: block.date ?? Date(timeIntervalSince1970: 0))
        let date = String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
        return "\(authorToken(block.author)) | \(date) UTC | #\(block.number)"
    }

    /// `\r\n` becomes `\n`, runs of three or more newlines collapse to two, and the body is trimmed.
    static func sanitizedBody(_ body: String) -> String {
        var text = body.replacingOccurrences(of: "\r\n", with: "\n")
        while text.contains(blockSeparator) { text = text.replacingOccurrences(of: blockSeparator, with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One page's text for `posts` (a post without a date gets the epoch).
    static func render(_ posts: [(block: PostBlock, body: String)]) -> String {
        posts
            .map { headerLine(for: $0.block) + "\n" + sanitizedBody($0.body) }
            .joined(separator: blockSeparator) + "\n"
    }

    /// The topic text for pages' texts, in page order.
    static func join(_ pageContents: [String]) -> String {
        pageContents.joined(separator: blockSeparator)
    }
}
