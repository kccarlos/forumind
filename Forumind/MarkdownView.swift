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

/// One lazy-renderable unit of a Markdown document: a standalone block, or a
/// single item of a list so long lists lay out item by item in a `LazyVStack`.
struct MarkdownRow: Equatable {
    enum Content: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case listItem(number: Int?, text: String)
        case quote(String)
        case code(language: String?, content: String)
        case table(headers: [String], rows: [[String]])
        case rule
    }

    let content: Content
    var topSpacing: CGFloat

    static func rows(
        from blocks: [MarkdownBlock],
        initialTopSpacing: CGFloat = 0,
        stackSpacing: CGFloat = 0
    ) -> [MarkdownRow] {
        var rows: [MarkdownRow] = []
        for block in blocks {
            let blockSpacing: CGFloat = rows.isEmpty ? initialTopSpacing : 12 - stackSpacing
            switch block {
            case .heading(let level, let text):
                rows.append(MarkdownRow(content: .heading(level: level, text: text), topSpacing: blockSpacing))
            case .paragraph(let text):
                rows.append(MarkdownRow(content: .paragraph(text), topSpacing: blockSpacing))
            case .unorderedList(let items), .orderedList(let items):
                let ordered = if case .orderedList = block { true } else { false }
                for (index, item) in items.enumerated() {
                    rows.append(MarkdownRow(
                        content: .listItem(number: ordered ? index + 1 : nil, text: item),
                        topSpacing: index == 0 ? blockSpacing : 8 - stackSpacing
                    ))
                }
            case .quote(let text):
                rows.append(MarkdownRow(content: .quote(text), topSpacing: blockSpacing))
            case .code(let language, let content):
                rows.append(MarkdownRow(content: .code(language: language, content: content), topSpacing: blockSpacing))
            case .table(let headers, let tableRows):
                rows.append(MarkdownRow(content: .table(headers: headers, rows: tableRows), topSpacing: blockSpacing))
            case .rule:
                rows.append(MarkdownRow(content: .rule, topSpacing: blockSpacing))
            }
        }
        return rows
    }

    /// Flattens Markdown sections separated by `sectionSpacing` (14 pt).
    static func rows(
        fromSections sections: [String],
        initialTopSpacing: CGFloat = 0,
        sectionSpacing: CGFloat = 14,
        stackSpacing: CGFloat = 0
    ) -> [MarkdownRow] {
        var result: [MarkdownRow] = []
        for section in sections {
            var rows = MarkdownCache.rows(for: section)
            guard !rows.isEmpty else { continue }
            for index in rows.indices {
                rows[index].topSpacing = index == 0
                    ? (result.isEmpty ? initialTopSpacing : sectionSpacing - stackSpacing)
                    : rows[index].topSpacing - stackSpacing
            }
            result.append(contentsOf: rows)
        }
        return result
    }
}

/// Parsed documents by source, so re-rendering the same text does not parse
/// it again (summaries and chat bubbles re-render while other text streams).
private enum MarkdownCache {
    private static let cache: NSCache<NSString, NSArray> = {
        let cache = NSCache<NSString, NSArray>()
        cache.countLimit = 96
        return cache
    }()

    static func rows(for source: String) -> [MarkdownRow] {
        let key = source as NSString
        if let cached = cache.object(forKey: key) as? [MarkdownRow] { return cached }
        let rows = MarkdownRow.rows(from: MarkdownParser.parse(source))
        cache.setObject(rows as NSArray, forKey: key)
        return rows
    }
}

/// Re-parses streaming Markdown at most every `MarkdownView.throttle` seconds,
/// rendering the first parse immediately and holding the previous output between ticks.
struct ThrottledParse<Input: Equatable, Output> {
    var input: Input
    var output: Output
    var parsedAt: Date

    static func refreshed(
        from previous: Self?,
        to target: Input,
        parse: (Input) -> Output
    ) async -> Self? {
        if let previous {
            guard previous.input != target else { return previous }
            let elapsed = Date().timeIntervalSince(previous.parsedAt)
            if elapsed < MarkdownView.throttle {
                try? await Task.sleep(for: .seconds(MarkdownView.throttle - elapsed))
                if Task.isCancelled { return nil }
            }
        }
        return Self(input: target, output: parse(target), parsedAt: Date())
    }
}

/// Scrolls with a brief animation, then re-applies without animation across
/// layout passes while lazy Markdown rows materialize along the way.
@MainActor
func settleScroll(
    animated: Bool = true,
    reduceMotion: Bool = false,
    onSettling: @MainActor () -> Void = {},
    shouldStop: @MainActor () -> Bool = { false },
    scroll: @MainActor () -> Void
) async {
    if animated {
        withAnimation(.easeOut(duration: reduceMotion ? 0.04 : 0.16)) { scroll() }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 50 : 180))
    }
    if Task.isCancelled || shouldStop() { return }
    onSettling()
    var transaction = Transaction()
    transaction.disablesAnimations = true
    for _ in 0..<24 {
        if Task.isCancelled || shouldStop() { return }
        withTransaction(transaction) { scroll() }
        try? await Task.sleep(for: .milliseconds(14))
    }
}

@available(iOS 18.0, *)
private struct BottomEdgeScrollModifier: ViewModifier {
    private struct BottomState: Equatable {
        var contentHeight: Int
        var nearBottom: Bool
    }

    let trigger: Int
    let reduceMotion: Bool
    @State private var position = ScrollPosition(edge: .top)
    @State private var scrolling = false
    @State private var following = false

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating {
                    scrolling = true
                    following = false
                } else if scrolling {
                    scrolling = false
                }
            }
            .onScrollGeometryChange(for: BottomState.self) { geometry in
                BottomState(
                    contentHeight: Int(geometry.contentSize.height.rounded()),
                    nearBottom: geometry.contentSize.height - geometry.visibleRect.maxY < 48
                )
            } action: { old, new in
                guard following, !scrolling, !new.nearBottom else { return }
                if new.contentHeight > old.contentHeight {
                    snapToBottom()
                    DispatchQueue.main.async {
                        if following, !scrolling { snapToBottom() }
                    }
                } else if old.nearBottom {
                    following = false
                }
            }
            .task(id: trigger) {
                guard trigger > 0 else {
                    following = false
                    return
                }
                scrolling = false
                following = false
                await settleScroll(
                    reduceMotion: reduceMotion,
                    onSettling: { following = true },
                    shouldStop: { scrolling }
                ) {
                    position.scrollTo(edge: .bottom)
                }
            }
    }

    private func snapToBottom() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(edge: .bottom) }
    }
}

extension View {
    @ViewBuilder
    func scrollToBottomEdge(trigger: Int, reduceMotion: Bool) -> some View {
        if #available(iOS 18.0, *) {
            modifier(BottomEdgeScrollModifier(trigger: trigger, reduceMotion: reduceMotion))
        } else {
            self
        }
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
    @State private var rendered: ThrottledParse<String, [MarkdownRow]>?

    static let throttle: TimeInterval = 0.12
    /// Short documents stay eager so scroll offsets and nested bubbles have
    /// exact heights; long documents use `LazyVStack`.
    static let lazyRowThreshold = 100

    init(_ source: String, citations: Bool = false) {
        self.source = source
        self.citations = citations
    }

    private var rows: [MarkdownRow] {
        guard !source.isEmpty else { return [] }
        if let rendered, rendered.input == source || !rendered.output.isEmpty {
            return rendered.output
        }
        return MarkdownCache.rows(for: source)
    }

    var body: some View {
        let currentRows = rows
        Group {
            if currentRows.count >= Self.lazyRowThreshold {
                LazyVStack(alignment: .leading, spacing: 0) {
                    rowViews(currentRows)
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    rowViews(currentRows)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            if let updated = await ThrottledParse.refreshed(from: rendered, to: source, parse: MarkdownCache.rows) {
                rendered = updated
            }
        }
    }

    private func rowViews(_ rows: [MarkdownRow]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            MarkdownBlockView(row: row, citations: citations)
                .equatable()
        }
    }
}

#if DEBUG
enum MarkdownLayoutProbe {
    nonisolated(unsafe) static var blockBodies = 0
    nonisolated(unsafe) static var citationLayouts = 0
    nonisolated(unsafe) static var textViews = 0

    static func reset() {
        blockBodies = 0
        citationLayouts = 0
        textViews = 0
    }
}
#endif

/// One block or list item; Equatable so unchanged rows skip re-rendering while
/// the document around them streams.
struct MarkdownBlockView: View, Equatable {
    let row: MarkdownRow
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
        #if DEBUG
        let _ = { MarkdownLayoutProbe.blockBodies += 1 }()
        #endif
        content
            .padding(.top, row.topSpacing)
    }

    @ViewBuilder
    private var content: some View {
        switch row.content {
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
        case .listItem(let number, let text):
            let ordered = number != nil
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: number.map { "\($0)." } ?? "•")
                    .font(ordered ? .body.weight(.semibold).monospacedDigit() : .body.weight(.heavy))
                    .foregroundStyle(DCTheme.brandBlue)
                    .frame(minWidth: ordered ? 20 : 12, alignment: ordered ? .trailing : .center)
                    .accessibilityHidden(!ordered)
                inline(text)
                    .font(.body)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
    /// A pointer came over the citation chip for this post.
    @Entry var citationHover = CitationHoverAction()
}

struct CitationHoverAction {
    var action: (Int) -> Void = { _ in }

    @MainActor
    func callAsFunction(_ number: Int) { action(number) }
}

/// A paragraph with `#N` post citations, laid out as text runs between chips so
/// each chip can be a real button: about 28 pt to look at, 44 × 44 pt to tap, at
/// least 4 pt apart. VoiceOver reads the paragraph as one element, then the chips.
struct CitedText: View {
    let source: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var wordSpacing = 4
    @ScaledMetric(relativeTo: .body) private var widePull: CGFloat = 1.25
    @ScaledMetric(relativeTo: .footnote) private var narrowPull: CGFloat = 1

    private enum Token {
        case text(AttributedString, spaceAfter: Bool)
        /// A chip and the punctuation right after it ("#37."), which never
        /// wraps onto the next line alone.
        case citation(Int, suffix: AttributedString?, spaceAfter: Bool)
    }

    private func suffixSpacing(for suffix: AttributedString?) -> CGFloat {
        guard let first = suffix?.characters.first else { return 0 }
        return first.isWide ? -widePull : -narrowPull
    }

    static func accessibilityLabel(for source: String) -> String {
        plain(tokens(source))
    }

    #if DEBUG
    static func citationSuffixes(for source: String) -> [String?] {
        var suffixes: [String?] = []
        for token in tokens(source) {
            if case .citation(_, let suffix, _) = token {
                suffixes.append(suffix.map { String($0.characters) })
            }
        }
        return suffixes
    }
    #endif

    var body: some View {
        let tokens = Self.tokens(source)
        #if DEBUG
        let _ = { MarkdownLayoutProbe.textViews += tokens.count }()
        #endif
        CitationFlowLayout(lineSpacing: 4) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                switch token {
                case .text(let text, let spaceAfter):
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutValue(key: TrailingSpace.self, value: spaceAfter ? wordSpacing : 0)
                        .accessibilityHidden(true)
                case .citation(let number, let suffix, let spaceAfter):
                    HStack(spacing: suffixSpacing(for: suffix)) {
                        CitationChip(number: number, trailingPunctuation: suffix != nil)
                        if let suffix {
                            Text(suffix)
                                .fixedSize()
                                .offset(y: dynamicTypeSize.isAccessibilitySize ? -6 : 0)
                                .accessibilityHidden(true)
                        }
                    }
                    .frame(minWidth: 46, alignment: .leading)
                    // The expanded target overlaps adjacent text, including
                    // the next line. Words must not intercept a chip tap.
                    .zIndex(1)
                    .layoutValue(key: TrailingSpace.self, value: suffix == nil || spaceAfter ? wordSpacing : 0)
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

    /// Runs of text between chips (with their inline styling) and the chips.
    private static func tokens(_ source: String) -> [Token] {
        let value = MarkdownInline.attributed(source.replacingOccurrences(of: "\n", with: " "))
        var tokens: [Token] = []
        var pending = AttributedString()

        func flushPending() {
            let chars = pending.characters
            var start = chars.startIndex
            while start < chars.endIndex, chars[start].isWhitespace {
                start = chars.index(after: start)
            }
            var end = chars.endIndex
            while end > start {
                let prev = chars.index(before: end)
                guard chars[prev].isWhitespace else { break }
                end = prev
            }
            let hasTrailingSpace = end < chars.endIndex
            if start < end {
                tokens.append(.text(AttributedString(pending[start..<end]), spaceAfter: hasTrailingSpace))
            }
            pending = AttributedString()
        }

        for run in value.runs {
            if let url = run.link, let number = PostCitations.postNumber(from: url) {
                flushPending()
                tokens.append(.citation(number, suffix: nil, spaceAfter: true))
                continue
            }

            var slice = AttributedString(value[run.range])

            // Punctuation right after a chip ("#37 ." from the model, "#37.", or "#37）。"):
            // glued onto the chip so it stays on the chip's line.
            if pending.characters.isEmpty, case .citation(let number, let existing, let existingSpace) = tokens.last {
                let chars = slice.characters
                var index = chars.startIndex
                var sawLeadingSpace = false
                while index < chars.endIndex, chars[index].isWhitespace {
                    sawLeadingSpace = true
                    index = chars.index(after: index)
                }

                let punctStart = index
                var punctEnd = index
                if existing == nil || (!sawLeadingSpace && !existingSpace) {
                    while punctEnd < chars.endIndex,
                          chars[punctEnd].unicodeScalars.allSatisfy(\.isTrailingPunctuation) {
                        punctEnd = chars.index(after: punctEnd)
                    }
                }

                let endsAtBoundary = punctStart < punctEnd && (
                    punctEnd == chars.endIndex
                        || chars[punctEnd].isWhitespace
                        || chars[punctEnd].isWide
                        || chars[chars.index(before: punctEnd)].isWide
                )

                if endsAtBoundary {
                    var combined = existing ?? AttributedString()
                    combined.append(AttributedString(slice[punctStart..<punctEnd]))
                    var afterPunct = punctEnd
                    var spaceAfterPunct = false
                    while afterPunct < chars.endIndex, chars[afterPunct].isWhitespace {
                        spaceAfterPunct = true
                        afterPunct = chars.index(after: afterPunct)
                    }
                    tokens[tokens.count - 1] = .citation(
                        number,
                        suffix: combined,
                        spaceAfter: spaceAfterPunct
                    )
                    slice = AttributedString(slice[afterPunct..<chars.endIndex])
                } else {
                    if sawLeadingSpace, let existing {
                        tokens[tokens.count - 1] = .citation(
                            number,
                            suffix: existing,
                            spaceAfter: true
                        )
                    }
                    slice = AttributedString(slice[index..<chars.endIndex])
                }
            }

            if !slice.characters.isEmpty {
                pending.append(slice)
            }
        }

        flushPending()
        return tokens
    }
}

private extension Character {
    /// CJK and other scripts written without spaces.
    var isWide: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F: return true
        default: return false
        }
    }
}

private extension Unicode.Scalar {
    var isTrailingPunctuation: Bool {
        CharacterSet.punctuationCharacters.contains(self)
            && properties.generalCategory != .openPunctuation
            && properties.generalCategory != .initialPunctuation
    }
}

/// `#37`: tap to scroll the page to post 37 (AppModel.jumpToCitation).
struct CitationChip: View {
    let number: Int
    var trailingPunctuation = false
    @Environment(\.openURL) private var openURL
    @Environment(\.activeCitation) private var activeCitation
    @Environment(\.citationHover) private var citationHover

    private var isActive: Bool { activeCitation == number }

    var body: some View {
        Button {
            if let url = PostCitations.url(post: number) { openURL(url) }
        } label: {
            Text(verbatim: "#\(number)")
                .font(.footnote.weight(.bold).monospacedDigit())
                .fixedSize()
                .foregroundStyle(isActive ? Color.white : DCTheme.citationText)
                .padding(.horizontal, 8)
                .frame(minWidth: 36, minHeight: 28)
                .background(
                    isActive ? AnyShapeStyle(DCTheme.brandBlue) : AnyShapeStyle(DCTheme.postHighlightBackground),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                // At least 44 pt wide in the line so neighbouring hit areas
                // never overlap, and 44 pt high to tap
                // without taking more room between the lines. 46 pt: the
                // drawer's floating sheet is drawn about 4 % smaller at medium.
                .frame(minWidth: trailingPunctuation ? 36 : 46)
                .padding(.horizontal, trailingPunctuation ? 5 : 0)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
                .padding(.horizontal, trailingPunctuation ? -5 : 0)
                .padding(.vertical, -9)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .onHover { if $0 { citationHover(number) } }
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

    struct Item {
        var size: CGSize
        var space: CGFloat
    }

    func makeCache(subviews: Subviews) -> [Item] {
        subviews.map { Item(size: $0.sizeThatFits(.unspecified), space: $0[TrailingSpace.self]) }
    }

    func updateCache(_ cache: inout [Item], subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [Item]) -> CGSize {
        #if DEBUG
        MarkdownLayoutProbe.citationLayouts += 1
        #endif
        if cache.count != subviews.count { cache = makeCache(subviews: subviews) }
        let lines = arrange(width: proposal.width ?? .infinity, subviews: subviews, items: cache)
        let width = lines.map(\.width).max() ?? 0
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [Item]) {
        if cache.count != subviews.count { cache = makeCache(subviews: subviews) }
        var y = bounds.minY
        for line in arrange(width: bounds.width, subviews: subviews, items: cache) {
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: y + (line.height - item.size.height) / 2),
                    proposal: ProposedViewSize(
                        width: item.wrapped ? bounds.width : item.size.width,
                        height: item.size.height
                    )
                )
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var items: [(index: Int, x: CGFloat, size: CGSize, wrapped: Bool)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews, items: [Item]) -> [Line] {
        var lines: [Line] = [Line()]
        var x: CGFloat = 0
        for index in items.indices {
            let unwrapped = items[index].size
            let space = items[index].space
            if unwrapped.width > width {
                if x > 0 {
                    lines.append(Line())
                    x = 0
                }
                let wrappedSize = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
                lines[lines.count - 1].items.append((index, 0, wrappedSize, true))
                lines[lines.count - 1].width = wrappedSize.width
                lines[lines.count - 1].height = max(lines[lines.count - 1].height, wrappedSize.height)
                x = width + 1
            } else {
                if x > 0, x + unwrapped.width > width {
                    lines.append(Line())
                    x = 0
                }
                lines[lines.count - 1].items.append((index, x, unwrapped, false))
                lines[lines.count - 1].width = x + unwrapped.width
                lines[lines.count - 1].height = max(lines[lines.count - 1].height, unwrapped.height)
                x += unwrapped.width + space
            }
        }
        return lines
    }
}
