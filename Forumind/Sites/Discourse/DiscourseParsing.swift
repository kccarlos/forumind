import Foundation

/// Discourse's JSON parsers: pure functions from response bytes to the
/// shared listing, hit, post and facts types.
enum DiscourseParsing {
    nonisolated static func parseBasicInfo(_ data: Data, siteURL: String) -> ForumSiteInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = json["title"] as? String
        else {
            return nil
        }
        let icon = [
            json["apple_touch_icon_url"],
            json["large_icon_url"],
            json["favicon_url"],
            json["logo_small_url"]
        ]
        .compactMap { $0 as? String }
        .first { !$0.isEmpty }
        return ForumSiteInfo(
            name: title.trimmingCharacters(in: .whitespacesAndNewlines),
            iconURL: icon.flatMap { resolve($0, siteURL: siteURL) }
        )
    }

    nonisolated static func parseAbout(_ data: Data, siteURL: String) -> ForumSiteInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let about = json["about"] as? [String: Any],
              let title = about["title"] as? String
        else {
            return nil
        }
        return ForumSiteInfo(name: title.trimmingCharacters(in: .whitespacesAndNewlines), iconURL: nil)
    }

    /// Icon paths may be relative (`/uploads/…`) or protocol-relative (`//cdn…`).
    private nonisolated static func resolve(_ value: String, siteURL: String) -> URL? {
        guard let base = ForumSite.parse(siteURL: siteURL).flatMap({ URL(string: $0.origin + "/") })
        else {
            return nil
        }
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
              url.scheme == "https" || url.scheme == "http"
        else {
            return nil
        }
        return url
    }

    /// One listing per topic, in the `topics` order, with its first hit's
    /// blurb as the excerpt (topics without a hit are kept).
    nonisolated static func parseSearchResults(_ data: Data, siteURL: String) -> [ForumTopicListing] {
        parseSearch(data, siteURL: siteURL).topics
    }

    /// Every hit of `/search.json` in the forum's order (the `posts` array,
    /// joined to `topics`), and the topic listings with their excerpts. A
    /// post without a post number, or whose topic is missing from `topics`
    /// (no title), is not a hit.
    nonisolated static func parseSearch(
        _ data: Data,
        siteURL: String
    ) -> (hits: [ForumSearchHit], topics: [ForumTopicListing]) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ([], [])
        }
        let topicObjects = json["topics"] as? [[String: Any]] ?? []
        var bare: [Int: ForumTopicListing] = [:]
        for topic in topicObjects {
            if let listing = listing(from: topic, siteURL: siteURL, excerpt: nil) {
                bare[listing.id] = listing
            }
        }
        let posts = json["posts"] as? [[String: Any]] ?? []
        let hits: [ForumSearchHit] = posts.compactMap { post in
            guard let topicID = post["topic_id"] as? Int,
                  let topic = bare[topicID],
                  let number = post["post_number"] as? Int, number >= 1
            else {
                return nil
            }
            return ForumSearchHit(
                topic: topic,
                postNumber: number,
                username: post["username"] as? String,
                blurb: post["blurb"] as? String,
                url: DiscourseRoutes.topicURL(
                    siteURL: siteURL, topicID: topic.topicID, slug: topic.slug, postNumber: number
                ) ?? topic.url
            )
        }
        // Blurbs live on the posts; a topic's first one is its excerpt (also
        // from posts too incomplete to be a hit).
        var excerpts: [Int: String] = [:]
        for post in posts {
            if let topicID = post["topic_id"] as? Int,
               let blurb = post["blurb"] as? String,
               excerpts[topicID] == nil {
                excerpts[topicID] = blurb
            }
        }
        let topics = topicObjects.compactMap { topic in
            listing(
                from: topic,
                siteURL: siteURL,
                excerpt: (topic["id"] as? Int).flatMap { excerpts[$0] }
            )
        }
        return (hits, topics)
    }

    /// Topic facts from `/t/{id}.json`. The accepted answer comes from the
    /// Solved plugin: `accepted_answer` (older versions), `accepted_answers`
    /// (current), or the loaded post marked `accepted_answer: true`. Posts'
    /// `topic_accepted_answer` only says the topic is solved. Likes are
    /// `like_count`, which is null for visitors, else the like action count
    /// in `actions_summary` (id 2).
    nonisolated static func parseTopicFacts(_ json: [String: Any]) -> TopicFacts {
        let stream = json["post_stream"] as? [String: Any]
        let posts: [TopicFacts.Post] = (stream?["posts"] as? [[String: Any]] ?? []).compactMap { post in
            guard let id = post["id"] as? Int,
                  let number = post["post_number"] as? Int,
                  let username = post["username"] as? String
            else {
                return nil
            }
            return TopicFacts.Post(id: id, number: number, username: username, likeCount: likeCount(of: post))
        }

        func answer(_ object: Any?) -> TopicFacts.AcceptedAnswer? {
            guard let object = object as? [String: Any],
                  let number = object["post_number"] as? Int, number >= 1
            else {
                return nil
            }
            return TopicFacts.AcceptedAnswer(postNumber: number, username: object["username"] as? String)
        }
        var accepted = answer(json["accepted_answer"])
            ?? answer((json["accepted_answers"] as? [Any])?.first)
        if accepted == nil,
           let marked = (stream?["posts"] as? [[String: Any]] ?? []).first(where: { $0["accepted_answer"] as? Bool == true }),
           let number = marked["post_number"] as? Int {
            accepted = TopicFacts.AcceptedAnswer(postNumber: number, username: marked["username"] as? String)
        }

        let createdBy = ((json["details"] as? [String: Any])?["created_by"] as? [String: Any])?["username"] as? String
        return TopicFacts(
            postsCount: json["posts_count"] as? Int,
            highestPostNumber: json["highest_post_number"] as? Int,
            stream: stream?["stream"] as? [Int] ?? [],
            openingPoster: createdBy ?? posts.first { $0.number == 1 }?.username,
            acceptedAnswer: accepted,
            posts: posts
        )
    }

    /// Posts of `/t/{id}/posts.json`, sorted by post number.
    nonisolated static func parsePosts(_ data: Data) -> [ForumPost] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let posts = (json["post_stream"] as? [String: Any])?["posts"] as? [[String: Any]]
        else {
            return []
        }
        return posts.compactMap { post -> ForumPost? in
            guard let id = post["id"] as? Int,
                  let number = post["post_number"] as? Int,
                  let username = post["username"] as? String
            else {
                return nil
            }
            return ForumPost(
                id: id,
                number: number,
                username: username,
                text: DiscourseHTML.plainText(post["cooked"] as? String ?? ""),
                likeCount: likeCount(of: post)
            )
        }
        .sorted { $0.number < $1.number }
    }

    private nonisolated static func likeCount(of post: [String: Any]) -> Int? {
        if let count = post["like_count"] as? Int { return count }
        guard let actions = post["actions_summary"] as? [[String: Any]] else { return nil }
        // An empty summary means no likes.
        return actions.first { $0["id"] as? Int == 2 }?["count"] as? Int ?? 0
    }

    nonisolated static func parseTopicList(_ data: Data, siteURL: String) -> [ForumTopicListing] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["topic_list"] as? [String: Any],
              let topics = list["topics"] as? [[String: Any]]
        else {
            return []
        }
        return topics.compactMap {
            listing(from: $0, siteURL: siteURL, excerpt: $0["excerpt"] as? String)
        }
    }

    /// The topic page, or the site when the ID makes no URL.
    nonisolated static func topicURL(siteURL: String, topicID: String, slug: String) -> URL {
        DiscourseRoutes.topicURL(siteURL: siteURL, topicID: topicID, slug: slug)
            ?? URL(string: siteURL) ?? URL(string: "about:blank")!
    }

    private nonisolated static func listing(
        from topic: [String: Any],
        siteURL: String,
        excerpt: String?
    ) -> ForumTopicListing? {
        guard let id = topic["id"] as? Int,
              let title = (topic["title"] as? String ?? topic["fancy_title"] as? String)
        else {
            return nil
        }
        let slug = topic["slug"] as? String ?? String(id)
        return ForumTopicListing(
            siteURL: siteURL,
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            slug: slug,
            url: Self.topicURL(siteURL: siteURL, topicID: String(id), slug: slug),
            postsCount: topic["posts_count"] as? Int ?? 0,
            lastPostedAt: topic["last_posted_at"] as? String ?? topic["bumped_at"] as? String,
            excerpt: excerpt,
            isPinned: topic["pinned"] as? Bool,
            likeCount: topic["like_count"] as? Int,
            hasAcceptedAnswer: topic["has_accepted_answer"] as? Bool
        )
    }

    nonisolated static func postCount(from json: [String: Any]) throws -> Int {
        let postsCount = json["posts_count"] as? Int
        let highestPostNumber = json["highest_post_number"] as? Int
        let streamCount = (
            (json["post_stream"] as? [String: Any])?["stream"] as? [Any]
        )?.count
        let candidates = [postsCount, highestPostNumber, streamCount].compactMap { $0 }
        guard let totalPosts = candidates.max(), totalPosts > 0 else {
            throw AssistantError.invalidResponse
        }
        return totalPosts
    }
}

/// Plain text from Discourse's cooked HTML: block ends become line breaks,
/// tags are dropped and common entities decoded. Image captions (lightbox
/// file name and size) are left out.
enum DiscourseHTML {
    nonisolated static func plainText(_ html: String) -> String {
        var text = html
        let replacements: [(String, String)] = [
            (#"(?is)<div class="meta">.*?</div>"#, ""),
            (#"(?is)<(script|style)[^>]*>.*?</\1>"#, ""),
            (#"(?i)<br\s*/?>"#, "\n"),
            (#"(?i)<li[^>]*>"#, "\n- "),
            (#"(?i)</(p|div|pre|blockquote|aside|h[1-6]|ul|ol|li|tr|table)>"#, "\n"),
            (#"(?s)<[^>]+>"#, "")
        ]
        for (pattern, template) in replacements {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        text = HTMLText.decodeEntities(text)
        // Trailing spaces go and blank-line runs collapse; leading spaces
        // stay (code indentation).
        text = text.replacingOccurrences(of: #"(?m)[ \t]+$"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
