import Foundation

/// Which pages of a topic to fetch. A page that was full when it was
/// fetched never changes (replies are appended), so it is reused; the last,
/// growing page and every missing one (a read cut short, pages dropped to
/// save space) are fetched. Fewer posts than before (deleted replies): all
/// pages again.
enum DiscoursePagePlan {
    /// `knownTotalPosts`: the session's post count, for pages saved without
    /// their own.
    static func make(
        cachedPages: [RawForumPage],
        knownTotalPosts: Int?,
        currentTotalPosts: Int,
        totalPages: Int
    ) -> TopicPagePlan {
        let allPages = Array(1...max(1, totalPages))
        let normalized = Dictionary(
            cachedPages.map { ($0.page, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        let fetchedAt = { (page: RawForumPage) in page.topicPostCount ?? knownTotalPosts }
        // Replies were deleted since a page was fetched: nothing lines up.
        if normalized.values.contains(where: { (fetchedAt($0) ?? 0) > currentTotalPosts }) {
            return .fetch(reusablePages: [], pageNumbers: allPages)
        }
        // Full when fetched (it never changes), or fetched at today's count.
        let reusable = normalized.values
            .filter { page in
                guard page.page <= totalPages, let count = fetchedAt(page) else { return false }
                return page.page * RawForumPage.size <= count || count == currentTotalPosts
            }
            .sorted { $0.page < $1.page }
        let reused = Set(reusable.map(\.page))
        let missing = allPages.filter { !reused.contains($0) }
        return missing.isEmpty ? .unchanged : .fetch(reusablePages: reusable, pageNumbers: missing)
    }
}

