import Foundation
@testable import Forumind

extension PageFacts {
    /// What the probe reports on a Discourse page: the generator meta, the
    /// setup element with the base path, and the site name.
    static func discourse(_ url: URL, basePath: String = "", forumName: String = "", iconURL: URL? = nil) -> PageFacts {
        var meta = ["generator": "Discourse 3.4.0.beta1"]
        if !forumName.isEmpty { meta["og:site_name"] = forumName }
        return PageFacts(
            url: url,
            meta: meta,
            elements: ["data-discourse-setup": basePath.isEmpty ? [:] : ["baseUri": basePath]],
            iconURL: iconURL
        )
    }
}

extension ForumTopic {
    /// `parse` with the Discourse recognizer, for tests of Discourse URLs.
    static func parse(url: URL?, title: String?, basePath: String = "", forumName: String? = nil) -> ForumTopic? {
        parse(url: url, title: title, basePath: basePath, forumName: forumName, recognizer: DiscourseRecognizer())
    }
}
