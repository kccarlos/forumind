import Foundation

/// Turns the HTML a site's API returns (WordPress posts and comments) into
/// the plain text the models read. A small tag stripper, no DOM: block tags
/// become line breaks, list items bullets, quotes "> " lines, links
/// "text (url)" and images "[image: alt]". Entities are decoded once, last.
nonisolated enum HTMLText {
    // MARK: Entities

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "hellip": "…", "laquo": "«", "raquo": "»", "copy": "©", "reg": "®", "trade": "™",
        "deg": "°", "euro": "€", "pound": "£", "cent": "¢", "times": "×", "bull": "•"
    ]

    private static let entity = regex(#"&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]*);"#)

    /// Decodes named and numeric entities (`&amp;`, `&#038;`, `&#x2019;`) once.
    /// Unknown names and invalid code points stay as written.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return replace(entity, in: text) { match, source in
            let body = source.substring(with: match.range(at: 1))
            if body.hasPrefix("#") {
                let digits = body.dropFirst()
                let code = digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16)
                    : UInt32(digits, radix: 10)
                guard let code, code > 0, let scalar = Unicode.Scalar(code) else {
                    return source.substring(with: match.range)
                }
                return String(Character(scalar))
            }
            return namedEntities[body.lowercased()] ?? source.substring(with: match.range)
        }
    }

    // MARK: HTML

    private static let comment = regex(#"<!--[\s\S]*?-->"#)
    private static let hiddenElements = regex(#"<(script|style|noscript|template)\b[\s\S]*?</\1\s*>"#)
    private static let anchor = regex(#"<a\b[^>]*>([\s\S]*?)</a\s*>"#)
    private static let image = regex(#"<img\b[^>]*>"#)
    private static let lineBreak = regex(#"<br\s*/?>"#)
    private static let listItem = regex(#"<li\b[^>]*>"#)
    private static let blockquote = regex(#"<blockquote\b[^>]*>([\s\S]*?)</blockquote\s*>"#)
    private static let blockClose = regex(#"</(p|div|h[1-6]|ul|ol|table|tr|pre|figure|section|article)\s*>"#)
    private static let blockOpen = regex(#"<(p|div|h[1-6]|ul|ol|table|tr|pre|figure|section|article)\b[^>]*>"#)
    private static let cellClose = regex(#"</(td|th)\s*>"#)
    private static let anyTag = regex(#"<[^>]*>"#)
    private static let spaces = regex(#"[\t\f\x{0B}\x{A0} ]+"#)
    private static let aroundNewline = regex(#" ?\n ?"#)
    private static let blankRuns = regex(#"\n{3,}"#)
    private static let httpURL = regex(#"^https?://"#)

    /// Plain text of an HTML fragment. Blank-line runs are capped at one
    /// blank line, so the output never contains `"\n\n\n"`.
    static func plainText(_ html: String) -> String {
        tidy(decodeEntities(convert(html)))
    }

    // Tags become text structure; entities stay encoded so a literal "<"
    // (as "&lt;") is never mistaken for a tag by a later pass.
    private static func convert(_ html: String) -> String {
        var text = replace(comment, in: html, with: "")
        text = replace(hiddenElements, in: text, with: "")
        text = replace(anchor, in: text) { match, source in
            let whole = source.substring(with: match.range)
            let inner = source.substring(with: match.range(at: 1))
            let openTag = whole.firstIndex(of: ">").map { String(whole[...$0]) } ?? whole
            let href = attribute(openTag, "href")
            let label = replace(anyTag, in: inner, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard httpURL.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)) != nil,
                  !label.isEmpty, decodeEntities(label) != href
            else { return inner }
            return "\(inner) (\(href))"
        }
        text = replace(image, in: text) { match, source in
            let alt = attribute(source.substring(with: match.range), "alt")
            return alt.isEmpty ? "[image]" : "[image: \(alt)]"
        }
        text = replace(lineBreak, in: text, with: "\n")
        text = replace(listItem, in: text, with: "\n- ")
        text = replace(blockquote, in: text) { match, source in
            let inner = convert(source.substring(with: match.range(at: 1)))
            let quoted = tidy(replace(anyTag, in: inner, with: ""))
                .components(separatedBy: "\n")
                .map { $0.isEmpty ? ">" : "> \($0)" }
                .joined(separator: "\n")
            return "\n\n\(quoted)\n\n"
        }
        text = replace(blockClose, in: text, with: "\n\n")
        text = replace(blockOpen, in: text, with: "\n\n")
        text = replace(cellClose, in: text, with: " | ")
        return replace(anyTag, in: text, with: "")
    }

    private static func tidy(_ text: String) -> String {
        var text = replace(spaces, in: text, with: " ")
        text = replace(aroundNewline, in: text, with: "\n")
        text = replace(blankRuns, in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func attribute(_ tag: String, _ name: String) -> String {
        guard let pattern = try? NSRegularExpression(
            pattern: #"\s"# + name + #"\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))"#, options: .caseInsensitive),
              let match = pattern.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag))
        else { return "" }
        let source = tag as NSString
        for group in 2...4 where match.range(at: group).location != NSNotFound {
            return decodeEntities(source.substring(with: match.range(at: group)))
        }
        return ""
    }

    // MARK: Regex plumbing

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are literals in this file; a bad one is a programming error.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: .caseInsensitive)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        replace(regex, in: text) { _, _ in template }
    }

    private static func replace(
        _ regex: NSRegularExpression, in text: String,
        using transform: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += transform(match, source)
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }
}
