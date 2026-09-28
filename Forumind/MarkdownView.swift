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
    @State private var rendered: Rendered?

    private struct Rendered {
        var source: String
        var document: MarkdownDocument
        var parsedAt: Date
    }

    private static let throttle: TimeInterval = 0.12

    init(_ source: String) {
        self.source = source
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
                MarkdownBlockView(block: block)
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
            MarkdownInline.text(text)
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
                    MarkdownInline.text(item)
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

