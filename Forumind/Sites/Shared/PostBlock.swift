import Foundation

/// One post of a topic as the adapter read it: the index of the raw text.
/// The adapter fills a page's blocks in the same call that writes its text,
/// and nothing edits either afterwards (`RawForumPage`).
struct PostBlock: Codable, Equatable, Sendable {
    /// The #N in the header. Discourse: the post number; other platforms 1…n in read order.
    var number: Int
    /// The header's author token.
    var author: String
    var date: Date?
    /// In-page and permalink anchor, opaque outside the adapter's `links`.
    /// Discourse: the post number as a string.
    var anchor: String
    /// Likes or votes when the source has them on every post (Discourse `/raw`: nil).
    var score: Int?
}
