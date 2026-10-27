import Foundation

/// Which pages of a topic to fetch. `unchanged`: every page is already saved.
/// `fetch`: reuse the given pages and request the numbered ones. Each adapter
/// decides (Discourse: `DiscoursePagePlan`); `PagedTopicFetch` runs it.
enum TopicPagePlan: Equatable {
    case unchanged
    case fetch(reusablePages: [RawForumPage], pageNumbers: [Int])
}

/// The batched page loop shared by adapters that read a topic page by page:
/// pages are requested in order, `maximumConcurrency` at a time (the pacer
/// spaces them out), cached pages are never requested, and each page is
/// handed to `onPage` as it arrives.
enum PagedTopicFetch {
    static func run(
        plan: TopicPagePlan,
        cachedPages: [RawForumPage],
        knownTotalPosts: Int?,
        totalPosts: Int,
        totalPages: Int,
        facts: TopicFacts,
        pace: ForumRequestPace,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void,
        onPage: (@Sendable (RawForumPage) async -> Void)?,
        fetchPage: @escaping @Sendable (Int) async throws -> RawForumPage
    ) async throws -> ForumFetchResult {
        switch plan {
        case .unchanged:
            let sorted = cachedPages.sorted { $0.page < $1.page }
            await progress(
                ForumFetchProgress(
                    completedPages: totalPages,
                    totalPages: totalPages,
                    totalPosts: totalPosts,
                    message: String(localized: "Saved pages already include every reply.", comment: "Progress while reading a forum topic: nothing new to download")
                )
            )
            return ForumFetchResult(
                content: RawTopicFormat.join(sorted.map(\.content)),
                rawPages: sorted,
                totalPosts: totalPosts,
                unchanged: true,
                newPosts: 0,
                facts: facts
            )

        case .fetch(let reusablePages, let pageNumbers):
            var fetchedPages: [RawForumPage] = []
            var completed = reusablePages.count
            let batchSize = max(1, pace.maximumConcurrency)
            if let first = pageNumbers.first {
                // Reported before the (paced) wait for the first page, so the
                // status says what is happening while the bar waits.
                await progress(
                    ForumFetchProgress(
                        completedPages: completed,
                        totalPages: totalPages,
                        totalPosts: totalPosts,
                        message: String(localized: "Reading response page \(first) of \(totalPages)…", comment: "Progress while downloading a forum topic's replies, before a page arrives")
                    )
                )
            }

            for start in stride(from: 0, to: pageNumbers.count, by: batchSize) {
                try Task.checkCancellation()
                let end = min(start + batchSize, pageNumbers.count)
                let batch = Array(pageNumbers[start..<end])
                let results = try await withThrowingTaskGroup(
                    of: RawForumPage.self,
                    returning: [RawForumPage].self
                ) { group in
                    for page in batch {
                        group.addTask { try await fetchPage(page) }
                    }

                    var pages: [RawForumPage] = []
                    for try await fetched in group {
                        var page = fetched
                        page.topicPostCount = totalPosts
                        pages.append(page)
                        // Kept by the caller as it arrives: a read that fails,
                        // is paused or killed later does not fetch it again.
                        await onPage?(page)
                        completed += 1
                        await progress(
                            ForumFetchProgress(
                                completedPages: completed,
                                totalPages: totalPages,
                                totalPosts: totalPosts,
                                message: String(localized: "Read response page \(page.page) of \(totalPages)", comment: "Progress while downloading a forum topic's replies, page by page")
                            )
                        )
                    }
                    return pages
                }
                fetchedPages.append(contentsOf: results)
            }

            let allPages = (reusablePages + fetchedPages).sorted { $0.page < $1.page }
            return ForumFetchResult(
                content: RawTopicFormat.join(allPages.map(\.content)),
                rawPages: allPages,
                totalPosts: totalPosts,
                unchanged: false,
                newPosts: max(0, totalPosts - (knownTotalPosts ?? 0)),
                facts: facts
            )
        }
    }
}
