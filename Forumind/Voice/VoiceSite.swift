import Foundation

/// The words of a site in the voice agent's prompt and tool texts (model-facing
/// English, not localized). `SiteAdapter.voice`.
struct VoiceSiteProfile: Sendable, Equatable {
    /// Completes "You are the voice of Forumind, …": "a reading companion for Discourse forums".
    var persona: String
    /// The `find` tool's rule on search words (the whole sentence).
    var findHint: String
    /// The language rule's sentence on searching in the forum's language.
    var languageHint: String

    /// A site-neutral voice, for a session that starts where no site is known
    /// once more than one platform exists (`SiteRegistry.voiceFallback`).
    static let neutral = VoiceSiteProfile(
        persona: "a reading companion for online forums and discussion sites",
        findHint: "Search matches words, so search a forum in its own language even when the user speaks another language.",
        languageHint: "Search matches words, so a question in another language is searched with words in the forum's language."
    )
}

/// What one voice session fixes when it connects (Gemini Live takes its tool
/// declarations once): the site's words and the focus modes its pages support.
/// Built from the adapter of the page the session starts on; the session is
/// not reconnected when the reader moves on, so a later page without a mode
/// answers `.unavailable` from its own data.
struct VoiceSite: Sendable, Equatable {
    static let allFocusModes = ["user", "op", "top", "posts", "clear"]
    /// Modes a site without `topicFilters` cannot narrow a topic to.
    static let authorFocusModes: Set<String> = ["user", "op"]

    var profile: VoiceSiteProfile
    /// `focus.mode` options, in declaration order.
    var focusModes: [String]

    init(profile: VoiceSiteProfile, topicFilters: Bool) {
        self.profile = profile
        focusModes = Self.allFocusModes.filter { topicFilters || !Self.authorFocusModes.contains($0) }
    }

    init(adapter: any SiteAdapter) {
        self.init(profile: adapter.voice, topicFilters: adapter.capabilities.topicFilters != nil)
    }

    var offersAuthorFocus: Bool { focusModes.contains("user") }
}

extension SiteRegistry {
    /// The voice setup of a session that starts on a site of `kind`; the
    /// fallback when the kind is unknown or has no adapter (a session can start
    /// from Home with no forum).
    func voiceSite(for kind: SiteKind?) -> VoiceSite {
        kind.flatMap(adapter(for:)).map(VoiceSite.init(adapter:)) ?? voiceFallback
    }

    /// In P0 the first adapter's phrases with the union of all adapters'
    /// options, which is that adapter alone while Discourse is the only one.
    /// TODO(P1): with a second adapter this must be `VoiceSiteProfile.neutral`
    /// (VoiceSiteTests.testTheFallbackIsNeutralOnceTwoAdaptersAreRegistered).
    var voiceFallback: VoiceSite {
        guard let first = adapters.first else { return VoiceSite(profile: .neutral, topicFilters: false) }
        return VoiceSite(profile: first.voice, topicFilters: adapters.contains { $0.capabilities.topicFilters != nil })
    }
}
