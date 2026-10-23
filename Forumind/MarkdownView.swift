import SwiftUI

enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case quote(String)
    case code(language: String?, content: String)
    case table(headers: [String], rows: [[String]])
    case rule
}

struct MarkdownDocument: Equatable {
    let blocks: [MarkdownBlock]

    init(source: String) {
        blocks = MarkdownParser.parse(source)
    }
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var blocks: [MarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") {
                let language = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```")
                {
                    code.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                blocks.append(
                    .code(
                        language: language.isEmpty ? nil : language,
                        content: code.joined(separator: "\n")
                    )
                )
                continue
            }

            if let heading = heading(from: trimmed) {
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if isRule(trimmed) {
                blocks.append(.rule)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               trimmed.contains("|"),
               isTableSeparator(lines[index + 1])
            {
                let headers = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, candidate.contains("|") else { break }
                    rows.append(tableCells(candidate))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(
                        String(candidate.dropFirst()).trimmingCharacters(in: .whitespaces)
                    )
                    index += 1
                }
                blocks.append(.quote(quoteLines.joined(separator: "\n")))
                continue
            }

            if unorderedItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                      let item = unorderedItem(
                        from: lines[index].trimmingCharacters(in: .whitespaces)
                      )
                {
                    items.append(item)
                    index += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            if orderedItem(from: trimmed) != nil {
                var items: [String] = []
                while index < lines.count,
                      let item = orderedItem(
                        from: lines[index].trimmingCharacters(in: .whitespaces)
                      )
                {
                    items.append(item)
                    index += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            var paragraph: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                if candidate.isEmpty || isBlockStart(candidate, next: lines[safe: index + 1]) {
                    break
                }
                paragraph.append(candidate)
                index += 1
            }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
        }

        return blocks
    }

    private static func heading(from line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix { $0 == "#" }
        guard (1...6).contains(prefix.count),
              line.dropFirst(prefix.count).first == " "
        else {
            return nil
        }
        return (
            prefix.count,
            String(line.dropFirst(prefix.count + 1))
                .trimmingCharacters(in: .whitespaces)
        )
    }

    private static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first,
              first == "-" || first == "*" || first == "_"
        else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private static func unorderedItem(from line: String) -> String? {
        guard line.count >= 2,
              ["- ", "* ", "+ "].contains(String(line.prefix(2)))
        else {
            return nil
        }
        return String(line.dropFirst(2))
    }

    private static func orderedItem(from line: String) -> String? {
        guard let dot = line.firstIndex(of: "."),
              dot != line.startIndex,
              line.index(after: dot) < line.endIndex,
              line[line.index(after: dot)] == " ",
              line[..<dot].allSatisfy(\.isNumber)
        else {
            return nil
        }
        return String(line[line.index(dot, offsetBy: 2)...])
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line.trimmingCharacters(in: .whitespaces))
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: " ", with: "")
            return compact.count >= 3 && compact.allSatisfy { $0 == "-" }
        }
    }

    private static func isBlockStart(_ line: String, next: String?) -> Bool {
        line.hasPrefix("```")
            || heading(from: line) != nil
            || isRule(line)
            || line.hasPrefix(">")
            || unorderedItem(from: line) != nil
            || orderedItem(from: line) != nil
            || (line.contains("|") && next.map(isTableSeparator) == true)
    }
}

/// Parsed documents by source, so re-rendering the same text does not parse
/// it again (summaries and chat bubbles re-render while other text streams).
private enum MarkdownCache {
    private final class Box {
        let document: MarkdownDocument
        init(_ document: MarkdownDocument) { self.document = document }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 96
        return cache
    }()

    static func document(for source: String) -> MarkdownDocument {
        let key = source as NSString
        if let box = cache.object(forKey: key) { return box.document }
        let document = MarkdownDocument(source: source)
        cache.setObject(Box(document), forKey: key)
        return document
    }
}

/// Renders Markdown as native text blocks. While the source keeps changing
/// (streaming), it re-parses at most every `throttle` seconds and keeps
/// showing the previous parse in between, so long answers stream smoothly.
struct MarkdownView: View {
    private let source: String
    /// `[#N](forumind-post:N)` links render as post-citation chips with a
    /// 44 pt hit area (paragraphs and list items lay out word by word).
    private let citations: Bool
    @State private var rendered: Rendered?

    private struct Rendered {
        var source: String
        var document: MarkdownDocument
        var parsedAt: Date
    }

    private static let throttle: TimeInterval = 0.12

    init(_ source: String, citations: Bool = false) {
        self.source = source
        self.citations = citations
    }

    private var document: MarkdownDocument {
        if let rendered, rendered.source == source || !rendered.document.blocks.isEmpty {
            return rendered.document
        }
        return MarkdownCache.document(for: source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, citations: citations)
                    .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            await refresh()
        }
    }

    private func refresh() async {
        if let rendered {
            guard rendered.source != source else { return }
            let elapsed = Date().timeIntervalSince(rendered.parsedAt)
            if elapsed < Self.throttle {
                try? await Task.sleep(for: .seconds(Self.throttle - elapsed))
                if Task.isCancelled { return }
            }
        }
        rendered = Rendered(
            source: source,
            document: MarkdownCache.document(for: source),
            parsedAt: Date()
        )
    }
}

/// One block; Equatable so unchanged blocks skip re-rendering while the
/// document around them streams.
private struct MarkdownBlockView: View, Equatable {
    let block: MarkdownBlock
    var citations = false

    /// Inline text; with citations in it, word by word around the chips.
    @ViewBuilder
    private func inline(_ text: String) -> some View {
        if citations, text.contains("](\(PostCitations.scheme):") {
            CitedText(source: text)
        } else {
            MarkdownInline.text(text)
        }
    }

    var body: some View {
        switch block {
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 6) {
                MarkdownInline.text(text)
                    .font(headingFont(level))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 {
                    Rectangle()
                        .fill(DCTheme.border)
                        .frame(height: 1)
                }
            }
            .padding(.top, level <= 2 ? 6 : 2)
            .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            inline(text)
                .font(.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedList(let items):
            list(items: items, ordered: false)
        case .orderedList(let items):
            list(items: items, ordered: true)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(DCTheme.brandGradient)
                    .frame(width: 3)
                MarkdownInline.text(text)
                    .font(.callout)
                    .italic()
                    .lineSpacing(3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
            .padding(.trailing, 10)
            .padding(.leading, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DCTheme.brandBlue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .code(let language, let content):
            VStack(alignment: .leading, spacing: 6) {
                if let language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(content)
                        .font(.system(.callout, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DCTheme.border)
            }
        case .table(let headers, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                            MarkdownInline.text(cell)
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    Divider()
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                MarkdownInline.text(cell)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(DCTheme.border)
            }
        case .rule:
            Rectangle()
                .fill(DCTheme.border)
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func list(items: [String], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: ordered ? "\(index + 1)." : "•")
                        .font(ordered ? .body.weight(.semibold).monospacedDigit() : .body.weight(.heavy))
                        .foregroundStyle(DCTheme.brandBlue)
                        .frame(minWidth: ordered ? 20 : 12, alignment: ordered ? .trailing : .center)
                        .accessibilityHidden(!ordered)
                    inline(item)
                        .font(.body)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.bold()
        case 2: .headline
        case 3: .subheadline.bold()
        default: .subheadline.weight(.semibold)
        }
    }
}

/// Inline Markdown (bold, italic, code, links). Inline code gets a subtle
/// background; a link whose text is a source label (`S1`) renders as a chip.
enum MarkdownInline {
    private static let sourceLabel = try? NSRegularExpression(pattern: #"^S\d{1,3}$"#)

    static func text(_ source: String) -> Text {
        Text(attributed(source))
    }

    static func attributed(_ source: String) -> AttributedString {
        var value = (
            try? AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        ) ?? AttributedString(source)
        for run in value.runs {
            let range = run.range
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                value[range].font = .system(.callout, design: .monospaced)
                value[range].backgroundColor = Color.primary.opacity(0.08)
            }
            if run.link != nil {
                let label = String(value[range].characters)
                let isSource = sourceLabel?.firstMatch(
                    in: label,
                    range: NSRange(location: 0, length: (label as NSString).length)
                ) != nil
                if isSource {
                    value[range].font = .footnote.weight(.bold).monospacedDigit()
                    value[range].foregroundColor = DCTheme.agentTint
                    value[range].backgroundColor = DCTheme.agentTint.opacity(0.14)
                } else if run.link?.scheme == PostCitations.scheme {
                    // A post citation outside a paragraph (a heading).
                    value[range].font = .footnote.weight(.bold).monospacedDigit()
                    value[range].foregroundColor = DCTheme.citationText
                    value[range].backgroundColor = DCTheme.postHighlightBackground
                } else {
                    value[range].foregroundColor = DCTheme.brandBlue
                    value[range].underlineStyle = .single
                }
            }
        }
        return value
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}


// MARK: - Post citations

extension EnvironmentValues {
    /// The post the reader last jumped to: its citation chips show filled.
    @Entry var activeCitation: Int?
}

/// A paragraph with `#N` post citations, laid out word by word so each chip
/// can be a real button: about 28 pt to look at, 44 × 44 pt to tap, at least
/// 4 pt apart. VoiceOver reads the paragraph as one element, then the chips.
private struct CitedText: View {
    let source: String

    private enum Token {
        case text(AttributedString, spaceAfter: Bool)
        /// A chip and the punctuation right after it ("#37."), which never
        /// wraps onto the next line alone.
        case citation(Int, suffix: AttributedString?, spaceAfter: Bool)
    }

    var body: some View {
        let tokens = Self.tokens(source)
        CitationFlowLayout(lineSpacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .text(let text, let spaceAfter):
                    Text(text)
                        .fixedSize()
                        .layoutValue(key: TrailingSpace.self, value: spaceAfter ? 4 : 0)
                        .accessibilityHidden(true)
                case .citation(let number, let suffix, let spaceAfter):
                    HStack(spacing: 1) {
                        CitationChip(number: number)
                        if let suffix {
                            Text(suffix).fixedSize().accessibilityHidden(true)
                        }
                    }
                    .layoutValue(key: TrailingSpace.self, value: suffix == nil || spaceAfter ? 4 : 0)
                }
            }
        }
        .background {
            Color.clear
                .accessibilityElement()
                .accessibilityLabel(Text(verbatim: Self.plain(tokens)))
        }
        .accessibilityElement(children: .contain)
    }

    private static func plain(_ tokens: [Token]) -> String {
        tokens.compactMap { token -> String? in
            switch token {
            case .text(let text, let spaceAfter):
                return String(text.characters) + (spaceAfter ? " " : "")
            case .citation(_, let suffix, let spaceAfter):
                return suffix.map { String($0.characters) + (spaceAfter ? " " : "") }
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespaces)
    }

    /// Words (CJK one character each) with their styling, and the chips.
    private static func tokens(_ source: String) -> [Token] {
        let value = MarkdownInline.attributed(source.replacingOccurrences(of: "\n", with: " "))
        var tokens: [Token] = []
        let characters = value.characters
        for run in value.runs {
            if let url = run.link, let number = PostCitations.postNumber(from: url) {
                tokens.append(.citation(number, suffix: nil, spaceAfter: true))
                continue
            }
            var start = run.range.lowerBound
            var index = start
            while index < run.range.upperBound {
                let character = characters[index]
                let next = characters.index(after: index)
                let breaksAfter = character.isWhitespace || character.isWide
                    || (next < run.range.upperBound && characters[next].isWide)
                if breaksAfter {
                    append(AttributedString(value[start..<next]), to: &tokens)
                    start = next
                }
                index = next
            }
            if start < run.range.upperBound {
                append(AttributedString(value[start..<run.range.upperBound]), to: &tokens)
            }
        }
        return tokens
    }

    private static func append(_ chunk: AttributedString, to tokens: inout [Token]) {
        let text = String(chunk.characters)
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // A lone space: belongs to the word before.
            if case .text(let previous, _) = tokens.last {
                tokens[tokens.count - 1] = .text(previous, spaceAfter: true)
            }
            return
        }
        // Punctuation after a chip ("#37 ." from the model, or "#37."): glued.
        if case .citation(let number, nil, _) = tokens.last,
           trimmed.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains),
           let range = chunk.range(of: trimmed) {
            tokens[tokens.count - 1] = .citation(
                number, suffix: AttributedString(chunk[range]), spaceAfter: text.last?.isWhitespace == true
            )
            return
        }
        var word = chunk
        if text.last?.isWhitespace == true, let range = word.range(of: trimmed) {
            word = AttributedString(word[range])
            tokens.append(.text(word, spaceAfter: true))
        } else {
            tokens.append(.text(word, spaceAfter: false))
        }
    }
}

private extension Character {
    /// CJK and other scripts written without spaces: lines break anywhere.
    var isWide: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
}

/// `#37`: tap to scroll the page to post 37 (AppModel.jumpToCitation).
struct CitationChip: View {
    let number: Int
    @Environment(\.openURL) private var openURL
    @Environment(\.activeCitation) private var activeCitation

    private var isActive: Bool { activeCitation == number }

    var body: some View {
        Button {
            if let url = PostCitations.url(post: number) { openURL(url) }
        } label: {
            Text(verbatim: "#\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .foregroundStyle(isActive ? Color.white : DCTheme.citationText)
                .padding(.horizontal, 8)
                .frame(minWidth: 36, minHeight: 28)
                .background(
                    isActive ? AnyShapeStyle(DCTheme.brandBlue) : AnyShapeStyle(DCTheme.postHighlightBackground),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                // At least 44 pt wide in the line (the chip centred in it), so
                // neighbouring hit areas never overlap, and 44 pt high to tap
                // without taking more room between the lines. 46 pt: the
                // drawer's floating sheet is drawn about 4 % smaller at medium.
                .frame(minWidth: 46)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .padding(.vertical, -9)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Post \(number)", comment: "Accessibility label of a post citation in an AI summary; the placeholder is the post number"))
        .accessibilityHint(Text("Shows the post on the page", comment: "Accessibility hint of a post citation in an AI summary"))
        .accessibilityIdentifier("citation-\(number)")
    }
}

/// Space after a flowed item (a word's trailing space, a chip's gap).
private struct TrailingSpace: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Lines of words and chips, each line centred vertically.
private struct CitationFlowLayout: Layout {
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews) {
            for item in line.items {
                let size = subviews[item.index].sizeThatFits(.unspecified)
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [(index: Int, x: CGFloat)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line()]
        var x: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let space = subviews[index][TrailingSpace.self]
            if x > 0, x + size.width > width {
                lines.append(Line())
                x = 0
            }
            lines[lines.count - 1].items.append((index, x))
            lines[lines.count - 1].width = x + size.width
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, size.height)
            x += size.width + space
        }
        return lines
    }
}
