//
//  CalendarTools.swift
//  Isle
//

import EventKit
import Foundation
import MCP

nonisolated struct CalendarTools: Sendable {
    let service: CalendarService

    static let toolNames: Set<String> = Set(tools.map(\.name))

    static let tools: [Tool] = [
        Tool(
            name: "list_calendars",
            description: "List calendars available in Calendar, including their ids and whether they can be changed.",
            inputSchema: ["type": "object", "properties": [:]]),
        Tool(
            name: "list_events",
            description: "List calendar events in a bounded time range. Defaults to now through the next seven days; use ISO 8601 dates and list_calendars to find a calendar id.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "start_date": ["type": "string", "description": "Optional ISO 8601 range start; defaults to now."],
                    "end_date": ["type": "string", "description": "Optional ISO 8601 range end; defaults to seven days after start_date."],
                    "calendar": ["type": "string", "description": "Optional calendar id or unambiguous calendar name."],
                    "query": ["type": "string", "description": "Optional text to match in event titles, locations, or notes."],
                    "limit": ["type": "integer", "description": "Maximum results, 1-200 (default 50)."],
                ],
            ]),
        Tool(
            name: "get_event",
            description: "Get one calendar event's full details by its id. For a repeating event, this returns the first occurrence.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "An event id returned by list_events."]],
                "required": ["id"],
            ]),
        Tool(
            name: "create_event",
            description: "Create a calendar event. It is saved immediately, without a confirmation step.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Event title."],
                    "start_date": ["type": "string", "description": "Start in ISO 8601, e.g. 2026-07-05T09:00:00Z."],
                    "end_date": ["type": "string", "description": "End in ISO 8601; must be after start_date."],
                    "calendar": ["type": "string", "description": "Optional writable calendar id or unambiguous name; defaults to Calendar's default."],
                    "location": ["type": "string", "description": "Optional location."],
                    "notes": ["type": "string", "description": "Optional notes."],
                    "url": ["type": "string", "description": "Optional associated URL."],
                    "all_day": ["type": "boolean", "description": "Whether this is an all-day event (default false)."],
                    "alert_minutes_before": ["type": "integer", "description": "Optional alert offset in minutes before the event."],
                    "recurrence": .object(recurrenceSchema),
                ],
                "required": ["title", "start_date", "end_date"],
            ]),
        Tool(
            name: "edit_event",
            description: "Edit an existing calendar event. Only supplied fields change; empty location, notes, or url clears that field. Repeating events default to changing this occurrence only.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "An event id returned by list_events."],
                    "title": ["type": "string", "description": "New title."],
                    "start_date": ["type": "string", "description": "New start in ISO 8601."],
                    "end_date": ["type": "string", "description": "New end in ISO 8601."],
                    "calendar": ["type": "string", "description": "New writable calendar id or unambiguous name."],
                    "location": ["type": "string", "description": "New location; use an empty string to clear."],
                    "notes": ["type": "string", "description": "New notes; use an empty string to clear."],
                    "url": ["type": "string", "description": "New URL; use an empty string to clear."],
                    "all_day": ["type": "boolean", "description": "Whether this is an all-day event."],
                    "alert_minutes_before": ["type": "integer", "description": "Replace existing alerts with one alert this many minutes before."],
                    "recurrence": .object(recurrenceSchema),
                    "clear_recurrence": ["type": "boolean", "description": "Remove the event's recurrence rule (default false)."],
                    "span": ["type": "string", "enum": ["this_event", "future_events"], "description": "For repeating events: change only this occurrence (default) or this and all future occurrences."],
                ],
                "required": ["id"],
            ]),
    ]

    private static let recurrenceSchema: [String: Value] = [
        "type": "object",
        "description": "Optional simple recurrence rule.",
        "properties": [
            "frequency": ["type": "string", "enum": ["daily", "weekly", "monthly", "yearly"]],
            "interval": ["type": "integer", "description": "Repeat every N units; defaults to 1."],
            "end_date": ["type": "string", "description": "Optional ISO 8601 date after which recurrence ends."],
        ],
        "required": ["frequency"],
    ]

    func call(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        #if os(macOS)
        let start = Date()
        let result = await dispatch(name: name, arguments: arguments)
        let chars = result.content.reduce(0) { total, item in
            if case let .text(text, _, _) = item { return total + text.count }
            return total
        }
        await Log.tool(name: name, arguments: Self.jsonObject(arguments),
                       isError: result.isError == true, resultChars: chars,
                       durationMs: Int(Date().timeIntervalSince(start) * 1000))
        return result
        #else
        return await dispatch(name: name, arguments: arguments)
        #endif
    }

    private func dispatch(name: String, arguments: [String: Value]?) async -> CallTool.Result {
        do {
            switch name {
            case "list_calendars":
                return Self.json(try await service.calendars())
            case "list_events":
                return Self.json(try await service.list(
                    startDate: arguments?["start_date"]?.stringValue,
                    endDate: arguments?["end_date"]?.stringValue,
                    calendar: arguments?["calendar"]?.stringValue,
                    query: arguments?["query"]?.stringValue,
                    limit: arguments?["limit"]?.intValue ?? 50))
            case "get_event":
                guard let id = arguments?["id"]?.stringValue else { return Self.error("Missing required argument: id") }
                return Self.json(try await service.get(id: id))
            case "create_event":
                guard let title = arguments?["title"]?.stringValue else { return Self.error("Missing required argument: title") }
                guard let startDate = arguments?["start_date"]?.stringValue else { return Self.error("Missing required argument: start_date") }
                guard let endDate = arguments?["end_date"]?.stringValue else { return Self.error("Missing required argument: end_date") }
                return Self.json(try await service.create(
                    title: title, startDate: startDate, endDate: endDate,
                    calendar: arguments?["calendar"]?.stringValue,
                    location: arguments?["location"]?.stringValue,
                    notes: arguments?["notes"]?.stringValue,
                    url: arguments?["url"]?.stringValue,
                    allDay: arguments?["all_day"]?.boolValue ?? false,
                    alertMinutesBefore: arguments?["alert_minutes_before"]?.intValue,
                    recurrence: try Self.recurrence(from: arguments?["recurrence"])))
            case "edit_event":
                guard let id = arguments?["id"]?.stringValue else { return Self.error("Missing required argument: id") }
                let span: EKSpan = arguments?["span"]?.stringValue == "future_events" ? .futureEvents : .thisEvent
                return Self.json(try await service.edit(
                    id: id,
                    title: arguments?["title"]?.stringValue,
                    startDate: arguments?["start_date"]?.stringValue,
                    endDate: arguments?["end_date"]?.stringValue,
                    calendar: arguments?["calendar"]?.stringValue,
                    location: arguments?["location"]?.stringValue,
                    notes: arguments?["notes"]?.stringValue,
                    url: arguments?["url"]?.stringValue,
                    allDay: arguments?["all_day"]?.boolValue,
                    alertMinutesBefore: arguments?["alert_minutes_before"]?.intValue,
                    recurrence: try Self.recurrence(from: arguments?["recurrence"]),
                    clearRecurrence: arguments?["clear_recurrence"]?.boolValue ?? false,
                    span: span))
            default:
                return Self.error("Unknown tool: \(name)")
            }
        } catch {
            return Self.error((error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    private static func recurrence(from value: Value?) throws -> CalendarRecurrenceInput? {
        guard let value else { return nil }
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(CalendarRecurrenceInput.self, from: data)
    }

    private static func jsonObject(_ arguments: [String: Value]?) -> Any {
        guard let arguments, !arguments.isEmpty,
              let data = try? JSONEncoder().encode(arguments),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [String: Any]() }
        return object
    }

    private static func text(_ string: String, isError: Bool = false) -> CallTool.Result {
        .init(content: [.text(text: string, annotations: nil, _meta: nil)], isError: isError)
    }

    private static func error(_ message: String) -> CallTool.Result {
        text(message, isError: true)
    }

    private static func json<T: Encodable>(_ value: T) -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value), let string = String(data: data, encoding: .utf8) else {
            return error("Failed to encode result.")
        }
        return text(string)
    }
}
