//
//  MarkdownText.swift
//  Isle
//

import SwiftUI

/// Renders a Codex answer as styled markdown. Codex replies in markdown — bold,
/// inline code, fenced code blocks, bullet/numbered lists, headings — and the
/// pill used to show that syntax raw. SwiftUI's `AttributedString(markdown:)`
/// only styles *inline* spans (it flattens block structure), so this view does a
/// light block parse itself and renders each block, deferring inline styling
/// (`**bold**`, `` `code` ``, `[links](…)`) to `AttributedString` per block.
///
/// Deliberately a pragmatic subset, not a full CommonMark engine: spoken Q&A
/// answers are short, and a self-contained file avoids the manual `pbxproj`
/// edits an SPM markdown dependency would need here.
struct MarkdownText: View {
    let markdown: String
    var textColor: Color = .white
    var tableStyle: TableStyle = .default

    private static let baseFont = Font.system(size: 14, weight: .regular, design: .rounded)

    struct TableStyle {
        var cornerRadius: CGFloat = 6
        var borderOpacity: Double = 0.17
        var dividerOpacity: Double = 0.10
        var headerBackgroundOpacity: Double = 0.10
        var headerTextOpacity: Double = 0.65
        var headerFontSize: CGFloat = 12
        var cellMinWidth: CGFloat = 86
        var cellHorizontalPadding: CGFloat = 8
        var cellVerticalPadding: CGFloat = 6

        static let `default` = Self()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownParser.parse(
                markdown,
                inlineCodeBackground: textColor.opacity(0.12)
            )) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level, let content):
            Text(content)
                .font(.system(size: headingSize(level), weight: .semibold, design: .rounded))
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .paragraph(let content):
            Text(content)
                .font(Self.baseFont)
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bulletList(let items):
            listView(items.map { ("•", $0) })

        case .numberedList(let items):
            listView(items.map { ("\($0.number).", $0.content) })

        case .table(let table):
            tableView(table)

        case .codeBlock(let code):
            codeBlockView(code)

        case .quote(let content):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(textColor.opacity(0.3))
                    .frame(width: 3)
                Text(content)
                    .font(Self.baseFont)
                    .foregroundStyle(textColor.opacity(0.8))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .rule:
            Rectangle()
                .fill(textColor.opacity(0.2))
                .frame(height: 1)
                .padding(.vertical, 2)
        }
    }

    private func listView(_ rows: [(marker: String, content: AttributedString)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(row.marker)
                        .font(Self.baseFont)
                        .foregroundStyle(textColor.opacity(0.6))
                        .frame(minWidth: 14, alignment: .trailing)
                    Text(row.content)
                        .font(Self.baseFont)
                        .foregroundStyle(textColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func codeBlockView(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                .foregroundStyle(textColor.opacity(0.92))
                .textSelection(.enabled)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
        }
        .background(textColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableView(_ table: MarkdownBlock.Table) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                tableRow(
                    table.header,
                    alignments: table.alignments,
                    isHeader: true,
                    isLastRow: table.rows.isEmpty
                )
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    tableRow(
                        row,
                        alignments: table.alignments,
                        isHeader: false,
                        isLastRow: index == table.rows.count - 1
                    )
                }
            }
            .background(textColor.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: tableStyle.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: tableStyle.cornerRadius, style: .continuous)
                    .stroke(textColor.opacity(tableStyle.borderOpacity), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tableRow(
        _ cells: [AttributedString],
        alignments: [MarkdownBlock.TableAlignment],
        isHeader: Bool,
        isLastRow: Bool
    ) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                Text(cell)
                    .font(isHeader
                        ? .system(size: tableStyle.headerFontSize, weight: .regular, design: .rounded)
                        : Self.baseFont)
                    .foregroundStyle(isHeader ? textColor.opacity(tableStyle.headerTextOpacity) : textColor)
                    .multilineTextAlignment(textAlignment(alignments[index]))
                    .frame(minWidth: tableStyle.cellMinWidth, maxWidth: .infinity, alignment: frameAlignment(alignments[index]))
                    .padding(.horizontal, tableStyle.cellHorizontalPadding)
                    .padding(.vertical, tableStyle.cellVerticalPadding)
                    .background(isHeader ? textColor.opacity(tableStyle.headerBackgroundOpacity) : .clear)
                    .overlay(alignment: .trailing) {
                        if index < cells.count - 1 {
                            Rectangle().fill(textColor.opacity(tableStyle.dividerOpacity)).frame(width: 1)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if !isLastRow {
                            Rectangle().fill(textColor.opacity(tableStyle.dividerOpacity)).frame(height: 1)
                        }
                    }
            }
        }
    }

    private func textAlignment(_ alignment: MarkdownBlock.TableAlignment) -> TextAlignment {
        switch alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    private func frameAlignment(_ alignment: MarkdownBlock.TableAlignment) -> Alignment {
        switch alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 19
        case 2: 17
        default: 15
        }
    }
}

/// One parsed markdown block. Inline styling is already baked into the
/// `AttributedString` payloads; only block layout is left to the view.
struct MarkdownBlock: Identifiable {
    let id: Int
    let kind: Kind

    struct NumberedItem {
        let number: Int
        let content: AttributedString
    }

    enum TableAlignment: Equatable {
        case left
        case center
        case right
    }

    struct Table {
        let header: [AttributedString]
        let alignments: [TableAlignment]
        let rows: [[AttributedString]]
    }

    enum Kind {
        case heading(level: Int, AttributedString)
        case paragraph(AttributedString)
        case bulletList([AttributedString])
        case numberedList([NumberedItem])
        case table(Table)
        case codeBlock(String)
        case quote(AttributedString)
        case rule
    }
}

/// A minimal, line-oriented markdown block splitter. Handles the constructs that
/// actually show up in Codex answers; anything it doesn't recognize falls
/// through to a paragraph, so unknown syntax degrades to plain (inline-styled)
/// text rather than breaking.
enum MarkdownParser {
    static func parse(
        _ text: String,
        inlineCodeBackground: Color = .white.opacity(0.12)
    ) -> [MarkdownBlock] {
        func inline(_ string: String) -> AttributedString {
            styledInline(string, background: inlineCodeBackground)
        }

        var blocks: [MarkdownBlock] = []
        var counter = 0
        func emit(_ kind: MarkdownBlock.Kind) {
            blocks.append(MarkdownBlock(id: counter, kind: kind))
            counter += 1
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var paragraph: [String] = []
        func flushParagraph() {
            let joined = paragraph.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { emit(.paragraph(inline(joined))) }
            paragraph = []
        }

        var i = 0
        while i < lines.count {
            let raw = lines[i]
            let line = raw.trimmingCharacters(in: .whitespaces)

            // Fenced code block: capture verbatim until the closing fence.
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(line.prefix(3))
                var code: [String] = []
                i += 1
                while i < lines.count,
                      !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                i += 1  // consume the closing fence (or end of input)
                emit(.codeBlock(code.joined(separator: "\n")))
                continue
            }

            if line.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Horizontal rule: a line of only ---, ***, or ___.
            if isRule(line) {
                flushParagraph()
                emit(.rule)
                i += 1
                continue
            }

            // ATX heading: # … ######
            if let heading = parseHeading(line) {
                flushParagraph()
                emit(.heading(level: heading.level, inline(heading.text)))
                i += 1
                continue
            }

            // GFM pipe table: header row followed immediately by a delimiter row.
            if i + 1 < lines.count,
               let header = tableCells(line),
               let alignments = tableAlignments(lines[i + 1].trimmingCharacters(in: .whitespaces)),
               header.count == alignments.count {
                flushParagraph()
                var rows: [[AttributedString]] = []
                i += 2
                while i < lines.count,
                      let cells = tableCells(lines[i].trimmingCharacters(in: .whitespaces)) {
                    rows.append(normalizeTableRow(cells, columnCount: header.count).map { inline($0) })
                    i += 1
                }
                emit(.table(.init(
                    header: header.map { inline($0) },
                    alignments: alignments,
                    rows: rows
                )))
                continue
            }

            // Bullet list: -, *, or + followed by a space. Consume the run.
            if bulletContent(line) != nil {
                flushParagraph()
                var items: [AttributedString] = []
                while i < lines.count,
                      let content = bulletContent(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(inline(content))
                    i += 1
                }
                emit(.bulletList(items))
                continue
            }

            // Numbered list: 1. or 1) followed by a space.
            if numberedContent(line) != nil {
                flushParagraph()
                var items: [MarkdownBlock.NumberedItem] = []
                while i < lines.count,
                      let parsed = numberedContent(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(.init(number: parsed.number, content: inline(parsed.text)))
                    i += 1
                }
                emit(.numberedList(items))
                continue
            }

            // Blockquote: one or more leading '>' lines.
            if line.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let q = lines[i].trimmingCharacters(in: .whitespaces)
                    guard q.hasPrefix(">") else { break }
                    quoted.append(String(q.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                emit(.quote(inline(quoted.joined(separator: " "))))
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    /// Parse inline markdown (`**bold**`, `*italic*`, `` `code` ``, links) into a
    /// styled `AttributedString`. SwiftUI's `Text` honors the resulting
    /// `inlinePresentationIntent` runs, so bold/italic/code render without us
    /// touching fonts. Inline code spans also get a faint background.
    private static func styledInline(
        _ string: String,
        background: Color
    ) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: string, options: options) else {
            return AttributedString(string)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].backgroundColor = background
        }
        return attributed
    }

    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }
        let level = hashes.count
        guard level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func bulletContent(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedContent(_ line: String) -> (number: Int, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        guard let separator = afterDigits.first, separator == "." || separator == ")" else { return nil }
        let rest = afterDigits.dropFirst()
        guard rest.first == " " else { return nil }
        return (number, rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isRule(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" } || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    /// Splits a GFM table row, allowing optional outer pipes and escaped pipes
    /// within a cell. Requiring an unescaped separator keeps ordinary prose out
    /// of the table parser.
    private static func tableCells(_ line: String) -> [String]? {
        var cells: [String] = []
        var cell = ""
        var sawSeparator = false
        var escaping = false

        for character in line {
            if escaping {
                if character == "|" {
                    cell.append(character)
                } else {
                    cell.append("\\")
                    cell.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                sawSeparator = true
            } else {
                cell.append(character)
            }
        }
        if escaping { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))

        guard sawSeparator else { return nil }
        if line.first == "|" { cells.removeFirst() }
        if line.last == "|" { cells.removeLast() }
        return cells
    }

    private static func tableAlignments(_ line: String) -> [MarkdownBlock.TableAlignment]? {
        guard let cells = tableCells(line), !cells.isEmpty else { return nil }
        var alignments: [MarkdownBlock.TableAlignment] = []
        for cell in cells {
            let startsWithColon = cell.hasPrefix(":")
            let endsWithColon = cell.hasSuffix(":")
            let colonCount = (startsWithColon ? 1 : 0) + (endsWithColon ? 1 : 0)
            guard cell.count >= colonCount + 2 else { return nil }

            var dashes = cell
            if startsWithColon { dashes.removeFirst() }
            if endsWithColon { dashes.removeLast() }
            guard dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(startsWithColon && endsWithColon ? .center : endsWithColon ? .right : .left)
        }
        return alignments
    }

    private static func normalizeTableRow(_ cells: [String], columnCount: Int) -> [String] {
        Array(cells.prefix(columnCount))
            + Array(repeating: "", count: max(0, columnCount - cells.count))
    }
}
