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

    private static let baseFont = Font.system(size: 14, weight: .regular, design: .rounded)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownParser.parse(markdown)) { block in
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

    enum Kind {
        case heading(level: Int, AttributedString)
        case paragraph(AttributedString)
        case bulletList([AttributedString])
        case numberedList([NumberedItem])
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
    static func parse(_ text: String) -> [MarkdownBlock] {
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
    private static func inline(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: string, options: options) else {
            return AttributedString(string)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].backgroundColor = .white.opacity(0.12)
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
}
