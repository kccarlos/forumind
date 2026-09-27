import Foundation

/// The app's identifiers, all derived from one prefix.
///
/// `scripts/generate_project.rb` sets the prefix (`BUNDLE_ID_PREFIX`, default
/// `io.github.kccarlos.forumind`) as build settings, and both the app's
/// and the share extension's Info.plist expose them:
/// - `DCIdentifierPrefix`   → keychain services, background task, log subsystem
/// - `DCAppGroupIdentifier` → the App Group shared with the share extension
///
/// Compiled into the app and the share extension (`Bundle.main` is each one's
/// own bundle; both plists carry the same keys).
enum AppIdentity {
    static let defaultPrefix = "io.github.kccarlos.forumind"

    /// Reverse-DNS prefix of every identifier (the app's bundle ID).
    static let identifierPrefix: String = infoValue("DCIdentifierPrefix") ?? defaultPrefix

    /// App Group shared by the app and the share extension.
    static let appGroupIdentifier: String = infoValue("DCAppGroupIdentifier")
        ?? "group.\(identifierPrefix)"

    /// `<prefix>.<suffix>`, e.g. keychain services and the background task.
    static func identifier(_ suffix: String) -> String {
        "\(identifierPrefix).\(suffix)"
    }

    /// A plist value, ignoring unexpanded `$(…)` build-setting placeholders.
    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        return trimmed
    }
}
