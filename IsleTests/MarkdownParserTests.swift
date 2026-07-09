//
//  MarkdownParserTests.swift
//  IsleTests
//

import Foundation
import Testing
@testable import Isle

@MainActor
struct MarkdownParserTests {
    @Test func parsesGFMTableWithAlignmentsAndInlineContent() throws {
        let blocks = MarkdownParser.parse("""
            | Name | Score | Note |
            | :--- | ---: | :---: |
            | **Isle** | 42 | `ready` |
            """)

        let parsedTable = try #require(table(in: blocks))
        #expect(parsedTable.header.count == 3)
        #expect(parsedTable.rows.count == 1)
        #expect(parsedTable.alignments.count == 3)
        #expect(parsedTable.alignments[0] == .left)
        #expect(parsedTable.alignments[1] == .right)
        #expect(parsedTable.alignments[2] == .center)
        #expect(String(parsedTable.header[0].characters) == "Name")
        #expect(String(parsedTable.rows[0][0].characters) == "Isle")
        #expect(String(parsedTable.rows[0][2].characters) == "ready")
    }

    @Test func padsShortRowsAndTruncatesLongRows() throws {
        let blocks = MarkdownParser.parse("""
            A | B
            --- | ---
            one |
            two | three | ignored
            """)

        let parsedTable = try #require(table(in: blocks))
        #expect(parsedTable.rows.count == 2)
        #expect(parsedTable.rows.allSatisfy { $0.count == 2 })
        #expect(String(parsedTable.rows[0][0].characters) == "")
        #expect(String(parsedTable.rows[1][0].characters) == "two")
        #expect(String(parsedTable.rows[1][1].characters) == "three")
    }

    @Test func leavesPipeProseAsParagraph() {
        let blocks = MarkdownParser.parse("a | b\nnot a delimiter")
        guard case .paragraph = blocks.first?.kind else {
            Issue.record("Expected pipe prose to remain a paragraph")
            return
        }
    }

    @Test func supportsEscapedPipesInCells() throws {
        let blocks = MarkdownParser.parse("""
            Key | Value
            --- | ---
            path | a\\|b
            """)

        let parsedTable = try #require(table(in: blocks))
        #expect(String(parsedTable.rows[0][1].characters) == "a|b")
    }

    private func table(in blocks: [MarkdownBlock]) -> MarkdownBlock.Table? {
        for block in blocks {
            if case .table(let table) = block.kind { return table }
        }
        return nil
    }
}
