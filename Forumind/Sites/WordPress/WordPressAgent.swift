import Foundation

/// WordPress's part of the agent: its search and list tools, the words its
/// prompt uses, and the mapping from tool arguments to a `SiteQuery`.
enum WordPressAgent {
    /// Its words in the voice agent.
    static let voice = VoiceSiteProfile(
        persona: "a reading companion for WordPress sites: articles with reader comments",
        findHint: "WordPress search matches words, so search in the site's own language even when the user speaks another.",
        languageHint: "WordPress search matches words, so a question in another language is searched with words in the site's language."
    )

    /// What its material is in the summary, chunk and chat prompts.
    static let discussion = DiscussionProfile(
        openingHeading: "Article",
        material: "a WordPress article with reader comments",
        blocks: "#1 is the article by its author; later numbers are reader comments, oldest first; "
            + "a comment may start with \"[Reply to #M]\" naming the comment it answers.",
        signals: "There are no likes or accepted answers."
    )

    private static let searchParameters: [AgentToolSpec.Parameter] = [
        .init(name: "query", description: "Search text", required: true),
        .init(name: "after", description: "Only items after this date, YYYY-MM-DD", required: false),
        .init(name: "before", description: "Only items before this date, YYYY-MM-DD", required: false),
        .init(name: "page", description: "Result page, 1 to 3", required: false)
    ]

    static let profile = AgentSiteProfile(
        siteDescription: "a WordPress site",
        siteNoun: "site",
        topicNoun: "post",
        postNumbering: """
        Posts are articles; read_topic text starts each item with "author | date UTC | #N":
          #1 is the article and later numbers are reader comments. A comment may start with
          "[Reply to #M]". Cite a post as [title](url) using the url from the tool results.
        """,
        postCitation: "When a point comes from a post, cite it as [title](url): the post's url.",
        siteTools: [
            AgentToolSpec(
                name: AgentToolName.searchForum.rawValue,
                description: "Search the site's posts (articles) by keyword; results are ranked by relevance. "
                    + "Returns up to about 20 posts with id, title, date and an excerpt. "
                    + "Example: {\"tool\": \"search_forum\", \"arguments\": {\"query\": \"chase sapphire bonus\", \"after\": \"2026-01-01\"}}.",
                parameters: [
                    searchParameters[0],
                    .init(name: "category", description: "Category name or slug", required: false)
                ] + searchParameters.dropFirst()
            ),
            AgentToolSpec(
                name: AgentToolName.searchComments.rawValue,
                description: "Search reader comments across all posts by keyword (newest first). Slow, so it returns "
                    + "only 10 comments per page, each with the post id and title, author, date and a text excerpt. "
                    + "Use it to find what readers report; then read_topic the post to get a citable source. "
                    + "Example: {\"tool\": \"search_comments\", \"arguments\": {\"query\": \"approved instantly\"}}.",
                parameters: searchParameters
            ),
            AgentToolSpec(
                name: AgentToolName.listLatest.rawValue,
                description: "List the site's newest posts (about 30). "
                    + "Example: {\"tool\": \"list_latest\", \"arguments\": {}}.",
                parameters: []
            )
        ],
        query: { tool, arguments in
            switch tool {
            case .searchForum, .searchComments:
                guard let text = arguments["query"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty
                else {
                    throw AgentError.missingArgument("query")
                }
                return .search(
                    text: text,
                    scope: tool == .searchComments ? .comments : .forum,
                    options: try SearchOptions(arguments: arguments, allowsCategory: tool == .searchForum)
                )
            case .listLatest:
                return .latest
            default:
                throw SiteQueryError.unsupported
            }
        },
        postLinkHint: { "(article and comments: \($0.absoluteString))" }
    )
}
