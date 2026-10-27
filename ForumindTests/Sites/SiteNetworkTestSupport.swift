import Foundation
@testable import Forumind

extension ForumService {
    /// A network scoped to `siteURL` over this service, as a job builds it.
    func net(
        _ siteURL: String,
        cookieHeader: String? = nil,
        resourceLoader: (@MainActor @Sendable (URL) async throws -> ForumResourceResponse)? = nil,
        pace: ForumRequestPace = .default
    ) -> SiteNetwork {
        SiteNetwork(
            service: self,
            siteURL: siteURL,
            context: SiteRequestContext(cookieHeader: cookieHeader, resourceLoader: resourceLoader, pace: pace)
        )
    }
}
