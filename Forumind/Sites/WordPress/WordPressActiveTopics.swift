import Foundation

/// The digest's candidates on a WordPress site: posts readers are commenting
/// on right now, then the newest posts. At most `budget` requests:
/// 1. the newest posts, 2. the recent comments (grouped by post, most active
/// first), 3. the titles of commented posts the newest ones did not include.
struct WordPressActiveTopics: ActiveTopicsSource {
    static let newestPosts = 15
    static let recentComments = 50

    func activeTopics(siteURL: String, budget: Int, net: SiteNetwork) async -> ActiveTopicsResult {
        let api = WordPressAPI(net: net)
        var result = ActiveTopicsResult(topics: nil, requests: 0, failures: 0)
        guard budget > 0 else { return result }

        // 1. The newest posts.
        var newest: [ForumTopicListing] = []
        var succeeded = false
        result.requests += 1
        do {
            newest = try await api.listings(query: [
                URLQueryItem(name: "per_page", value: String(Self.newestPosts)),
                URLQueryItem(name: "orderby", value: "date"),
                URLQueryItem(name: "order", value: "desc"),
                URLQueryItem(name: "_fields", value: WordPressAPI.listFields)
            ])
            succeeded = true
        } catch {
            if Task.isCancelled { return result }
            result.failures += 1
        }

        // 2. Recent comments, grouped by post.
        var commented: [Int] = []
        if result.requests < budget {
            result.requests += 1
            do {
                let comments = try await api.jsonList("/comments", [
                    URLQueryItem(name: "per_page", value: String(Self.recentComments)),
                    URLQueryItem(name: "orderby", value: "date_gmt"),
                    URLQueryItem(name: "order", value: "desc"),
                    URLQueryItem(name: "_fields", value: "id,post,date_gmt")
                ])
                commented = Self.postsByActivity(comments)
                succeeded = true
            } catch AssistantError.http(let status, _) where [401, 403, 404].contains(status) {
                // Closed comments are no activity, not a failure.
                succeeded = true
            } catch {
                if Task.isCancelled { return result }
                result.failures += 1
            }
        }

        // 3. Titles of commented posts the newest list lacks.
        var known = Dictionary(newest.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = commented.filter { known[$0] == nil }.prefix(Self.newestPosts)
        if !missing.isEmpty, result.requests < budget {
            result.requests += 1
            do {
                let titled = try await api.listings(query: [
                    URLQueryItem(name: "include", value: missing.map(String.init).joined(separator: ",")),
                    URLQueryItem(name: "per_page", value: String(missing.count)),
                    URLQueryItem(name: "_fields", value: WordPressAPI.listFields)
                ])
                for listing in titled { known[listing.id] = listing }
            } catch {
                if Task.isCancelled { return result }
                result.failures += 1
            }
        }

        guard succeeded else { return result }
        // Commented posts first (a post whose title is unknown is skipped, never
        // shown as "Post 123"), then the newest posts not listed yet.
        var ordered: [ForumTopicListing] = commented.compactMap { known[$0] }
        let listed = Set(ordered.map(\.id))
        ordered += newest.filter { !listed.contains($0.id) }
        result.topics = ordered
        return result
    }

    /// Post ids by number of recent comments, then by how recent the latest one
    /// is (the list is newest first, so the first sighting decides).
    static func postsByActivity(_ comments: [Any]) -> [Int] {
        var counts: [Int: Int] = [:]
        var firstSeen: [Int: Int] = [:]
        for (index, entry) in comments.enumerated() {
            guard let post = (entry as? [String: Any])?["post"] as? Int, post > 0 else { continue }
            counts[post, default: 0] += 1
            if firstSeen[post] == nil { firstSeen[post] = index }
        }
        return counts.keys.sorted {
            counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : firstSeen[$0]! < firstSeen[$1]!
        }
    }
}
