import Foundation

/// The language the app's interface is running in: English (the development
/// language), Simplified Chinese, or Traditional Chinese. iOS picks it from
/// Settings › Forumind › Language (or the device languages); the app can't
/// change it itself.
///
/// This follows the bundle's resolved localization, not `Locale.current`:
/// the region format (`-AppleLocale`, Settings › General › Language & Region)
/// can differ from the language the interface is shown in.
enum AppLanguage {
    /// The resolved localization: "en", "zh-Hans", or "zh-Hant".
    static var current: String {
        Bundle.main.preferredLocalizations.first ?? "en"
    }

    static var isChinese: Bool { current.hasPrefix("zh") }
    static var isSimplifiedChinese: Bool { current == "zh-Hans" }
    static var isTraditionalChinese: Bool { current == "zh-Hant" }

    /// The language's English name, for AI prompts ("Simplified Chinese").
    static var englishName: String {
        switch current {
        case "en": "English"
        case "zh-Hans": "Simplified Chinese"
        case "zh-Hant": "Traditional Chinese"
        default: Locale(identifier: "en").localizedString(forIdentifier: current) ?? current
        }
    }

    /// The language's name in the interface language ("English", "简体中文").
    static var displayName: String {
        let locale = Locale(identifier: current)
        let name = locale.localizedString(forIdentifier: current) ?? current
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }
}
