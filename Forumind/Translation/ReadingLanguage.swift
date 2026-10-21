import Foundation
import NaturalLanguage

// MARK: - Reading language (C3)
//
// Summaries, agent answers, digest cards and the posts on screen can be
// translated on the device with Apple's Translation framework (iOS 18+;
// TranslationViews.swift). The target is the reading language in Settings
// (`AppSettings.readingLanguage`; empty means the app's language). A
// Translate button only shows when the text is not already in that
// language, detected with NaturalLanguage. The daily podcast's script is
// written in the reading language too.

enum ReadingLanguage {
    /// Offered in Settings besides "the app's language". Languages the
    /// Translation framework supports; the names come from the system.
    static let choices = [
        "en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "it", "pt-BR",
        "ru", "uk", "pl", "nl", "tr", "ar", "hi", "id", "th", "vi"
    ]

    /// The setting resolved to a language code ("" → the app's language).
    static func resolved(_ setting: String, appLanguage: String = AppLanguage.current) -> String {
        let trimmed = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? appLanguage : trimmed
    }

    /// The language's name in the interface language ("Japanese", "日语").
    static func displayName(_ code: String, interfaceLanguage: String = AppLanguage.current) -> String {
        let locale = Locale(identifier: interfaceLanguage)
        let name = locale.localizedString(forIdentifier: code) ?? code
        return name.prefix(1).uppercased(with: locale) + name.dropFirst()
    }

    /// Whether the system can translate at all (the button's first gate).
    static var isTranslationAvailable: Bool {
        if #available(iOS 18, *) { return true }
        return false
    }

    /// The text's dominant language ("en", "zh-Hans", "ja"), or nil when
    /// NaturalLanguage isn't confident (short or mixed text).
    static func detect(_ text: String) -> String? {
        let sample = String(text.prefix(2_000))
        guard sample.contains(where: { $0.isLetter }) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage, language != .undetermined,
              let confidence = recognizer.languageHypotheses(withMaximum: 1)[language],
              confidence >= 0.5
        else {
            return nil
        }
        return language.rawValue
    }

    /// Same language and, when either side implies one, the same script:
    /// "en" = "en-GB", "pt" = "pt-BR", "zh-Hans" ≠ "zh-Hant" = "zh-TW".
    static func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        let left = Locale.Language(identifier: lhs)
        let right = Locale.Language(identifier: rhs)
        guard let leftCode = left.languageCode, let rightCode = right.languageCode,
              leftCode == rightCode
        else {
            return false
        }
        let leftScript = Locale.Language(identifier: left.maximalIdentifier).script
        let rightScript = Locale.Language(identifier: right.maximalIdentifier).script
        guard let leftScript, let rightScript else { return true }
        return leftScript == rightScript
    }

    /// Show a Translate button: translation exists here, the text has
    /// words, and it isn't already in the reading language. Text whose
    /// language can't be told gets the button (the system detects it).
    static func offersTranslation(
        of text: String,
        into readingLanguage: String,
        isAvailable: Bool = isTranslationAvailable
    ) -> Bool {
        guard isAvailable, text.contains(where: { $0.isLetter }) else { return false }
        guard let source = detect(text) else { return true }
        return !sameLanguage(source, readingLanguage)
    }
}

extension ReadingLanguage {
    /// The posts worth translating: those not already in the reading
    /// language (Translate Posts on Screen leaves the others out).
    static func needingTranslation(_ sources: [TranslationSource], into readingLanguage: String) -> [TranslationSource] {
        sources.filter { offersTranslation(of: $0.text, into: readingLanguage, isAvailable: true) }
    }
}

// MARK: - Markdown in, Markdown out

/// Splits Markdown into the pieces worth translating, so the result keeps
/// its headings, lists, quotes, tables and code: markers and code stay as
/// they are, and each line's text is translated on its own.
enum TranslationText {
    struct Segment: Equatable {
        /// Kept as is (list marker, "## ", "> ", a table pipe, code).
        var prefix: String
        /// Translated; empty for lines that are kept whole.
        var text: String
        var suffix = ""
        /// A table cell after the first: continues the previous line.
        var continuesLine = false
    }

    static func segments(of markdown: String) -> [Segment] {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var result: [Segment] = []
        var inCode = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inCode.toggle()
                result.append(Segment(prefix: line, text: ""))
                continue
            }
            if inCode || trimmed.isEmpty || isRule(trimmed) || isTableSeparator(trimmed) {
                result.append(Segment(prefix: line, text: ""))
                continue
            }
            if trimmed.hasPrefix("|") {
                result += tableSegments(line)
                continue
            }
            let marker = blockMarker(of: line)
            let rest = String(line.dropFirst(marker.count))
            result.append(rest.contains(where: { $0.isLetter })
                ? Segment(prefix: marker, text: rest)
                : Segment(prefix: line, text: ""))
        }
        return result
    }

    /// The segments' texts to send (one request each), with their index.
    static func requests(_ segments: [Segment]) -> [(index: Int, text: String)] {
        segments.enumerated().compactMap { index, segment in
            segment.text.isEmpty ? nil : (index, segment.text)
        }
    }

    /// Puts translations (by segment index) back; missing ones keep the
    /// original.
    static func assemble(_ segments: [Segment], translations: [Int: String]) -> String {
        var lines: [String] = []
        for (index, segment) in segments.enumerated() {
            let text = segment.text.isEmpty ? "" : (translations[index] ?? segment.text)
            let piece = segment.prefix + text.replacingOccurrences(of: "\n", with: " ") + segment.suffix
            if segment.continuesLine, let last = lines.popLast() {
                lines.append(last + piece)
            } else {
                lines.append(piece)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Private

    /// "## ", "- ", "1. ", "> ", "- [ ] ", nested, with leading spaces.
    private static func blockMarker(of line: String) -> String {
        let pattern = #"^\s*(?:(?:#{1,6}|[-*+]|\d{1,3}[.)]|>)\s+(?:\[[ xX]\]\s+)?)*"#
        guard let range = line.range(of: pattern, options: .regularExpression) else { return "" }
        return String(line[range])
    }

    private static func isRule(_ trimmed: String) -> Bool {
        trimmed.count >= 3 && Set(trimmed.replacingOccurrences(of: " ", with: "")).count == 1
            && ["-", "*", "_"].contains(trimmed.first.map(String.init) ?? "")
    }

    private static func isTableSeparator(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("|") && trimmed.allSatisfy { "|-: ".contains($0) }
    }

    /// One segment per cell: `| a | b |` → "| " a " |", then " " b " |"
    /// continuing the line.
    private static func tableSegments(_ line: String) -> [Segment] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let leading = cells.removeFirst()
        if cells.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { cells.removeLast() }
        guard !cells.isEmpty else { return [Segment(prefix: line, text: "")] }
        return cells.enumerated().map { index, cell in
            let text = cell.trimmingCharacters(in: .whitespaces)
            let start = index == 0 ? "\(leading)| " : " "
            let translatable = text.contains(where: { $0.isLetter })
            return Segment(
                prefix: translatable ? start : start + text,
                text: translatable ? text : "",
                suffix: " |",
                continuesLine: index > 0
            )
        }
    }
}
