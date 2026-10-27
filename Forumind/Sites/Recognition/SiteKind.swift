import Foundation

/// A platform Forumind can read. Stable id: stored on `Forum` and synced, never renamed.
/// A struct, not an enum: nothing switches exhaustively over kinds, so a new
/// platform adds a value, not a case to every switch. Only `Forumind/Sites/`
/// may name a concrete kind (scripts/ci/check-site-layering.sh).
struct SiteKind: Hashable, Codable, Sendable, CustomStringConvertible {
    let id: String

    init(_ id: String) { self.id = id }

    init(from decoder: Decoder) throws {
        id = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }

    /// A placeholder for a site no directory forum or recognized page backs (display only):
    /// no adapter has this kind, so no job runs on it.
    static let unknown = SiteKind("unknown")

    var description: String { id }
}
