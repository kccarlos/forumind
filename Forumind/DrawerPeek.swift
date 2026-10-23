import Foundation

// MARK: - AI drawer peek line and post citations
//
// The pure parts of the iPhone AI drawer (AIDrawer.swift, SummaryPanel.swift):
// the peek's one line for each page state, and the `#N` post citations in a
// summary (found, linked and tapped to jump to the post, §4.5).

/// The peek's one line: the first sentence of the summary, or what the page
/// is ("Summarize this topic", "Not a forum", …).
enum DrawerPeek {
    struct Input: Equatable {
        var pageState: PageContext.State
        var mode: AssistantMode = .summary
        /// The AI provider for the mode is set up.
        var providerReady = true
        /// The summary shown (streamed text while one is being written).
        var summary = ""
        var summaryRunning = false
    }

    static func line(_ input: Input) -> String {
        switch input.pageState {
        case .loading:
            return String(localized: "Loading page…")
        case .notForum:
            return String(localized: "Not a forum", comment: "AI drawer peek line on a page that is not a Discourse forum")
        case .maybe:
            return String(localized: "Might be a forum · Try again", comment: "AI drawer peek line while it is unclear whether the page is a forum")
        case .forumHome:
            return String(localized: "Forum home", comment: "AI drawer peek line on a forum's home or topic list")
        case .topic:
            break
        }
        if !input.providerReady {
            return String(localized: "Set up AI", comment: "AI drawer peek line when no AI provider is set up")
        }
        if input.mode == .agent {
            return String(localized: "Ask the forum")
        }
        if let sentence = firstSentence(of: input.summary) {
            return sentence
        }
        if input.summaryRunning {
            return String(localized: "Writing summary…")
        }
        return String(localized: "Summarize this topic", comment: "AI drawer peek line on a topic without a summary")
    }

    /// The first sentence of the first text block (headings, code and tables
    /// skipped), as plain text without citations.
    static func firstSentence(of markdown: String) -> String? {
        for block in MarkdownParser.parse(markdown) {
            let text: String
            switch block {
            case .paragraph(let value), .quote(let value): text = value
            case .unorderedList(let items), .orderedList(let items):
                guard let first = items.first else { continue }
                text = first
            case .heading, .code, .table, .rule:
                continue
            }
            let plain = plainText(PostCitations.stripped(text))
            guard !plain.isEmpty else { continue }
            return sentence(in: plain)
        }
        return nil
    }

    private static func plainText(_ markdown: String) -> String {
        let attributed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
        return String(attributed.characters)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Up to and including the first sentence end (Latin or CJK).
    private static func sentence(in text: String) -> String {
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if "。！？".contains(character) {
                return String(text[...index])
            }
            if let last = previous, ".!?".contains(last), character == " " {
                return String(text[..<index])
            }
            previous = character
        }
        return text
    }
}

/// `#N` post citations in AI text. The summary prompt asks for them; the
/// drawer turns each into a link (`forumind-post:N`) that renders as a chip
/// and jumps to the post.
enum PostCitations {
    static let scheme = "forumind-post"

    /// `#37`, not inside a word, a URL or `##`. ASCII only before it, so
    /// `确认#37` still counts.
    private static let pattern = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_&/#\[])#(\d{1,5})(?![\d\]])"#
    )

    static func url(post number: Int) -> URL? {
        URL(string: "\(scheme):\(number)")
    }

    /// The post number of a citation link, or nil.
    static func postNumber(from url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.absoluteString.dropFirst(scheme.count + 1)).flatMap { $0 >= 1 ? $0 : nil }
    }

    /// The cited post numbers in order of first appearance.
    static func numbers(in text: String, maximum: Int? = nil) -> [Int] {
        var seen: [Int] = []
        for (_, number) in matches(in: text, maximum: maximum) where !seen.contains(number) {
            seen.append(number)
        }
        return seen
    }

    /// Rewrites `#37` as `[#37](forumind-post:37)` outside code. Numbers above
    /// `maximum` (the topic's highest post) stay plain text.
    static func linked(_ markdown: String, maximum: Int? = nil) -> String {
        transform(markdown) { line in
            let nsLine = line as NSString
            var result = ""
            var cursor = 0
            for (range, number) in matches(in: line, maximum: maximum) {
                result += nsLine.substring(with: NSRange(location: cursor, length: range.location - cursor))
                result += "[#\(number)](\(scheme):\(number))"
                cursor = range.location + range.length
            }
            return result + nsLine.substring(from: cursor)
        }
    }

    /// The text without citations (the peek line, read aloud).
    static func stripped(_ markdown: String) -> String {
        guard let pattern else { return markdown }
        let nsText = markdown as NSString
        let removed = pattern.stringByReplacingMatches(
            in: markdown, range: NSRange(location: 0, length: nsText.length), withTemplate: ""
        )
        // "fixes it #37 ; three" → "fixes it; three"
        return removed
            .replacingOccurrences(of: #"[ \t]+([.,;:!?。，；：！？])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }

    private static func matches(in text: String, maximum: Int?) -> [(NSRange, Int)] {
        guard let pattern else { return [] }
        let nsText = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match in
            guard let number = Int(nsText.substring(with: match.range(at: 1))), number >= 1 else { return nil }
            if let maximum, maximum > 0, number > maximum { return nil }
            return (match.range, number)
        }
    }

    /// Applies `body` to the text outside fenced code blocks and inline code.
    private static func transform(_ markdown: String, _ body: (String) -> String) -> String {
        var inFence = false
        return markdown.components(separatedBy: "\n").map { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                return line
            }
            if inFence { return line }
            // Odd pieces between backticks are inline code.
            return line.components(separatedBy: "`").enumerated()
                .map { $0.offset.isMultiple(of: 2) ? body($0.element) : $0.element }
                .joined(separator: "`")
        }
        .joined(separator: "\n")
    }
}

/// One jump to a cited post; `serial` makes a second tap on the same post a
/// new event (haptic).
struct CitationJump: Equatable {
    var number: Int
    var serial: Int
}
