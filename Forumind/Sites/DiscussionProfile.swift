import Foundation

/// What a site's material is, in the summary, chunk and chat prompts
/// (model-facing English, not localized). `SiteAdapter.discussion`. Three
/// factual slots; the shared instructions around them live in `PromptBuilder`.
struct DiscussionProfile: Sendable, Equatable {
    /// The first heading of the default summary, naming the opening block
    /// ("Original post"); users see it in the summary, so it is per site.
    var openingHeading: String
    /// What the material is, completing "The material is …" (no final period).
    var material: String
    /// What `#1` and the later numbers are (a full sentence).
    var blocks: String
    /// Which extra signals exist: likes, accepted answers, none (a full sentence).
    var signals: String
}
