import Foundation

/// The one list of platforms in a build, compiled into the share extension
/// (and the app) without the adapters, so the extension can tell a Discourse
/// page from a plain one from the same probe facts the app reads.
/// `SiteRegistry.standard` is derived from it, in the same order.
enum SiteRecognizers {
    static let standard: [any SiteRecognizer] = {
        var list: [any SiteRecognizer] = [DiscourseRecognizer(), WordPressRecognizer()]
        #if FORUMIND_LABS
        // list.append(RedditRecognizer())      // P2
        #endif
        return list
    }()

    /// The platforms' names in order, joined for a sentence ("Discourse and
    /// WordPress"; "or" for a choice): the strings that list what Forumind works
    /// with read them from here.
    static func platformNames(_ type: ListFormatStyle<StringStyle, [String]>.ListType = .and) -> String {
        standard.map(\.platformName).formatted(.list(type: type, width: .standard))
    }

    /// The keys every recognizer declares, in order: the probe collects exactly these.
    static var factKeys: PageFactKeys {
        PageFactKeys.declared(by: standard)
    }

    /// The first recognizer, in order, that accepts the page.
    static func recognize(facts: PageFacts, url: URL) -> SitePageMatch? {
        standard.lazy.compactMap { $0.recognize(facts: facts, url: url) }.first
    }
}
