import SwiftUI

/// Renders a reply's Markdown: paragraphs, headings, bullet and numbered lists, tables,
/// and fenced code blocks, with inline styling (bold, italics, code, links) inside each block.
/// Deliberately small; unknown syntax falls through as plain paragraph text.
struct MarkdownText: View {
    private let blocks: [MarkdownBlock]
    init(_ text: String) { blocks = MarkdownBlock.parse(text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                block(blocks[index])
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func block(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text))
        case .heading(let level, let text):
            Text(Self.inline(text)).font(.system(size: level == 1 ? 17 : 15.5, weight: .semibold))
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items.indices, id: \.self) { index in
                    let item = items[index]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker).foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.inline(item.text))
                    }
                    .padding(.leading, CGFloat(item.depth) * 16 + 4)
                }
            }
        case .table(let table):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        Text(Self.inline(table.header[column]))
                            .fontWeight(.semibold)
                            .gridColumnAlignment(table.alignments[column])
                    }
                }
                ForEach(table.rows.indices, id: \.self) { row in
                    Divider().opacity(row == 0 ? 1 : 0.5)
                    GridRow {
                        ForEach(table.header.indices, id: \.self) { column in
                            Text(Self.inline(column < table.rows[row].count ? table.rows[row][column] : ""))
                        }
                    }
                }
            }
            .font(.system(size: 13.5))
            .lineSpacing(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 10))
        case .code(let code):
            Text(code)
                .font(.system(size: 12.5, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.07), in: .rect(cornerRadius: 10))
        }
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        var marker: String
        var text: String
        var depth: Int
    }

    struct Table: Equatable {
        var header: [String]
        var alignments: [HorizontalAlignment]
        var rows: [[String]]
    }

    case paragraph(String)
    case heading(level: Int, String)
    case list([ListItem])
    case table(Table)
    case code(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [ListItem] = []
        var code: [String]?   // non-nil while inside a ``` fence
        var table: Table?     // non-nil after a header row and its |---| separator

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !items.isEmpty { blocks.append(.list(items)); items = [] }
            if let done = table { blocks.append(.table(done)); table = nil }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code!.append(line); continue }

            if table != nil, trimmed.contains("|") {
                table!.rows.append(cells(trimmed))
                continue
            }
            if let alignments = separatorAlignments(trimmed), let header = paragraph.last, header.contains("|"),
               cells(header).count == alignments.count {
                paragraph.removeLast()
                flush()
                table = Table(header: cells(header), alignments: alignments, rows: [])
                continue
            }
            if table != nil { flush() }

            if trimmed.isEmpty {
                flush()
            } else if let heading = heading(trimmed) {
                flush()
                blocks.append(heading)
            } else if let item = listItem(line) {
                if !paragraph.isEmpty { flush() }
                items.append(item)
            } else if !items.isEmpty, line.first == " " {
                items[items.count - 1].text += " " + trimmed   // wrapped list item
            } else {
                if !items.isEmpty { flush() }
                paragraph.append(line)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) } // unterminated while streaming
        flush()
        return blocks
    }

    /// `| a | b |` → ["a", "b"]. Escaped pipes (`\|`) stay in the cell.
    private static func cells(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }
        return row.replacingOccurrences(of: "\\|", with: "\u{0}")
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\u{0}", with: "|").trimmingCharacters(in: .whitespaces) }
    }

    /// For a `|:---|:-:|--:|` row, the column alignments; nil for any other line.
    private static func separatorAlignments(_ line: String) -> [HorizontalAlignment]? {
        guard line.contains("-"), line.allSatisfy({ "|:- ".contains($0) }) else { return nil }
        let columns = cells(line)
        guard !columns.isEmpty, columns.allSatisfy({ $0.contains("-") }) else { return nil }
        return columns.map { cell in
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): .center
            case (false, true): .trailing
            default: .leading
            }
        }
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, String(line.dropFirst(hashes + 1)))
    }

    private static func listItem(_ line: String) -> ListItem? {
        let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count
        let rest = line.dropFirst(indent)
        let depth = min(indent / 2, 3)
        if let first = rest.first, "-*+•".contains(first), rest.dropFirst().first == " " {
            return ListItem(marker: "•", text: String(rest.dropFirst(2)), depth: depth)
        }
        let digits = rest.prefix(while: \.isNumber)
        let after = rest.dropFirst(digits.count)
        if !digits.isEmpty, digits.count <= 3, let dot = after.first, ".)".contains(dot), after.dropFirst().first == " " {
            return ListItem(marker: "\(digits).", text: String(after.dropFirst(2)), depth: depth)
        }
        return nil
    }
}
