import Foundation

// MARK: - AI drawer hint row and post citations
//
// The pure parts of the iPhone AI drawer (AIDrawer.swift, Dock.swift,
// SummaryPanel.swift): the hint row over the bar while the drawer is closed,
// and the `#N` post citations in a summary (found, linked and tapped to jump
// to the post, §4.5).

/// The row over the bar that says what the drawer can do for this topic,
/// only when it is worth a look: the first topic ever opened (the one-time
/// "Summarize this topic" tip), new replies since the summary, or AI not set
/// up or not allowed. Otherwise there is no row.
enum DrawerHint {
    struct Input: Equatable {
        var pageState: PageContext.State
        var mode: AssistantMode = .summary
        /// The AI provider for the mode is set up.
        var providerReady = true
        /// The provider isn't ready because the AI data consent was declined.
        var consentDeclined = false
        var hasSummary = false
        /// A summary (or a pull of the posts) runs for the topic.
        var summaryRunning = false
        /// The topic's post count and how many the summary covered.
        var totalPosts: Int?
        var summaryPostCount: Int?
    }

    /// The row's trailing button.
    enum Action: Equatable {
        case summarize
        /// The summary is stale; the count is nil when unknown.
        case checkNew(Int?)
        case setUpAI
        case allowAI

        /// Spoken label of the icon-only button.
        var title: String {
            switch self {
            case .summarize: String(localized: "Summarize this topic", comment: "Hint row over the bar on a topic without a summary, and its button")
            case .checkNew(let count?): String(localized: "Check \(count) new replies", comment: "Button on the hint row over the bar; the placeholder is the number of replies since the summary")
            case .checkNew(nil): String(localized: "Check for new replies")
            case .setUpAI: String(localized: "Set up AI", comment: "Hint row over the bar when no AI provider is set up, and its button")
            case .allowAI: String(localized: "Allow AI", comment: "Hint row over the bar when the AI data consent was declined, and its button: show the consent again")
            }
        }

        var symbol: String {
            switch self {
            case .summarize: "sparkles"
            case .checkNew: "arrow.clockwise"
            case .setUpAI, .allowAI: "key.fill"
            }
        }

        /// The count on the badge ("99+" from 100), if any.
        var badge: String? {
            guard case .checkNew(let count?) = self, count > 0 else { return nil }
            return count > 99 ? "99+" : "\(count)"
        }

        var needsAttention: Bool { self == .setUpAI || self == .allowAI }
    }

    /// The row: its text, and the button that does the action.
    struct Row: Equatable {
        let action: Action
        /// The one-time first-run tip (a bulb, highlighted).
        let isTip: Bool

        var text: String {
            switch action {
            case .checkNew(let count?): String(localized: "\(count) new replies")
            case .summarize, .checkNew(nil), .setUpAI, .allowAI: action.title
            }
        }
    }

    /// What the drawer's main action is for a page state; nil when there is
    /// nothing to do (no topic, a summary running or up to date, Ask the forum).
    static func action(_ input: Input) -> Action? {
        guard input.pageState == .topic else { return nil }
        if !input.providerReady { return input.consentDeclined ? .allowAI : .setUpAI }
        guard input.mode == .summary, !input.summaryRunning else { return nil }
        if !input.hasSummary { return .summarize }
        if let total = input.totalPosts, let covered = input.summaryPostCount, total > covered {
            return .checkNew(total - covered)
        }
        return nil
    }

    /// The hint row, or nil for no row. "Summarize this topic" shows only as
    /// the first-run tip (`tipPending`); new replies and AI setup always.
    static func row(_ input: Input, tipPending: Bool) -> Row? {
        switch action(input) {
        case nil: nil
        case .summarize: tipPending ? Row(action: .summarize, isTip: true) : nil
        case let action?: Row(action: action, isTip: false)
        }
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

    /// The text without citations (read aloud, translated).
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
