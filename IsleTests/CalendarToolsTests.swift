//
//  CalendarToolsTests.swift
//  IsleTests
//

import Foundation
import MCP
import Testing
@testable import Isle

struct CalendarToolsTests {
    @Test func exposesExpectedToolNames() {
        #expect(Set(CalendarTools.tools.map(\.name)) == [
            "list_calendars",
            "list_events",
            "get_event",
            "create_event",
            "edit_event",
        ])
        #expect(CalendarTools.toolNames == Set(CalendarTools.tools.map(\.name)))
    }

    @Test func recurrenceInputDecodesSchemaFieldNames() throws {
        let data = Data("""
        {"frequency":"weekly","interval":2,"end_date":"2026-12-31T00:00:00Z"}
        """.utf8)
        let recurrence = try JSONDecoder().decode(CalendarRecurrenceInput.self, from: data)
        #expect(recurrence.frequency == "weekly")
        #expect(recurrence.interval == 2)
        #expect(recurrence.endDate == "2026-12-31T00:00:00Z")
    }
}
