import Foundation
@testable import Forumind

/// A made-up platform that proves the layers need no kind branches: topics
/// at `/topic/{id}`, posts at `#p{n}`, one site tool (`search_comments`, no
/// `list_latest`) and every optional capability nil (unless a test sets one). It makes no requests.
struct FakeSiteAdapter: SiteAdapter {
    static let kind = SiteKind("fake")
    /// The article revision the fake stamps on its page.
    static let revision = "2026-10-20T12:00:00"
    /// Two posts in the shared raw shape, as one page.
    static let pageContent = """
    alice | 2026-10-20 12:00:00 UTC | #1
    Opening post of the fake topic.


    bob | 2026-10-20 12:05:00 UTC | #2
    A reply.

    """

    /// Candidates for the digest; nil like the other optional capabilities.
    var activeTopics: (any ActiveTopicsSource)?

    /// The generator meta its recognizer accepts.
    var generator = "FakeCMS"
    /// A host its recognizer claims whatever the path.
    var claimedHost: String?
    /// The page scripts the fake offers; nil like the other optional capabilities.
    var pageBridge: PageBridgeProfile?
    /// What a site query returns; nil: the query is unsupported.
    var queryResult: SiteQueryResult?
    /// When set, a read waits here until the test releases it.
    var readGate: ReadGate?
    /// Every query `run` received, in order.
    var queryLog = QueryLog()

    var kind: SiteKind { Self.kind }
    var recognizer: any SiteRecognizer { FakeRecognizer(generator: generator, claimedHost: claimedHost) }
    var links: any SiteLinks { FakeLinks() }

    var capabilities: SiteCapabilities {
        SiteCapabilities(
            activeTopics: activeTopics,
            postLookup: nil,
            topicFilters: nil,
            pageBridge: pageBridge,
            loginURL: nil,
            searchPageURL: nil,
            session: nil,
            firstPartyPathPatterns: []
        )
    }

    var suggestedForums: SuggestedForums {
        #if DEBUG
        SuggestedForums(general: [], chinese: [], sample: [])
        #else
        SuggestedForums(general: [], chinese: [])
        #endif
    }

    var agent: AgentSiteProfile {
        AgentSiteProfile(
            siteDescription: "a fake site",
            siteNoun: "site",
            topicNoun: "thread",
            postNumbering: "Posts are numbered. Cite a specific post as the thread url plus #pN.",
            postCitation: "When a point comes from a specific post, cite it as [title](url#pN).",
            siteTools: [
                AgentToolSpec(
                    name: AgentToolName.searchComments.rawValue,
                    description: "Search the comments of this site.",
                    parameters: [
                        .init(name: "query", description: "Search text", required: true),
                        .init(name: "category", description: "Category name", required: false),
                        .init(name: "after", description: "YYYY-MM-DD", required: false),
                        .init(name: "before", description: "YYYY-MM-DD", required: false),
                        .init(name: "page", description: "1 to 3", required: false)
                    ]
                )
            ],
            query: { tool, arguments in
                guard tool == .searchComments else { throw SiteQueryError.unsupported }
                guard let text = arguments["query"], !text.isEmpty else { throw AgentError.missingArgument("query") }
                return .search(text: text, scope: .comments, options: try SearchOptions(arguments: arguments))
            },
            postLinkHint: { "(post N: \($0.absoluteString)#pN)" }
        )
    }

    var discussion: DiscussionProfile {
        DiscussionProfile(
            openingHeading: "Fake opener",
            material: "a fake site thread",
            blocks: "#1 is the first fake entry; later numbers are fake answers.",
            signals: "There are no signals on a fake site."
        )
    }

    var voice: VoiceSiteProfile {
        VoiceSiteProfile(
            persona: "a reading companion for fake sites",
            findHint: "Fake search matches whole sentences.",
            languageHint: "Fake search matches whole sentences, so ask it in the site's language."
        )
    }

    func siteURLCandidates(fromAddress address: String) -> [String] {
        address.hasPrefix("fake.") ? ["https://\(address)"] : []
    }

    func siteInfo(siteURL: String, net: SiteNetwork) async throws -> ForumSiteInfo {
        ForumSiteInfo(name: "Fake Site", iconURL: nil)
    }

    func overview(_ topic: TopicRef, net: SiteNetwork) async throws -> ForumTopicOverview {
        ForumTopicOverview(siteURL: topic.siteURL, topicID: topic.topicID, title: "Fake topic", slug: topic.topicID,
            url: FakeLinks().topicURL(siteURL: topic.siteURL, topicID: topic.topicID, slug: nil)!, postCount: 2, facts: nil)
    }

    func readTopic(
        _ request: TopicReadRequest,
        net: SiteNetwork,
        progress: @escaping @Sendable (ForumFetchProgress) async -> Void,
        onPage: (@Sendable (RawForumPage) async -> Void)?
    ) async throws -> ForumFetchResult {
        await readGate?.wait()
        // The cache hint is honoured the way an append-only platform would.
        if !request.cachedPages.isEmpty, request.knownTotalPosts == 2 {
            return ForumFetchResult(
                content: request.cachedPages.map(\.content).joined(separator: "\n\n\n"),
                rawPages: request.cachedPages,
                totalPosts: 2,
                unchanged: true,
                newPosts: 0,
                facts: nil
            )
        }
        let day = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 10, day: 20)
        func time(_ hour: Int, _ minute: Int) -> Date? {
            var parts = day
            parts.hour = hour
            parts.minute = minute
            return parts.date
        }
        let page = RawForumPage(
            page: 1,
            content: Self.pageContent,
            topicPostCount: 2,
            blocks: [
                PostBlock(number: 1, author: "alice", date: time(12, 0), anchor: "comment-1", score: nil),
                PostBlock(number: 2, author: "bob", date: time(12, 5), anchor: "comment-2", score: nil)
            ],
            revision: Self.revision
        )
        await onPage?(page)
        await progress(ForumFetchProgress(completedPages: 1, totalPages: 1, totalPosts: 2, message: "Read"))
        return ForumFetchResult(
            content: page.content,
            rawPages: [page],
            totalPosts: 2,
            unchanged: false,
            newPosts: 2,
            facts: nil
        )
    }

    func run(_ query: SiteQuery, net: SiteNetwork) async throws -> SiteQueryResult {
        queryLog.append(query)
        guard let queryResult else { throw SiteQueryError.unsupported }
        return queryResult
    }
}

/// The queries a fake adapter ran (a struct adapter cannot record them itself).
final class QueryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [SiteQuery] = []

    var all: [SiteQuery] {
        lock.lock()
        defer { lock.unlock() }
        return queries
    }

    func append(_ query: SiteQuery) {
        lock.lock()
        queries.append(query)
        lock.unlock()
    }
}

/// Holds a fake read mid-flight: `wait()` parks until `release()`; `hasWaiter`
/// tells the test the read has started.
final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private var entered = false

    var hasWaiter: Bool {
        lock.lock()
        defer { lock.unlock() }
        return entered
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            entered = true
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
    }
}

/// An `ActiveTopicsSource` that makes `requests` requests (none really) and
/// records the budget it was given.
final class FakeActiveTopics: ActiveTopicsSource, @unchecked Sendable {
    let requests: Int
    private let lock = NSLock()
    private var budgets: [Int] = []

    init(requests: Int) {
        self.requests = requests
    }

    var receivedBudgets: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return budgets
    }

    func activeTopics(siteURL: String, budget: Int, net: SiteNetwork) async -> ActiveTopicsResult {
        lock.lock()
        budgets.append(budget)
        lock.unlock()
        return ActiveTopicsResult(topics: [], requests: requests, failures: 0)
    }
}

struct FakeLinks: SiteLinks {
    func homeURL(siteURL: String) -> URL? { URL(string: siteURL + "/home") }

    func topicURL(siteURL: String, topicID: String, slug: String?) -> URL? {
        URL(string: "\(siteURL)/topic/\(topicID)")
    }

    func postURL(topicURL: URL, number: Int, anchor: String?) -> URL {
        URL(string: topicPageURL(topicURL).absoluteString + "#p\(number)")!
    }

    func topicPageURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        return components?.url ?? url
    }

    func parse(_ url: URL, basePath: String) -> SiteLink? {
        let path = url.path.dropFirst(basePath.count)
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "topic", Int(parts[1]) != nil else { return nil }
        let number = url.fragment.flatMap { $0.hasPrefix("p") ? Int($0.dropFirst()) : nil }
        return SiteLink(topicID: parts[1], slug: nil, postNumber: number)
    }

    func lastPostURL(topicURL: URL) -> URL? { nil }
}

extension AppSnapshot {
    /// Jobs resolve their adapter from the site's forum record, which a real
    /// session always has: harnesses that start work seed one.
    mutating func ensureForum(_ siteURL: String, kind: SiteKind = .discourse) {
        if !forums.contains(where: { $0.siteURL == siteURL }) {
            forums.append(Forum(siteURL: siteURL, kind: kind, name: "Test Forum"))
        }
    }
}

/// Accepts pages whose generator meta equals `generator`; topics live at `/topic/{id}`.
struct FakeRecognizer: SiteRecognizer {
    var generator = "FakeCMS"
    var claimedHost: String?

    var kind: SiteKind { FakeSiteAdapter.kind }
    var platformName: String { "FakeCMS" }
    var factKeys: PageFactKeys { PageFactKeys(meta: ["generator", "fake-site", "fake-topic"]) }

    func recognize(facts: PageFacts, url: URL) -> SitePageMatch? {
        guard facts.meta["generator"] == generator, let origin = ForumSite.origin(of: url)?.origin else { return nil }
        return SitePageMatch(
            siteURL: origin, basePath: "", forumName: facts.meta["fake-site"] ?? "",
            kind: kind, platformName: platformName,
            // The id may live only in the facts (a permalink without one).
            topicID: facts.meta["fake-topic"] ?? topicID(fromURL: url, basePath: "")
        )
    }

    func topicID(fromURL url: URL, basePath: String) -> String? {
        let parts = url.path.dropFirst(basePath.count).split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "topic", Int(parts[1]) != nil else { return nil }
        return parts[1]
    }

    func claimedSiteURL(forHost host: String) -> String? { host == claimedHost ? "https://\(host)" : nil }
    func looseTopicID(in url: URL) -> String? { topicID(fromURL: url, basePath: "") }
    func postNumber(in url: URL) -> Int? { nil }
}
