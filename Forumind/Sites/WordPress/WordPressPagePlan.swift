import Foundation

/// Which pages of a post to fetch. Page 1 (the article and the first comments)
/// is always read fresh, because it holds the article's revision. Comment
/// pages that were full when cached never gain comments and are reused; the
/// page the previous read ended on, every page after it and every missing one
/// are fetched. Fewer comments than before (deletions) or an unknown previous
/// count: all pages again. Unchanged: same count, same article revision and
/// every page cached.
enum WordPressPagePlan {
    /// `knownTotalPosts` counts the article plus its comments.
    static func make(
        cachedPages: [RawForumPage],
        knownTotalPosts: Int?,
        currentComments: Int,
        articleRevision: String,
        totalPages: Int
    ) -> TopicPagePlan {
        let allPages = Array(1...max(1, totalPages))
        let cached = Dictionary(cachedPages.map { ($0.page, $0) }, uniquingKeysWith: { _, newest in newest })
        let knownComments = knownTotalPosts.flatMap { $0 >= 1 ? $0 - 1 : nil }

        let sameRevision = cached[1]?.revision == articleRevision
        if knownComments == currentComments, sameRevision, allPages.allSatisfy({ cached[$0] != nil }) {
            return .unchanged
        }
        // Pages before the one the known comments end on were full.
        let firstPageWithNewComments = knownComments.flatMap { known in
            known <= currentComments ? known / WordPressAPI.commentsPerPage + 1 : nil
        } ?? 1
        let reusable = allPages
            .filter { $0 >= 2 && $0 < firstPageWithNewComments }
            .compactMap { cached[$0] }
        let reused = Set(reusable.map(\.page))
        return .fetch(reusablePages: reusable, pageNumbers: allPages.filter { !reused.contains($0) })
    }
}
