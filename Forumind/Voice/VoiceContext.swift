import Foundation
import NaturalLanguage

/// The open topic's facts for the topic brief.
struct VoiceTopicBrief: Equatable {
    struct Post: Equatable {
        var number: Int
        var username: String
        var likes: Int?
    }

    var topicKey: String
    var title: String
    var forumName: String
    /// The opening post's text (trimmed by the note).
    var opening: String?
    var openingPoster: String?
    var postCount: Int?
    var solution: Post?
    var topPosts: [Post] = []
    /// The saved AI summary, when the topic has one.
    var summary: String?
}

/// The silent context (plan B4): what the model is told without asking, as
/// bracketed `[Screen: …]` / `[Forumind: …]` notes. It remembers what was
/// sent, so a note carries only the change since the last one; `reset()`
/// (after a reconnect: context sent after the last handle is lost) makes
/// the next notes whole again.
///
/// Budget: every turn re-bills the whole context, so the focused post is
/// capped at about 800 tokens (`BrowseText.contentLimit`), the opening
/// question and the summary are trimmed, and a visible post is one line.
struct VoiceContext {
    static let openingLimit = 700
    static let summaryLimit = 1_500
    static let lineLimit = 120
    static let visibleLimit = 6

    /// The topic the last brief was about.
    private(set) var briefedTopic: String?
    private(set) var briefNote: String?
    private(set) var summaryNote: String?
    /// The last position note's parts, for deltas.
    private var lastCurrent: String?
    private var lastVisible: [Int] = []
    private var lastList: String?
    private var lastVisibleText: String?
    private var lastPositionNote: String?
    /// Posts (`topicKey#n`) whose full text the model has.
    private(set) var fullTextSent: Set<String> = []

    // MARK: Topic brief

    /// The brief for a newly opened topic; nil when it was already sent.
    mutating func topicBriefNote(_ brief: VoiceTopicBrief) -> String? {
        guard brief.topicKey != briefedTopic else { return nil }
        briefedTopic = brief.topicKey
        summaryNote = nil
        lastCurrent = nil
        lastVisible = []
        var lines = ["[Screen: the user opened the topic “\(brief.title)” on \(brief.forumName)."]
        let language = Self.languageName(of: [brief.title, brief.opening ?? ""].joined(separator: "\n"))
        if let language { lines.append("The forum writes in \(language); search it in \(language).") }
        if let count = brief.postCount { lines.append("It has \(count) posts.") }
        if let opening = brief.opening, !opening.isEmpty {
            let author = brief.openingPoster.map { " by \($0)" } ?? ""
            lines.append("The opening post\(author) asks: \(BrowseText.trimmed(opening, limit: Self.openingLimit))")
        }
        if let solution = brief.solution {
            lines.append("Accepted answer: post \(solution.number) by \(solution.username).")
        } else {
            lines.append("No accepted answer.")
        }
        if !brief.topPosts.isEmpty {
            let top = brief.topPosts.prefix(5).map { post in
                "post \(post.number) by \(post.username)" + (post.likes.map { " (\($0) likes)" } ?? "")
            }
            lines.append("Most liked: \(top.joined(separator: ", ")).")
        }
        var note = lines.joined(separator: " ") + "]"
        if let summary = brief.summary, !summary.isEmpty {
            note += "\n" + summaryText(summary, title: brief.title)
            summaryNote = summaryText(summary, title: brief.title)
        }
        briefNote = note
        return note
    }

    /// The quick summary made after the brief, as a second note.
    mutating func summaryNote(_ summary: String, topicKey: String, title: String) -> String? {
        guard topicKey == briefedTopic, summaryNote == nil, !summary.isEmpty else { return nil }
        let note = summaryText(summary, title: title)
        summaryNote = note
        return note
    }

    private func summaryText(_ summary: String, title: String) -> String {
        "[Forumind: AI summary of “\(title)”: \(BrowseText.trimmed(summary, limit: Self.summaryLimit))]"
    }

    // MARK: Position

    /// The current post, the visible posts and the current list: only what
    /// changed since the last note; nil when nothing did.
    mutating func positionNote(page: PageContext, visible: [VisiblePost], cursor: BrowseCursor) -> String? {
        guard page.state == .topic, let topic = page.topic else { return nil }
        var parts: [String] = []
        let current = page.currentPost.map { number in
            let author = visible.first { $0.number == number }?.username
            return BrowseText.postDescription(
                number: number, total: page.postsCount, username: author, acceptedAnswer: page.acceptedAnswerPost
            )
        }
        if let current, current != lastCurrent {
            parts.append("At \(current).")
        }
        let shownNumbers = visible.map(\.number)
        if !shownNumbers.isEmpty, shownNumbers != lastVisible {
            let lines = visible.prefix(Self.visibleLimit).map { post in
                "#\(post.number) \(post.username): \(BrowseText.oneLine(Self.firstSentence(post.excerpt), limit: Self.lineLimit))"
            }
            let text = "On screen: " + lines.joined(separator: " | ")
            parts.append(text)
            lastVisibleText = text
        }
        let list = Self.listText(cursor)
        if list != lastList, let list {
            parts.append(list)
        }
        lastCurrent = current ?? lastCurrent
        if !shownNumbers.isEmpty { lastVisible = shownNumbers }
        lastList = list
        guard !parts.isEmpty else { return nil }
        if briefedTopic == nil { briefedTopic = topic.topicKey }
        let note = "[Screen: " + parts.joined(separator: " ") + "]"
        lastPositionNote = "[Screen: " + [current.map { "At \($0)." }, lastVisibleText, list].compactMap { $0 }.joined(separator: " ") + "]"
        return note
    }

    static func listText(_ cursor: BrowseCursor) -> String? {
        guard !cursor.isEmpty else { return nil }
        let kind: String = switch cursor.origin {
        case .search(let query)?: "search results for “\(query)”"
        case .research?, .sources?: "research sources"
        case .focus?: "focused posts"
        case nil: "items"
        }
        let position = cursor.positionText.map { ", at \($0)" } ?? ", none open yet"
        return "Current list: \(cursor.items.count) \(kind)\(position)."
    }

    // MARK: Full text (grounding)

    static func postKey(topicKey: String, number: Int) -> String { "\(topicKey)#\(number)" }

    func hasFullText(topicKey: String, number: Int) -> Bool {
        fullTextSent.contains(Self.postKey(topicKey: topicKey, number: number))
    }

    /// A post's full text as a note (capped at about 800 tokens).
    mutating func fullTextNote(_ result: BrowseResult, topicKey: String, number: Int) -> String? {
        guard result.status == .read, let content = result.content else { return nil }
        fullTextSent.insert(Self.postKey(topicKey: topicKey, number: number))
        return "[Screen: full text of \(result.shown), which the user is looking at: \(content)]"
    }

    /// Records that a tool result carried a post's text (open, move, read).
    mutating func noteContentSent(topicKey: String, number: Int) {
        fullTextSent.insert(Self.postKey(topicKey: topicKey, number: number))
    }

    mutating func forgetFullText(topicKey: String, number: Int) {
        fullTextSent.remove(Self.postKey(topicKey: topicKey, number: number))
    }

    // MARK: Reconnect

    /// Everything the model should know now, whole: sent first on a new
    /// connection. Clears the delta state so later notes build on it.
    mutating func fullContextNotes() -> [String] {
        let notes = [briefNote, briefNote?.contains("[Forumind: AI summary") == true ? nil : summaryNote, lastPositionNote]
            .compactMap { $0 }
        fullTextSent = []
        return notes
    }

    /// Forgets what was sent (a fresh model session knows nothing).
    mutating func reset() {
        self = VoiceContext()
    }

    // MARK: Screen references

    /// Words that point at the screen: the user means the post in front of
    /// them. English matches whole words; Chinese anywhere.
    static let screenReferences: [String] = [
        "this post", "this one", "this reply", "this answer", "this comment", "he said", "she said", "they said",
        "he says", "she says", "what he", "what she", "the op", "original poster", "this guy", "on screen",
        "这一楼", "这楼", "这个", "这条", "这篇", "这段", "他说的", "她说的", "他说", "她说", "楼主", "上面",
        "這一樓", "這樓", "這個", "這條", "這篇", "這段", "他說的", "她說的", "他說", "她說", "樓主"
    ]

    static func refersToScreen(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let padded = " " + lowered.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression) + " "
        return screenReferences.contains { phrase in
            phrase.unicodeScalars.first.map { $0.isASCII } == true
                ? padded.contains(" \(phrase) ")
                : lowered.contains(phrase)
        }
    }

    // MARK: Helpers

    /// The first sentence (or the whole line when it has none).
    static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [". ", "。", "? ", "？", "! ", "！", "\n"] {
            if let range = trimmed.range(of: separator), trimmed.distance(from: trimmed.startIndex, to: range.lowerBound) >= 20 {
                let end = separator.hasSuffix(" ") || separator == "\n" ? range.lowerBound : range.upperBound
                let sentence = String(trimmed[..<end])
                return separator == ". " ? sentence + "." : sentence
            }
        }
        return trimmed
    }

    /// The language a forum writes in, in English ("German"), guessed from
    /// a topic's text; nil when unsure.
    static func languageName(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.5 else {
            return nil
        }
        var code = language.rawValue
        if code.hasPrefix("zh") { code = "zh" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code)
    }
}
