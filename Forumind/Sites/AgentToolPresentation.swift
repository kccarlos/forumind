import Foundation

/// How a step of each tool shows in the agent panel: icon, tint and title.
/// One exhaustive table next to `AgentToolName`, so a new tool cannot ship
/// without a row (the compiler and `AgentToolPresentationTests` check it).
/// Titles are site-neutral; the panel maps `Tint` to its theme colors.
extension AgentToolName {
    enum Tint: Sendable {
        case search, read, summarize, watch, answer
    }

    var symbol: String {
        switch self {
        case .searchForum: "magnifyingglass"
        case .searchComments: "text.bubble"
        case .listLatest: "clock"
        case .readTopic: "doc.text"
        case .summarizeTopic: "text.alignleft"
        case .savedSummaries: "tray.full"
        case .watchTopic: "eye"
        case .finalAnswer: "checkmark"
        }
    }

    var tint: Tint {
        switch self {
        case .searchForum, .searchComments, .listLatest: .search
        case .readTopic, .savedSummaries: .read
        case .summarizeTopic: .summarize
        case .watchTopic: .watch
        case .finalAnswer: .answer
        }
    }

    /// The step's title (localized, past tense). `query` is the step's
    /// `query` argument, `topic` the topic's title or "topic N".
    func title(query: String, topic: () -> String) -> String {
        switch self {
        case .searchForum:
            String(localized: "Searched “\(query)”", comment: "Agent step; the placeholder is the search query")
        case .searchComments:
            String(localized: "Searched comments for “\(query)”", comment: "Agent step; the placeholder is the search query")
        case .listLatest:
            String(localized: "Listed the latest", comment: "Agent step")
        case .readTopic:
            String(localized: "Read \(topic())", comment: "Agent step (past tense); the placeholder is a topic title")
        case .summarizeTopic:
            String(localized: "Summarized \(topic())", comment: "Agent step; the placeholder is a topic title")
        case .savedSummaries:
            query.isEmpty
                ? String(localized: "Checked saved summaries", comment: "Agent step")
                : String(localized: "Saved summaries: \(query)", comment: "Agent step; the placeholder is a search query")
        case .watchTopic:
            String(localized: "Watching \(topic())", comment: "Agent step; the placeholder is a topic title")
        case .finalAnswer:
            String(localized: "Wrote the answer", comment: "Agent step")
        }
    }
}
