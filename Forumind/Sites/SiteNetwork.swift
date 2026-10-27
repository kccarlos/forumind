import Foundation

/// What a job needs to make requests to one site: the forum's cookies, the
/// in-page loader and the pace the job started with. Gathered once per job
/// (the cookie, loader and pace triple that was repeated at every call site).
struct SiteRequestContext: Sendable {
    var cookieHeader: String?
    var resourceLoader: (@MainActor @Sendable (URL) async throws -> ForumResourceResponse)?
    var pace: ForumRequestPace

    init(
        cookieHeader: String? = nil,
        resourceLoader: (@MainActor @Sendable (URL) async throws -> ForumResourceResponse)? = nil,
        pace: ForumRequestPace = .default
    ) {
        self.cookieHeader = cookieHeader
        self.resourceLoader = resourceLoader
        self.pace = pace
    }
}

enum SiteNetworkError: Error, Equatable {
    /// The URL is not on the site this network is scoped to.
    case outsideSite(URL)
}

/// What an adapter gets: the shared transport and a context, scoped to one
/// site. Adapters only build URLs and parse; pacing, retries, the in-page
/// loader and redirect guarding stay in `ForumService`.
struct SiteNetwork: Sendable {
    let service: ForumService
    let siteURL: String
    let context: SiteRequestContext

    /// One paced, retried GET through `ForumService`. Refuses a URL outside the site.
    func data(_ url: URL, accept: String? = nil) async throws -> Data {
        guard ForumSite.isSameForum(url: url, siteURL: siteURL) else {
            throw SiteNetworkError.outsideSite(url)
        }
        return try await service.data(url, accept: accept, context: context)
    }

    /// `data` decoded as a JSON object; `invalidResponse` when it is not one.
    func json(_ url: URL) async throws -> [String: Any] {
        let data = try await data(url)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.invalidResponse
        }
        return object
    }
}
