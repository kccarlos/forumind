import Foundation

/// Discourse's part of the agent: its search and list tools, the words its
/// prompt uses, and the mapping from tool arguments to a `SiteQuery`.
enum DiscourseAgent {
    /// Its words in the voice agent.
    static let voice = VoiceSiteProfile(
        persona: "a reading companion for Discourse forums",
        findHint: "Discourse matches words, so search an English forum in English even when the user speaks another language.",
        languageHint: "Discourse search matches words, so a Chinese question about an English forum is searched with English words."
    )

    static let profile = AgentSiteProfile(
        siteDescription: "a Discourse forum",
        siteNoun: "forum",
        topicNoun: "topic",
        postNumbering: """
        Posts are numbered: read_topic text starts each post with "author | date UTC | #N",
          and search results list posts as "#N @author". Cite a specific post as
          /t/slug/id/N (the topic url plus /N), for example the accepted fix or a quote.
        """,
        postCitation: "When a point comes from a specific post, cite that post as "
            + "[title](url/N): the topic url plus /N, its post number.",
        siteTools: [
            AgentToolSpec(
                name: AgentToolName.searchForum.rawValue,
                description: "Search this forum's posts. Supports Discourse syntax: "
                    + "#category, order:latest, after:YYYY-MM-DD, in:title, topic:<id>. Returns up to "
                    + "20 topics with id, title, post count, last activity, and the matching posts "
                    + "as #N @author: excerpt.",
                parameters: [.init(name: "query", description: "Search text", required: true)]
            ),
            AgentToolSpec(
                name: AgentToolName.listLatest.rawValue,
                description: "List the forum's most recently active topics (about 30).",
                parameters: []
            )
        ],
        query: { tool, arguments in
            switch tool {
            case .searchForum:
                guard let text = arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else {
                    throw AgentError.missingArgument("query")
                }
                return .search(text: text, scope: .forum)
            case .listLatest:
                return .latest
            default:
                throw SiteQueryError.unsupported
            }
        },
        postLinkHint: { "(post N: \(DiscourseRoutes.topicPageURL($0).absoluteString)/N)" }
    )
}
